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

# ─────────────────────────────────────────────────────────────────────
#  SOBE A STACK
# ─────────────────────────────────────────────────────────────────────
cd "$(dirname "$(readlink -f "$0")")"

if [[ "$USE_BUILD" == "true" ]]; then
  info "USE_BUILD=true  → build local dos Dockerfiles"
  docker compose up -d
else
  info "USE_BUILD=false → imagens do registry"

  # Verifica autenticação ghcr antes de tentar pull
  if ! docker login ghcr.io &>/dev/null; then
    warn "Não autenticado no ghcr.io. Execute 'sudo bash init.sh' para configurar o login."
    if ! ask_no "Tentar pull mesmo assim?"; then
      exit 1
    fi
  fi

  info "Fazendo pull das imagens…"
  docker compose pull
  docker compose up -d --no-build
fi

ok "Stack EasyFone iniciada."
echo
echo -e "  ${GREEN}→${NC} Traefik:    https://app.${DOMAIN:-exemplo.com}  /  https://api.${DOMAIN:-exemplo.com}"
echo -e "  ${GREEN}→${NC} Postgres:   localhost:${PG_PORT_HOST:-7001}  (interno)"
echo -e "  ${GREEN}→${NC} PgBouncer:  localhost:${PGBOUNCER_PORT_HOST:-7003}  (pool, interno)"
echo -e "  ${GREEN}→${NC} Asterisk:   SIP 5060/udp  |  RTP 10000-20000/udp (AMI/ARI internos)"
