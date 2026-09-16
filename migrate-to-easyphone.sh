#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Migração de instalações antigas (EasyFone → EasyPhone)
# Uso: sudo bash migrate-to-easyphone.sh [opções]
#
# Migra uma instalação antiga SEM PERDER DADOS. Rode DEPOIS do `git pull` (o
# docker-compose.yml já traz os nomes novos) e ANTES do
# `docker compose up -d --force-recreate`.
#
# O script DETECTA o estado real (projeto/volumes/BD) e é IDEMPOTENTE: pode ser
# re-executado (retoma pela análise do estado atual) sem recriar/apagar dados.
#
# Segurança de dados (travas):
#   - nunca usa `down -v`/`volume prune`;
#   - faz backup (.env + pg_dump + snapshot dos volumes) ANTES de qualquer mutação;
#   - a cópia de volume é read-only na origem e nunca sobrescreve alvo com dados;
#   - exige PG_VERSION no volume (nunca inicializa banco vazio);
#   - aborta se o volume estiver em uso ou sem espaço em disco;
#   - operações de banco são não-destrutivas (só RENAME/PASSWORD);
#   - nada antigo é apagado antes do sucesso (--cleanup é explícito e pede confirmação).
#
# Opções:
#   --dry-run              Mostra o plano sem alterar nada.
#   --yes                  Não-interativo (responde "sim" às confirmações).
#   --restart              Ignora o estado anterior e recomeça do zero.
#   --resume               Força a retomada de uma execução interrompida.
#   --skip-volume-backup   Não faz snapshot dos volumes (não recomendado).
#   --old-project <nome>   Força o projeto Compose antigo (senão, auto-detecta).
#   --password <valor>     Define a senha do Postgres explicitamente.
#   --keep-db-password     Não altera a senha existente (avisa se for insegura).
#   --skip-db              Não mexe em role/db/senha do Postgres.
#   --skip-firewall        Não mexe no firewall do host.
#   --cleanup              Após sucesso, remove o resíduo antigo (pede confirmação).
#   --force                Prossegue em situações ambíguas de menor risco.
#   -h, --help             Mostra esta ajuda.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
#  CONSTANTES  (tudo dentro da pasta do orquestrador)
# ─────────────────────────────────────────────────────────────────────
REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

ENV_FILE="$REPO_DIR/.env"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
LOGS_DIR="$REPO_DIR/logs"
LOG_FILE="$LOGS_DIR/migrate-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="$LOGS_DIR/migrate.state"
BACKUP_DIR="$LOGS_DIR/backups"
LOCK_FILE="$LOGS_DIR/migrate.lock"

# Estado/backups do script ANTIGO (lido só para compatibilidade da retomada).
LEGACY_STATE="/var/lib/easyphone-migrate/state"
LEGACY_BACKUP_DIR="/var/backups/easyphone-migrate"

NEW_PROJECT="easyphone"
NEW_PG_USER="easyphone"
NEW_PG_DB="easyphone"

OLD_UNIT="easyfone-firewall.service"
NEW_UNIT="easyphone-firewall.service"
OLD_TEMPLATE="$REPO_DIR/systemd/easyfone-firewall.service.example"
OLD_CHAIN_IN="EASYFONE_INPUT"
OLD_CHAIN_WL="EASYFONE_WHITELIST"
NEW_UNIT_TEMPLATE="$REPO_DIR/systemd/easyphone-firewall.service.example"
NEW_UNIT_PATH="/etc/systemd/system/$NEW_UNIT"

PG_MIGRATE_NAME="easyphone-pg-migrate"
TEMP_ROLE="ep_mig"
PG_HOST_PORT="7001"
TRUST_STARTED=false

# ─────────────────────────────────────────────────────────────────────
#  CORES / LOG
# ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

OWNER="${SUDO_USER:-}"
chown_owner() { [[ -n "$OWNER" && "$(id -u)" -eq 0 ]] && chown "$OWNER" "$@" 2>/dev/null || true; }

info()  { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
step()  { echo; echo -e "${BOLD}${BLUE}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"; }

# Garante que o container temporário do Postgres nunca fique pendurado segurando
# o volume de dados, seja qual for o caminho de saída.
on_exit() { [[ "$TRUST_STARTED" == true ]] && docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; }

# run <cmd...> — imprime e executa (ou só imprime em --dry-run)
run() {
  echo -e "  ${BOLD}\$ $*${NC}" | tee -a "$LOG_FILE"
  if ! $DRY_RUN; then
    "$@" >>"$LOG_FILE" 2>&1
  fi
}

# ─────────────────────────────────────────────────────────────────────
#  ARGUMENTOS
# ─────────────────────────────────────────────────────────────────────
DRY_RUN=false; ASSUME_YES=false; RESTART=false; FORCE_RESUME=false
SKIP_DB=false; SKIP_FW=false; CLEANUP=false; FORCE=false
KEEP_DB_PASSWORD=false; SKIP_VOLUME_BACKUP=false; PW_OVERRIDE=""
OLD_PROJECT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)            DRY_RUN=true; shift ;;
    --yes)                ASSUME_YES=true; shift ;;
    --restart)            RESTART=true; shift ;;
    --resume)             FORCE_RESUME=true; shift ;;
    --skip-volume-backup) SKIP_VOLUME_BACKUP=true; shift ;;
    --old-project)        OLD_PROJECT_OVERRIDE="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    --password)           PW_OVERRIDE="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    --keep-db-password)   KEEP_DB_PASSWORD=true; shift ;;
    --skip-db|--skip-db-rename) SKIP_DB=true; shift ;;
    --skip-firewall)      SKIP_FW=true; shift ;;
    --cleanup)            CLEANUP=true; shift ;;
    --force)              FORCE=true; shift ;;
    -h|--help)            sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$LOGS_DIR" "$BACKUP_DIR"
: > "$LOG_FILE"
chown_owner "$LOGS_DIR" "$LOG_FILE"
trap on_exit EXIT

# ─────────────────────────────────────────────────────────────────────
#  CONFIRMAÇÃO / SELEÇÃO
# ─────────────────────────────────────────────────────────────────────
confirm() {
  local action="$1" risk="${2:-}"
  $ASSUME_YES && return 0
  if [[ ! -t 0 ]]; then
    error "Confirmação necessária (${action}) e sem TTY. Use --yes se souber o que faz."
    return 1
  fi
  {
    echo
    echo -e "${YELLOW}⚠  ${action}${NC}"
    [[ -n "$risk" ]] && echo -e "   ${YELLOW}Riscos:${NC} $risk"
  } >&2
  local ans
  read -r -p "$(echo -e "${YELLOW}?${NC} Prosseguir? [s/N]: ")" ans
  [[ "${ans:-}" =~ ^[SsYy]$ ]]
}

# select_option "<prompt>" opt1 opt2 ... → imprime a opção escolhida (stdout)
select_option() {
  local prompt="$1"; shift
  local -a opts=("$@")
  if $ASSUME_YES; then
    if [[ ${#opts[@]} -eq 1 ]]; then echo "${opts[0]}"; return 0; fi
    error "Ambiguidade (${#opts[@]} opções) com --yes: não escolho automaticamente. Rode interativamente para selecionar."
    return 1
  fi
  if [[ ! -t 0 ]]; then
    error "Seleção necessária (sem TTY). Use --yes para escolher a primeira opção."
    return 1
  fi
  {
    echo
    echo -e "${YELLOW}${prompt}${NC}"
    local i=1
    for o in "${opts[@]}"; do echo "  $i) $o"; i=$((i+1)); done
  } >&2
  local choice
  read -r -p "Escolha [1-${#opts[@]}]: " choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#opts[@]} )); then
    return 1
  fi
  echo "${opts[$((choice-1))]}"
}

# ─────────────────────────────────────────────────────────────────────
#  ESTADO / FASES
# ─────────────────────────────────────────────────────────────────────
declare -A ST=()
state_load()  { [[ -f "$STATE_FILE" ]] || return 0; while IFS='=' read -r k v; do [[ -n "$k" ]] && ST["$k"]="$v"; done < "$STATE_FILE"; }
state_flush() {
  $DRY_RUN && return 0
  local k
  { for k in "${!ST[@]}"; do printf '%s=%s\n' "$k" "${ST[$k]}"; done; } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"; chown_owner "$STATE_FILE"
}
state_set()   { ST["$1"]="$2"; state_flush; }
state_get()   { echo "${ST[$1]:-}"; }
phase_done()  { [[ "${ST[PHASE_$1]:-}" == "done" ]]; }
phase_mark()  { state_set "PHASE_$1" "done"; }

RESUME=false

# ─────────────────────────────────────────────────────────────────────
#  0. PREFLIGHT
# ─────────────────────────────────────────────────────────────────────
step "0/7 — Verificações iniciais"

[[ $EUID -eq 0 ]] || { error "Execute como root: sudo bash $0"; exit 1; }
command -v docker >/dev/null || { error "docker não encontrado."; exit 1; }
docker compose version >/dev/null 2>&1 || { error "docker compose (plugin) não encontrado."; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { error "docker-compose.yml não encontrado em $REPO_DIR."; exit 1; }
[[ -f "$ENV_FILE" ]]     || { error ".env não encontrado em $REPO_DIR (copie de .env.example)."; exit 1; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  error "Outra execução está em andamento ($LOCK_FILE)."
  exit 1
fi

# ── Estado: nova execução ou retomada ────────────────────────────────
if $RESTART; then
  rm -f "$STATE_FILE"; ST=()
fi
state_load
if [[ -z "$(state_get RUN_ID)" ]]; then
  if [[ -f "$LEGACY_STATE" ]]; then
    legacy_ts="$(grep -E '^ts=' "$LEGACY_STATE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    ST[RUN_ID]="${legacy_ts:-$(date +%Y%m%d-%H%M%S)}"
    ST[STATUS]="in_progress"
    ST[LEGACY]="true"
    ST[LEGACY_BACKUP_DIR]="$LEGACY_BACKUP_DIR"
    state_flush
    RESUME=true
    info "Execução anterior (script antigo, RUN_ID=${ST[RUN_ID]}) detectada — retomando pela análise do estado atual."
    run mkdir -p "$BACKUP_DIR/${ST[RUN_ID]}/volumes"
    [[ -f "$LEGACY_BACKUP_DIR/env.${ST[RUN_ID]}.bak" ]]     && run cp -a "$LEGACY_BACKUP_DIR/env.${ST[RUN_ID]}.bak"     "$BACKUP_DIR/${ST[RUN_ID]}/"
    [[ -f "$LEGACY_BACKUP_DIR/db.${ST[RUN_ID]}.sql.gz" ]]   && run cp -a "$LEGACY_BACKUP_DIR/db.${ST[RUN_ID]}.sql.gz"   "$BACKUP_DIR/${ST[RUN_ID]}/"
  else
    ST[RUN_ID]="$(date +%Y%m%d-%H%M%S)"
    ST[STATUS]="in_progress"
    state_flush
  fi
else
  if [[ "$(state_get STATUS)" != "completed" ]]; then
    RESUME=true
    info "Retomando execução anterior (RUN_ID=$(state_get RUN_ID))."
  fi
fi
$FORCE_RESUME && RESUME=true
TS="$(state_get RUN_ID)"

# ── Detecção do estado real ──────────────────────────────────────────
container_env() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -m1 "^$2=" | cut -d= -f2- || true
}
detect_pg_container() {
  local n
  n="$(docker ps     --filter 'label=com.docker.compose.service=postgres' --format '{{.Names}}' 2>/dev/null | head -1)"
  [[ -z "$n" ]] && n="$(docker ps -a --filter 'label=com.docker.compose.service=postgres' --format '{{.Names}}' 2>/dev/null | head -1)"
  echo "$n"
}
password_is_safe() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
gen_hex_secret() {
  local bytes="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$bytes"
  elif [[ -r /dev/urandom ]]; then head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  else error "Sem 'openssl' nem /dev/urandom."; return 1; fi
}
read_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
update_env() {
  local key="$1" value="$2"
  [[ "$value" == *$'\n'* ]] && { error "Valor de $key contém quebra de linha."; return 1; }
  KEY="$key" VAL="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; replaced = 0 }
    index($0, k "=") == 1 { print k "=" v; replaced = 1; next }
    { print }
    END { if (!replaced) print k "=" v }' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
  chown_owner "$ENV_FILE"
}
remove_env() {
  local key="$1"
  awk -v k="$key" 'index($0, k "=") == 1 { next } { print }' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
  chown_owner "$ENV_FILE"
}
rename_env() {
  local old="$1" new="$2" val
  grep -qE "^${old}=" "$ENV_FILE" || return 0
  val="$(grep -E "^${old}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
  remove_env "$old"; grep -qE "^${new}=" "$ENV_FILE" || update_env "$new" "$val"
}

# OLD_PROJECT (retomada usa o estado; senão detecta)
if [[ -n "$(state_get OLD_PROJECT)" ]]; then
  OLD_PROJECT="$(state_get OLD_PROJECT)"
elif [[ -n "$OLD_PROJECT_OVERRIDE" ]]; then
  OLD_PROJECT="$OLD_PROJECT_OVERRIDE"; state_set OLD_PROJECT "$OLD_PROJECT"
else
  OLD_PROJECT="$(docker ps -a --filter 'label=com.docker.compose.service=postgres' --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -1 || true)"
  [[ -z "$OLD_PROJECT" ]] && OLD_PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  [[ -z "$OLD_PROJECT" ]] && OLD_PROJECT="$(basename "$REPO_DIR")"
  state_set OLD_PROJECT "$OLD_PROJECT"
fi

# Container Postgres / imagem / volume-alvo
PG_CONTAINER="$(detect_pg_container)"
PG_IMAGE="$(state_get PG_IMAGE)"; TARGET_PG_VOLUME="$(state_get TARGET_PG_VOLUME)"
OLD_PG_USER="$(state_get OLD_PG_USER)"; OLD_PG_DB="$(state_get OLD_PG_DB)"
if [[ -n "$PG_CONTAINER" ]]; then
  [[ -z "$PG_IMAGE" ]] && PG_IMAGE="$(docker inspect "$PG_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
  pgvol="$(docker inspect "$PG_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
  [[ -z "$TARGET_PG_VOLUME" && -n "$pgvol" ]] && TARGET_PG_VOLUME="${NEW_PROJECT}${pgvol#"$OLD_PROJECT"}"
  [[ -z "$OLD_PG_USER" ]] && OLD_PG_USER="$(container_env "$PG_CONTAINER" POSTGRES_USER)"
  [[ -z "$OLD_PG_DB" ]]   && OLD_PG_DB="$(container_env "$PG_CONTAINER" POSTGRES_DB)"
fi
# Fallback: valor do .env de backup do legado (antes de qualquer rename).
if [[ -z "$OLD_PG_USER" && -f "$BACKUP_DIR/$TS/env.$TS.bak" ]]; then
  OLD_PG_USER="$(grep -E '^POSTGRES_USER=' "$BACKUP_DIR/$TS/env.$TS.bak" | tail -1 | cut -d= -f2- || true)"
fi
if [[ -z "$OLD_PG_DB" && -f "$BACKUP_DIR/$TS/env.$TS.bak" ]]; then
  OLD_PG_DB="$(grep -E '^POSTGRES_DB=' "$BACKUP_DIR/$TS/env.$TS.bak" | tail -1 | cut -d= -f2- || true)"
fi
[[ -z "$PG_IMAGE" ]] && PG_IMAGE="postgres:17-alpine"
[[ -z "$TARGET_PG_VOLUME" ]] && TARGET_PG_VOLUME="${NEW_PROJECT}_pgdata"
OLD_PG_USER="${OLD_PG_USER:-easyfone}"
OLD_PG_DB="${OLD_PG_DB:-easyfone}"
state_set PG_IMAGE "$PG_IMAGE"; state_set TARGET_PG_VOLUME "$TARGET_PG_VOLUME"
state_set OLD_PG_USER "$OLD_PG_USER"; state_set OLD_PG_DB "$OLD_PG_DB"

# Senha alvo
CUR_PW="$(read_env POSTGRES_PASSWORD)"
FINAL_PW="$CUR_PW"; ROTATE_PW=false
if [[ -n "$PW_OVERRIDE" ]]; then
  FINAL_PW="$PW_OVERRIDE"
  password_is_safe "$FINAL_PW" || warn "A senha de --password contém caracteres que podem quebrar ODBC/URL."
elif $KEEP_DB_PASSWORD; then
  [[ -n "$CUR_PW" ]] && ! password_is_safe "$CUR_PW" && warn "--keep-db-password: senha com caracteres problemáticos — ODBC pode falhar."
else
  if [[ -z "$CUR_PW" ]] || ! password_is_safe "$CUR_PW"; then
    FINAL_PW="$(gen_hex_secret 24)"; ROTATE_PW=true
    warn "POSTGRES_PASSWORD tem caracteres que quebram ODBC/URL — será regenerada em hex."
  fi
fi

ok "RUN_ID:               $TS$($RESUME && echo '  (retomando)')"
ok "Projeto Compose real: $OLD_PROJECT"
ok "Projeto Compose novo: $NEW_PROJECT"
ok "Container Postgres:   ${PG_CONTAINER:-(nenhum)}"
ok "Postgres (referência): user=$OLD_PG_USER db=$OLD_PG_DB"
ok "Postgres novo:        user=$NEW_PG_USER db=$NEW_PG_DB"
ok "Volume de dados alvo: $TARGET_PG_VOLUME"

# Volumes do projeto real e plano de cópia
mapfile -t OLD_VOLUMES < <(docker volume ls -q --filter "name=^${OLD_PROJECT}_" 2>/dev/null || true)
COPY_PAIRS=()
for v in "${OLD_VOLUMES[@]}"; do
  suffix="${v#"${OLD_PROJECT}"}"; target="${NEW_PROJECT}${suffix}"
  [[ "$v" == "$target" ]] && continue
  if docker volume inspect "$target" >/dev/null 2>&1; then
    if $FORCE; then
      warn "Alvo '$target' já existe — --force pode sobrescrever dados."
      confirm "Sobrescrever o volume '$target' com o conteúdo de '$v'" "os dados atuais do volume '$target' serão PERDIDOS." || { error "Abortado."; exit 1; }
    else
      error "O volume alvo '$target' já existe (origem: '$v'). Não sobrescrevo dados. Use --force se tiver certeza."
      exit 1
    fi
  fi
  COPY_PAIRS+=("$v|$target")
done
if [[ -z "${OLD_PROJECT_OVERRIDE}" && -z "$(docker volume ls -q --filter "name=^${OLD_PROJECT}_" 2>/dev/null)" ]]; then
  warn "Nenhum volume '${OLD_PROJECT}_*' encontrado."
fi
ok "Volumes atuais: ${#OLD_VOLUMES[@]}  |  a copiar: ${#COPY_PAIRS[@]}"

OLD_NETS=("${OLD_PROJECT}_default" "${OLD_PROJECT}-traefik-public" "easyfone-traefik-public")

if ! docker image inspect alpine >/dev/null 2>&1; then
  info "Baixando imagem 'alpine'…"; run docker pull alpine
fi

# Nomes antigos -> padrão atual / chaves obsoletas (usados no plano e na fase 4)
ENV_RENAMES=(
  "EASYPHONE_FIREBASE_SERVICE_ACCOUNT|FIREBASE_SERVICE_ACCOUNT"
  "EASYPHONE_LICENSE_CLIENT_ID|LICENSE_CLIENT_ID"
  "EASYPHONE_LICENSE_HARDWARE_ID|LICENSE_HARDWARE_ID"
  "EF_AMI_DIALPLAN_EXTENSION_CONTEXT|ASTERISK_DIALPLAN_ORIGINATE_CONTEXT"
  "EF_DIALPLAN_EXTENSION_CONTEXT_BLOCK|ASTERISK_DIALPLAN_BLOCK_CONTEXT"
  "MUSIC_ON_HOLD_FOLDER_PATH|ASTERISK_PATH_MOH"
  "AUDIO_URA_FOLDER_PATH|ASTERISK_PATH_URA"
  "VITE_EF_FILES_FOLDER_PATH|ASTERISK_PATH_CONFIG"
  "VITE_EF_CALL_RECORD_FOLDER_PATH|ASTERISK_PATH_MONITOR"
  "VITE_FORMAT_FILES_UPLOAD_MOH|UPLOAD_MOH_FORMAT"
  "VITE_MAX_FILES_UPLOAD_MOH|UPLOAD_MOH_MAX_FILES"
  "VITE_MAX_FILE_SIZE_UPLOAD_MOH|UPLOAD_MOH_MAX_FILE_SIZE"
  "VITE_MAX_FILE_SIZE_UPLOAD_IVR_AUDIO|UPLOAD_IVR_MAX_FILE_SIZE"
)
OBSOLETE_ENV_KEYS=(
  WHISPER_MODEL ACTIVATE_DISCADOR_MAILING DANGEROUSLY_ALLOW_ANY_URL_FOR_UNIT_ADDRESS
  VITE_EF_ORGS_FOLDER_PATH
  API_IMAGE API_PORT_CONTAINER API_PORT_HOST
  ASTERISK_IMAGE ASTERISK_AMI_PORT_HOST ASTERISK_ARI_PORT_HOST
  ASTERISK_ARI_HTTPS_PORT_HOST ASTERISK_SIP_PORT_HOST
  PGBOUNCER_PORT_HOST PG_PORT_HOST POSTGRES_IMAGE_TAG
  WEB_IMAGE WEB_PORT_HOST TZ PRISMA_LOGS_OFF PG_POOL_MAX PG_POOL_MIN
  VITE_API_DELAY VITE_ENABLE_API_DELAY
  VITE_ASTERISK_HOST VITE_ASTERISK_ARI_PORT VITE_ASTERISK_AMI_PORT
  VITE_ASTERISK_USERNAME VITE_ASTERISK_PASSWORD VITE_APP_NAME_ARI_ASTERISK
  VITE_TIMEOUT_ORIGINATE_LOGIN_CALL_MS COMPOSE_PROJECT_NAME
)

# ── Inspeção READ-ONLY do cluster Postgres (para o plano do dry-run) ──
# Usa o container em execução, se houver; senão sobe um Postgres temporário
# (trust) sobre o volume. Só roda SELECT em pg_roles/pg_database; nenhum DDL.
# Remove o container temporário ao final.
inspect_database_plan() {
  local cname="$PG_MIGRATE_NAME" mode="" boot="" maint="" started_here=false
  if [[ -n "$PG_CONTAINER" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
    cname="$PG_CONTAINER"; mode="container em execução"
    boot="$(container_env "$PG_CONTAINER" POSTGRES_USER)"; [[ -z "$boot" ]] && boot="postgres"
  else
    docker volume inspect "$TARGET_PG_VOLUME" >/dev/null 2>&1 || { warn "Plano do banco: volume '$TARGET_PG_VOLUME' não existe — não inspecionei."; return 0; }
    docker run --rm -v "$TARGET_PG_VOLUME":/v:ro alpine sh -c 'test -f /v/PG_VERSION' >/dev/null 2>&1 \
      || { warn "Plano do banco: '$TARGET_PG_VOLUME' sem PG_VERSION — não é dataset do Postgres."; return 0; }
    if [[ -n "$(docker ps -q --filter "volume=$TARGET_PG_VOLUME" 2>/dev/null)" ]]; then
      warn "Plano do banco: volume em uso por outro container — não montei em paralelo."; return 0
    fi
    info "Plano do banco: subindo Postgres temporário (trust) SÓ para ler (nenhum DDL)."
    docker rm -f "$cname" >/dev/null 2>&1 || true
    if ! docker run --rm -d --name "$cname" -v "$TARGET_PG_VOLUME":/var/lib/postgresql/data \
           -e POSTGRES_HOST_AUTH_METHOD=trust "$PG_IMAGE" >>"$LOG_FILE" 2>&1; then
      warn "Plano do banco: não consegui subir o container temporário."; return 0
    fi
    TRUST_STARTED=true; started_here=true; mode="inspeção temporária"
    local ready=false
    for _ in $(seq 1 60); do docker exec "$cname" pg_isready >/dev/null 2>&1 && { ready=true; break; }; sleep 1; done
    if ! $ready; then
      warn "Plano do banco: o Postgres temporário não subiu."
      docker rm -f "$cname" >/dev/null 2>&1 || true; TRUST_STARTED=false; return 0
    fi
  fi

  local -a cands=("$boot" "$OLD_PG_USER" "easyfone" "easyphone" "postgres")
  local db u
  for db in postgres template1; do
    for u in "${cands[@]}"; do
      [[ -z "$u" ]] && continue
      if docker exec -i "$cname" psql -U "$u" -d "$db" -tAc 'select 1' >/dev/null 2>&1; then boot="$u"; maint="$db"; break 2; fi
    done
  done
  if [[ -z "$maint" ]]; then
    warn "Plano do banco: não consegui conectar (candidatos: ${cands[*]})."
    if $started_here; then docker rm -f "$cname" >/dev/null 2>&1 || true; TRUST_STARTED=false; fi
    return 0
  fi

  local roles dbs
  roles="$(docker exec -i "$cname" psql -U "$boot" -d "$maint" -tAc "SELECT rolname FROM pg_roles" 2>>"$LOG_FILE" || true)"
  dbs="$(docker exec -i "$cname" psql -U "$boot" -d "$maint" -tAc "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1')" 2>>"$LOG_FILE" || true)"

  echo -e "  ${BOLD}Plano do banco (origem: $mode):${NC}" | tee -a "$LOG_FILE"
  if grep -qx "$NEW_PG_DB" <<<"$dbs"; then
    echo "    - banco:  já é '$NEW_PG_DB' (nada a fazer)" | tee -a "$LOG_FILE"
  elif grep -qx "$OLD_PG_DB" <<<"$dbs"; then
    echo "    - banco:  renomear '$OLD_PG_DB' → '$NEW_PG_DB'" | tee -a "$LOG_FILE"
  else
    echo "    - banco:  '$OLD_PG_DB'/'$NEW_PG_DB' não encontrados — será pedido para escolher entre: $(tr '\n' ' ' <<<"$dbs")" | tee -a "$LOG_FILE"
  fi
  if grep -qx "$NEW_PG_USER" <<<"$roles"; then
    echo "    - role:   já é '$NEW_PG_USER' (nada a fazer)" | tee -a "$LOG_FILE"
  elif grep -qx "$OLD_PG_USER" <<<"$roles"; then
    echo "    - role:   renomear '$OLD_PG_USER' → '$NEW_PG_USER' (sessão trocada; 'ep_mig' temporário se preciso)" | tee -a "$LOG_FILE"
  else
    echo "    - role:   '$OLD_PG_USER'/'$NEW_PG_USER' não encontradas — será pedido para escolher entre as superusuárias: $(tr '\n' ' ' <<<"$roles")" | tee -a "$LOG_FILE"
  fi
  if $KEEP_DB_PASSWORD; then
    echo "    - senha:  mantida (--keep-db-password)" | tee -a "$LOG_FILE"
  else
    echo "    - senha:  será alinhada ao .env (hex se a atual tiver caracteres problemáticos)" | tee -a "$LOG_FILE"
  fi

  if $started_here; then docker rm -f "$cname" >/dev/null 2>&1 || true; TRUST_STARTED=false; fi
  return 0
}

# ── Relatório + plano (somente em --dry-run) ─────────────────────────
if $DRY_RUN; then
  phase_status() { if phase_done "$1"; then echo "pulada (já concluída)"; else echo "SERIA executada"; fi; }
  ren=0; for p in "${ENV_RENAMES[@]}"; do if grep -qE "^${p%%|*}=" "$ENV_FILE"; then ren=$((ren+1)); fi; done
  obl=0; for k in "${OBSOLETE_ENV_KEYS[@]}"; do if grep -qE "^${k}=" "$ENV_FILE"; then obl=$((obl+1)); fi; done
  echo
  echo -e "${BOLD}Plano de execução (dry-run)${NC}" | tee -a "$LOG_FILE"
  printf '  %-20s %s\n' "Fase 1  Backup"   "$(phase_status 1)" | tee -a "$LOG_FILE"
  printf '  %-20s %s\n' "Fase 2  Down"     "$(phase_status 2)" | tee -a "$LOG_FILE"
  printf '  %-20s %s\n' "Fase 3  Volumes"  "$(phase_status 3)  (${#COPY_PAIRS[@]} cópia(s), ${#OLD_VOLUMES[@]} volume(s) p/ snapshot)" | tee -a "$LOG_FILE"
  printf '  %-20s %s\n' "Fase 4  .env"     "$(phase_status 4)  (${ren} rename(s), ${obl} chave(s) obsoleta(s))" | tee -a "$LOG_FILE"
  printf '  %-20s %s\n' "Fase 5  Banco"    "$(phase_status 5)" | tee -a "$LOG_FILE"
  printf '  %-20s %s\n' "Fase 6  Firewall" "$(phase_status 6)" | tee -a "$LOG_FILE"
  echo
  inspect_database_plan
  echo
fi

# ─────────────────────────────────────────────────────────────────────
#  1. BACKUP (.env + pg_dump)
# ─────────────────────────────────────────────────────────────────────
step "1/7 — Backup"
if phase_done 1; then
  ok "Fase 1 já concluída — pulando."
else
  run mkdir -p "$BACKUP_DIR/$TS/volumes"
  run cp -a "$ENV_FILE" "$BACKUP_DIR/$TS/env.bak"
  [[ -f "$BACKUP_DIR/$TS/env.bak" ]] || { error "Falha no backup do .env. Abortando."; exit 1; }
  if [[ -n "$PG_CONTAINER" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
    info "pg_dump do banco ${OLD_PG_DB}…"
    if ! $DRY_RUN; then
      if docker exec "$PG_CONTAINER" pg_dump -U "$OLD_PG_USER" "$OLD_PG_DB" 2>>"$LOG_FILE" | gzip > "$BACKUP_DIR/$TS/db.sql.gz"; then
        ok "Backup: $BACKUP_DIR/$TS/db.sql.gz ($(du -h "$BACKUP_DIR/$TS/db.sql.gz" | cut -f1))"
      else
        warn "pg_dump falhou — o banco pode estar inicializando. Seguindo (o snapshot do volume cobre)."
        rm -f "$BACKUP_DIR/$TS/db.sql.gz"
      fi
    fi
  else
    warn "Container do Postgres não está rodando — pulando pg_dump (o snapshot do volume cobre)."
  fi
  phase_mark 1
fi

# ─────────────────────────────────────────────────────────────────────
#  2. DOWN DO PROJETO ANTIGO
# ─────────────────────────────────────────────────────────────────────
step "2/7 — Derrubar o projeto antigo (volumes preservados)"
if phase_done 2; then
  ok "Fase 2 já concluída — pulando."
else
  if ! $ASSUME_YES && ! $DRY_RUN; then
    confirm "Parar os containers do projeto '$OLD_PROJECT' (web/api/asterisk/SIP ficam fora do ar)" \
            "curta indisponibilidade até o 'up'." || { error "Abortado pelo operador."; exit 1; }
  fi
  run docker compose -p "$OLD_PROJECT" down
  for net in "${OLD_NETS[@]}"; do
    [[ "$net" == "${NEW_PROJECT}_default" || "$net" == "${NEW_PROJECT}-traefik-public" ]] && continue
    docker network inspect "$net" >/dev/null 2>&1 && run docker network rm "$net" || true
  done
  phase_mark 2
fi

# ─────────────────────────────────────────────────────────────────────
#  3. SNAPSHOT + CÓPIA DOS VOLUMES
# ─────────────────────────────────────────────────────────────────────
step "3/7 — Snapshot e cópia dos volumes"
vol_size_kb() { docker run --rm -v "$1":/v:ro alpine du -sk /v 2>/dev/null | awk '{print $1}'; }

if phase_done 3; then
  ok "Fase 3 já concluída — pulando."
else
  # Espaço: soma dos volumes (snapshot + cópia = 2x)
  total_kb=0
  for v in "${OLD_VOLUMES[@]}"; do total_kb=$((total_kb + $(vol_size_kb "$v" || echo 0))); done
  need_kb=$((total_kb * 2))
  avail_kb="$(df -Pk "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" | awk 'NR==2{print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$need_kb" ]]; then
    error "Espaço insuficiente: preciso de ~$((need_kb/1024)) MB, tenho $((avail_kb/1024)) MB."
    exit 1
  fi

  # Snapshot físico (volumes parados)
  if ! $SKIP_VOLUME_BACKUP; then
    for v in "${OLD_VOLUMES[@]}"; do
      run docker run --rm -v "$v":/from:ro -v "$BACKUP_DIR/$TS/volumes":/backup \
        alpine tar -C /from -cf "/backup/$v.tar" .
      [[ -f "$BACKUP_DIR/$TS/volumes/$v.tar" ]] || { error "Falha no snapshot de '$v'. Abortando."; exit 1; }
      ! $DRY_RUN && ok "Snapshot: $v.tar"
    done
  else
    warn "--skip-volume-backup: SEM snapshot dos volumes."
  fi

  # Cópia OLD→NEW (read-only na origem) + verificação
  if [[ ${#COPY_PAIRS[@]} -gt 0 ]]; then
    for pair in "${COPY_PAIRS[@]}"; do
      old="${pair%%|*}"; target="${pair##*|}"
      src_kb="$(vol_size_kb "$old" || echo 0)"
      run docker volume create "$target"
      run docker run --rm -v "$old":/from:ro -v "$target":/to alpine sh -c 'tar -C /from -cf - . | tar -C /to -xf -'
      if ! $DRY_RUN; then
        dst_kb="$(vol_size_kb "$target" || echo 0)"
        if [[ -n "$src_kb" && "$src_kb" -gt 0 && "$dst_kb" -lt "$((src_kb * 99 / 100))" ]]; then
          error "Cópia divergente ($old→$target): origem ${src_kb}KB, destino ${dst_kb}KB. Abortando SEM usar o alvo."
          exit 1
        fi
      fi
      ! $DRY_RUN && ok "Copiado: $old → $target"
    done
  else
    ok "Nada a copiar — os volumes já estão no nome-alvo."
  fi
  phase_mark 3
fi

# ─────────────────────────────────────────────────────────────────────
#  4. AJUSTAR .env
# ─────────────────────────────────────────────────────────────────────
step "4/7 — Ajustar .env"
if phase_done 4; then
  ok "Fase 4 já concluída — pulando."
else
  if ! $DRY_RUN; then
    for pair in "${ENV_RENAMES[@]}"; do rename_env "${pair%%|*}" "${pair##*|}"; done
    for key in "${OBSOLETE_ENV_KEYS[@]}"; do remove_env "$key"; done
    fb_functions="$(read_env FIREBASE_FUNCTIONS_URL)"
    [[ -z "$fb_functions" ]] && fb_functions="$(read_env EASYPHONE_FIREBASE_FUNCTIONS_URL)"
    remove_env "FIREBASE_URL"; remove_env "EASYPHONE_FIREBASE_URL"
    remove_env "FIREBASE_FUNCTIONS_URL"; remove_env "EASYPHONE_FIREBASE_FUNCTIONS_URL"
    [[ -n "$fb_functions" ]] && update_env "FIREBASE_URL" "$fb_functions"
    update_env "POSTGRES_USER" "$NEW_PG_USER"
    update_env "POSTGRES_DB" "$NEW_PG_DB"
  fi
  phase_mark 4
fi
info "POSTGRES_USER=$NEW_PG_USER  POSTGRES_DB=$NEW_PG_DB"

# ─────────────────────────────────────────────────────────────────────
#  5. AJUSTAR BANCO (role/db + senha) — state-aware, não-destrutivo
# ─────────────────────────────────────────────────────────────────────
step "5/7 — Ajustar banco (role/db + senha)"

db_probe()   { docker exec -i "$PG_MIGRATE_NAME" psql -U "$1" -d "$2" -tAc 'select 1' >/dev/null 2>&1; }
db_query()   { docker exec -i "$PG_MIGRATE_NAME" psql -U "$1" -d "$2" -tAc "$3" 2>>"$LOG_FILE"; }

migrate_database() {
  # Travas de segurança
  if ! $DRY_RUN; then
    docker volume inspect "$TARGET_PG_VOLUME" >/dev/null 2>&1 || { error "Volume '$TARGET_PG_VOLUME' não existe."; return 1; }
    if ! docker run --rm -v "$TARGET_PG_VOLUME":/v:ro alpine sh -c 'test -f /v/PG_VERSION' >/dev/null 2>&1; then
      error "O volume '$TARGET_PG_VOLUME' não tem PG_VERSION — não é um dataset do Postgres. Aborto para NÃO inicializar banco vazio."
      return 1
    fi
    if [[ -n "$(docker ps -q --filter "volume=$TARGET_PG_VOLUME" 2>/dev/null)" ]]; then
      error "O volume '$TARGET_PG_VOLUME' está em uso por container. Abortando."
      return 1
    fi
  fi

  run docker rm -f "$PG_MIGRATE_NAME" || true
  run docker run --rm -d --name "$PG_MIGRATE_NAME" \
    -v "$TARGET_PG_VOLUME":/var/lib/postgresql/data \
    -e POSTGRES_HOST_AUTH_METHOD=trust "$PG_IMAGE"
  $DRY_RUN && return 0
  TRUST_STARTED=true

  local ready=false
  for _ in $(seq 1 60); do
    docker exec "$PG_MIGRATE_NAME" pg_isready >/dev/null 2>&1 && { ready=true; break; }
    sleep 1
  done
  if ! $ready; then
    error "O Postgres (trust) não subiu."
    docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true
    return 1
  fi

  # Descobrir uma conexão (candidatos: estado/env/easyfone/easyphone/postgres)
  local -a CANDS=("$OLD_PG_USER" "easyfone" "easyphone" "postgres")
  local BOOT="" MAINT_DB=""
  local db u
  for db in postgres template1; do
    for u in "${CANDS[@]}"; do
      [[ -z "$u" ]] && continue
      if db_probe "$u" "$db"; then BOOT="$u"; MAINT_DB="$db"; break 2; fi
    done
  done
  if [[ -z "$MAINT_DB" ]]; then
    error "Não consegui conectar ao cluster (candidatos: ${CANDS[*]}). Nada foi alterado."
    docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true
    return 1
  fi
  info "Conectado como '$BOOT' no banco '$MAINT_DB'."

  local ROLES DBS
  ROLES="$(db_query "$BOOT" "$MAINT_DB" "SELECT rolname FROM pg_roles")"
  DBS="$(db_query "$BOOT" "$MAINT_DB" "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1')")"

  # ── Banco: renomear OLD→NEW (se preciso) ──
  local db_old="$OLD_PG_DB" db_new="$NEW_PG_DB"
  if grep -qx "$db_new" <<<"$DBS"; then
    info "Banco '$db_new' já existe — nada a renomear."
  elif grep -qx "$db_old" <<<"$DBS"; then
    if ! db_query "$BOOT" "$MAINT_DB" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db_old' AND pid<>pg_backend_pid();" >/dev/null; then
      error "Falha ao encerrar conexões em '$db_old'."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1
    fi
    if ! db_query "$BOOT" "$MAINT_DB" "ALTER DATABASE \"$db_old\" RENAME TO \"$db_new\";" >/dev/null; then
      error "Falha ao renomear banco '$db_old' → '$db_new'."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1
    fi
    ok "Banco: $db_old → $db_new"
  else
    local dbopts; mapfile -t dbopts < <(grep -v '^$' <<<"$DBS")
    if [[ ${#dbopts[@]} -eq 0 ]]; then
      error "Nenhum banco além dos templates."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1
    fi
    local chosen
    chosen="$(select_option "Não encontrei '$db_old' nem '$db_new'. Qual banco renomear para '$db_new'?" "${dbopts[@]}")" || {
      error "Seleção cancelada."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1; }
    db_old="$chosen"
    db_query "$BOOT" "$MAINT_DB" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$db_old' AND pid<>pg_backend_pid();" >/dev/null || true
    db_query "$BOOT" "$MAINT_DB" "ALTER DATABASE \"$db_old\" RENAME TO \"$db_new\";" >/dev/null || {
      error "Falha ao renomear banco '$db_old' → '$db_new'."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1; }
    ok "Banco: $db_old → $db_new"
  fi

  # ── Role: renomear OLD→NEW (a sessão NÃO pode ser a role renomeada) ──
  local role_final="$NEW_PG_USER"
  if grep -qx "$NEW_PG_USER" <<<"$ROLES"; then
    info "Role '$NEW_PG_USER' já existe."
  else
    local role_old=""
    if grep -qx "$OLD_PG_USER" <<<"$ROLES"; then
      role_old="$OLD_PG_USER"
    else
      local -a roleopts=()
      while IFS= read -r r; do
        [[ -z "$r" || "$r" == "$TEMP_ROLE" || "$r" == "postgres" ]] && continue
        roleopts+=("$r")
      done <<<"$ROLES"
      if [[ ${#roleopts[@]} -eq 1 ]]; then
        role_old="${roleopts[0]}"
      elif [[ ${#roleopts[@]} -gt 1 ]]; then
        role_old="$(select_option "Qual role renomear para '$NEW_PG_USER'?" "${roleopts[@]}")" || {
          error "Cancelado."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1; }
      else
        error "Nenhuma role superusuária candidata a renomear."
        docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1
      fi
    fi
    confirm "Renomear a role do banco '$role_old' → '$NEW_PG_USER'" "nenhum dado é perdido; apenas o nome da role muda." || {
      error "Cancelado."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1; }

    if [[ "$BOOT" == "$role_old" ]]; then
      # A sessão não pode renomear a própria role: cria um superusuário temporário
      info "Criando superusuário temporário '$TEMP_ROLE' para renomear a role da sessão."
      db_query "$BOOT" "$MAINT_DB" "DROP ROLE IF EXISTS \"$TEMP_ROLE\";" >/dev/null 2>&1 || true
      db_query "$BOOT" "$MAINT_DB" "CREATE ROLE \"$TEMP_ROLE\" SUPERUSER LOGIN;" >/dev/null || {
        error "Falha ao criar '$TEMP_ROLE'."; docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1; }
      BOOT="$TEMP_ROLE"
    fi
    if ! db_query "$BOOT" "$MAINT_DB" "ALTER ROLE \"$role_old\" RENAME TO \"$NEW_PG_USER\";" >/dev/null; then
      error "Falha ao renomear a role '$role_old' → '$NEW_PG_USER'."
      docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1
    fi
    ok "Role: $role_old → $NEW_PG_USER"
    role_final="$NEW_PG_USER"
  fi

  # ── Senha da role final ──
  if ! $KEEP_DB_PASSWORD; then
    local sql=""
    sql+="\\set pw \`printf '%s' \"\$NP\"\`"$'\n'
    sql+="ALTER ROLE \"$role_final\" WITH PASSWORD :'pw';"$'\n'
    if ! printf '%s' "$sql" | docker exec -i -e NP="$FINAL_PW" "$PG_MIGRATE_NAME" \
         psql -U "$BOOT" -d "$MAINT_DB" -v ON_ERROR_STOP=1 >>"$LOG_FILE" 2>&1; then
      error "Falha ao ajustar a senha da role '$role_final'."
      docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true; return 1
    fi
    ok "Senha alinhada ao .env."
  fi

  # Remove o superusuário temporário
  if grep -qx "$TEMP_ROLE" <<<"$(db_query "$role_final" "$MAINT_DB" "SELECT rolname FROM pg_roles" 2>/dev/null || true)"; then
    db_query "$role_final" "$MAINT_DB" "DROP ROLE \"$TEMP_ROLE\";" >/dev/null 2>&1 || warn "Não removi '$TEMP_ROLE' (remova manualmente)."
  fi

  docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true
  TRUST_STARTED=false
  return 0
}

if $SKIP_DB; then
  warn "Pulando banco (--skip-db)."
elif phase_done 5; then
  ok "Fase 5 já concluída — pulando."
else
  if ! migrate_database; then
    error "O banco pode ter ficado PARCIALMENTE migrado. Os volumes originais e os backups estão intactos."
    error "Revise e rode de novo (retoma automaticamente) com 'sudo bash $0'; para recomeçar, 'sudo bash $0 --restart'."
    error "Backups: $BACKUP_DIR/$TS  |  .env: $BACKUP_DIR/$TS/env.bak"
    exit 1
  fi
  phase_mark 5

  if ! $DRY_RUN && ! $KEEP_DB_PASSWORD && [[ "$FINAL_PW" != "$CUR_PW" ]]; then
    update_env "POSTGRES_PASSWORD" "$FINAL_PW"; ROTATE_PW=true
  fi

  # Verificação: sobe só o Postgres e testa login TCP com a senha do .env
  if ! $DRY_RUN; then
    run docker compose up -d postgres
    pg_ready=false
    for _ in $(seq 1 60); do
      docker exec "${NEW_PROJECT}-pg" pg_isready -U "$NEW_PG_USER" -d "$NEW_PG_DB" >/dev/null 2>&1 && { pg_ready=true; break; }
      sleep 1
    done
    if ! $pg_ready; then error "Postgres não subiu para verificação."; exit 1; fi
    if PGPASSWORD="$FINAL_PW" docker run --rm -e PGPASSWORD --network host "$PG_IMAGE" \
         psql -h 127.0.0.1 -p "$PG_HOST_PORT" -U "$NEW_PG_USER" -d "$NEW_PG_DB" -c 'select 1' >>"$LOG_FILE" 2>&1; then
      ok "Login TCP com a senha do .env: OK."
    else
      error "Login TCP FALHOU com a senha do .env — abortando antes de subir a stack."
      run docker compose down
      exit 1
    fi
    run docker compose down
  fi
fi

# ─────────────────────────────────────────────────────────────────────
#  6. FIREWALL DO HOST
# ─────────────────────────────────────────────────────────────────────
step "6/7 — Migrar o firewall do host"
if $SKIP_FW; then
  warn "Pulando (--skip-firewall)."
elif phase_done 6; then
  ok "Fase 6 já concluída — pulando."
elif ! command -v iptables >/dev/null 2>&1; then
  warn "iptables não encontrado — pulando firewall."
else
  if systemctl list-unit-files 2>/dev/null | grep -q "^${OLD_UNIT%.service}"; then run systemctl disable --now "$OLD_UNIT"; fi
  run rm -f "/etc/systemd/system/$OLD_UNIT"
  run rm -f "/etc/systemd/system/multi-user.target.wants/$OLD_UNIT"
  if [[ -f "$NEW_UNIT_PATH" ]]; then
    warn "Removendo $NEW_UNIT_PATH pré-existente (resíduo de guia antigo)."
    run systemctl disable --now "$NEW_UNIT"
    run rm -f "$NEW_UNIT_PATH"
  fi
  run rm -rf /opt/easyphone/firewall
  run systemctl daemon-reload
  if ! $DRY_RUN; then
    while iptables -C INPUT -j "$OLD_CHAIN_WL" 2>/dev/null; do iptables -D INPUT -j "$OLD_CHAIN_WL"; done
    while iptables -C INPUT -j "$OLD_CHAIN_IN" 2>/dev/null; do iptables -D INPUT -j "$OLD_CHAIN_IN"; done
    iptables -F "$OLD_CHAIN_WL" 2>/dev/null || true
    iptables -X "$OLD_CHAIN_WL" 2>/dev/null || true
    iptables -F "$OLD_CHAIN_IN" 2>/dev/null || true
    iptables -X "$OLD_CHAIN_IN" 2>/dev/null || true
  fi
  info "Chains antigas $OLD_CHAIN_IN / $OLD_CHAIN_WL removidas."
  if [[ -f "$NEW_UNIT_TEMPLATE" ]]; then
    if ! $DRY_RUN; then
      sed "s|__FIREWALL_SCRIPT__|$REPO_DIR/firewall-rules.sh|g" "$NEW_UNIT_TEMPLATE" > "$NEW_UNIT_PATH"
    fi
    run systemctl daemon-reload
    run systemctl enable "$NEW_UNIT"
    run bash "$REPO_DIR/firewall-rules.sh"
    ! $DRY_RUN && ok "$NEW_UNIT instalado e regras reaplicadas."
  else
    warn "Template '$NEW_UNIT_TEMPLATE' não encontrado; unit não instalado."
    run bash "$REPO_DIR/firewall-rules.sh"
  fi
  phase_mark 6
fi

# ─────────────────────────────────────────────────────────────────────
#  7. RESUMO
# ─────────────────────────────────────────────────────────────────────
step "7/7 — Resumo"

if $DRY_RUN; then
  warn "MODO DRY-RUN: nada foi alterado. Revise o plano acima e rode sem --dry-run."
  exit 0
fi

state_set STATUS completed
echo
ok "Migração concluída. (RUN_ID=$TS)"
if $ROTATE_PW; then
  echo
  printf '  Senha nova do Postgres (guarde em local seguro): %s\n' "$FINAL_PW"
fi
echo -e "  Backups desta execução: ${BOLD}$BACKUP_DIR/$TS${NC}"
echo
echo -e "  ${BOLD}Próximos passos:${NC}"
echo -e "    1) Suba a stack:  ${BOLD}./run.sh${NC}  (ou ${BOLD}docker compose up -d --force-recreate${NC})"
echo -e "    2) Valide:        ${BOLD}docker compose ps${NC}  |  ${BOLD}curl -fsS https://api.\$DOMAIN/health${NC}"
echo -e "    3) Firewall:      ${BOLD}systemctl is-enabled $NEW_UNIT${NC}  |  ${BOLD}iptables -L EASYPHONE_INPUT -n${NC}"
echo -e "    4) Limpeza final: ${BOLD}sudo bash $0 --cleanup${NC}"
echo

# ─────────────────────────────────────────────────────────────────────
#  CLEANUP OPCIONAL
# ─────────────────────────────────────────────────────────────────────
if $CLEANUP; then
  step "Cleanup — remover resíduo antigo"
  if [[ "$OLD_PROJECT" == "$NEW_PROJECT" ]]; then
    info "Projeto antigo == novo: nada a remover."
  else
    if ! $ASSUME_YES; then
      if [[ ! -t 0 ]]; then
        error "O cleanup remove volumes e exige confirmação interativa. Use --yes se souber o que faz."
        exit 1
      fi
      read -r -p "Digite APAGAR para remover os volumes antigos '${OLD_PROJECT}_*': " local_ans
      if [[ "${local_ans:-}" != "APAGAR" ]]; then warn "Cleanup cancelado."; exit 0; fi
    fi
    for pair in "${COPY_PAIRS[@]}"; do
      old="${pair%%|*}"
      if [[ -n "$(docker ps -q --filter "volume=$old" 2>/dev/null)" ]]; then
        warn "Volume '$old' em uso — não removido."
      else
        run docker volume rm "$old" || warn "Não foi possível remover $old."
      fi
    done
    for net in "${OLD_NETS[@]}"; do
      [[ "$net" == "${NEW_PROJECT}_default" || "$net" == "${NEW_PROJECT}-traefik-public" ]] && continue
      docker network inspect "$net" >/dev/null 2>&1 && run docker network rm "$net" || true
    done
  fi
  run rm -f "$OLD_TEMPLATE"
  ok "Resíduo antigo removido."
fi
