#!/usr/bin/env bash
# Wrapper de compatibilidade: a implementação fica em scripts/init.sh.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
TARGET="$SCRIPT_DIR/scripts/init.sh"

[[ -f "$TARGET" ]] || { echo "Implementação não encontrada: $TARGET" >&2; exit 1; }
exec bash "$TARGET" "$@"
