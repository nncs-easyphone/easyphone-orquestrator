#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Logo no terminal
# =========================================
# Instala/reinstala o banner do console (/etc/issue) e o MOTD do SSH
# (/etc/update-motd.d/01-easyphone) em máquinas que já rodaram o init.sh.
#
# Uso: sudo bash install-terminal-logo.sh [--console|--ssh|--all]
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
ROOT_DIR="$SCRIPT_DIR"

case "${1:-}" in
  -h|--help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo bash $0" >&2
  exit 1
fi

install_console() {
  bash "$ROOT_DIR/scripts/banner-easyphone.sh"
}

install_ssh() {
  bash "$ROOT_DIR/scripts/motd-easyphone.sh"
}

case "${1:-}" in
  ""|--all)
    install_console
    install_ssh
    ;;
  --console)
    install_console
    ;;
  --ssh|--motd)
    install_ssh
    ;;
  *)
    echo "Opção desconhecida: $1" >&2
    echo "Use: sudo bash $0 [--console|--ssh|--all]" >&2
    exit 1
    ;;
esac
