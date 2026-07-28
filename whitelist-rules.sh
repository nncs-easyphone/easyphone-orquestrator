#!/usr/bin/env bash
#
# EasyFone Orchestrator — Whitelist de origens (iptables)
# Uso: sudo bash whitelist-rules.sh [--remove] [--force]
#
# Restringe POR ORIGEM o tráfego que chega na chain INPUT, usando uma chain
# dedicada (EASYFONE_WHITELIST) avaliada ANTES da EASYFONE_INPUT:
#
#   INPUT (policy DROP)
#     1  ESTABLISHED,RELATED  → ACCEPT
#     2  -i lo                → ACCEPT
#     3  icmp echo-request    → ACCEPT
#     4  -j EASYFONE_WHITELIST   ← este script: filtra por ORIGEM
#     5  -j EASYFONE_INPUT       ← firewall-rules.sh: filtra por PORTA
#
# ORIGEM PERMITIDA = ACESSO TOTAL. A chain devolve ACCEPT para os CIDRs do
# ALLOWED: o pacote sai da INPUT ali mesmo e NÃO passa pelo filtro de portas da
# EASYFONE_INPUT. Um IP da lista alcança QUALQUER porta do host, incluindo AMI
# (5038), ARI (8088), WSS (8089) e Postgres (7001).
#
# Foi uma decisão deliberada: a EASYFONE_INPUT libera um conjunto fixo de portas
# (22, 80, 443, 5061, 3478, 5349, UDP 5060 e as faixas de RTP/TURN) e NÃO cobre,
# por exemplo, SIP em TCP/5060 nem portas 50xx alternativas. Com RETURN, um
# tronco legítimo já na whitelist continuava sendo descartado por falar numa
# porta fora dessa lista — falha silenciosa e difícil de diagnosticar.
#
# Consequência a assumir: para as origens do ALLOWED, a proteção do AMI passa a
# ser apenas a ACL do manager.conf (deny 0.0.0.0/0 + permits de faixas privadas).
# Trate o whitelist.conf como lista de hosts confiáveis, não como filtro de borda.
#
# ⚠️ NUNCA use `iptables -F` (nem `-F INPUT`) neste host: isso apaga os jumps das
# duas chains e derruba SIP/RTP/AMI, porque Asterisk e Coturn rodam em host
# networking. Este script só esvazia a sua própria chain.
#
# ALCANCE — o que a whitelist filtra e o que não filtra:
#   ✓ SIP, RTP, AMI, ARI e WSS do Asterisk, STUN/TURN do Coturn e SSH — tudo isso
#     chega pela INPUT porque esses serviços usam `network_mode: host`.
#   ✗ As portas 80/443 do Traefik. Porta publicada por container não passa pela
#     INPUT (vai por nat/PREROUTING → FORWARD → chains DOCKER-*), então app./api.
#     e o desafio TLS do Let's Encrypt seguem abertos ao mundo — de propósito.
#
# O QUE ISTO NÃO EXPLICA: erros do Asterisk ao CRIAR requisições de SAÍDA, como
# "Unable to create outbound OPTIONS request" / "Unable to create request to
# qualify contact". Não existe nenhuma regra de OUTPUT neste projeto (a política
# é ACCEPT) e o PJSIP falha nesses casos antes de emitir qualquer pacote — não
# adianta procurar a causa no firewall.
#
# CONSEQUÊNCIAS de ativar (revise o whitelist.conf antes):
#   - Ramais e troncos fora das faixas perdem SIP e RTP. Os IPs de MÍDIA das
#     operadoras precisam estar na lista: se só a sinalização estiver liberada, a
#     chamada completa e fica muda — sintoma que não aponta para o firewall.
#   - Clientes WebRTC fora das faixas param de fazer STUN/TURN.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

WHITELIST_CHAIN="EASYFONE_WHITELIST"
PORTS_CHAIN="EASYFONE_INPUT"
LOG_PREFIX="EASYFONE-WL-DROP: "
CONF_FILE="$(dirname "$(readlink -f "$0")")/whitelist.conf"

MODE="apply"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --remove) MODE="remove" ;;
    --force)  FORCE=true ;;
    -h|--help)
      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      error "Argumento desconhecido: $arg (use --remove, --force ou --help)"
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  error "Execute como root: sudo bash $0"
  exit 1
fi

# ── Remoção ──────────────────────────────────────────────────────────
if [[ "$MODE" == "remove" ]]; then
  while iptables -C INPUT -j "$WHITELIST_CHAIN" &>/dev/null; do
    iptables -D INPUT -j "$WHITELIST_CHAIN"
  done

  if iptables -n -L "$WHITELIST_CHAIN" &>/dev/null; then
    iptables -F "$WHITELIST_CHAIN"
    iptables -X "$WHITELIST_CHAIN"
  fi

  ok "Whitelist removida — a INPUT voltou a aceitar qualquer origem nas portas do projeto."
  exit 0
fi

# ── Configuração ─────────────────────────────────────────────────────
#     A existência do whitelist.conf é o que ativa a whitelist. Sem ele saímos com
#     0 para que o firewall-rules.sh possa chamar este script incondicionalmente.
if [[ ! -f "$CONF_FILE" ]]; then
  info "whitelist.conf não encontrado — whitelist desativada."
  info "Para ativar: cp whitelist.conf.example whitelist.conf && revise a lista."
  exit 0
fi

# shellcheck source=whitelist.conf.example
source "$CONF_FILE"

if [[ -z "${ALLOWED+x}" || ${#ALLOWED[@]} -eq 0 ]]; then
  error "O whitelist.conf não define nenhuma origem em ALLOWED."
  error "Aplicar assim bloquearia todo o tráfego de entrada. Abortando."
  exit 1
fi

# ── Matcher CIDR (bash puro) ─────────────────────────────────────────
ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# ip_in_cidr <ip> <cidr>  →  0 se o ip pertence à faixa
ip_in_cidr() {
  local ip="$1" cidr="$2" network bits mask

  network="${cidr%%/*}"
  if [[ "$cidr" == */* ]]; then bits="${cidr##*/}"; else bits=32; fi

  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

  (( bits == 0 )) && return 0
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))

  (( ($(ip_to_int "$ip") & mask) == ($(ip_to_int "$network") & mask) ))
}

# ── Trava contra lockout ─────────────────────────────────────────────
#     A regra ESTABLISHED,RELATED mantém a sessão SSH atual viva mesmo com a
#     origem bloqueada — quem falha é a PRÓXIMA conexão. Sem esta checagem, o
#     erro só apareceria quando já não houvesse como entrar.
if [[ -n "${SSH_CLIENT:-}" ]] && ! $FORCE; then
  ssh_source_ip="${SSH_CLIENT%% *}"
  ssh_allowed=false

  for cidr in "${ALLOWED[@]}"; do
    if ip_in_cidr "$ssh_source_ip" "$cidr"; then
      ssh_allowed=true
      break
    fi
  done

  if ! $ssh_allowed; then
    error "Seu IP de origem ($ssh_source_ip) não está na whitelist."
    error "Aplicar isto encerraria seu acesso SSH na próxima conexão."
    error "Acrescente-o ao $CONF_FILE ou rode com --force se souber o que faz."
    exit 1
  fi

  ok "Origem do seu SSH ($ssh_source_ip) está na whitelist."
fi

# ── Monta a chain ────────────────────────────────────────────────────
iptables -N "$WHITELIST_CHAIN" 2>/dev/null || true
iptables -F "$WHITELIST_CHAIN"

# Bridges do Docker primeiro: api/seed alcançam AMI/ARI e o Traefik alcança o WSS
# via host.docker.internal, e esse tráfego entra pela interface br-<hash>. Casar
# pela interface cobre redes fora da faixa 172.16/14 (ex.: 172.20.x) e sobrevive
# à recriação da rede — mesmo critério já usado na EASYFONE_INPUT.
#
# Aqui é RETURN, não ACCEPT: os containers seguem restritos ao conjunto de portas
# da EASYFONE_INPUT (que já os libera para AMI/ARI/WSS via -i br+). Só as origens
# explicitamente listadas no ALLOWED ganham acesso irrestrito.
iptables -A "$WHITELIST_CHAIN" -i br+ -j RETURN
echo -e "  ${GREEN}✓${NC} bridges do Docker (-i br+, segue para o filtro de portas)"

# ACCEPT (não RETURN): as origens confiáveis saem da INPUT aqui, sem passar pelo
# filtro de portas. Ver o bloco "ORIGEM PERMITIDA = ACESSO TOTAL" no cabeçalho.
info "Liberando origens do whitelist.conf (acesso total a todas as portas)…"
for cidr in "${ALLOWED[@]}"; do
  iptables -A "$WHITELIST_CHAIN" -s "$cidr" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} $cidr"
done

iptables -A "$WHITELIST_CHAIN" -m limit --limit 5/min -j LOG --log-prefix "$LOG_PREFIX"
iptables -A "$WHITELIST_CHAIN" -j DROP
ok "Chain $WHITELIST_CHAIN montada (${#ALLOWED[@]} origens + bridges do Docker)."
warn "As ${#ALLOWED[@]} origens do ALLOWED têm acesso a TODAS as portas do host (inclusive AMI/Postgres)."

# ── Posiciona o jump na INPUT ────────────────────────────────────────
#     Precisa vir ANTES da EASYFONE_INPUT: aquela chain aceita por porta sem olhar
#     a origem, então um jump posterior nunca veria o tráfego que ela liberou.
while iptables -C INPUT -j "$WHITELIST_CHAIN" &>/dev/null; do
  iptables -D INPUT -j "$WHITELIST_CHAIN"
done

ports_chain_position=$(
  iptables -L INPUT -n --line-numbers | awk -v c="$PORTS_CHAIN" '$2 == c { print $1; exit }'
)

if [[ -n "$ports_chain_position" ]]; then
  iptables -I INPUT "$ports_chain_position" -j "$WHITELIST_CHAIN"
  ok "Jump inserido na INPUT, antes da $PORTS_CHAIN (posição $ports_chain_position)."
else
  iptables -A INPUT -j "$WHITELIST_CHAIN"
  warn "Chain $PORTS_CHAIN não encontrada na INPUT; jump acrescentado ao final."
  warn "Rode 'bash firewall-rules.sh' para montar as regras de porta."
fi

echo
echo -e "${GREEN}✓ Whitelist aplicada.${NC} Bloqueios ficam no log do kernel com o prefixo '${LOG_PREFIX}'."
echo -e "  Para desfazer: ${YELLOW}sudo bash $0 --remove${NC}"
