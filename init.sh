#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Script de Inicialização do Servidor
# ============================================================
# Instala e configura Docker, iptables e dependências para
# rodar a stack completa do EasyPhone (Postgres, API, Web, Asterisk).
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

ask_value() {
  local prompt="$1" default="$2" var_name="$3" ans current
  current="${!var_name:-}"
  [[ -n "$current" ]] && default="$current"
  read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt} [${default}]: ")" ans
  ans="${ans:-$default}"
  printf -v "$var_name" '%s' "$ans"
}

# ask_secret: como ask_value, mas não ecoa a digitação nem exibe o valor
# padrão. Enter mantém o valor atual da variável (se houver).
ask_secret() {
  local prompt="$1" default="$2" var_name="$3" ans
  printf '%s' "$(echo -e "${YELLOW}?${NC} ${prompt} [Enter mantém o atual]: ")"
  read -rs ans
  echo
  ans="${ans:-$default}"
  printf -v "$var_name" '%s' "$ans"
}

# gen_hex_secret <bytes>: senha só com [0-9a-f] — segura para ODBC, URLs e .env.
gen_hex_secret() {
  local bytes="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  elif [[ -r /dev/urandom ]]; then
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    error "Sem 'openssl' nem /dev/urandom para gerar segredo seguro."
    return 1
  fi
}

# is_safe_secret: aceita apenas caracteres que não quebram ODBC/URL/.env.
is_safe_secret() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# is_valid_port: inteiro entre 1 e 65535.
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# Portas já usadas pela stack — a porta de gestão não deve colidir com elas.
is_stack_port() {
  case "$1" in
    80|443|5060|5061|3478|5349|7001|7003|8089) return 0 ;;
    *) return 1 ;;
  esac
}

# read_env <chave>: lê um valor do .env SEM source (evita executar o arquivo).
read_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-; }

# load_env_safe: carrega o .env inteiro SEM executá-lo — atribui cada valor
# literalmente. Evita que aspas, `$`, crases ou o JSON do service account
# quebrem/executem algo e evita que valores exportados sobrescrevam o .env.
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

# update_env: grava o valor literal (via ENVIRON, sem interpretar escapes).
update_env() {
  local key="$1" value="$2" file="$3"
  [[ "$value" == *$'\n'* ]] && { error "Valor de $key contém quebra de linha."; return 1; }
  KEY="$key" VAL="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; replaced = 0 }
    index($0, k "=") == 1 { print k "=" v; replaced = 1; next }
    { print }
    END { if (!replaced) print k "=" v }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  chown_owner "$file"
}

# ─────────────────────────────────────────────────────────────────────
#  DIRETÓRIO DO PROJETO E OWNERSHIP
# ─────────────────────────────────────────────────────────────────────
REPO_DIR="$(dirname "$(readlink -f "$0")")"
OWNER="${SUDO_USER:-}"
# chown_owner: arquivos criados por este script (que roda como root) passam a
# pertencer ao usuário real do repositório, mantendo a pasta editável por ele.
chown_owner() { [[ -n "$OWNER" && "$(id -u)" -eq 0 ]] && chown "$OWNER" "$@" 2>/dev/null || true; }

# ─────────────────────────────────────────────────────────────────────
#  SISTEMA DE LOGS — caixa emoldurada + arquivo
# ─────────────────────────────────────────────────────────────────────
LOGS_DIR="$REPO_DIR/logs"
mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/install-$(date +%Y%m%d-%H%M%S).log"
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
#  VERIFICAÇÕES INICIAIS
# ─────────────────────────────────────────────────────────────────────
cat << "EOF"

 ╔══════════════════════════════════════════════════════════╗
 ║        EasyPhone Orchestrator — Server Setup              ║
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
apt-get update 2>&1 | tee -a "$LOGFILE" || { error "Falha ao atualizar índice de pacotes. Verifique a conexão."; exit 1; }
ok "Índice de pacotes atualizado."
box_end

# ─────────────────────────────────────────────────────────────────────
#  0. CONFIGURAÇÃO DE AMBIENTE (.env)
# ─────────────────────────────────────────────────────────────────────
step "0/6 — Configuração de Ambiente (.env)"

ENV_FILE="$(dirname "$(readlink -f "$0")")/.env"
ENV_EXAMPLE="$(dirname "$(readlink -f "$0")")/.env.example"

FIRST_RUN=false
CONFIG_ENABLED=false

if [[ -f "$ENV_FILE" ]]; then
  if ask_no "Deseja atualizar as variáveis do .env?"; then
    info "Carregando valores atuais do .env..."
    load_env_safe
    CONFIG_ENABLED=true
  else
    ok "Arquivo .env já existe — pulando configuração."
  fi
else
  info "Criando .env a partir do .env.example..."
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  chown_owner "$ENV_FILE"
  FIRST_RUN=true
  CONFIG_ENABLED=true
fi

if $CONFIG_ENABLED; then

  box_start "Configuração Global"
  ask_value "Domínio padrão (ex: easyphone.com.br)" "exemplo.com" DOMAIN
  update_env "DOMAIN" "$DOMAIN" "$ENV_FILE"

  ask_value "Email para Let's Encrypt" "admin@exemplo.com" LETSENCRYPT_EMAIL
  update_env "LETSENCRYPT_EMAIL" "$LETSENCRYPT_EMAIL" "$ENV_FILE"

  box_end

  # ── Porta de gestão (SSH) ──
  # Gravada no .env e usada pelo firewall-rules.sh (inclusive no boot) para
  # liberar o acesso administrativo. O sshd NÃO é alterado por este script.
  if ask_yes "Configurar a porta de gestão do servidor (SSH)?"; then
    box_start "Porta de gestão (SSH)"
    ask_value "Porta de gestão (SSH)" "22" SSH_PORT
    while ! is_valid_port "$SSH_PORT"; do
      warn "Informe um número entre 1 e 65535."
      ask_value "Porta de gestão (SSH)" "22" SSH_PORT
    done
    if is_stack_port "$SSH_PORT"; then
      warn "A porta $SSH_PORT é usada pela stack EasyPhone — escolha outra para evitar conflito."
    fi
    update_env "SSH_PORT" "$SSH_PORT" "$ENV_FILE"
    box_end

    if [[ "$SSH_PORT" != "22" ]]; then
      warn "O firewall vai liberar apenas a porta $SSH_PORT para acesso administrativo."
      warn "O sshd TAMBÉM precisa escutar nessa porta, senão você perderá o acesso."
      echo
      echo -e "  Para ajustar o sshd:"
      echo -e "    ${BLUE}▶${NC} Crie /etc/ssh/sshd_config.d/10-management-port.conf com: ${BOLD}Port $SSH_PORT${NC}"
      echo -e "    ${BLUE}▶${NC} Valide e reinicie: ${BOLD}sshd -t && systemctl restart ssh${NC}"
      echo
    fi
  else
    ok "Porta de gestão mantida como está (${SSH_PORT:-22})."
  fi

  # ── Postgres ──
  if ask_yes "Configurar variáveis do Postgres?"; then
    box_start "Configuração Postgres"
    ask_value "Usuário do Postgres" "easyphone" POSTGRES_USER
    update_env "POSTGRES_USER" "$POSTGRES_USER" "$ENV_FILE"

    if command -v docker >/dev/null 2>&1 && docker volume ls -q 2>/dev/null | grep -qE '_pgdata$'; then
      warn "Já existe um volume de dados do Postgres neste host."
      warn "Trocar POSTGRES_PASSWORD aqui NÃO altera a senha da role no banco —"
      warn "isso quebra a conexão. Para trocar, use rotate-postgres-password.sh (ou ALTER ROLE)."
    fi

    printf -v RANDOM_PG_PASS '%s' "$(gen_hex_secret 24)"
    ask_secret "Senha do Postgres" "$RANDOM_PG_PASS" POSTGRES_PASSWORD
    while ! is_safe_secret "$POSTGRES_PASSWORD"; do
      warn "Use apenas letras, números, ponto, hífen e underline (evita quebrar ODBC/URL/.env)."
      ask_secret "Senha do Postgres" "$RANDOM_PG_PASS" POSTGRES_PASSWORD
    done
    update_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD" "$ENV_FILE"

    ask_value "Banco padrão" "easyphone" POSTGRES_DB
    update_env "POSTGRES_DB" "$POSTGRES_DB" "$ENV_FILE"
    box_end
  elif $FIRST_RUN; then
    box_start "Configuração Postgres"
    printf -v POSTGRES_PASSWORD '%s' "$(gen_hex_secret 24)"
    update_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD" "$ENV_FILE"
    ok "Senha do Postgres gerada automaticamente."
    box_end
  else
    ok "Variáveis do Postgres mantidas como estão."
  fi

  # ── API ──
  if ask_yes "Configurar variáveis da API (JWT, crypto key)?"; then
    box_start "Configuração da API"
    warn "Trocar o JWT_SECRET invalida as sessões ativas."
    warn "Trocar a DATA_SECRET_CRYPTOGRAPHY_KEY torna ILEGÍVEIS os dados já cifrados — em instalação que já roda, mantenha o valor atual (Enter)."
    printf -v RANDOM_JWT '%s' "$(gen_hex_secret 32)"
    ask_secret "JWT Secret" "$RANDOM_JWT" JWT_SECRET
    update_env "JWT_SECRET" "$JWT_SECRET" "$ENV_FILE"

    printf -v RANDOM_CRYPTO '%s' "$(gen_hex_secret 24)"
    ask_secret "Data Secret Cryptography Key" "$RANDOM_CRYPTO" DATA_SECRET_CRYPTOGRAPHY_KEY
    update_env "DATA_SECRET_CRYPTOGRAPHY_KEY" "$DATA_SECRET_CRYPTOGRAPHY_KEY" "$ENV_FILE"
    box_end
  elif $FIRST_RUN; then
    box_start "Configuração da API"
    printf -v JWT_SECRET '%s' "$(gen_hex_secret 32)"
    update_env "JWT_SECRET" "$JWT_SECRET" "$ENV_FILE"
    printf -v DATA_SECRET_CRYPTOGRAPHY_KEY '%s' "$(gen_hex_secret 24)"
    update_env "DATA_SECRET_CRYPTOGRAPHY_KEY" "$DATA_SECRET_CRYPTOGRAPHY_KEY" "$ENV_FILE"
    ok "JWT Secret e Cryptography Key gerados automaticamente."
    box_end
  else
    ok "Variáveis da API mantidas como estão."
  fi

  # ── Coturn ──
  if ask_yes "Configurar variáveis do Coturn (STUN/TURN)?"; then
    box_start "Configuração Coturn"
    ask_value "Usuário do Coturn" "easyphone" COTURN_USER
    update_env "COTURN_USER" "$COTURN_USER" "$ENV_FILE"

    printf -v RANDOM_COTURN_PASS '%s' "$(gen_hex_secret 24)"
    ask_secret "Senha do Coturn" "$RANDOM_COTURN_PASS" COTURN_PASS
    while ! is_safe_secret "$COTURN_PASS"; do
      warn "Use apenas letras, números, ponto, hífen e underline."
      ask_secret "Senha do Coturn" "$RANDOM_COTURN_PASS" COTURN_PASS
    done
    update_env "COTURN_PASS" "$COTURN_PASS" "$ENV_FILE"
    box_end
  elif $FIRST_RUN; then
    box_start "Configuração Coturn"
    printf -v COTURN_PASS '%s' "$(gen_hex_secret 24)"
    update_env "COTURN_PASS" "$COTURN_PASS" "$ENV_FILE"
    ok "Senha do Coturn gerada automaticamente."
    box_end
  else
    ok "Variáveis do Coturn mantidas como estão."
  fi

  # ── Firebase Service Account ──
  if $FIRST_RUN; then
    update_env "FIREBASE_SERVICE_ACCOUNT" "" "$ENV_FILE"
    ok "Firebase Service Account definido como vazio — edite manualmente no .env."
  else
    warn "Firebase Service Account não foi alterado. Edite manualmente no .env se necessário."
  fi

  # ── Firebase ──
  if ask_yes "Configurar URL do Firebase?"; then
    box_start "Configuração Firebase"
    ask_value "URL base das Cloud Functions" "https://us-central1-easyfone-bc601.cloudfunctions.net" FIREBASE_URL
    update_env "FIREBASE_URL" "$FIREBASE_URL" "$ENV_FILE"
    box_end
  else
    ok "URL do Firebase mantida como está."
  fi

  # ── License ──
  if ask_yes "Configurar variáveis de Licença?"; then
    box_start "Configuração de Licença"
    ask_value "Client ID da licença" "" LICENSE_CLIENT_ID
    update_env "LICENSE_CLIENT_ID" "$LICENSE_CLIENT_ID" "$ENV_FILE"

    MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
    ask_value "Hardware ID da licença" "$MACHINE_ID" LICENSE_HARDWARE_ID
    update_env "LICENSE_HARDWARE_ID" "$LICENSE_HARDWARE_ID" "$ENV_FILE"
    box_end
  else
    ok "Variáveis de Licença mantidas como estão."
  fi

  # ── Corporate Integration (Matriz/Unidade) ──
  if ask_yes "Configurar integração corporativa (Matriz/Unidade)?"; then
    box_start "Integração Corporativa"
    echo -e "  A instalação é:"
    echo -e "    ${BOLD}1${NC}) Matriz  (recebe dados das unidades)"
    echo -e "    ${BOLD}2${NC}) Unidade (envia dados para a matriz)"
    echo
    CORP_ROLE=""
    while [[ "$CORP_ROLE" != "1" && "$CORP_ROLE" != "2" ]]; do
      read -r -p "$(echo -e "${YELLOW}?${NC} Escolha 1 ou 2: ")" CORP_ROLE
    done

    if [[ "$CORP_ROLE" == "1" ]]; then
      ask_value "Chave para autorizar unidades" \
        "" CORPORATE_ALLOW_API_KEY
      update_env "CORPORATE_ALLOW_API_KEY" "$CORPORATE_ALLOW_API_KEY" "$ENV_FILE"
      update_env "CORPORATE_API_KEY" "" "$ENV_FILE"
      ok "Matriz configurada — CORPORATE_ALLOW_API_KEY definida."
    else
      ask_value "Chave de API fornecida pela matriz para envio de dados" \
        "" CORPORATE_API_KEY
      update_env "CORPORATE_API_KEY" "$CORPORATE_API_KEY" "$ENV_FILE"
      update_env "CORPORATE_ALLOW_API_KEY" "" "$ENV_FILE"
      ok "Unidade configurada — CORPORATE_API_KEY definida."
    fi
    box_end
  else
    ok "Integração corporativa não configurada."
  fi

  ok ".env configurado com sucesso!"
fi

# Carrega .env para os steps seguintes (se existe) — sem executar o arquivo
if [[ -f "$ENV_FILE" ]]; then
  load_env_safe
fi

# ─────────────────────────────────────────────────────────────────────
#  0b. ARQUIVOS GERADOS A PARTIR DO .ENV
# ─────────────────────────────────────────────────────────────────────
# Rodam SEMPRE (não só na primeira execução): instalações que já tinham .env
# também precisam do proxy WSS e do turnserver.conf, e ambos precisam ser
# regerados quando o domínio ou a senha do Coturn mudam.
step "0b/6 — Configuração gerada (Traefik WSS + Coturn)"

ROOT_DIR="$REPO_DIR"

# Escapa o que o lado direito de um `sed s|…|…|` interpreta.
escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

render_template() {
  local template="$1" output="$2" label="$3"
  if [[ ! -f "$template" ]]; then
    warn "Template não encontrado: $template — pulando ${label}."
    return
  fi
  mkdir -p "$(dirname "$output")"
  sed \
    -e "s|\${DOMAIN}|$(escape_sed_replacement "${DOMAIN:-exemplo.com}")|g" \
    -e "s|\${COTURN_USER}|$(escape_sed_replacement "${COTURN_USER:-easyphone}")|g" \
    -e "s|\${COTURN_PASS}|$(escape_sed_replacement "${COTURN_PASS:-easyphone}")|g" \
    -e "s|\${COTURN_EXTERNAL_IP}|$(escape_sed_replacement "${COTURN_EXTERNAL_IP:-}")|g" \
    "$template" > "$output"
  # Diretiva sem valor faz o Coturn recusar a config: remove `chave=` vazio.
  # No caso do external-ip, cair fora deixa valer a autodetecção do CMD da imagem.
  sed -i.bak -E '/^[a-z0-9-]+=[[:space:]]*$/d' "$output" && rm -f "${output}.bak"
  chown_owner "$(dirname "$output")" "$output"
  ok "${label} gerado em ${output}."
}

box_start "Arquivos gerados"
render_template "${ROOT_DIR}/traefik/conf/wss.yml.example" \
                "${ROOT_DIR}/traefik/conf/wss.yml" \
                "Proxy WSS do Traefik (pbx.${DOMAIN:-exemplo.com})"
render_template "${ROOT_DIR}/coturn/turnserver.conf.example" \
                "${ROOT_DIR}/coturn/turnserver.conf" \
                "Config do Coturn"
box_end

divider

# ─────────────────────────────────────────────────────────────────────
#  1. DOCKER
# ─────────────────────────────────────────────────────────────────────
step "1/6 — Docker Engine"

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
step "2/6 — GitHub Container Registry (ghcr.io)"

if ! command -v docker &>/dev/null; then
  warn "Docker não está disponível. Faça o login manual depois com:"
  echo "  echo TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
else
  box_start "Autenticação GHCR"

  if docker login ghcr.io </dev/null &>/dev/null; then
    if docker buildx imagetools inspect ghcr.io/nncs-easyphone/easyphone-api:main &>/dev/null; then
      ok "Já está autenticado no ghcr.io com token válido."
    else
      warn "Autenticação OK, mas a verificação da imagem falhou (verifique rede ou disponibilidade do registry)."
    fi
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
        if docker buildx imagetools inspect ghcr.io/nncs-easyphone/easyphone-api:main &>/dev/null; then
          ok "Autenticado no ghcr.io como '$GHCR_USER' — token válido."
        else
          warn "Login OK, mas a verificação da imagem falhou. O token pode não ter escopo 'read:packages'."
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
step "3/6 — iptables"

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
step "4/6 — Regras de Firewall"

FIREWALL_SCRIPT="$REPO_DIR/firewall-rules.sh"
FIREWALL_UNIT_TEMPLATE="$REPO_DIR/systemd/easyphone-firewall.service.example"
FIREWALL_UNIT_PATH="/etc/systemd/system/easyphone-firewall.service"

if [[ ! -f "$FIREWALL_SCRIPT" ]]; then
  warn "Arquivo 'firewall-rules.sh' não encontrado ao lado do init.sh."
  warn "Crie-o ou copie-o para '$FIREWALL_SCRIPT' antes de aplicar as regras."
elif ! $IPTABLES_INSTALLED; then
  warn "iptables não está instalado; não é possível aplicar regras de firewall."
else
  # ── 4a. Serviço que reaplica o firewall a cada boot ────────────────
  #     Instalado ANTES de aplicar as regras: o firewall-rules.sh checa se este
  #     unit está habilitado para decidir se ainda precisa salvar um snapshot da
  #     tabela. O unit roda depois do docker.service, então as chains DOCKER-*
  #     já existem quando as regras do projeto entram — o oposto do snapshot,
  #     que é restaurado com FLUSH e apaga essas chains, quebrando o
  #     `docker network create` com "No chain/target/match by that name".
  if [[ ! -f "$FIREWALL_UNIT_TEMPLATE" ]]; then
    warn "Template 'systemd/easyphone-firewall.service.example' não encontrado; unit não instalado."
  elif ! command -v systemctl &>/dev/null; then
    warn "systemctl não disponível; unit de firewall não instalado."
  elif ask_yes "Instalar o serviço que reaplica o firewall a cada boot (recomendado)?"; then
    box_start "Instalação do easyphone-firewall.service"
    sed "s|__FIREWALL_SCRIPT__|$FIREWALL_SCRIPT|g" \
      "$FIREWALL_UNIT_TEMPLATE" > "$FIREWALL_UNIT_PATH"
    systemctl daemon-reload
    systemctl enable easyphone-firewall.service 2>&1 | tee -a "$LOGFILE"
    ok "easyphone-firewall.service instalado e habilitado."
    INSTALLED+=("easyphone-firewall.service")
    box_end

    if systemctl is-enabled netfilter-persistent &>/dev/null; then
      warn "netfilter-persistent restaura um snapshot da tabela inteira no boot."
      warn "É esse snapshot que pode apagar as chains do Docker; o serviço acima"
      warn "substitui a função reaplicando as regras depois que o Docker sobe."
      if ask_yes "Desabilitar o netfilter-persistent?"; then
        systemctl disable netfilter-persistent 2>&1 | tee -a "$LOGFILE"
        ok "netfilter-persistent desabilitado."
      else
        echo "  → Mantido. Se o 'docker compose up' falhar após um reboot, comece por aqui."
      fi
    fi
  else
    echo "  → Serviço não instalado; as regras não serão reaplicadas no boot."
  fi

  # ── 4b. Aplica as regras agora ─────────────────────────────────────
  if ask_yes "Aplicar regras de firewall padrão agora?"; then
    APPLY_FIREWALL=true
    # Salvaguarda: com porta de gestão ≠ 22 o firewall passa a liberar APENAS
    # ela. Se o sshd ainda escutar na 22, aplicar as regras derruba o acesso.
    if [[ "${SSH_PORT:-22}" != "22" ]]; then
      warn "O firewall vai liberar APENAS a porta ${SSH_PORT} para acesso administrativo."
      warn "Confirme que o sshd JÁ escuta nela. Caso contrário você perderá o acesso ao servidor."
      if ! ask_yes "O sshd já está escutando na porta ${SSH_PORT}. Aplicar as regras?"; then
        APPLY_FIREWALL=false
      fi
    fi

    if $APPLY_FIREWALL; then
      box_start "Aplicação de regras de firewall"
      bash "$FIREWALL_SCRIPT" 2>&1 | tee -a "$LOGFILE"
      ok "Regras de firewall aplicadas."
      box_end
      INSTALLED+=("firewall-rules")
    else
      echo "  → Regras de firewall não aplicadas."
      echo "  → Ajuste o sshd e rode: sudo bash firewall-rules.sh"
    fi
  else
    echo "  → Regras de firewall não aplicadas."
    echo "  → Execute manualmente quando quiser: sudo bash firewall-rules.sh"
  fi
fi

divider

# ─────────────────────────────────────────────────────────────────────
#  5. DOCKER COMPOSE  (plugin)
# ─────────────────────────────────────────────────────────────────────
step "5/6 — Docker Compose"

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
echo -e "${BOLD}${BLUE}═══════════════════  LOG COMPLETO  ═══════════════════${NC}"
echo
if [[ -s "$LOGFILE" ]]; then
  cat "$LOGFILE"
else
  echo "  (log vazio)"
fi
echo
echo
echo -e "${BOLD}${YELLOW}═══════════════════  ATENÇÃO  ═══════════════════${NC}"
echo
echo -e "  ${YELLOW}⚠${NC} O Firebase Service Account foi definido como ${BOLD}vazio${NC} neste script."
echo -e "  Para funcionar corretamente, edite o arquivo ${BOLD}.env${NC} e"
echo -e "  preencha a variável ${BOLD}FIREBASE_SERVICE_ACCOUNT${NC}"
echo -e "  com o JSON da sua conta de serviço (em linha única)."
echo
echo -e "  ${BOLD}Exemplo:${NC}"
echo -e "    ${BLUE}▶${NC} Edite manualmente:  ${BOLD}nano .env${NC}"
echo
echo -e "${GREEN}${BOLD}✓ Init concluído com sucesso.${NC}"
