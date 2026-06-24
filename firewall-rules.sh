#!/usr/bin/env bash
#
# EasyFone Orchestrator — Regras de Firewall (iptables)
# Uso: sudo bash firewall-rules.sh
#
# Define regras de entrada para as portas do projeto usando
# uma chain dedicada (EASYFONE_INPUT) para não interferir
# nas regras geridas pelo Docker.
#
# NOTA: FORWARD fica ACCEPT para não quebrar o roteamento de redes do Docker.
# IPv6 deve estar desabilitado no kernel; este script não configura ip6tables.

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

cat << "EOF"
  ╔══════════════════════════════════════════════╗
  ║   EasyFone Orchestrator — Firewall Rules     ║
  ╚══════════════════════════════════════════════╝
EOF
echo

# NOTA: o Asterisk roda em host networking, então seu tráfego (SIP/RTP)
# chega na chain INPUT (política DROP) — por isso precisa ser liberado aqui.
# Apenas portas estritamente necessárias para acesso externo:
# - 22  (SSH)     — administração do servidor
# - 80  (HTTP)    — Traefik (redireciona para HTTPS + Let's Encrypt)
# - 443 (HTTPS)   — Traefik (frontend app.exemplo.com + API api.exemplo.com)
# - 5061 (SIP TLS) — ramais com SIP criptografado
# AMI (5038) e ARI (8088) são internos: a api/seed os acessam via host.docker.internal,
# tráfego que chega na chain INPUT pela interface de bridge do Docker. São liberados na
# seção dedicada abaixo APENAS via interface de bridge (-i br+), sem expô-los à internet.
# PostgreSQL (7001) é interno — o Asterisk (host networking) o alcança em 127.0.0.1.
PORTS_TCP=(22 80 443 5061)
PORTS_UDP=(5060)

# Faixa de RTP (mídia/áudio das chamadas) — DEVE casar com rtp.conf (rtpstart/rtpend).
# Necessária externamente para áudio bidirecional das ligações.
RTP_UDP_RANGE="10000:20000"

# ── 0. Verifica módulo conntrack ──────────────────────────────────────
if ! lsmod 2>/dev/null | grep -q nf_conntrack; then
  modprobe nf_conntrack 2>/dev/null || warn "Módulo nf_conntrack não disponível — regras ESTABLISHED,RELATED podem falhar."
fi

# ── 1. Cria e limpa a chain dedicada EASYFONE_INPUT ──────────────────
#     (Assim nunca mexemos nas regras do Docker)
iptables -N EASYFONE_INPUT 2>/dev/null || true
iptables -F EASYFONE_INPUT
ok "Chain EASYFONE_INPUT limpa."

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
if ! iptables -C INPUT -j EASYFONE_INPUT &>/dev/null; then
  iptables -A INPUT -j EASYFONE_INPUT
fi
ok "Tráfego da stack encaminhado para chain EASYFONE_INPUT."

# ── 7. Portas TCP (regras na chain dedicada) ─────────────────────────
info "Liberando portas TCP na EASYFONE_INPUT…"
for port in "${PORTS_TCP[@]}"; do
  iptables -A EASYFONE_INPUT -p tcp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} TCP/$port"
done

# ── 8. Portas UDP (regras na chain dedicada) ─────────────────────────
info "Liberando portas UDP na EASYFONE_INPUT…"
for port in "${PORTS_UDP[@]}"; do
  iptables -A EASYFONE_INPUT -p udp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} UDP/$port"
done

# ── 9. Faixa de RTP (mídia) ─────────────────────────────────────────
info "Liberando faixa de RTP (UDP ${RTP_UDP_RANGE}) na EASYFONE_INPUT…"
iptables -A EASYFONE_INPUT -p udp --dport "$RTP_UDP_RANGE" -j ACCEPT
echo -e "  ${GREEN}✓${NC} UDP/${RTP_UDP_RANGE} (RTP)"

# ── 9b. Serviços internos AMI/ARI — acessíveis APENAS pela rede dos containers ──
#     O Asterisk roda em host networking; api/seed o alcançam via host.docker.internal.
#     Esse tráfego ENTRA no host pela interface de bridge da rede do container (br-<hash>)
#     e chega na chain INPUT (entrega local). Casamos pela interface (-i br+) em vez de IP:
#     cobre todas as redes bridge do Docker, sobrevive à recriação da rede e não depende de
#     faixa de IP. NÃO expõe AMI/ARI à internet (só tráfego vindo das bridges Docker).
PORTS_INTERNAL_TCP=(5038 8088)    # AMI, ARI
info "Liberando AMI/ARI (TCP) apenas via interface de bridge do Docker (-i br+)…"
for port in "${PORTS_INTERNAL_TCP[@]}"; do
  iptables -A EASYFONE_INPUT -i br+ -p tcp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} TCP/$port (interno Docker)"
done

# ── 10. Persistência ─────────────────────────────────────────────────
echo
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

# ── 11. Aviso sobre Docker ──────────────────────────────────────────
if pidof dockerd &>/dev/null; then
  ok "Docker detectado — chains e regras do Docker foram preservadas."
fi

echo
echo -e "${GREEN}${BOLD}✓ Firewall configurado com sucesso.${NC}"
