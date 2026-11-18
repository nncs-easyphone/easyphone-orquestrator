#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Reaplica a whitelist quando containers sobem
# =====================================================================
# Escuta os eventos start/restart do Docker para containers easyphone-* e
# executa scripts/whitelist-rules.sh de forma agrupada (debounce).
#
# Uso: sudo bash scripts/whitelist-watch.sh
#
# Normalmente roda como easyphone-whitelist-watch.service; não é necessário
# chamar manualmente. Sem whitelist.conf o watcher fica ocioso e não loga.
#
set -euo pipefail

case "${1:-}" in
  -h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WHITELIST_SCRIPT="${EASYPHONE_WHITELIST_SCRIPT:-$SCRIPT_DIR/whitelist-rules.sh}"
CONF_FILE="${EASYPHONE_WHITELIST_CONF:-$ROOT_DIR/whitelist.conf}"
CONTAINER_PREFIX="${EASYPHONE_CONTAINER_PREFIX:-easyphone-}"
DEBOUNCE_SECONDS="${EASYPHONE_WHITELIST_DEBOUNCE:-2}"
RECONNECT_SECONDS="${EASYPHONE_WHITELIST_RECONNECT:-5}"

[[ -n "$CONTAINER_PREFIX" ]] || CONTAINER_PREFIX="easyphone-"
[[ "$DEBOUNCE_SECONDS" =~ ^[0-9]+$ ]] || DEBOUNCE_SECONDS=2
[[ "$RECONNECT_SECONDS" =~ ^[1-9][0-9]*$ ]] || RECONNECT_SECONDS=5

log() { echo "[easyphone-whitelist-watch] $*"; }

apply_whitelist() {
  # Sem whitelist.conf não há o que aplicar; não loga para não poluir
  # o journal a cada start de container.
  [[ -f "$CONF_FILE" ]] || return 0

  if [[ ! -f "$WHITELIST_SCRIPT" ]]; then
    log "Script não encontrado: $WHITELIST_SCRIPT"
    return 0
  fi

  log "Reaplicando whitelist de origens…"
  if bash "$WHITELIST_SCRIPT"; then
    log "Whitelist aplicada."
  else
    log "Falha ao aplicar a whitelist; veja o log acima."
  fi

  # Nunca propaga falha: uma config inválida não pode encerrar o watcher.
  return 0
}

if ! command -v docker >/dev/null 2>&1; then
  log "docker não encontrado; encerrando."
  exit 1
fi

log "Watcher iniciado (prefixo=${CONTAINER_PREFIX}, debounce=${DEBOUNCE_SECONDS}s)."

while :; do
  if ! timeout 10 docker info >/dev/null 2>&1; then
    log "Docker indisponível; tentando novamente em ${RECONNECT_SECONDS}s."
    sleep "$RECONNECT_SECONDS"
    continue
  fi

  # Aplicação inicial e após reconexão: um restart do Docker pode recriar as
  # chains DOCKER-* ou derrubar as regras enquanto o daemon estava parado.
  apply_whitelist

  # O filtro de nome é feito no shell para sobreviver a mudanças de project
  # name do Compose. O read interno com timeout coalesce a rajada de starts
  # de um `docker compose up -d`.
  docker events \
    --filter type=container \
    --filter event=start \
    --filter event=restart \
    --format '{{.Actor.Attributes.name}}' 2>/dev/null |
  while read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$name" == "$CONTAINER_PREFIX"* ]] || continue
    # Sem whitelist.conf não há o que aplicar e o watcher não deve logar
    # a cada evento; a checagem é repetida aqui para o caso de o arquivo
    # ser criado/removido com o serviço já em execução.
    [[ -f "$CONF_FILE" ]] || continue

    log "Evento de container: ${name}"
    while read -r -t "$DEBOUNCE_SECONDS" _; do :; done
    apply_whitelist
  done || true

  log "Stream de eventos encerrou; reconectando em ${RECONNECT_SECONDS}s."
  sleep "$RECONNECT_SECONDS"
done
