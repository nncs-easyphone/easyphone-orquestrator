#!/usr/bin/env bash
#
# EasyFone Orchestrator — Script de Inicialização do Servidor
# ============================================================
# Instala e configura Docker, iptables e dependências para
# rodar a stack completa do EasyFone (Postgres, API, Web, Asterisk).
#
# Uso: sudo bash init.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
#  CORES E LOGS
# ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

info()     { echo -e "${BLUE}[INFO]${NC}     $*"; }
ok()       { echo -e "${GREEN}[OK]${NC}       $*"; }
warn()     { echo -e "${YELLOW}[WARN]${NC}     $*"; }
error()    { echo -e "${RED}[ERROR]${NC}    $*"; }
step()     { echo -e "\n${MAGENTA}${BOLD}━━━ $* ━━━${NC}"; }
divider()  { echo -e "${BLUE}────────────────────────────────────────────${NC}"; }

# ─────────────────────────────────────────────────────────────────────
#  FUNÇÕES DE INTERAÇÃO
# ─────────────────────────────────────────────────────────────────────
ask_yes() {
  local prompt="$1 [S/n] " ans
  read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt}")" ans
  [[ -z "${ans:-}" || "$ans" =~ ^[SsYy]$ ]]
}

ask_no() {
  local prompt="$1 [s/N] " ans
  read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt}")" ans
  [[ "${ans:-}" =~ ^[Ss]$ ]]
}

# ─────────────────────────────────────────────────────────────────────
#  SISTEMA DE LOGS — caixa emoldurada + arquivo
# ─────────────────────────────────────────────────────────────────────
LOGFILE="/tmp/easyfone-orquestrator-install.log"
: > "$LOGFILE"

box_start() {
  local title="$1"
  local len=60
  local dashes
  dashes=$(printf '─%.0s' $(seq 1 $((len - ${#title} - 2))))
  echo -e "┌─ ${BOLD}${title}${NC} ${dashes}┐"
}

box_end() {
  echo -e "└$(printf '─%.0s' $(seq 1 58))┘"
  echo
}

# ─────────────────────────────────────────────────────────────────────
#  VERIFICAÇÕES INICIAIS
# ─────────────────────────────────────────────────────────────────────
cat << "EOF"

 ╔══════════════════════════════════════════════════════════╗
 ║        EasyFone Orchestrator — Server Setup              ║
 ║        Docker + iptables + Firewall                      ║
 ╚══════════════════════════════════════════════════════════╝
EOF

if [[ $EUID -ne 0 ]]; then
  error "Este script precisa ser executado como root."
  echo "  sudo bash $0"
  exit 1
fi

INSTALLED=()

# Atualiza índice de pacotes uma única vez no início
box_start "Atualização de pacotes"
apt-get update 2>&1 | tee -a "$LOGFILE"
ok "Índice de pacotes atualizado."
box_end

# ─────────────────────────────────────────────────────────────────────
#  1. DOCKER
# ─────────────────────────────────────────────────────────────────────
step "1/5 — Docker Engine"

if command -v docker &>/dev/null; then
  ok "Docker já está instalado: $(docker --version 2>/dev/null)"
  if ! ask_yes "Deseja reinstalar/atualizar o Docker?"; then
    echo "  → Pulando instalação do Docker."
  else
    warn "Removendo instalação existente…"
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    INSTALLED+=("docker (reinstalado)")
  fi
fi

if ! command -v docker &>/dev/null || [[ " ${INSTALLED[*]} " =~ "docker (reinstalado)" ]]; then
  if ask_yes "Instalar Docker?"; then
    info "Verificando curl…"
    if ! command -v curl &>/dev/null; then
      apt-get install -y -qq curl
      ok "curl instalado."
    fi

    box_start "Instalação do Docker"
    if ! curl -fsSL https://get.docker.com | sh 2>&1 | tee -a "$LOGFILE"; then
      error "Falha na instalação do Docker."
    else
      ok "Docker instalado com sucesso."
      INSTALLED+=("docker")

      if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        info "Usuário '$SUDO_USER' adicionado ao grupo docker."
        info "Requisite um novo shell ou faça logout/login para usar docker sem sudo."
      fi

      if docker info &>/dev/null; then
        ok "Docker daemon operacional."
      else
        warn "Docker instalado, mas o daemon pode não ter iniciado completamente."
        warn "Execute 'docker info' manualmente para verificar."
      fi
    fi
    box_end
  else
    echo "  → Pulando instalação do Docker."
  fi
fi

# Garante Docker habilitado no boot (sempre, não só na instalação)
if command -v docker &>/dev/null; then
  systemctl enable docker &>/dev/null || true
  systemctl start docker  &>/dev/null || true
  ok "Docker habilitado e iniciado no boot."
fi

divider

# ─────────────────────────────────────────────────────────────────────
#  2. GHCR LOGIN
# ─────────────────────────────────────────────────────────────────────
step "2/5 — GitHub Container Registry (ghcr.io)"

if ! command -v docker &>/dev/null; then
  warn "Docker não está disponível. Faça o login manual depois com:"
  echo "  echo TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
else
  box_start "Autenticação GHCR"

  if docker login ghcr.io &>/dev/null && docker pull ghcr.io/nncs-easyphone/easyphone-api:main --quiet &>/dev/null; then
    ok "Já está autenticado no ghcr.io com token válido."
  else
    echo ""
    warn "As imagens da stack estão em ghcr.io/nncs-easyphone"
    warn "Você precisa de um Personal Access Token (PAT) do GitHub com escopo 'read:packages'."
    echo ""
    if ask_yes "Fazer login no ghcr.io agora?"; then
      GHCR_USER=""
      while [[ -z "$GHCR_USER" ]]; do
        echo -e "${YELLOW}?${NC} Informe seu usuário do GitHub:"
        read -r -p "$(echo -e '  → ')" GHCR_USER
        [[ -z "$GHCR_USER" ]] && warn "Usuário não pode estar vazio."
      done

      GHCR_TOKEN=""
      while [[ -z "$GHCR_TOKEN" ]]; do
        echo -e "${YELLOW}?${NC} Informe seu Personal Access Token (PAT) com escopo 'read:packages':"
        read -r -s -p "$(echo -e '  → ')" GHCR_TOKEN
        echo
        [[ -z "$GHCR_TOKEN" ]] && warn "Token não pode estar vazio."
      done

      if printf '%s\n' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin; then
        if docker pull ghcr.io/nncs-easyphone/easyphone-api:main --quiet &>/dev/null; then
          ok "Autenticado no ghcr.io como '$GHCR_USER' — token válido."
        else
          warn "Login OK, mas o pull falhou. O token pode não ter escopo 'read:packages'."
          warn "Verifique o PAT em: https://github.com/settings/tokens"
        fi
      else
        error "Falha na autenticação. Verifique o usuário e o token."
      fi
    else
      echo "  → Pulando login. Você pode fazer manualmente depois:"
      echo "      echo TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
    fi
  fi

  unset GHCR_TOKEN GHCR_USER
  box_end
fi

divider

# ─────────────────────────────────────────────────────────────────────
#  3. IPTABLES
# ─────────────────────────────────────────────────────────────────────
step "3/5 — iptables"

IPTABLES_INSTALLED=false

if ! command -v iptables &>/dev/null; then
  warn "iptables não encontrado."
  if ask_yes "Instalar iptables?"; then
    box_start "Instalação do iptables"
    if ! apt-get install -y iptables 2>&1 | tee -a "$LOGFILE"; then
      error "Falha na instalação do iptables."
    else
      ok "iptables instalado."
      IPTABLES_INSTALLED=true
      INSTALLED+=("iptables")

      if ask_yes "Instalar iptables-persistent (persistência de regras entre reboots)?"; then
        box_start "Instalação do iptables-persistent"
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>&1 | tee -a "$LOGFILE"; then
          error "Falha na instalação do iptables-persistent."
        else
          ok "iptables-persistent instalado."
        fi
        box_end
      fi
    fi
    box_end
  else
    echo "  → Pulando instalação do iptables."
  fi
else
  ok "iptables já está instalado: $(iptables --version 2>/dev/null)"
  IPTABLES_INSTALLED=true

  if ! dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q "install ok installed"; then
    if ask_yes "Instalar iptables-persistent para persistência de regras?"; then
      box_start "Instalação do iptables-persistent"
      echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
      echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>&1 | tee -a "$LOGFILE"; then
        error "Falha na instalação do iptables-persistent."
      else
        ok "iptables-persistent instalado."
      fi
      box_end
    fi
  fi
fi

divider

# ─────────────────────────────────────────────────────────────────────
#  4. FIREWALL RULES
# ─────────────────────────────────────────────────────────────────────
step "4/5 — Regras de Firewall"

FIREWALL_SCRIPT="$(dirname "$(readlink -f "$0")")/firewall-rules.sh"

if [[ ! -f "$FIREWALL_SCRIPT" ]]; then
  warn "Arquivo 'firewall-rules.sh' não encontrado ao lado do init.sh."
  warn "Crie-o ou copie-o para '$FIREWALL_SCRIPT' antes de aplicar as regras."
elif ! $IPTABLES_INSTALLED; then
  warn "iptables não está instalado; não é possível aplicar regras de firewall."
elif ask_yes "Aplicar regras de firewall padrão agora?"; then
  box_start "Aplicação de regras de firewall"
  bash "$FIREWALL_SCRIPT" 2>&1 | tee -a "$LOGFILE"
  ok "Regras de firewall aplicadas."
  box_end
  INSTALLED+=("firewall-rules")
else
  echo "  → Regras de firewall não aplicadas."
  echo "  → Execute manualmente quando quiser: sudo bash firewall-rules.sh"
fi

divider

# ─────────────────────────────────────────────────────────────────────
#  5. DOCKER COMPOSE  (plugin)
# ─────────────────────────────────────────────────────────────────────
step "5/5 — Docker Compose"

if docker compose version &>/dev/null; then
  ok "Docker Compose já está disponível: $(docker compose version 2>/dev/null)"
else
  warn "Plugin 'docker compose' não encontrado."
  if ask_yes "Instalar docker-compose-plugin?"; then
    box_start "Instalação do Docker Compose"
    if ! apt-get install -y docker-compose-plugin 2>&1 | tee -a "$LOGFILE"; then
      error "Falha na instalação do docker-compose-plugin."
    else
      ok "docker-compose-plugin instalado."
      INSTALLED+=("docker-compose-plugin")
    fi
    box_end
  fi
fi

if docker compose version &>/dev/null; then
  if ask_no "Fazer pull das imagens agora (docker compose pull)?"; then
    box_start "Pull das imagens Docker"
    docker compose pull 2>&1 | tee -a "$LOGFILE"
    ok "Imagens baixadas."
    box_end
  fi

  if ask_no "Deseja subir a stack agora (docker compose up -d)?"; then
    info "Subindo serviços…"
    docker compose up -d
    ok "Stack EasyFone iniciada."
    echo
    echo -e "  ${GREEN}→${NC} Traefik:    https://app.${DOMAIN:-exemplo.com}  |  https://api.${DOMAIN:-exemplo.com}"
    echo -e "  ${GREEN}→${NC} Postgres:   localhost:${PG_PORT_HOST:-7001}  (interno)"
    echo -e "  ${GREEN}→${NC} Asterisk:   SIP 5060/udp  |  RTP 10000-20000/udp  (AMI/ARI internos)"
  fi
fi

divider

# ─────────────────────────────────────────────────────────────────────
#  SUMÁRIO FINAL
# ─────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}═══════════════════  RESUMO DA INSTALAÇÃO  ═══════════════════${NC}"
echo
if [[ ${#INSTALLED[@]} -eq 0 ]]; then
  echo "  Nenhum componente novo foi instalado (tudo já presente)."
else
  echo -e "  ${GREEN}Itens instalados/configurados:${NC}"
  for item in "${INSTALLED[@]}"; do
    echo -e "    ${GREEN}✓${NC} $item"
  done
fi
echo
echo -e "  ${BOLD}Arquivo de log:${NC} $LOGFILE"
echo
echo -e "  ${BOLD}Comandos úteis:${NC}"
echo -e "    ${BLUE}▶${NC} Subir a stack:         ${BOLD}docker compose up -d${NC}"
echo -e "    ${BLUE}▶${NC} Parar a stack:          ${BOLD}docker compose down${NC}"
echo -e "    ${BLUE}▶${NC} Ver logs:               ${BOLD}docker compose logs -f${NC}"
echo -e "    ${BLUE}▶${NC} Reaplicar firewall:     ${BOLD}sudo bash firewall-rules.sh${NC}"
echo
echo -e "${GREEN}${BOLD}✓ Init concluído com sucesso.${NC}"
