#!/usr/bin/env bash
#
# EasyFone Orchestrator — Regras de Firewall (iptables)
# Uso: sudo bash firewall-rules.sh
#
# Define regras de entrada para as portas do projeto e
# mantém política restritiva (DROP) nas chains INPUT e FORWARD.

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

# ── 1. Limpeza ────────────────────────────────────────────────────────
info "Limpando regras existentes em todas as tabelas…"
iptables -F
iptables -X
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
ok "Regras antigas removidas."

# ── 2. Políticas padrão ──────────────────────────────────────────────
info "Definindo políticas padrão…"
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT
ok "Políticas definidas: INPUT=DROP  FORWARD=DROP  OUTPUT=ACCEPT"

# ── 3. Loopback ──────────────────────────────────────────────────────
iptables -A INPUT -i lo -j ACCEPT
ok "Loopback liberado."

# ── 4. Conexões estabelecidas / related ───────────────────────────────
iptables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ok "Conexões estabelecidas/related aceitas."

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

# ── 8. Redes do Docker ───────────────────────────────────────────────
# bridge padrão (docker0)
if ip link show docker0 &>/dev/null; then
  iptables -A INPUT   -i docker0 -j ACCEPT
  iptables -A FORWARD -i docker0 -j ACCEPT
  ok "Tráfego da bridge docker0 liberado."
fi

# docker_gwbridge (usado em Swarm/overlay)
if ip link show docker_gwbridge &>/dev/null; then
  iptables -A INPUT   -i docker_gwbridge -j ACCEPT 2>/dev/null || true
  iptables -A FORWARD -i docker_gwbridge -j ACCEPT 2>/dev/null || true
  ok "Tráfego da bridge docker_gwbridge liberado."
fi

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
  warn "Docker está rodando. Se os contêineres perderem conectividade,"
  warn "reinicie o Docker:  sudo systemctl restart docker"
fi

echo
echo -e "${GREEN}${BOLD}✓ Firewall configurado com sucesso.${NC}"
