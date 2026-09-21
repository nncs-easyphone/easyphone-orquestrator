#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Regras de Firewall (iptables)
# Uso: sudo bash firewall-rules.sh
#
# Define regras de entrada para as portas do projeto usando
# uma chain dedicada (EASYPHONE_INPUT) para não interferir
# nas regras geridas pelo Docker.
#
# NOTA: FORWARD fica ACCEPT para não quebrar o roteamento de redes do Docker.
# IPv6 deve estar desabilitado no kernel; este script não configura ip6tables.
#
# ⚠️ NUNCA use `iptables -F` (nem `-F INPUT`) neste host. A INPUT termina em DROP
# e carrega o jump para a EASYPHONE_INPUT: esvaziá-la derruba SIP/RTP/AMI na hora,
# porque o Asterisk e o Coturn rodam em host networking e seu tráfego chega pela
# INPUT. Para mudar regras, edite este script e rode-o de novo — ele é
# idempotente e o único `-F` que executa é na sua própria chain.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
  error "Execute como root: sudo bash $0"
  exit 1
fi

# ── Porta de gestão (SSH) ─────────────────────────────────────────────
# Lida do .env ao lado deste script para valer também no boot
# (easyphone-firewall.service executa o script direto, sem carregar o .env).
# Fallback 22 quando ausente ou inválida. Aspas e \r (.env editado no Windows)
# são removidos: SSH_PORT="2244" caía no fallback e liberava a 22 no lugar da 2244.
REPO_DIR="$(dirname "$(readlink -f "$0")")"
SSH_PORT="$(grep -E '^SSH_PORT=' "$REPO_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d "[:space:]\"'" || true)"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  if [[ -n "$SSH_PORT" ]]; then
    warn "SSH_PORT inválida no .env ('$SSH_PORT') — usando 22."
  else
    warn "SSH_PORT ausente em $REPO_DIR/.env — usando 22."
  fi
  SSH_PORT=22
fi

# ── Salvaguarda anti-lockout ──────────────────────────────────────────
# Libera também as portas em que o sshd está CONFIGURADO para escutar
# (sshd -T resolve sshd_config + sshd_config.d e vale com socket activation).
# Sem isto, um SSH_PORT divergente do sshd bloqueia toda conexão nova: a sessão
# aberta sobrevive pelo ESTABLISHED e o problema só aparece quando ela cai.
SSHD_PORTS=()
if command -v sshd &>/dev/null; then
  mapfile -t SSHD_PORTS < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un)
fi
for p in "${SSHD_PORTS[@]}"; do
  if [[ "$p" != "$SSH_PORT" ]]; then
    warn "sshd escuta na porta $p, mas SSH_PORT=$SSH_PORT — liberando as duas."
    warn "Ajuste SSH_PORT no .env para refletir a porta real do sshd."
  fi
done

cat << "EOF"
  ╔══════════════════════════════════════════════╗
  ║   EasyPhone Orchestrator — Firewall Rules     ║
  ╚══════════════════════════════════════════════╝
EOF
echo

# NOTA: o Asterisk roda em host networking, então seu tráfego (SIP/RTP)
# chega na chain INPUT (política DROP) — por isso precisa ser liberado aqui.
# Apenas portas estritamente necessárias para acesso externo:
# - $SSH_PORT (SSH) — administração do servidor (porta configurada no .env)
# - 80  (HTTP)    — Traefik (redireciona para HTTPS + Let's Encrypt)
# - 443 (HTTPS)   — Traefik (frontend app.exemplo.com + API api.exemplo.com)
# - 5061 (SIP TLS) — ramais com SIP criptografado
# - 3478 (STUN/TURN) — Coturn, UDP e TCP
# - 5349 (TURNS)  — Coturn sobre TLS (redes que só liberam TLS)
# AMI (5038), ARI (8088) e WSS (8089) são internos e NÃO entram nesta lista: a
# api/seed acessam AMI/ARI e o Traefik acessa o WSS via host.docker.internal —
# tráfego que chega na chain INPUT pela interface de bridge do Docker. São
# liberados na seção 9b APENAS via interface de bridge (-i br+), sem expô-los à
# internet. Se estiverem aqui em PORTS_TCP, a regra genérica é avaliada ANTES da
# regra -i br+ e do DROP da seção 9c, e o AMI acaba aberto ao mundo.
# Proteção em camadas:
#   1. manager.conf — ACL deny + permit somente IPs privados (10/8, 172.16/12, 192.168/16)
#   2. iptables     — porta 5038 só aceita tráfego vindo de interfaces br+ (Docker)
# PostgreSQL (7001) é interno — o Asterisk (host networking) o alcança em 127.0.0.1.
#
# Origens do whitelist.conf não passam por esta lista: a EASYPHONE_WHITELIST faz
# ACCEPT antes, dando acesso total a elas (ver whitelist-rules.sh).
PORTS_TCP=("$SSH_PORT" 80 443 5061 3478 5349)
for p in "${SSHD_PORTS[@]}"; do
  [[ " ${PORTS_TCP[*]} " == *" $p "* ]] || PORTS_TCP+=("$p")
done
PORTS_UDP=(5060 3478 5349)

# Faixa de RTP (mídia/áudio das chamadas) — DEVE casar com rtp.conf (rtpstart/rtpend).
# Necessária externamente para áudio bidirecional das ligações.
RTP_UDP_RANGE="10000:20000"

# ── 0. Verifica módulo conntrack ──────────────────────────────────────
if ! lsmod 2>/dev/null | grep -q nf_conntrack; then
  modprobe nf_conntrack 2>/dev/null || warn "Módulo nf_conntrack não disponível — regras ESTABLISHED,RELATED podem falhar."
fi

# ── 0b. Sanidade das chains do Docker ────────────────────────────────
#     O dockerd cria DOCKER, DOCKER-USER, DOCKER-FORWARD e DOCKER-ISOLATION-*
#     apenas na inicialização do daemon; depois disso só acrescenta regras nelas.
#     Se um flush amplo ou um `iptables-restore` de snapshot antigo as apagou,
#     todo `docker network create` falha com "No chain/target/match by that name"
#     e só volta ao normal reiniciando o daemon. Aqui apenas avisamos: reiniciar
#     o Docker derruba containers e chamadas em curso, e essa decisão é do
#     operador.
if pidof dockerd &>/dev/null && ! iptables -n -L DOCKER-USER &>/dev/null; then
  warn "O dockerd está rodando, mas as chains DOCKER-* não existem no netfilter."
  warn "Nenhum 'docker network create' vai funcionar até o daemon ser reiniciado:"
  warn "    systemctl restart docker   # ⚠ derruba containers e chamadas em curso"
fi

# ── 1. Cria e limpa a chain dedicada EASYPHONE_INPUT ──────────────────
#     (Assim nunca mexemos nas regras do Docker)
iptables -N EASYPHONE_INPUT 2>/dev/null || true
iptables -F EASYPHONE_INPUT
ok "Chain EASYPHONE_INPUT limpa."

# ── 2. Conexões estabelecidas / related ──────────────────────────────
#     PRIMEIRO liberamos conexões ativas (ex: SSH atual) ANTES de mudar
#     a política padrão para DROP, evitando queda da sessão.
#     Usamos -C para evitar duplicar regras entre execuções.
if ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &>/dev/null; then
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
if ! iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT &>/dev/null; then
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
ok "Conexões estabelecidas/related aceitas."

# ── 3. Políticas padrão ──────────────────────────────────────────────
#     INPUT → DROP  (bloqueia tudo que não foi explicitamente liberado)
#     FORWARD → ACCEPT  (obrigatório para o Docker rotear tráfego entre
#                        containers e para fora; o Docker gerencia suas
#                        próprias restrições nas chains DOCKER / DOCKER-USER)
iptables -P INPUT   DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT
ok "Políticas definidas: INPUT=DROP  FORWARD=ACCEPT  OUTPUT=ACCEPT"

# ── 4. Loopback ──────────────────────────────────────────────────────
if ! iptables -C INPUT -i lo -j ACCEPT &>/dev/null; then
  iptables -A INPUT -i lo -j ACCEPT
fi
ok "Loopback liberado."

# ── 5. ICMP (ping) ───────────────────────────────────────────────────
if ! iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT &>/dev/null; then
  iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
fi
ok "ICMP echo-request liberado."

# ── 6. Jump da INPUT para a chain dedicada ───────────────────────────
if ! iptables -C INPUT -j EASYPHONE_INPUT &>/dev/null; then
  iptables -A INPUT -j EASYPHONE_INPUT
fi
ok "Tráfego da stack encaminhado para chain EASYPHONE_INPUT."

# ── 7. Portas TCP (regras na chain dedicada) ─────────────────────────
info "Liberando portas TCP na EASYPHONE_INPUT…"
for port in "${PORTS_TCP[@]}"; do
  iptables -A EASYPHONE_INPUT -p tcp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} TCP/$port"
done

# ── 8. Portas UDP (regras na chain dedicada) ─────────────────────────
info "Liberando portas UDP na EASYPHONE_INPUT…"
for port in "${PORTS_UDP[@]}"; do
  iptables -A EASYPHONE_INPUT -p udp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} UDP/$port"
done

# ── 9. Faixa de RTP (mídia) ─────────────────────────────────────────
info "Liberando faixa de RTP (UDP ${RTP_UDP_RANGE}) na EASYPHONE_INPUT…"
iptables -A EASYPHONE_INPUT -p udp --dport "$RTP_UDP_RANGE" -j ACCEPT
echo -e "  ${GREEN}✓${NC} UDP/${RTP_UDP_RANGE} (RTP)"

# ── 9a. Faixa de relay Coturn (mídia TURN) ──────────────────────────
info "Liberando faixa de relay Coturn (UDP 49152-65535) na EASYPHONE_INPUT…"
iptables -A EASYPHONE_INPUT -p udp --dport 49152:65535 -j ACCEPT
echo -e "  ${GREEN}✓${NC} UDP/49152-65535 (Coturn relay)"

# ── 9b. Serviços internos AMI/ARI/WSS — acessíveis APENAS pela rede dos containers ──
#     O Asterisk roda em host networking; api/seed o alcançam via host.docker.internal,
#     e o Traefik faz o mesmo para o WebSocket SIP na 8089 (proxy de wss://pbx.${DOMAIN}).
#     Esse tráfego ENTRA no host pela interface de bridge da rede do container (br-<hash>)
#     e chega na chain INPUT (entrega local). Casamos pela interface (-i br+) em vez de IP:
#     cobre todas as redes bridge do Docker, sobrevive à recriação da rede e não depende de
#     faixa de IP. NÃO expõe esses serviços à internet (só tráfego vindo das bridges Docker).
PORTS_INTERNAL_TCP=(5038 8088 8089)    # AMI, ARI, WSS (WebRTC)
info "Liberando AMI/ARI/WSS (TCP) apenas via interface de bridge do Docker (-i br+)…"
for port in "${PORTS_INTERNAL_TCP[@]}"; do
  iptables -A EASYPHONE_INPUT -i br+ -p tcp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} TCP/$port (interno Docker)"
done

# ── 9c. Drop explícito do AMI para tráfego NÃO vindo do Docker ──────────
#     Reforço de segurança: mesmo que a política INPUT DROP seja alterada,
#     tráfego externo na porta 5038 é explicitamente rejeitado aqui.
#     A regra -i br+ ACCEPT acima prevalece para tráfego legítimo dos containers.
info "Bloqueando acesso externo ao AMI (TCP/5038)…"
iptables -A EASYPHONE_INPUT -p tcp --dport 5038 -j DROP
echo -e "  ${GREEN}✓${NC} TCP/5038 (DROP explícito para tráfego não-bridge)"

# ── 9d. Whitelist de origens (opcional) ──────────────────────────────
#     Roda depois de montar a EASYPHONE_INPUT porque o whitelist-rules.sh insere o
#     jump dele imediatamente ANTES dela — precisa que a chain já esteja na INPUT
#     para calcular a posição. Sem whitelist.conf o script sai sem fazer nada, e
#     uma falha dele (ex.: trava de lockout) não pode abortar o firewall.
WHITELIST_SCRIPT="$(dirname "$(readlink -f "$0")")/whitelist-rules.sh"

if [[ -f "$WHITELIST_SCRIPT" ]]; then
  echo
  if ! bash "$WHITELIST_SCRIPT"; then
    warn "whitelist-rules.sh falhou — as regras de porta acima seguem aplicadas."
    warn "Rode 'sudo bash $WHITELIST_SCRIPT' para ver o motivo."
  fi
fi

# ── 10. Persistência ─────────────────────────────────────────────────
#     Duas estratégias, mutuamente exclusivas:
#
#     a) easyphone-firewall.service (preferida) — reaplica ESTE script a cada boot,
#        depois do docker.service. As chains do Docker sempre existem antes das
#        nossas regras entrarem, e nada é congelado em arquivo.
#
#     b) Snapshot da tabela inteira (netfilter-persistent / rules.v4) — fallback
#        para quando o unit não está instalado. Funciona, mas é o mecanismo que
#        causou o incidente: o `iptables-restore` do boot FLUSHA a tabela antes
#        de aplicar, então um snapshot tirado sem as chains do Docker as apaga
#        e quebra todo `docker network create`.
echo

if systemctl is-enabled easyphone-firewall.service &>/dev/null; then
  ok "easyphone-firewall.service habilitado — as regras são reaplicadas no boot."
  info "Snapshot da tabela dispensado (não congela as chains do Docker)."

  if systemctl is-enabled netfilter-persistent &>/dev/null; then
    warn "netfilter-persistent também está habilitado e restaura um snapshot no boot."
    warn "É esse snapshot que pode apagar as chains do Docker. Para desativá-lo:"
    warn "    systemctl disable netfilter-persistent"
  fi
else
  info "Salvando regras para restaurar no boot…"

  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    ok "Regras salvas via netfilter-persistent."
  elif [[ -d /etc/iptables ]]; then
    iptables-save > /etc/iptables/rules.v4
    ok "Regras salvas em /etc/iptables/rules.v4"
  else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "Diretório /etc/iptables criado e regras salvas."
  fi

  warn "Persistência por snapshot: se ele for gravado sem as chains do Docker,"
  warn "o boot vai apagá-las e o 'docker compose up' falhará."
  warn "Prefira instalar o unit — 'sudo bash init.sh' (etapa 4/6) cuida disso."
fi

# ── 11. Aviso sobre Docker ──────────────────────────────────────────
if pidof dockerd &>/dev/null; then
  ok "Docker detectado — chains e regras do Docker foram preservadas."
fi

echo
echo -e "${GREEN}${BOLD}✓ Firewall configurado com sucesso.${NC}"
