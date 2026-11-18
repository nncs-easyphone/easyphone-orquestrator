#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Instala a limpeza diária de imagens Docker
# ====================================================================
# Instala/reinstala easyphone-image-prune.service e easyphone-image-prune.timer,
# que removem imagens não usadas criadas há mais de
# DOCKER_IMAGE_PRUNE_RETENTION (padrão: 24h).
#
# Uso: sudo bash scripts/install-image-prune.sh [--remove]
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SERVICE_TEMPLATE="$ROOT_DIR/systemd/easyphone-image-prune.service.example"
TIMER_TEMPLATE="$ROOT_DIR/systemd/easyphone-image-prune.timer.example"
PRUNE_SCRIPT="$SCRIPT_DIR/docker-image-prune.sh"
SERVICE_NAME="easyphone-image-prune.service"
TIMER_NAME="easyphone-image-prune.timer"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TIMER_PATH="/etc/systemd/system/$TIMER_NAME"

usage() {
  cat <<'EOF'
Instala a limpeza diária de imagens Docker antigas do EasyPhone.

Uso:
  sudo bash scripts/install-image-prune.sh
  sudo bash scripts/install-image-prune.sh --remove

O timer executa scripts/docker-image-prune.sh uma vez ao dia (03:30, com
atraso aleatório de até 30 min) e remove imagens não usadas mais antigas que
DOCKER_IMAGE_PRUNE_RETENTION (padrão: 24h). Para desativar sem remover o timer,
defina DOCKER_IMAGE_PRUNE_ENABLED=false no .env.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --remove)
    MODE="remove"
    ;;
  "")
    MODE="install"
    ;;
  *)
    echo "Opção desconhecida: $1" >&2
    echo "Use: sudo bash $0 [--remove]" >&2
    exit 1
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo bash $0" >&2
  exit 1
fi

if ! command -v systemctl &>/dev/null; then
  echo "systemctl não encontrado; este instalador requer systemd." >&2
  exit 1
fi

if [[ "$MODE" == "remove" ]]; then
  systemctl disable --now "$TIMER_NAME" 2>/dev/null || true
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_PATH" "$TIMER_PATH"
  systemctl daemon-reload
  echo "[OK] $TIMER_NAME removido."
  echo "O script scripts/docker-image-prune.sh permanece para execução manual."
  exit 0
fi

if ! command -v docker &>/dev/null; then
  echo "docker não encontrado; instale o Docker antes de habilitar a limpeza." >&2
  exit 1
fi

[[ -f "$SERVICE_TEMPLATE" ]] || { echo "Template não encontrado: $SERVICE_TEMPLATE" >&2; exit 1; }
[[ -f "$TIMER_TEMPLATE" ]] || { echo "Template não encontrado: $TIMER_TEMPLATE" >&2; exit 1; }
[[ -f "$PRUNE_SCRIPT" ]] || { echo "Script não encontrado: $PRUNE_SCRIPT" >&2; exit 1; }

render_unit() {
  local template="$1" output="$2"
  sed "s|__IMAGE_PRUNE_SCRIPT__|$PRUNE_SCRIPT|g" "$template" > "$output"
  chmod 644 "$output"
}

render_unit "$SERVICE_TEMPLATE" "$SERVICE_PATH"
render_unit "$TIMER_TEMPLATE" "$TIMER_PATH"

systemctl daemon-reload
systemctl enable "$TIMER_NAME" >/dev/null
systemctl restart "$TIMER_NAME"

if systemctl is-active --quiet "$TIMER_NAME"; then
  echo "[OK] $TIMER_NAME instalado, habilitado e ativo."
else
  echo "[ERROR] $TIMER_NAME não ficou ativo." >&2
  systemctl status "$TIMER_NAME" --no-pager 2>&1 | sed 's/^/    /' >&2 || true
  exit 1
fi

echo "Agendamento: systemctl list-timers $TIMER_NAME"
echo "Logs:        journalctl -u $SERVICE_NAME -f"
echo "Executar já: sudo bash scripts/docker-image-prune.sh"
