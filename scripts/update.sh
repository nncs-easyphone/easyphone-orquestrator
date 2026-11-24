#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Atualização da máquina já instalada
# ============================================================
# Baixa a imagem bundle mais recente (:main), compara com o digest instalado
# e, se houver mudança, extrai os arquivos preservando .env e dados locais.
#
# Uso:
#   sudo bash scripts/update.sh
#   sudo bash scripts/update.sh --check
#   sudo bash scripts/update.sh --rollback
#
# A imagem usada é ghcr.io/nncs-easyphone/easyphone-orquestrator:main.
# O PAT (read:packages) é solicitado apenas se o Docker ainda não estiver
# autenticado no registry.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

REGISTRY="${EASYPHONE_REGISTRY:-ghcr.io}"
BUNDLE_IMAGE="${EASYPHONE_BUNDLE_IMAGE:-${REGISTRY}/nncs-easyphone/easyphone-orquestrator:main}"
STATE_FILE="$REPO_DIR/.installed-image"
BACKUP_ROOT="$REPO_DIR/.backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { error "$*"; exit 1; }

ASSUME_YES=false
HAS_TTY=false
if { exec 3</dev/tty; } 2>/dev/null; then
  HAS_TTY=true
fi

ask_yes() {
  local prompt="$1" ans
  $ASSUME_YES && return 0
  $HAS_TTY || return 1
  read -r -u 3 -p "$(echo -e "${YELLOW}?${NC} ${prompt} [S/n] ")" ans || return 1
  [[ -z "${ans:-}" || "$ans" =~ ^[SsYy]$ ]]
}

report_overwrites() {
  local manifest="$1" rel count=0
  if [[ ! -f "$manifest" ]]; then
    warn "manifest.txt ausente no bundle; não foi possível listar os arquivos sobrescritos."
    return 0
  fi
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ -e "$REPO_DIR/$rel" ]]; then
      count=$((count + 1))
    fi
  done < "$manifest"
  ok "${count} arquivo(s) existente(s) serão sobrescritos (backup em .backup/)."
}

restore_bundle_owner() {
  local manifest="$1" owner="$2" rel
  [[ -f "$manifest" ]] || return 0
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    chown "$owner" "$REPO_DIR/$rel" 2>/dev/null || true
    chown "$owner" "$(dirname "$REPO_DIR/$rel")" 2>/dev/null || true
    chown "$owner" "$REPO_DIR/${rel%%/*}" 2>/dev/null || true
  done < "$manifest"
}

check_git_changes() {
  local status
  [[ -d "$REPO_DIR/.git" ]] || return 0

  if ! command -v git &>/dev/null; then
    warn "Diretório .git encontrado, mas git não está instalado; não foi possível verificar alterações locais."
    return 0
  fi

  if ! status="$(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null)"; then
    warn "Não foi possível verificar alterações locais com git."
    return 0
  fi

  [[ -z "$status" ]] && return 0

  warn "O clone git em $REPO_DIR tem alterações locais em arquivos versionados:"
  printf '%s\n' "$status" | sed 's/^/    /'
  warn "Esses arquivos serão sobrescritos pelo bundle. O backup será criado antes."

  if $FORCE; then
    warn "Continuando por --force."
    return 0
  fi

  ask_yes "Continuar e sobrescrever esses arquivos?" \
    || die "Atualização cancelada. Nada foi alterado."
}

usage() {
  cat <<'EOF'
Uso: sudo bash scripts/update.sh [opções]

Opções:
  --check       Apenas verifica se há uma versão nova (não altera nada).
  --rollback    Restaura o backup mais recente e sobe a stack.
  --force       Reextrai o bundle mesmo se o digest for o mesmo.
  --no-start    Não pergunta se deve subir a stack ao final.
  --yes, -y     Responde "sim" às confirmações.
  --help        Mostra esta ajuda.

Variáveis opcionais:
  EASYPHONE_BUNDLE_IMAGE   Imagem usada no update (padrão ...:main)
  EASYPHONE_REGISTRY       Registry (padrão ghcr.io)
  GHCR_USER / GHCR_TOKEN   Credenciais para ambientes sem TTY
                           (use: sudo GHCR_USER=... GHCR_TOKEN=... bash ...)
EOF
}

CHECK_ONLY=false
ROLLBACK=false
FORCE=false
START=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true ;;
    --rollback) ROLLBACK=true ;;
    --force) FORCE=true ;;
    --no-start) START=false ;;
    --yes|-y) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Execute como root: sudo bash scripts/update.sh"
command -v docker &>/dev/null || die "Docker não encontrado."

mkdir -p "$REPO_DIR/logs"
LOG_FILE="$REPO_DIR/logs/update-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

info "Log: $LOG_FILE"

login_registry() {
  local user token

  if [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]]; then
    user="$GHCR_USER"
    token="$GHCR_TOKEN"
  elif $HAS_TTY; then
    read -r -u 3 -p "$(echo -e "${YELLOW}?${NC} Usuário do GitHub: ")" user \
      || return 1
    read -rs -u 3 -p "$(echo -e "${YELLOW}?${NC} PAT com read:packages: ")" token \
      || return 1
    echo
  else
    error "Credenciais ausentes. Defina GHCR_USER e GHCR_TOKEN (ou rode em um terminal interativo)."
    return 1
  fi

  if ! printf '%s' "$token" | docker login "$REGISTRY" -u "$user" --password-stdin; then
    unset token
    error "Falha no login no $REGISTRY. Verifique o PAT e o SSO."
    return 1
  fi
  unset token

  if ! docker manifest inspect "$BUNDLE_IMAGE" >/dev/null 2>&1; then
    warn "Login efetuado, mas não foi possível validar o acesso a $BUNDLE_IMAGE."
    warn "Confira o escopo read:packages e o SSO da organização."
  fi
}

pull_bundle() {
  local pull_log context

  pull_log="$(mktemp)"
  info "Baixando ${BUNDLE_IMAGE}…"

  if docker pull "$BUNDLE_IMAGE" 2>&1 | tee "$pull_log"; then
    rm -f "$pull_log"
    return 0
  fi

  if ! grep -qiE 'unauthorized|authentication required|failed to authorize|no basic auth credentials|pull access denied|insufficient_scope|permission_denied|does not match expected scopes|denied: requested access|denied: denied' "$pull_log"; then
    rm -f "$pull_log"
    warn "O pull falhou antes de qualquer tentativa de renovar credenciais."
    warn "Imagem: $BUNDLE_IMAGE"
    info "DOCKER_CONFIG=${DOCKER_CONFIG:-<padrão>} HOME=${HOME:-<vazio>}"
    info "DOCKER_HOST=${DOCKER_HOST:-<padrão>}"
    context="$(docker context show 2>/dev/null || true)"
    [[ -n "$context" ]] && info "Contexto Docker: $context"
    warn "Teste manualmente: sudo docker pull $BUNDLE_IMAGE"
    die "Não foi possível baixar $BUNDLE_IMAGE (erro não relacionado a credenciais)."
  fi

  rm -f "$pull_log"
  warn "O pull falhou por autenticação no $REGISTRY. Renovando o login…"
  docker logout "$REGISTRY" >/dev/null 2>&1 || true
  login_registry || die "Não foi possível renovar o login no $REGISTRY."

  docker pull "$BUNDLE_IMAGE" \
    || die "Não foi possível baixar $BUNDLE_IMAGE após renovar o login. Verifique o PAT (read:packages) e o acesso à organização."
}

image_digest() {
  local digest
  digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$BUNDLE_IMAGE" 2>/dev/null \
    | awk -F@ '/@sha256:/ {print $2; exit}')"
  if [[ -z "$digest" ]]; then
    digest="$(docker image inspect --format '{{.Id}}' "$BUNDLE_IMAGE" 2>/dev/null || true)"
  fi
  printf '%s' "$digest"
}

image_version() {
  docker run --rm --entrypoint cat "$BUNDLE_IMAGE" /bundle/VERSION 2>/dev/null \
    | tr -d '\r\n' || true
}

current_version() {
  cat "$REPO_DIR/VERSION" 2>/dev/null | tr -d '\r\n' || true
}

backup_current() {
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="$BACKUP_ROOT/${stamp}-$(current_version)"
  mkdir -p "$backup"
  chown 0:0 "$BACKUP_ROOT" "$backup" 2>/dev/null || true
  chmod 700 "$BACKUP_ROOT" "$backup"
  tar -C "$REPO_DIR" -czf "$backup/bundle-before-update.tar.gz" \
    --exclude=./logs \
    --exclude=./states \
    --exclude=./safety \
    --exclude=./data \
    --exclude=./.backup \
    --exclude=./.git \
    --exclude=./node_modules \
    .
  chmod 600 "$backup/bundle-before-update.tar.gz"
  ok "Backup dos arquivos atuais: $backup/bundle-before-update.tar.gz"
}

extract_bundle() {
  local tmp cid target_owner
  tmp="$(mktemp -d)"
  cid="$(docker create "$BUNDLE_IMAGE")"

  if ! docker cp "$cid:/bundle/." "$tmp/"; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    die "Falha ao extrair o bundle da imagem."
  fi
  docker rm "$cid" >/dev/null

  [[ -f "$tmp/scripts/init.sh" && -f "$tmp/docker-compose.yml" && -f "$tmp/VERSION" ]] \
    || { rm -rf "$tmp"; die "Bundle inválido: arquivos obrigatórios não encontrados."; }

  target_owner="$(stat -c '%u:%g' "$REPO_DIR" 2>/dev/null || echo '0:0')"
  report_overwrites "$tmp/manifest.txt"

  # Merge: sobrescreve os arquivos do bundle e preserva .env, logs, states,
  # safety, whitelist, .git e arquivos gerados (que não existem na imagem).
  # O temp fica root-only; o dono do destino é restaurado só nos arquivos do
  # manifest (evita expor o bundle em /tmp a um usuário não-root).
  cp -a "$tmp/." "$REPO_DIR/"
  restore_bundle_owner "$tmp/manifest.txt" "$target_owner"
  rm -rf "$tmp"

  chmod +x "$REPO_DIR"/*.sh "$REPO_DIR"/scripts/*.sh 2>/dev/null || true
  chmod 600 "$REPO_DIR/.env" 2>/dev/null || true
}

restore_latest_backup() {
  local backups latest
  shopt -s nullglob
  backups=("$BACKUP_ROOT"/*/bundle-before-update.tar.gz)
  shopt -u nullglob

  (( ${#backups[@]} > 0 )) || die "Nenhum backup encontrado em $BACKUP_ROOT."

  latest="${backups[0]}"
  for candidate in "${backups[@]}"; do
    if [[ "$candidate" -nt "$latest" ]]; then
      latest="$candidate"
    fi
  done

  tar -C "$REPO_DIR" -xzf "$latest"
  chmod 600 "$REPO_DIR/.env" 2>/dev/null || true
  ok "Arquivos restaurados de $latest"
}

# Rollback não depende do registry: restaura o backup local e reaplica a
# configuração. Se a stack estiver no ar, o init --refresh reaplica firewall
# e units; o run.sh sobe a versão restaurada.
if $ROLLBACK; then
  restore_latest_backup

  # O backup pode ser de uma versão anterior ao suporte a --refresh. Nesse
  # caso não chamamos um init interativo: as units existentes continuam
  # apontando para o mesmo diretório e o operador pode reaplicar à mão.
  if grep -q -- '--refresh)' "$REPO_DIR/scripts/init.sh" 2>/dev/null; then
    if ! bash "$REPO_DIR/scripts/init.sh" --refresh; then
      error "Falha ao reaplicar a configuração após o rollback."
      exit 1
    fi
  else
    warn "O init.sh restaurado não suporta --refresh."
    warn "As units existentes foram mantidas; reaplique a configuração manualmente se necessário."
  fi

  if $START && ask_yes "Subir a stack com a versão restaurada?"; then
    bash "$REPO_DIR/scripts/run.sh"
  fi
  ok "Rollback concluído. .env e configurações foram restaurados do backup."
  exit 0
fi

pull_bundle

NEW_DIGEST="$(image_digest)"
NEW_VERSION="$(image_version)"
OLD_DIGEST="$(cat "$STATE_FILE" 2>/dev/null | tr -d '\r\n' || true)"
OLD_VERSION="$(current_version)"

if $CHECK_ONLY; then
  if [[ -n "$OLD_DIGEST" && "$OLD_DIGEST" == "$NEW_DIGEST" ]]; then
    ok "Instalação atualizada (${OLD_VERSION:-desconhecida})."
  else
    warn "Atualização disponível: ${OLD_VERSION:-desconhecida} → ${NEW_VERSION:-desconhecida}."
  fi
  exit 0
fi

NEED_EXTRACT=true
if [[ -n "$OLD_DIGEST" && "$OLD_DIGEST" == "$NEW_DIGEST" && "$FORCE" != true ]]; then
  ok "Já está atualizado (${OLD_VERSION:-desconhecida})."
  if ! ask_yes "Reaplicar configuração (firewall/whitelist/systemd) mesmo assim?"; then
    exit 0
  fi
  NEED_EXTRACT=false
fi

if $NEED_EXTRACT; then
  check_git_changes
fi

# O backup também é feito no reapply: init --refresh regenera arquivos
# derivados (wss.yml, turnserver.conf) e pode acrescentar chaves ao .env.
backup_current

if $NEED_EXTRACT; then
  extract_bundle
  printf '%s\n' "$NEW_DIGEST" > "$STATE_FILE"
  chmod 644 "$STATE_FILE"
  chown "$(stat -c '%u:%g' "$REPO_DIR" 2>/dev/null || echo '0:0')" "$STATE_FILE" 2>/dev/null || true
  ok "Bundle atualizado para ${NEW_VERSION:-desconhecida} (in-place)."
else
  ok "Reaplicando a configuração sem extrair novamente."
fi

if ! bash "$REPO_DIR/scripts/init.sh" --refresh; then
  error "Falha ao reaplicar a configuração. Use 'sudo bash scripts/update.sh --rollback' se necessário."
  exit 1
fi

if $START && ask_yes "Subir/atualizar a stack agora?"; then
  bash "$REPO_DIR/scripts/run.sh"
fi

ok "Atualização concluída."
