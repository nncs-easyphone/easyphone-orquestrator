#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Instala o watcher da whitelist
# ======================================================
# Instala/reinstala o easyphone-whitelist-watch.service, que reaplica
# scripts/whitelist-rules.sh quando containers easyphone-* sobem.
#
# Uso: sudo bash scripts/install-whitelist-watch.sh [--remove]
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$ROOT_DIR/systemd/easyphone-whitelist-watch.service.example"
WATCH_SCRIPT="$SCRIPT_DIR/whitelist-watch.sh"
UNIT_NAME="easyphone-whitelist-watch.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

usage() {
  cat <<'EOF'
Instala o watcher da whitelist do EasyPhone.

Uso:
  sudo bash scripts/install-whitelist-watch.sh
  sudo bash scripts/install-whitelist-watch.sh --remove

O watcher escuta os eventos start/restart dos containers easyphone-* e
reaplica scripts/whitelist-rules.sh. Sem whitelist.conf ele fica ocioso.
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
  systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  echo "[OK] $UNIT_NAME removido."
  echo "As regras de iptables atuais permanecem; para removê-las:"
  echo "  sudo bash scripts/whitelist-rules.sh --remove"
  exit 0
fi

[[ -f "$TEMPLATE" ]] || { echo "Template não encontrado: $TEMPLATE" >&2; exit 1; }
[[ -f "$WATCH_SCRIPT" ]] || { echo "Watcher não encontrado: $WATCH_SCRIPT" >&2; exit 1; }

sed "s|__WHITELIST_WATCH_SCRIPT__|$WATCH_SCRIPT|g" "$TEMPLATE" > "$UNIT_PATH"
chmod 644 "$UNIT_PATH"

systemctl daemon-reload
systemctl enable "$UNIT_NAME"

if ! systemctl restart "$UNIT_NAME"; then
  echo "[ERROR] Falha ao iniciar $UNIT_NAME." >&2
  systemctl status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/    /' >&2 || true
  exit 1
fi

if systemctl is-active --quiet "$UNIT_NAME"; then
  echo "[OK] $UNIT_NAME instalado, habilitado e ativo."
else
  echo "[ERROR] $UNIT_NAME não ficou ativo." >&2
  systemctl status "$UNIT_NAME" --no-pager 2>&1 | sed 's/^/    /' >&2 || true
  exit 1
fi

echo "Status: systemctl status $UNIT_NAME"
echo "Logs:   journalctl -u $UNIT_NAME -f"
if [[ ! -f "$ROOT_DIR/whitelist.conf" ]]; then
  echo "Aviso: whitelist.conf ainda não existe; o watcher ficará ocioso até ser criado."
fi
