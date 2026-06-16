#!/usr/bin/env bash
#
# EasyFone Orchestrator — Regras de Firewall (iptables)
# Uso: sudo bash firewall-rules.sh
#
# Define regras de entrada para as portas do projeto.
# NOTA: FORWARD fica ACCEPT para não quebrar o roteamento de redes do Docker.
# IPv6 deve estar desabilitado no kernel; este script não configura ip6tables.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
  error "Execute como root: sudo bash $0"
  exit 1
fi

cat << "EOF"
  ╔══════════════════════════════════════════════╗
  ║   EasyFone Orchestrator — Firewall Rules     ║
  ╚══════════════════════════════════════════════╝
EOF
echo

PORTS_TCP=(22 7000 7001 7002 5038 8088 8089)
PORTS_UDP=(5060)

# ── 1. Limpeza (apenas INPUT/OUTPUT, preserva chains do Docker) ────
info "Limpando regras das chains INPUT e OUTPUT…"
iptables -F INPUT
iptables -F OUTPUT
ok "Regras antigas de INPUT/OUTPUT removidas (Docker intacto)."

# ── 2. Conexões estabelecidas / related ──────────────────────────────
# PRIMEIRO liberamos conexões ativas (ex: SSH atual) ANTES de mudar
# a política padrão para DROP, evitando queda da sessão.
iptables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ok "Conexões estabelecidas/related aceitas."

# ── 3. Políticas padrão ──────────────────────────────────────────────
# INPUT → DROP  (bloqueia tudo que não foi explicitamente liberado)
# FORWARD → ACCEPT  (obrigatório para o Docker rotear tráfego entre
#                     containers e para fora; o Docker gerencia suas
#                     próprias restrições nas chains DOCKER / DOCKER-USER)
info "Definindo políticas padrão…"
iptables -P INPUT   DROP
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT
ok "Políticas definidas: INPUT=DROP  FORWARD=ACCEPT  OUTPUT=ACCEPT"

# ── 4. Loopback ──────────────────────────────────────────────────────
iptables -A INPUT -i lo -j ACCEPT
ok "Loopback liberado."

# ── 5. ICMP (ping) ───────────────────────────────────────────────────
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
ok "ICMP echo-request liberado."

# ── 6. Portas TCP ────────────────────────────────────────────────────
info "Liberando portas TCP…"
for port in "${PORTS_TCP[@]}"; do
  iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} TCP/$port"
done

# ── 7. Portas UDP ────────────────────────────────────────────────────
info "Liberando portas UDP…"
for port in "${PORTS_UDP[@]}"; do
  iptables -A INPUT -p udp --dport "$port" -j ACCEPT
  echo -e "  ${GREEN}✓${NC} UDP/$port"
done

# ── 8. NOTA sobre Docker ──────────────────────────────────────────────
# O Docker gerencia automaticamente suas próprias regras de FORWARD,
# NAT e bridges (docker0, docker_gwbridge, etc.).
# Não inserimos regras manuais nessas chains para evitar conflitos.
#
# ⚠ FORWARD policy = ACCEPT (indispensável para o Docker).
# Se precisar restringir tráfego entre containers, use a chain DOCKER-USER:
#   iptables -A DOCKER-USER -i docker0 -o docker0 -j DROP

# ── 9. Persistência ──────────────────────────────────────────────────
echo
info "Salvando regras para restaurar no boot…"

if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save
  ok "Regras salvas via netfilter-persistent."
elif [[ -d /etc/iptables ]]; then
  iptables-save > /etc/iptables/rules.v4
  ok "Regras salvas em /etc/iptables/rules.v4"
else
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  ok "Diretório /etc/iptables criado e regras salvas."
fi

# ── 10. Aviso sobre Docker ───────────────────────────────────────────
if pidof dockerd &>/dev/null; then
  ok "Docker detectado — chains e regras do Docker foram preservadas."
fi

echo
echo -e "${GREEN}${BOLD}✓ Firewall configurado com sucesso.${NC}"
