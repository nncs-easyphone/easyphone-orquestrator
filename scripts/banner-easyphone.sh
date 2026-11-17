#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Banner do console
# ==========================================
# Instala o logo do EasyPhone no /etc/issue, exibido na tela de login
# do console (TTY) no Ubuntu/Debian Server.
#
# Uso: sudo bash scripts/banner-easyphone.sh
#      sudo bash banner-easyphone.sh   (wrapper na raiz)
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Execute como root: sudo bash $0" >&2
  exit 1
fi

# 1) Backup do /etc/issue original (só na primeira vez)
if [[ ! -f /etc/issue.orig ]]; then
  if [[ -f /etc/issue ]]; then
    cp /etc/issue /etc/issue.orig
  else
    : > /etc/issue.orig
  fi
fi

# 2) Remove o serviço de paleta da versão anterior (era sobrescrito pelo driver de vídeo)
LEGACY_UNIT="easyphone-console-cores.service"
if [[ -f "/etc/systemd/system/$LEGACY_UNIT" ]] || systemctl cat "$LEGACY_UNIT" &>/dev/null; then
  systemctl disable --now "$LEGACY_UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$LEGACY_UNIT"
  systemctl daemon-reload 2>/dev/null || true
fi

# 3) Novo /etc/issue
#    Primeira linha: redefine a paleta do console a cada exibição do login
#      \e]P5 5B30D0 -> cor 5  (magenta)       vira azul EasyPhone
#      \e]PD C4B3EE -> cor 13 (magenta claro) vira lavanda
#    O ícone usa só '█' (as fontes do console nem sempre têm ▄ e ▀)
cat > /etc/issue <<'EOF'
\e]P55B30D0\e]PDC4B3EE
  \e[0;35m ██████████████████ \e[0m
  \e[0;35m████████████████████\e[0m   \e[1;37m _____                ____  _\e[0m
  \e[0;35m████\e[1;37m████████████\e[0;35m████\e[0m   \e[1;37m| ____|__ _ ___ _   _|  _ \\| |__   ___  _ __   ___\e[0m
  \e[0;35m████████████████████\e[0m   \e[1;37m|  _| / _` / __| | | | |_) | '_ \\ / _ \\| '_ \\ / _ \\\e[0m
  \e[0;35m████\e[1;37m█████████\e[0;35m███████\e[0m   \e[1;37m| |__| (_| \\__ \\ |_| |  __/| | | | (_) | | | |  __/\e[0m
  \e[0;35m████████████████████\e[0m   \e[1;37m|_____\\__,_|___/\\__, |_|   |_| |_|\\___/|_| |_|\\___|\e[0m
  \e[0;35m████\e[1;35m████████████\e[0;35m████\e[0m   \e[1;37m                |___/\e[0m
  \e[0;35m████████████████████\e[0m
  \e[0;35m ██████████████████ \e[0m   \e[1;35mPlataforma de Telefonia\e[0m

  Servidor: \n  |  IP: \4  |  \d \t


EOF

# 4) Reinicia o getty para o banner aparecer imediatamente
if command -v systemctl &>/dev/null && systemctl cat getty@tty1.service &>/dev/null; then
  systemctl restart getty@tty1.service 2>/dev/null || true
fi

echo "Pronto. Veja o resultado no console (Ctrl+Alt+F1)."
echo "Para desfazer: cp /etc/issue.orig /etc/issue && systemctl restart getty@tty1"
