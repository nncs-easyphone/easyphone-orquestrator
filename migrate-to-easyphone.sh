#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Migração de instalações antigas (EasyFone → EasyPhone)
# Uso: sudo bash migrate-to-easyphone.sh [opções]
#
# Migra uma instalação criada pelo orquestrador ANTIGO para a identidade NOVA
# deste repositório, SEM perder dados. Rode DEPOIS do `git pull` (o
# docker-compose.yml já traz os nomes novos) e ANTES do
# `docker compose up -d --force-recreate`.
#
# O script DETECTA o estado real (projeto/volumes/BD) pelo Docker em execução,
# sem confiar no .env. Cobre os cenários encontrados em campo:
#   A) projeto "easyphone-orquestrator" e volumes "easyphone-orquestrator_*"
#      → copia os volumes para os nomes-alvo "easyphone_*";
#   B) projeto já "easyphone" e volumes já "easyphone_*"
#      → não copia nada; só recria containers e migra o firewall.
#
# O que este script faz:
#   1. backup lógico do Postgres e do .env;
#   2. derruba o projeto antigo (preservando volumes);
#   3. copia os volumes de dados para os nomes-alvo (quando necessário);
#   4. renomeia banco/role do Postgres e ALINHA a senha da role ao .env
#      (regenera em hex se a senha tiver caracteres que quebram ODBC/URL),
#      com verificação de login TCP antes de encerrar;
#   5. ajusta o .env;
#   6. migra o firewall do host (unit systemd + chains iptables);
#   7. imprime os próximos passos (e, com --cleanup, remove o resíduo antigo).
#
# As imagens de api/web NÃO mudam: a configuração vem das env do Compose em
# tempo de execução (o .env fica fora da imagem).
#
# Opções:
#   --dry-run             Mostra o plano (volumes e tamanhos) sem alterar nada.
#   --yes                 Não-interativo.
#   --old-project <nome>  Força o projeto Compose antigo (senão, auto-detecta).
#   --skip-db             Não renomeia role/db nem mexe na senha do Postgres.
#   --keep-db-password    Não altera a senha existente (avisa se for insegura).
#   --password <valor>    Define a senha do Postgres explicitamente.
#   --skip-firewall       Não mexe no firewall do host.
#   --cleanup             Após sucesso, remove volumes/rede/backups antigos.
#   --force               Prossegue mesmo com estado ambíguo.
#   -h, --help            Mostra esta ajuda.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
#  CONSTANTES
# ─────────────────────────────────────────────────────────────────────
REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

ENV_FILE="$REPO_DIR/.env"
COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
LOG_FILE="/tmp/easyphone-migrate.log"
STATE_DIR="/var/lib/easyphone-migrate"
BACKUP_DIR="/var/backups/easyphone-migrate"
LOCK_FILE="/var/lock/easyphone-migrate.lock"

NEW_PROJECT="easyphone"

OLD_UNIT="easyfone-firewall.service"
NEW_UNIT="easyphone-firewall.service"
OLD_TEMPLATE="$REPO_DIR/systemd/easyfone-firewall.service.example"
OLD_CHAIN_IN="EASYFONE_INPUT"
OLD_CHAIN_WL="EASYFONE_WHITELIST"
NEW_UNIT_TEMPLATE="$REPO_DIR/systemd/easyphone-firewall.service.example"
NEW_UNIT_PATH="/etc/systemd/system/$NEW_UNIT"

PG_MIGRATE_NAME="easyphone-pg-migrate"

# ─────────────────────────────────────────────────────────────────────
#  CORES / LOG
# ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
step()  { echo; echo -e "${BOLD}${BLUE}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"; }

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
DRY_RUN=false; ASSUME_YES=false; SKIP_DB=false; SKIP_FW=false; CLEANUP=false; FORCE=false
KEEP_DB_PASSWORD=false; PW_OVERRIDE=""
OLD_PROJECT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true; shift ;;
    --yes)            ASSUME_YES=true; shift ;;
    --old-project)
      OLD_PROJECT_OVERRIDE="${2:-}"
      shift
      [[ $# -gt 0 ]] && shift
      ;;
    --password)
      PW_OVERRIDE="${2:-}"
      shift
      [[ $# -gt 0 ]] && shift
      ;;
    --keep-db-password) KEEP_DB_PASSWORD=true; shift ;;
    --skip-db|--skip-db-rename) SKIP_DB=true; shift ;;
    --skip-firewall)  SKIP_FW=true; shift ;;
    --cleanup)        CLEANUP=true; shift ;;
    --force)          FORCE=true; shift ;;
    -h|--help)        sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) error "Argumento desconhecido: $1"; exit 1 ;;
  esac
done

: > "$LOG_FILE"

# ─────────────────────────────────────────────────────────────────────
#  0. PREFLIGHT
# ─────────────────────────────────────────────────────────────────────
step "0/7 — Verificações iniciais"

if [[ $EUID -ne 0 ]]; then
  error "Execute como root: sudo bash $0"
  exit 1
fi

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

command -v docker >/dev/null || { error "docker não encontrado."; exit 1; }
docker compose version >/dev/null 2>&1 || { error "docker compose (plugin) não encontrado."; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { error "docker-compose.yml não encontrado em $REPO_DIR."; exit 1; }
[[ -f "$ENV_FILE" ]]     || { error ".env não encontrado em $REPO_DIR (copie de .env.example)."; exit 1; }

# Lock exclusivo (evita duas migrações simultâneas)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  error "Outra execução está em andamento ($LOCK_FILE)."
  exit 1
fi

# ── Detecção do estado real (não confia no .env) ─────────────────────
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

# Senha segura: só caracteres que não quebram ODBC (odbc.ini), DATABASE_URL ou .env.
password_is_safe() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# Senha hex (só [0-9a-f]) — segura em qualquer consumidor.
gen_hex_secret() {
  local bytes="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  elif [[ -r /dev/urandom ]]; then
    head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    error "Sem 'openssl' nem /dev/urandom para gerar senha segura."
    return 1
  fi
}

# read_env <chave>: lê um valor do .env sem source.
read_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }

# update_env: grava o valor literal (via ENVIRON, sem interpretar escapes).
update_env() {
  local key="$1" value="$2"
  [[ "$value" == *$'\n'* ]] && { error "Valor de $key contém quebra de linha."; return 1; }
  KEY="$key" VAL="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; replaced = 0 }
    index($0, k "=") == 1 { print k "=" v; replaced = 1; next }
    { print }
    END { if (!replaced) print k "=" v }
  ' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

# remove_env: apaga do .env as linhas que começam exatamente com "<chave>=".
remove_env() {
  local key="$1"
  awk -v k="$key" 'index($0, k "=") == 1 { next } { print }' \
    "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

# rename_env OLD NEW: move o valor de OLD para NEW e remove OLD. Se NEW já
# existir, mantém o NEW e apenas remove o OLD.
rename_env() {
  local old="$1" new="$2" val
  grep -qE "^${old}=" "$ENV_FILE" || return 0
  val="$(grep -E "^${old}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
  remove_env "$old"
  grep -qE "^${new}=" "$ENV_FILE" || update_env "$new" "$val"
}

NEW_PG_USER="easyphone"
NEW_PG_DB="easyphone"

if [[ -n "$OLD_PROJECT_OVERRIDE" ]]; then
  OLD_PROJECT="$OLD_PROJECT_OVERRIDE"
else
  OLD_PROJECT="$(docker ps -a --filter 'label=com.docker.compose.service=postgres' \
    --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -1 || true)"
  [[ -z "$OLD_PROJECT" ]] && OLD_PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  [[ -z "$OLD_PROJECT" ]] && OLD_PROJECT="$(basename "$REPO_DIR")"
fi

PG_CONTAINER="$(detect_pg_container)"
OLD_PG_USER=""; OLD_PG_DB=""
if [[ -n "$PG_CONTAINER" ]]; then
  OLD_PG_USER="$(container_env "$PG_CONTAINER" POSTGRES_USER)"
  OLD_PG_DB="$(container_env "$PG_CONTAINER" POSTGRES_DB)"
fi
[[ -z "$OLD_PG_USER" ]] && OLD_PG_USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
[[ -z "$OLD_PG_DB" ]]   && OLD_PG_DB="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
OLD_PG_USER="${OLD_PG_USER:-easyfone}"
OLD_PG_DB="${OLD_PG_DB:-easyfone}"

# Imagem e volume-alvo do Postgres (usados no ajuste de role/db/senha)
PG_IMAGE=""; TARGET_PG_VOLUME=""
if [[ -n "$PG_CONTAINER" ]]; then
  PG_IMAGE="$(docker inspect "$PG_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
  pgvol="$(docker inspect "$PG_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
  [[ -n "$pgvol" ]] && TARGET_PG_VOLUME="${NEW_PROJECT}${pgvol#"$OLD_PROJECT"}"
fi
[[ -z "$PG_IMAGE" ]] && PG_IMAGE="postgres:17-alpine"
[[ -z "$TARGET_PG_VOLUME" ]] && TARGET_PG_VOLUME="${NEW_PROJECT}_pgdata"

# Senha do Postgres: lê do .env e decide se regenera.
# - alvo: role no banco == POSTGRES_PASSWORD do .env (é o que todos os clientes usam);
# - se a senha tiver caractere que quebra ODBC/URL, regenera em hex.
CUR_PW="$(read_env POSTGRES_PASSWORD)"
FINAL_PW="$CUR_PW"; ROTATE_PW=false
if [[ -n "$PW_OVERRIDE" ]]; then
  FINAL_PW="$PW_OVERRIDE"
  password_is_safe "$FINAL_PW" || warn "A senha de --password contém caracteres que podem quebrar ODBC/URL."
elif $KEEP_DB_PASSWORD; then
  if [[ -n "$CUR_PW" ]] && ! password_is_safe "$CUR_PW"; then
    warn "--keep-db-password: a senha atual tem caracteres problemáticos — o ODBC do Asterisk pode continuar falhando."
  fi
else
  if [[ -z "$CUR_PW" ]] || ! password_is_safe "$CUR_PW"; then
    FINAL_PW="$(gen_hex_secret 24)"
    ROTATE_PW=true
    warn "POSTGRES_PASSWORD tem caracteres que quebram ODBC/URL — será regenerada em hex."
  fi
fi

ok "Projeto Compose real:    $OLD_PROJECT"
ok "Projeto Compose novo:    $NEW_PROJECT"
ok "Container Postgres:      ${PG_CONTAINER:-(nenhum)}"
ok "Postgres real:           user=$OLD_PG_USER db=$OLD_PG_DB"
ok "Postgres novo:           user=$NEW_PG_USER db=$NEW_PG_DB"
ok "Volume de dados alvo:    $TARGET_PG_VOLUME"
if [[ -z "$CUR_PW" ]]; then
  warn "Senha Postgres:          (vazia)"
elif password_is_safe "$CUR_PW"; then
  ok "Senha Postgres:          segura (len=${#CUR_PW})"
else
  warn "Senha Postgres:          INSEGURA (len=${#CUR_PW}) — será regenerada"
fi
[[ "$OLD_PROJECT" == "$NEW_PROJECT" ]] && ok "O projeto já é '$NEW_PROJECT' — volumes já devem estar no nome-alvo."

# Volumes do projeto real (prefixo detectado, não o do .env)
mapfile -t OLD_VOLUMES < <(docker volume ls -q --filter "name=^${OLD_PROJECT}_" 2>/dev/null || true)
if [[ ${#OLD_VOLUMES[@]} -eq 0 ]]; then
  warn "Nenhum volume '${OLD_PROJECT}_*' encontrado."
else
  ok "Volumes do projeto atual: ${#OLD_VOLUMES[@]}"
fi

# Plano de cópia: só quando o nome muda e o alvo não é o próprio volume
COPY_PAIRS=()
for v in "${OLD_VOLUMES[@]}"; do
  suffix="${v#"${OLD_PROJECT}"}"           # ex.: _pgdata
  target="${NEW_PROJECT}${suffix}"
  [[ "$v" == "$target" ]] && continue       # já está no nome-alvo
  if docker volume inspect "$target" >/dev/null 2>&1; then
    if $FORCE; then
      warn "Alvo '$target' já existe — sobrescrevendo com --force ($v → $target)."
    else
      error "O volume alvo '$target' já existe (origem: '$v')."
      error "Não sobrescrevo dados. Remova o alvo ou use --force."
      exit 1
    fi
  fi
  COPY_PAIRS+=("$v|$target")
done

if [[ ${#COPY_PAIRS[@]} -eq 0 ]]; then
  ok "Nenhum volume a copiar (nomes já estão no alvo)."
else
  ok "Volumes a copiar: ${#COPY_PAIRS[@]}"
fi

# Redes antigas a remover (nunca as novas)
OLD_NETS=("${OLD_PROJECT}_default" "${OLD_PROJECT}-traefik-public" "easyfone-traefik-public")

# docker pull alpine (usado na cópia)
if ! docker image inspect alpine >/dev/null 2>&1; then
  info "Baixando imagem 'alpine' (usada na cópia dos volumes)…"
  run docker pull alpine
fi

# ─────────────────────────────────────────────────────────────────────
#  1. BACKUP
# ─────────────────────────────────────────────────────────────────────
step "1/7 — Backup"

TS="$(date +%Y%m%d-%H%M%S)"
run cp -a "$ENV_FILE" "$BACKUP_DIR/env.$TS.bak"

if [[ -n "$PG_CONTAINER" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CONTAINER"; then
  info "pg_dump do banco atual (${OLD_PG_DB})…"
  if ! $DRY_RUN; then
    if docker exec "$PG_CONTAINER" pg_dump -U "$OLD_PG_USER" "$OLD_PG_DB" 2>>"$LOG_FILE" | gzip > "$BACKUP_DIR/db.$TS.sql.gz"; then
      ok "Backup: $BACKUP_DIR/db.$TS.sql.gz ($(du -h "$BACKUP_DIR/db.$TS.sql.gz" | cut -f1))"
    else
      warn "pg_dump falhou (o banco pode estar apenas inicializando). Seguindo com o backup do .env."
    fi
  fi
else
  warn "Container do Postgres não está rodando — pulando pg_dump."
fi

echo "ts=$TS" > "$STATE_DIR/state"

# ─────────────────────────────────────────────────────────────────────
#  2. DOWN DO PROJETO ANTIGO
# ─────────────────────────────────────────────────────────────────────
step "2/7 — Derrubar o projeto antigo (volumes preservados)"

# Usa o compose NOVO, mas o projeto REAL: casa por label de serviço.
run docker compose -p "$OLD_PROJECT" down

# Redes antigas (o nome mudou, então o down pode não removê-las).
# Nunca remove as redes novas (ex.: easyphone_default / easyphone-traefik-public).
for net in "${OLD_NETS[@]}"; do
  [[ "$net" == "${NEW_PROJECT}_default" || "$net" == "${NEW_PROJECT}-traefik-public" ]] && continue
  if docker network inspect "$net" >/dev/null 2>&1; then
    run docker network rm "$net"
  fi
done

# ─────────────────────────────────────────────────────────────────────
#  3. CÓPIA DOS VOLUMES
# ─────────────────────────────────────────────────────────────────────
step "3/7 — Copiar volumes para os nomes-alvo"

if [[ ${#COPY_PAIRS[@]} -gt 0 ]]; then
  total_kb=0
  for pair in "${COPY_PAIRS[@]}"; do
    old="${pair%%|*}"; target="${pair##*|}"
    kb=$(docker run --rm -v "${old}:/v:ro" alpine du -sk /v 2>/dev/null | awk '{print $1}')
    kb=${kb:-0}
    total_kb=$((total_kb + kb))
    printf '  %-45s → %s (%s KB)\n' "$old" "$target" "$kb" | tee -a "$LOG_FILE"
  done
  ok "Total a copiar: ~$((total_kb / 1024)) MB"

  avail_kb=$(df -Pk "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" | awk 'NR==2{print $4}')
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$((total_kb * 2))" ]]; then
    error "Espaço em disco insuficiente: ~$((total_kb/1024)) MB a copiar, $((avail_kb/1024)) MB livres."
    $FORCE || exit 1
  fi

  for pair in "${COPY_PAIRS[@]}"; do
    old="${pair%%|*}"; target="${pair##*|}"
    run docker volume create "$target"
    run docker run --rm -v "${old}:/from:ro" -v "${target}:/to" \
      alpine sh -c 'tar -C /from -cf - . | tar -C /to -xf -'
    echo "$target" >> "$STATE_DIR/copied_volumes"
    ok "Copiado: $old → $target"
  done
else
  ok "Nada a copiar — os volumes já estão no nome-alvo."
fi

# ─────────────────────────────────────────────────────────────────────
#  4. AJUSTAR .env
# ─────────────────────────────────────────────────────────────────────
step "4/7 — Ajustar .env (nomes novos + obsoletas)"

# Nomes antigos -> padrão atual (ver README/contrato de env).
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

# Chaves obsoletas (sem equivalente no padrão atual).
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

if ! $DRY_RUN; then
  for pair in "${ENV_RENAMES[@]}"; do rename_env "${pair%%|*}" "${pair##*|}"; done
  for key in "${OBSOLETE_ENV_KEYS[@]}"; do remove_env "$key"; done

  # Unifica FIREBASE_URL: o valor passa a ser a base DIRETA das cloud functions
  # (antes havia a base do Hosting + a das functions; agora é só uma).
  fb_functions="$(read_env FIREBASE_FUNCTIONS_URL)"
  [[ -z "$fb_functions" ]] && fb_functions="$(read_env EASYPHONE_FIREBASE_FUNCTIONS_URL)"
  remove_env "FIREBASE_URL"; remove_env "EASYPHONE_FIREBASE_URL"
  remove_env "FIREBASE_FUNCTIONS_URL"; remove_env "EASYPHONE_FIREBASE_FUNCTIONS_URL"
  [[ -n "$fb_functions" ]] && update_env "FIREBASE_URL" "$fb_functions"

  update_env "POSTGRES_USER" "$NEW_PG_USER"
  update_env "POSTGRES_DB" "$NEW_PG_DB"
fi
info "Variáveis migradas para o padrão atual; obsoletas removidas."
info "POSTGRES_USER=$NEW_PG_USER"
info "POSTGRES_DB=$NEW_PG_DB"

# ─────────────────────────────────────────────────────────────────────
#  5. AJUSTAR BANCO (role/db + senha)
# ─────────────────────────────────────────────────────────────────────
step "5/7 — Ajustar banco (role/db + senha)"

pg_db_changed=false;   [[ "$OLD_PG_DB"   != "$NEW_PG_DB"   ]] && pg_db_changed=true
pg_role_changed=false; [[ "$OLD_PG_USER" != "$NEW_PG_USER" ]] && pg_role_changed=true

if $SKIP_DB; then
  warn "Pulando rename/senha do Postgres (--skip-db)."
elif ! $DRY_RUN && ! docker volume inspect "$TARGET_PG_VOLUME" >/dev/null 2>&1; then
  warn "Volume de dados '$TARGET_PG_VOLUME' não encontrado — pulando rename/senha."
elif $pg_db_changed || $pg_role_changed || ! $KEEP_DB_PASSWORD; then
  # Container temporário com trust, montando o MESMO volume de dados. Bypassa a
  # autenticação, então funciona mesmo sem saber a senha atual da role.
  run docker rm -f "$PG_MIGRATE_NAME" || true
  run docker run --rm -d --name "$PG_MIGRATE_NAME" \
    -v "$TARGET_PG_VOLUME":/var/lib/postgresql/data \
    -e POSTGRES_HOST_AUTH_METHOD=trust "$PG_IMAGE"

  if ! $DRY_RUN; then
    ready=false
    for _ in $(seq 1 60); do
      if docker exec "$PG_MIGRATE_NAME" pg_isready -U "$OLD_PG_USER" -d postgres >/dev/null 2>&1; then
        ready=true; break
      fi
      sleep 1
    done
    if ! $ready; then
      error "Postgres (trust) não ficou pronto. Nada foi alterado."
      docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true
      exit 1
    fi

    # Renomeia só o que difere (ALTER para o mesmo nome falha) e aplica a senha.
    sql=""
    if $pg_db_changed; then
      sql+="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$OLD_PG_DB' AND pid <> pg_backend_pid();"$'\n'
      sql+="ALTER DATABASE \"$OLD_PG_DB\" RENAME TO \"$NEW_PG_DB\";"$'\n'
    fi
    if $pg_role_changed; then
      sql+="ALTER ROLE \"$OLD_PG_USER\" RENAME TO \"$NEW_PG_USER\";"$'\n'
    fi
    if ! $KEEP_DB_PASSWORD; then
      sql+="\\set pw \`printf '%s' \"\$NP\"\`"$'\n'
      sql+="ALTER ROLE \"$NEW_PG_USER\" WITH PASSWORD :'pw';"$'\n'
    fi
    sql+="\\echo MIGRATE_DB_OK"$'\n'

    if ! printf '%s' "$sql" | docker exec -i -e NP="$FINAL_PW" "$PG_MIGRATE_NAME" \
          psql -U "$OLD_PG_USER" -d postgres -v ON_ERROR_STOP=1 >>"$LOG_FILE" 2>&1; then
      error "Falha ao ajustar role/db/senha. Volumes antigos intactos."
      error "Restaure o .env de $BACKUP_DIR/env.$TS.bak para voltar atrás."
      docker rm -f "$PG_MIGRATE_NAME" >/dev/null 2>&1 || true
      exit 1
    fi
    ok "Banco ajustado: db $OLD_PG_DB → $NEW_PG_DB; role $OLD_PG_USER → $NEW_PG_USER; senha alinhada ao .env."
  fi

  run docker rm -f "$PG_MIGRATE_NAME" || true

  # Regrava a senha no .env se foi regenerada
  if ! $KEEP_DB_PASSWORD && [[ "$FINAL_PW" != "$CUR_PW" ]]; then
    if ! $DRY_RUN; then update_env "POSTGRES_PASSWORD" "$FINAL_PW"; fi
    ROTATE_PW=true
  fi

  # Verificação: sobe só o Postgres e testa login TCP com a senha final do .env
  if ! $DRY_RUN; then
    info "Verificando login TCP do Postgres com a senha do .env…"
    run docker compose up -d postgres
    pg_ready=false
    for _ in $(seq 1 60); do
      if docker exec "${NEW_PROJECT}-pg" pg_isready -U "$NEW_PG_USER" -d "$NEW_PG_DB" >/dev/null 2>&1; then
        pg_ready=true; break
      fi
      sleep 1
    done
    if ! $pg_ready; then
      error "Postgres não subiu para a verificação."
      exit 1
    fi
    if PGPASSWORD="$FINAL_PW" docker run --rm -e PGPASSWORD --network host "$PG_IMAGE" \
         psql -h 127.0.0.1 -p 7001 -U "$NEW_PG_USER" -d "$NEW_PG_DB" -c 'select 1' >>"$LOG_FILE" 2>&1; then
      ok "Login TCP com a senha do .env: OK."
    else
      error "Login TCP FALHOU com a senha do .env — abortando antes de subir a stack."
      error "Restaure o .env de $BACKUP_DIR/env.$TS.bak para voltar atrás."
      run docker compose down
      exit 1
    fi
    run docker compose down
  fi
else
  ok "Postgres já é easyphone e a senha é segura — nada a ajustar."
fi

# ─────────────────────────────────────────────────────────────────────
#  6. FIREWALL DO HOST
# ─────────────────────────────────────────────────────────────────────
step "6/7 — Migrar o firewall do host"

if $SKIP_FW; then
  warn "Pulando (--skip-firewall)."
elif ! command -v iptables >/dev/null 2>&1; then
  warn "iptables não encontrado — pulando firewall."
else
  # 6a. Desabilitar/remover o unit antigo (arquivo + symlink de enable)
  if systemctl list-unit-files 2>/dev/null | grep -q "^${OLD_UNIT%.service}"; then
    run systemctl disable --now "$OLD_UNIT"
  fi
  run rm -f "/etc/systemd/system/$OLD_UNIT"
  run rm -f "/etc/systemd/system/multi-user.target.wants/$OLD_UNIT"

  # 6b. Remover resíduo do guia antigo (mesmo nome do unit novo)
  if [[ -f "$NEW_UNIT_PATH" ]]; then
    warn "Removendo $NEW_UNIT_PATH pré-existente (resíduo de guia antigo)."
    run systemctl disable --now "$NEW_UNIT"
    run rm -f "$NEW_UNIT_PATH"
  fi
  run rm -rf /opt/easyphone/firewall
  run systemctl daemon-reload

  # 6c. Purgar chains antigas (ordem: desencadear da INPUT, depois apagar)
  if ! $DRY_RUN; then
    while iptables -C INPUT -j "$OLD_CHAIN_WL" 2>/dev/null; do iptables -D INPUT -j "$OLD_CHAIN_WL"; done
    while iptables -C INPUT -j "$OLD_CHAIN_IN" 2>/dev/null; do iptables -D INPUT -j "$OLD_CHAIN_IN"; done
    iptables -F "$OLD_CHAIN_WL" 2>/dev/null || true
    iptables -X "$OLD_CHAIN_WL" 2>/dev/null || true
    iptables -F "$OLD_CHAIN_IN" 2>/dev/null || true
    iptables -X "$OLD_CHAIN_IN" 2>/dev/null || true
  fi
  info "Chains antigas $OLD_CHAIN_IN / $OLD_CHAIN_WL removidas."

  # 6d. Instalar o unit novo e aplicar as regras
  if [[ -f "$NEW_UNIT_TEMPLATE" ]]; then
    if ! $DRY_RUN; then
      sed "s|__FIREWALL_SCRIPT__|$REPO_DIR/firewall-rules.sh|g" "$NEW_UNIT_TEMPLATE" > "$NEW_UNIT_PATH"
    fi
    run systemctl daemon-reload
    run systemctl enable "$NEW_UNIT"
    run bash "$REPO_DIR/firewall-rules.sh"
    ok "$NEW_UNIT instalado e regras reaplicadas."
  else
    warn "Template '$NEW_UNIT_TEMPLATE' não encontrado; unit não instalado."
    run bash "$REPO_DIR/firewall-rules.sh"
  fi
fi

# ─────────────────────────────────────────────────────────────────────
#  7. RESUMO
# ─────────────────────────────────────────────────────────────────────
step "7/7 — Resumo"

if $DRY_RUN; then
  warn "MODO DRY-RUN: nada foi alterado. Revise o plano acima e rode sem --dry-run."
  exit 0
fi

echo "$TS" > "$STATE_DIR/last_success"
echo
ok "Migração concluída."
if $ROTATE_PW; then
  echo
  printf '  Senha nova do Postgres (guarde em local seguro): %s\n' "$FINAL_PW"
fi
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
  if [[ "$OLD_PROJECT" != "$NEW_PROJECT" ]]; then
    for pair in "${COPY_PAIRS[@]}"; do
      old="${pair%%|*}"
      run docker volume rm "$old" || warn "Não foi possível remover $old (em uso?)."
    done
    for net in "${OLD_NETS[@]}"; do
      [[ "$net" == "${NEW_PROJECT}_default" || "$net" == "${NEW_PROJECT}-traefik-public" ]] && continue
      docker network inspect "$net" >/dev/null 2>&1 && run docker network rm "$net" || true
    done
  fi
  run rm -f "$OLD_TEMPLATE"
  ok "Resíduo antigo removido."
fi
