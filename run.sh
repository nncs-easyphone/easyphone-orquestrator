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
  info "Fazendo pull das imagens…"
  docker compose pull
  docker compose up -d --no-build
fi

ok "Stack EasyFone iniciada."
echo
echo -e "  ${GREEN}→${NC} Web:        http://localhost:${WEB_PORT_HOST:-7000}"
echo -e "  ${GREEN}→${NC} API:        http://localhost:${API_PORT_HOST:-7002}"
echo -e "  ${GREEN}→${NC} Postgres:   localhost:${PG_PORT_HOST:-7001}"
echo -e "  ${GREEN}→${NC} Asterisk:   SIP 5060/udp  |  AMI 5038  |  ARI 8088"
