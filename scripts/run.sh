#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Script de inicialização da stack
# =========================================================
# Sobe a stack completa (Postgres, API, Web, Asterisk)
# respeitando a variável USE_BUILD do .env.
#
# Uso: bash scripts/run.sh
#        ./scripts/run.sh

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
#  DIRETÓRIO DO PROJETO E OWNERSHIP
# ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OWNER="${SUDO_USER:-}"
chown_owner() { [[ -n "$OWNER" && "$(id -u)" -eq 0 ]] && chown "$OWNER" "$@" 2>/dev/null || true; }

# ─────────────────────────────────────────────────────────────────────
#  SISTEMA DE LOGS — caixa emoldurada + arquivo
# ─────────────────────────────────────────────────────────────────────
LOGS_DIR="$REPO_DIR/logs"
mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/run-$(date +%Y%m%d-%H%M%S).log"
: > "$LOGFILE"
chown_owner "$LOGS_DIR" "$LOGFILE"

box_start() {
  local title="$1"
  local len=60
  local dashes
  dashes=$(printf '%*s' "$((len - ${#title} - 5))" '' | tr ' ' '─')
  echo -e "┌─ ${BOLD}${title}${NC} ${dashes}┐"
}

box_end() {
  echo -e "└$(printf '─%.0s' $(seq 1 58))┘"
  echo
}

# ─────────────────────────────────────────────────────────────────────
#  CARREGA .ENV
# ─────────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  error "Arquivo .env não encontrado em $ENV_FILE"
  echo "  Copie o .env.example para .env e ajuste as variáveis:"
  echo "    cp .env.example .env"
  exit 1
fi

# Carrega o .env sem executá-lo (sem `source`): atribui cada valor literalmente.
load_env_safe() {
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
    printf -v "$key" '%s' "$val"
  done < "$ENV_FILE"
}
load_env_safe

# A chave do DNS challenge precisa existir antes do compose: ela vai no
# environment da API e na URL do HTTPREQ_ENDPOINT do Traefik.
if [[ -z "${DNS_CHALLENGE_API_KEY:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    DNS_CHALLENGE_API_KEY="$(openssl rand -hex 32)"
  else
    DNS_CHALLENGE_API_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi

  if grep -q '^DNS_CHALLENGE_API_KEY=' "$ENV_FILE"; then
    sed -i "s|^DNS_CHALLENGE_API_KEY=.*|DNS_CHALLENGE_API_KEY=${DNS_CHALLENGE_API_KEY}|" "$ENV_FILE"
  else
    printf '\nDNS_CHALLENGE_API_KEY=%s\n' "$DNS_CHALLENGE_API_KEY" >> "$ENV_FILE"
  fi

  chmod 600 "$ENV_FILE" 2>/dev/null || true
  ok "API Key do DNS challenge gerada automaticamente."
fi

if [[ -z "${ASTERISK_AMI_PASSWORD:-}" || "${ASTERISK_AMI_PASSWORD}" == "default-secret" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    ASTERISK_AMI_PASSWORD="$(openssl rand -hex 24)"
  else
    ASTERISK_AMI_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi

  if grep -q '^ASTERISK_AMI_PASSWORD=' "$ENV_FILE"; then
    sed -i "s|^ASTERISK_AMI_PASSWORD=.*|ASTERISK_AMI_PASSWORD=${ASTERISK_AMI_PASSWORD}|" "$ENV_FILE"
  else
    printf '\nASTERISK_AMI_PASSWORD=%s\n' "$ASTERISK_AMI_PASSWORD" >> "$ENV_FILE"
  fi

  chmod 600 "$ENV_FILE" 2>/dev/null || true
  ok "Credencial AMI/ARI gerada automaticamente."
fi

USE_BUILD="${USE_BUILD:-false}"
chmod 600 "$ENV_FILE" 2>/dev/null || true

cd "$REPO_DIR"

# Em instalações gerenciadas o override de build não é distribuído. Um .env
# antigo com USE_BUILD=true não pode impedir a stack de subir.
if [[ "$USE_BUILD" == "true" && ! -f docker-compose.build.yml ]]; then
  warn "USE_BUILD=true, mas docker-compose.build.yml não existe — usando as imagens do registry."
  USE_BUILD=false
fi

# USE_BUILD=true é exclusivo de desenvolvimento: acrescenta o override que
# recompila as imagens a partir dos repositórios irmãos.
compose() {
  if [[ "$USE_BUILD" == "true" ]]; then
    local -a files=(-f docker-compose.yml -f docker-compose.build.yml)
    # Compose auto-carrega docker-compose.override.yml quando chamado sem -f.
    # No modo build os arquivos são explícitos, então o override precisa ser
    # incluído à mão para manter o comportamento de antes.
    [[ -f docker-compose.override.yml ]] && files+=(-f docker-compose.override.yml)
    docker compose "${files[@]}" "$@"
  else
    docker compose "$@"
  fi
}

# ─────────────────────────────────────────────────────────────────────
#  ESTADO/LOGS DO BACKUP (bind mount em /app/states)
# ─────────────────────────────────────────────────────────────────────
# O container roda como uid/gid 1001 (runner) e um bind mount NÃO herda o dono
# da imagem — o entrypoint da imagem ajusta o dono no start de forma automática.
# Espelha o que o init.sh faz apenas como reforço, para o run.sh não depender dele.
BACKUP_STATES_DIR="$REPO_DIR/states"
mkdir -p "$BACKUP_STATES_DIR"
if [[ "$(id -u)" -eq 0 ]]; then
  chown 1001:1001 "$BACKUP_STATES_DIR"
  ok "Pasta de estado/logs do backup: ${BACKUP_STATES_DIR} (dono 1001:1001)"
else
  warn "Não é root: garanta que ${BACKUP_STATES_DIR} pertença a 1001:1001 (ou rode 'sudo bash scripts/run.sh')."
fi

# ─────────────────────────────────────────────────────────────────────
#  ARQUIVOS GERADOS PELO INIT.SH
# ─────────────────────────────────────────────────────────────────────
# O compose faz bind mount de coturn/turnserver.conf. Se o arquivo não existir,
# o Docker cria um DIRETÓRIO com esse nome e o Coturn falha com um erro obscuro —
# por isso a checagem acontece antes de qualquer `up`.
MISSING_GENERATED=()
[[ -f "traefik/conf/wss.yml"      ]] || MISSING_GENERATED+=("traefik/conf/wss.yml")
[[ -f "coturn/turnserver.conf"    ]] || MISSING_GENERATED+=("coturn/turnserver.conf")

if [[ ${#MISSING_GENERATED[@]} -gt 0 ]]; then
  error "Arquivos de configuração ausentes (gerados pelo init.sh a partir do .env):"
  for f in "${MISSING_GENERATED[@]}"; do
    echo "    - $f"
  done
  echo
  echo "  Gere-os com:"
  echo "    sudo bash init.sh"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────
#  SOBE A STACK
# ─────────────────────────────────────────────────────────────────────

if [[ "$USE_BUILD" == "true" ]]; then
  info "USE_BUILD=true  → build local dos Dockerfiles"

  box_start "Build e inicialização da stack"
  compose up -d 2>&1 | tee -a "$LOGFILE"
  echo ""
  info "Logs de inicialização:"
  compose logs --tail=100 2>&1 | tee -a "$LOGFILE"
  box_end
else
  info "USE_BUILD=false → imagens do registry"

  # Verifica autenticação ghcr; </dev/null evita travamento
  if ! docker login ghcr.io </dev/null &>/dev/null; then
    warn "Não autenticado no ghcr.io. Execute 'sudo bash init.sh' para configurar o login."
    if ! ask_no "Tentar pull mesmo assim?"; then
      exit 1
    fi
  fi

  box_start "Pull das imagens"
  compose pull 2>&1 | tee -a "$LOGFILE"
  ok "Imagens baixadas."
  box_end

  box_start "Inicialização da stack"
  compose up -d --no-build 2>&1 | tee -a "$LOGFILE"
  echo ""
  info "Logs de inicialização:"
  compose logs --tail=100 2>&1 | tee -a "$LOGFILE"
  box_end
fi

# Reaplica a whitelist de origens, se configurada. O watcher systemd cobre os
# demais caminhos (compose up manual, restart, docker start); aqui garantimos
# aplicação imediata no fluxo documentado do run.sh.
if [[ -f "$REPO_DIR/whitelist.conf" ]]; then
  if [[ ! -f "$REPO_DIR/scripts/whitelist-rules.sh" ]]; then
    warn "scripts/whitelist-rules.sh não encontrado; whitelist não reaplicada."
  elif [[ "$(id -u)" -eq 0 ]]; then
    info "Reaplicando a whitelist de origens…"
    if ! bash "$REPO_DIR/scripts/whitelist-rules.sh" 2>&1 | tee -a "$LOGFILE"; then
      warn "Falha ao reaplicar a whitelist; a stack segue em execução."
    fi
  else
    warn "Whitelist não reaplicada: rode 'sudo bash scripts/whitelist-rules.sh'."
  fi
fi

ok "Stack EasyPhone iniciada."
echo
PG_BIND="${POSTGRES_BIND_ADDR:-127.0.0.1}"
case "$PG_BIND" in
  ""|127.0.0.1|localhost|::1) PG_EXPOSED=false ;;
  *)                          PG_EXPOSED=true ;;
esac
echo -e "  ${GREEN}→${NC} Traefik:    https://app.${DOMAIN:-exemplo.com} (web)  /  https://api.${DOMAIN:-exemplo.com} (api)  /  https://pbx.${DOMAIN:-exemplo.com} (wss)"
if [[ "$PG_EXPOSED" == true ]]; then
  echo -e "  ${YELLOW}→${NC} Postgres:   ${PG_BIND}:${PG_PORT_HOST:-7001}  (EXPOSTO EXTERNAMENTE)"
  warn "Postgres publicado fora do loopback (POSTGRES_BIND_ADDR=$PG_BIND). Use apenas no ambiente de testes."
else
  echo -e "  ${GREEN}→${NC} Postgres:   127.0.0.1:${PG_PORT_HOST:-7001}  (loopback, não exposto)"
fi
echo -e "  ${GREEN}→${NC} PgBouncer:  127.0.0.1:${PGBOUNCER_PORT_HOST:-7003}  (loopback, não exposto)"
echo -e "  ${GREEN}→${NC} Coturn:     STUN 3478/udp  |  TURN 3478/tcp+udp  |  TURNS 5349/tcp+udp  |  Relay 49152-65535/udp"
echo -e "  ${GREEN}→${NC} Asterisk:   SIP 5060/udp  |  SIP TLS 5061/tcp  |  RTP 10000-20000/udp (AMI/ARI internos)"
echo
echo -e "  ${BOLD}Arquivo de log:${NC} $LOGFILE"
