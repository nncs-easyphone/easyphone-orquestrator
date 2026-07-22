#!/usr/bin/env bash
#
# EasyFone Orchestrator — Script de inicialização da stack
# =========================================================
# Sobe a stack completa (Postgres, API, Web, Asterisk)
# respeitando a variável USE_BUILD do .env.
#
# Uso: bash run.sh
#        ./run.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
#  CORES E LOGS
# ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()     { echo -e "${BLUE}[INFO]${NC}     $*"; }
ok()       { echo -e "${GREEN}[OK]${NC}       $*"; }
warn()     { echo -e "${YELLOW}[WARN]${NC}     $*"; }
error()    { echo -e "${RED}[ERROR]${NC}    $*"; }

# ─────────────────────────────────────────────────────────────────────
#  FUNÇÕES DE INTERAÇÃO
# ─────────────────────────────────────────────────────────────────────
ask_no() {
  local prompt="$1 [s/N] " ans
  read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt}")" ans
  [[ "${ans:-}" =~ ^[Ss]$ ]]
}

# ─────────────────────────────────────────────────────────────────────
#  SISTEMA DE LOGS — caixa emoldurada + arquivo
# ─────────────────────────────────────────────────────────────────────
LOGFILE="/tmp/easyfone-orquestrator-run.log"
: > "$LOGFILE"

box_start() {
  local title="$1"
  local len=60
  local dashes
  dashes=$(printf '%*s' "$((len - ${#title} - 5))" '' | tr ' ' '─')
  echo -e "┌─ ${BOLD}${title}${NC} ${dashes}┐"
}

box_end() {
  echo -e "└$(printf '─%.0s' $(seq 1 58))┘"
  echo
}

# ─────────────────────────────────────────────────────────────────────
#  CARREGA .ENV
# ─────────────────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$(readlink -f "$0")")/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  error "Arquivo .env não encontrado em $ENV_FILE"
  echo "  Copie o .env.example para .env e ajuste as variáveis:"
  echo "    cp .env.example .env"
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

USE_BUILD="${USE_BUILD:-false}"

cd "$(dirname "$(readlink -f "$0")")"

# ─────────────────────────────────────────────────────────────────────
#  ARQUIVOS GERADOS PELO INIT.SH
# ─────────────────────────────────────────────────────────────────────
# O compose faz bind mount de coturn/turnserver.conf. Se o arquivo não existir,
# o Docker cria um DIRETÓRIO com esse nome e o Coturn falha com um erro obscuro —
# por isso a checagem acontece antes de qualquer `up`.
MISSING_GENERATED=()
[[ -f "traefik/conf/wss.yml"      ]] || MISSING_GENERATED+=("traefik/conf/wss.yml")
[[ -f "coturn/turnserver.conf"    ]] || MISSING_GENERATED+=("coturn/turnserver.conf")

if [[ ${#MISSING_GENERATED[@]} -gt 0 ]]; then
  error "Arquivos de configuração ausentes (gerados pelo init.sh a partir do .env):"
  for f in "${MISSING_GENERATED[@]}"; do
    echo "    - $f"
  done
  echo
  echo "  Gere-os com:"
  echo "    sudo bash init.sh"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────
#  SOBE A STACK
# ─────────────────────────────────────────────────────────────────────

if [[ "$USE_BUILD" == "true" ]]; then
  info "USE_BUILD=true  → build local dos Dockerfiles"

  box_start "Build e inicialização da stack"
  docker compose up -d 2>&1 | tee -a "$LOGFILE"
  echo ""
  info "Logs de inicialização:"
  docker compose logs --tail=100 2>&1 | tee -a "$LOGFILE"
  box_end
else
  info "USE_BUILD=false → imagens do registry"

  # Verifica autenticação ghcr; </dev/null evita travamento
  if ! docker login ghcr.io </dev/null &>/dev/null; then
    warn "Não autenticado no ghcr.io. Execute 'sudo bash init.sh' para configurar o login."
    if ! ask_no "Tentar pull mesmo assim?"; then
      exit 1
    fi
  fi

  box_start "Pull das imagens"
  docker compose pull 2>&1 | tee -a "$LOGFILE"
  ok "Imagens baixadas."
  box_end

  box_start "Inicialização da stack"
  docker compose up -d --no-build 2>&1 | tee -a "$LOGFILE"
  echo ""
  info "Logs de inicialização:"
  docker compose logs --tail=100 2>&1 | tee -a "$LOGFILE"
  box_end
fi

ok "Stack EasyFone iniciada."
echo
echo -e "  ${GREEN}→${NC} Traefik:    https://app.${DOMAIN:-exemplo.com} (web)  /  https://api.${DOMAIN:-exemplo.com} (api)  /  https://pbx.${DOMAIN:-exemplo.com} (wss)"
echo -e "  ${GREEN}→${NC} Postgres:   localhost:${PG_PORT_HOST:-7001}  (interno)"
echo -e "  ${GREEN}→${NC} PgBouncer:  localhost:${PGBOUNCER_PORT_HOST:-7003}  (pool, interno)"
echo -e "  ${GREEN}→${NC} Coturn:     STUN 3478/udp  |  TURN 3478/tcp+udp  |  TURNS 5349/tcp+udp  |  Relay 49152-65535/udp"
echo -e "  ${GREEN}→${NC} Asterisk:   SIP 5060/udp  |  SIP TLS 5061/tcp  |  RTP 10000-20000/udp (AMI/ARI internos)"
echo -e "  ${GREEN}→${NC} Transcriber: interno (Whisper STT, porta 3335)"
echo
echo -e "  ${BOLD}Arquivo de log:${NC} $LOGFILE"
