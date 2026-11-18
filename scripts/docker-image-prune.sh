#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Limpeza de imagens Docker antigas
# ==========================================================
# Remove imagens não usadas criadas há mais de DOCKER_IMAGE_PRUNE_RETENTION
# (padrão: 24h). Normalmente executado pelo easyphone-image-prune.timer.
#
# Uso: sudo bash scripts/docker-image-prune.sh
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<'EOF'
Remove imagens Docker não usadas antigas.

Uso:
  sudo bash scripts/docker-image-prune.sh
  sudo bash scripts/docker-image-prune.sh --help

Configuração no .env:
  DOCKER_IMAGE_PRUNE_ENABLED    true|false (padrão: true)
  DOCKER_IMAGE_PRUNE_RETENTION  duração mínima das imagens (padrão: 24h)
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    error "Opção desconhecida: $1"
    usage >&2
    exit 1
    ;;
esac

# read_env <chave>: lê um valor do .env sem executar o arquivo.
read_env() {
  local key="$1" value
  [[ -f "$ENV_FILE" ]] || return 0
  value="$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

ENABLED="${DOCKER_IMAGE_PRUNE_ENABLED:-$(read_env DOCKER_IMAGE_PRUNE_ENABLED)}"
RETENTION="${DOCKER_IMAGE_PRUNE_RETENTION:-$(read_env DOCKER_IMAGE_PRUNE_RETENTION)}"
ENABLED="${ENABLED:-true}"
RETENTION="${RETENTION:-24h}"

case "${ENABLED,,}" in
  false|0|no|off)
    info "Limpeza de imagens desativada (DOCKER_IMAGE_PRUNE_ENABLED=${ENABLED})."
    exit 0
    ;;
esac

if [[ ! "$RETENTION" =~ ^[1-9][0-9]*[smh]$ ]]; then
  error "DOCKER_IMAGE_PRUNE_RETENTION inválido: '${RETENTION}' (use, por exemplo, 24h ou 168h)."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  error "docker não encontrado; limpeza de imagens abortada."
  exit 1
fi

if ! timeout 10 docker info >/dev/null 2>&1; then
  error "Docker daemon indisponível; limpeza de imagens abortada."
  exit 1
fi

image_count() {
  docker image ls -q 2>/dev/null | wc -l | tr -d ' '
}

before="$(image_count)"
info "Removendo imagens não usadas criadas há mais de ${RETENTION} (imagens antes: ${before})…"

if ! prune_output="$(docker image prune --all --force --filter "until=${RETENTION}" 2>&1)"; then
  error "Falha ao executar a limpeza de imagens."
  printf '%s\n' "$prune_output" >&2
  exit 1
fi
printf '%s\n' "$prune_output"

after="$(image_count)"
ok "Limpeza concluída. Imagens antes: ${before}; depois: ${after}."
