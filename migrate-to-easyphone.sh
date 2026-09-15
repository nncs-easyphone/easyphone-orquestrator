#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Migração de instalações antigas (EasyFone → EasyPhone)
# Uso: sudo bash migrate-to-easyphone.sh [opções]
#
# Migra uma instalação criada pelo orquestrador ANTIGO (projeto Compose
# "easyfone") para a identidade NOVA deste repositório ("easyphone"), SEM perder
# dados. Rode DEPOIS do `git pull` (o docker-compose.yml já traz os nomes novos)
# e ANTES do `docker compose up -d --force-recreate`.
#
# O que este script faz:
#   1. backup lógico do Postgres e do .env;
#   2. derruba o projeto antigo (preservando volumes);
#   3. copia cada volume easyfone_* → easyphone_*;
#   4. renomeia o banco/role do Postgres (easyfone → easyphone);
#   5. ajusta o .env;
#   6. migra o firewall do host (unit systemd + chains iptables);
#   7. imprime os próximos passos (e, com --cleanup, remove o resíduo antigo).
#
# ATENÇÃO: os nomes de 3 a 5 e 6 são a "identidade de runtime". As imagens de
# api/web NÃO mudam: toda a configuração vem das env do Compose em tempo de
# execução (o .env fica fora da imagem).
#
# Opções:
#   --dry-run          Mostra o plano (volumes e tamanhos) sem alterar nada.
#   --yes              Não-interativo (obrigatório para uso automatizado).
#   --skip-db-rename   Não renomeia role/db do Postgres (só projeto + volumes).
#   --skip-firewall    Não mexe no firewall do host.
#   --cleanup          Após sucesso, remove volumes/rede/backups antigos.
#   --force            Prossegue mesmo com estado ambíguo.
#   -h, --help         Mostra esta ajuda.

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

OLD_PROJECT_DEFAULT="easyfone"
NEW_PROJECT="easyphone"

OLD_UNIT="easyfone-firewall.service"
NEW_UNIT="easyphone-firewall.service"
OLD_TEMPLATE="$REPO_DIR/systemd/easyfone-firewall.service.example"
OLD_CHAIN_IN="EASYFONE_INPUT"
OLD_CHAIN_WL="EASYFONE_WHITELIST"
NEW_UNIT_TEMPLATE="$REPO_DIR/systemd/easyphone-firewall.service.example"
NEW_UNIT_PATH="/etc/systemd/system/$NEW_UNIT"

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

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --yes)            ASSUME_YES=true ;;
    --skip-db-rename) SKIP_DB=true ;;
    --skip-firewall)  SKIP_FW=true ;;
    --cleanup)        CLEANUP=true ;;
    --force)          FORCE=true ;;
    -h|--help)        sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) error "Argumento desconhecido: $arg"; exit 1 ;;
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

OLD_PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
OLD_PROJECT="${OLD_PROJECT:-$OLD_PROJECT_DEFAULT}"
OLD_NETWORKS=("${OLD_PROJECT}_default" "${OLD_PROJECT}-traefik-public")
OLD_PG_USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
OLD_PG_DB="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
NEW_PG_USER="easyphone"
NEW_PG_DB="easyphone"

ok "Projeto Compose atual:   $OLD_PROJECT"
ok "Projeto Compose novo:    $NEW_PROJECT"
ok "Postgres atual:          user=$OLD_PG_USER db=$OLD_PG_DB"
ok "Postgres novo:           user=$NEW_PG_USER db=$NEW_PG_DB"

if [[ "$OLD_PROJECT" == "$NEW_PROJECT" ]]; then
  ok "O projeto já é '$NEW_PROJECT'. Nada a migrar de Compose/volumes."
  ALREADY_RENAMED_PROJECT=true
else
  ALREADY_RENAMED_PROJECT=false
fi

# Volumes antigos existentes (dinâmico: pega qualquer volume easyfone_*)
mapfile -t OLD_VOLUMES < <(docker volume ls -q --filter "name=^${OLD_PROJECT}_" 2>/dev/null || true)
if [[ ${#OLD_VOLUMES[@]} -eq 0 ]]; then
  warn "Nenhum volume '${OLD_PROJECT}_*' encontrado."
else
  ok "Volumes antigos encontrados: ${#OLD_VOLUMES[@]}"
fi

# Volumes novos já existentes
mapfile -t NEW_EXISTING < <(docker volume ls -q --filter "name=^${NEW_PROJECT}_" 2>/dev/null || true)
if [[ ${#NEW_EXISTING[@]} -gt 0 ]]; then
  if $FORCE; then
    warn "Volumes '${NEW_PROJECT}_*' já existem (${#NEW_EXISTING[@]}) — prosseguindo com --force."
  else
    error "Volumes '${NEW_PROJECT}_*' já existem (${#NEW_EXISTING[@]}): ${NEW_EXISTING[*]}"
    error "Não sobrescrevo dados. Confira e remova antes, ou use --force."
    exit 1
  fi
fi

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

OLD_PG_CONTAINER="${OLD_PROJECT}-pg"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OLD_PG_CONTAINER"; then
  info "pg_dump do banco atual (${OLD_PG_DB})…"
  if ! $DRY_RUN; then
    if docker exec "$OLD_PG_CONTAINER" pg_dump -U "$OLD_PG_USER" "$OLD_PG_DB" 2>>"$LOG_FILE" | gzip > "$BACKUP_DIR/db.$TS.sql.gz"; then
      ok "Backup: $BACKUP_DIR/db.$TS.sql.gz ($(du -h "$BACKUP_DIR/db.$TS.sql.gz" | cut -f1))"
    else
      warn "pg_dump falhou (o banco pode estar apenas inicializando). Seguindo com o backup do .env."
    fi
  fi
else
  warn "Container '$OLD_PG_CONTAINER' não está rodando — pulando pg_dump."
fi

echo "ts=$TS" > "$STATE_DIR/state"

# ─────────────────────────────────────────────────────────────────────
#  2. DOWN DO PROJETO ANTIGO
# ─────────────────────────────────────────────────────────────────────
step "2/7 — Derrubar o projeto antigo (volumes preservados)"

if $ALREADY_RENAMED_PROJECT; then
  info "Projeto já é $NEW_PROJECT — ajustando o down para ele."
  run docker compose down
else
  # Usa o compose NOVO, mas o projeto ANTIGO: casa por label de serviço.
  run docker compose -p "$OLD_PROJECT" down
fi

# Redes antigas (o nome mudou, então o down pode não removê-las)
for net in "${OLD_NETWORKS[@]}"; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    run docker network rm "$net"
  fi
done

# ─────────────────────────────────────────────────────────────────────
#  3. CÓPIA DOS VOLUMES
# ─────────────────────────────────────────────────────────────────────
step "3/7 — Copiar volumes ${OLD_PROJECT}_* → ${NEW_PROJECT}_*"

if ${#OLD_VOLUMES[@]} -gt 0; then
  total_kb=0
  for v in "${OLD_VOLUMES[@]}"; do
    kb=$(docker run --rm -v "${v}:/v:ro" alpine du -sk /v 2>/dev/null | awk '{print $1}')
    kb=${kb:-0}
    total_kb=$((total_kb + kb))
    suffix="${v#"${OLD_PROJECT}"}"
    printf '  %-40s → %s (%s KB)\n' "$v" "${NEW_PROJECT}${suffix}" "$kb" | tee -a "$LOG_FILE"
  done
  ok "Total a copiar: ~$((total_kb / 1024)) MB"

  avail_kb=$(df -Pk "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)" | awk 'NR==2{print $4}')
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$((total_kb * 2))" ]]; then
    error "Espaço em disco insuficiente: ~$((total_kb/1024)) MB a copiar, $((avail_kb/1024)) MB livres."
    $FORCE || exit 1
  fi

  for v in "${OLD_VOLUMES[@]}"; do
    suffix="${v#"${OLD_PROJECT}"}"
    new="${NEW_PROJECT}${suffix}"
    run docker volume create "$new"
    run docker run --rm -v "${v}:/from:ro" -v "${new}:/to" \
      alpine sh -c 'tar -C /from -cf - . | tar -C /to -xf -'
    echo "$new" >> "$STATE_DIR/copied_volumes"
    ok "Copiado: $v → $new"
  done
else
  warn "Nada a copiar (nenhum volume ${OLD_PROJECT}_*)."
fi

# ─────────────────────────────────────────────────────────────────────
#  4. AJUSTAR .env
# ─────────────────────────────────────────────────────────────────────
step "4/7 — Ajustar .env"

update_env() {
  local key="$1" value="$2"
  awk -v key="$key" -v val="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 { print key "=" val; replaced = 1; next }
    { print }
    END { if (!replaced) print key "=" val }
  ' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

if ! $DRY_RUN; then
  update_env "COMPOSE_PROJECT_NAME" "$NEW_PROJECT"
  update_env "POSTGRES_USER" "$NEW_PG_USER"
  update_env "POSTGRES_DB" "$NEW_PG_DB"
fi
info "COMPOSE_PROJECT_NAME=$NEW_PROJECT"
info "POSTGRES_USER=$NEW_PG_USER"
info "POSTGRES_DB=$NEW_PG_DB"

# ─────────────────────────────────────────────────────────────────────
#  5. RENOMEAR ROLE/DB DO POSTGRES
# ─────────────────────────────────────────────────────────────────────
step "5/7 — Renomear role/db do Postgres"

if $SKIP_DB; then
  warn "Pulando (--skip-db-rename)."
elif [[ "$OLD_PG_USER" == "$NEW_PG_USER" && "$OLD_PG_DB" == "$NEW_PG_DB" ]]; then
  ok "Postgres já é easyphone."
else
  run docker compose up -d postgres

  if ! $DRY_RUN; then
    info "Aguardando o Postgres aceitar conexões…"
    ready=false
    for _ in $(seq 1 60); do
      if docker exec "${NEW_PROJECT}-pg" pg_isready -U "$OLD_PG_USER" -d postgres >/dev/null 2>&1; then
        ready=true; break
      fi
      sleep 1
    done
    if ! $ready; then
      error "Postgres não ficou pronto a tempo. Nada foi renomeado."
      error "Stack parada. Restaure o .env de $BACKUP_DIR/env.$TS.bak se necessário."
      exit 1
    fi

    if ! docker exec "${NEW_PROJECT}-pg" psql -U "$OLD_PG_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '$OLD_PG_DB' AND pid <> pg_backend_pid();
ALTER DATABASE "$OLD_PG_DB" RENAME TO "$NEW_PG_DB";
ALTER ROLE "$OLD_PG_USER" RENAME TO "$NEW_PG_USER";
SQL
    then
      error "Falha ao renomear role/db. A stack está parada e os volumes antigos estão intactos."
      error "Restaure o .env de $BACKUP_DIR/env.$TS.bak e suba o projeto antigo para voltar atrás."
      exit 1
    fi
    ok "Banco renomeado: $OLD_PG_DB → $NEW_PG_DB; role: $OLD_PG_USER → $NEW_PG_USER."
  fi

  run docker compose down
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
  # 6a. Desabilitar/remover o unit antigo
  if systemctl list-unit-files 2>/dev/null | grep -q "^${OLD_UNIT%.service}"; then
    run systemctl disable --now "$OLD_UNIT"
  fi
  run rm -f "/etc/systemd/system/$OLD_UNIT"

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
    for v in "${OLD_VOLUMES[@]}"; do
      run docker volume rm "$v" || warn "Não foi possível remover $v (em uso?)."
    done
    for net in "${OLD_NETWORKS[@]}"; do
      docker network inspect "$net" >/dev/null 2>&1 && run docker network rm "$net" || true
    done
  fi
  run rm -f "$OLD_TEMPLATE"
  ok "Resíduo antigo removido."
fi
