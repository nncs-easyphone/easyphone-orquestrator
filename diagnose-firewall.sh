#!/usr/bin/env bash
#
# EasyPhone Orchestrator — Diagnóstico de firewall e rede (SOMENTE LEITURA)
# Uso: sudo bash diagnose-firewall.sh [> diagnostico-$(date +%F-%H%M).txt]
#
# Este script NÃO altera nada: só lê estado do netfilter, do systemd, do Docker
# e do Asterisk. Rode-o ANTES de mexer em qualquer regra e, de preferência,
# TAMBÉM durante uma janela de indisponibilidade — é a comparação entre as duas
# coletas que aponta a causa.
#
# Ele foi escrito para responder três perguntas:
#   1. Existe um firewall CONCORRENTE no host? (netfilter-persistent, ufw,
#      firewalld) ou resíduo de guia antigo (/opt/easyphone/firewall/)?
#   2. As chains do Docker e as chains EASYPHONE_* estão íntegras?
#   3. A tabela de conntrack está saturando? (causa clássica de "cai tudo e só
#      volta reiniciando o Docker")

set -uo pipefail   # sem -e: um comando ausente não pode abortar a coleta

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

section() { echo; echo -e "${BOLD}${BLUE}══ $* ${NC}"; echo; }
ok()      { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}!${NC} $*"; }
bad()     { echo -e "  ${RED}✗${NC} $*"; }
run()     { echo -e "  ${BOLD}\$ $*${NC}"; "$@" 2>&1 | sed 's/^/    /'; echo; }

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Execute como root: sudo bash $0"
  exit 1
fi

echo "EasyPhone — diagnóstico de firewall"
echo "Host: $(hostname)  —  $(date -Is)"
echo "Kernel: $(uname -r)"

# ── 1. Firewalls concorrentes ────────────────────────────────────────
section "1. Serviços de firewall no host"

for unit in easyphone-firewall.service netfilter-persistent ufw firewalld; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${unit%.service}"; then
    state="$(systemctl is-enabled "$unit" 2>/dev/null || echo desconhecido)"
    active="$(systemctl is-active "$unit" 2>/dev/null || echo inativo)"
    case "$unit" in
      easyphone-firewall.service)
        ok "$unit — enabled=$state active=$active  (é o serviço oficial do projeto)" ;;
      *)
        warn "$unit — enabled=$state active=$active  (pode conflitar com as chains EASYPHONE_*)" ;;
    esac
  fi
done

if [[ -d /opt/easyphone/firewall ]]; then
  bad "/opt/easyphone/firewall existe — scripts do guia obsoleto ainda no host:"
  ls -l /opt/easyphone/firewall/ 2>&1 | sed 's/^/    /'
else
  ok "/opt/easyphone/firewall não existe."
fi

if [[ -f /etc/iptables/rules.v4 ]]; then
  docker_refs=$(grep -c DOCKER /etc/iptables/rules.v4 2>/dev/null || echo 0)
  if [[ "$docker_refs" -eq 0 ]]; then
    bad "/etc/iptables/rules.v4 existe e NÃO tem as chains DOCKER ($docker_refs referências)."
    bad "    Se for restaurado no boot, apaga as chains do Docker e quebra 'docker network create'."
  else
    warn "/etc/iptables/rules.v4 existe ($docker_refs referências a DOCKER) — snapshot de regras."
  fi
fi

section "2. Últimas execuções do firewall oficial"
run journalctl -u easyphone-firewall.service -n 30 --no-pager

# ── 3. Estado do netfilter ───────────────────────────────────────────
section "3. Chain INPUT (ordem importa: whitelist tem que vir ANTES da EASYPHONE_INPUT)"
run iptables -L INPUT -n -v --line-numbers

section "4. Chain EASYPHONE_WHITELIST (filtro por origem)"
if iptables -n -L EASYPHONE_WHITELIST &>/dev/null; then
  run iptables -L EASYPHONE_WHITELIST -n -v --line-numbers
  if iptables -S EASYPHONE_WHITELIST 2>/dev/null | grep -q -- '-j RETURN.*-s\|-s.*-j RETURN'; then
    warn "Há origens com RETURN — versão antiga do script (origem ainda passava pelo filtro de portas)."
    warn "Rode 'sudo bash firewall-rules.sh' para aplicar a versão com ACCEPT (acesso total)."
  fi
else
  warn "Chain EASYPHONE_WHITELIST não existe — whitelist DESATIVADA (sem whitelist.conf)."
fi

section "5. Chain EASYPHONE_INPUT (filtro por porta)"
if iptables -n -L EASYPHONE_INPUT &>/dev/null; then
  run iptables -L EASYPHONE_INPUT -n -v --line-numbers
else
  bad "Chain EASYPHONE_INPUT NÃO existe — o firewall do projeto não está aplicado."
fi

section "6. Chains do Docker (se sumirem, port publishing para até reiniciar o daemon)"
docker_chains=$(iptables -S 2>/dev/null | grep -c DOCKER)
if [[ "$docker_chains" -eq 0 ]]; then
  bad "Nenhuma chain DOCKER no filter. 'docker network create' vai falhar."
  bad "    Correção: systemctl restart docker && bash firewall-rules.sh"
else
  ok "$docker_chains regras/chains DOCKER presentes no filter."
fi
run iptables -t nat -L DOCKER -n
run iptables -n -L DOCKER-USER

section "7. Portas em escuta no host"
run ss -tulpn

# ── 8. Conntrack ─────────────────────────────────────────────────────
section "8. Conntrack — hipótese principal para 'cai tudo e só volta com restart do Docker'"

# Asterisk e Coturn em network_mode: host, com RTP 10000-20000 e relay TURN
# 49152-65535, geram dezenas de milhares de fluxos UDP rastreados. Quando a
# tabela satura, a regra ESTABLISHED,RELATED (primeira da INPUT, sob policy
# DROP) deixa de casar e TODA conexão nova cai — SSH inclusive. Reiniciar o
# Docker mata os containers, libera as entradas e "resolve" temporariamente.
ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "?")
echo "  nf_conntrack_count = $ct_count"
echo "  nf_conntrack_max   = $ct_max"

if [[ "$ct_count" =~ ^[0-9]+$ && "$ct_max" =~ ^[0-9]+$ && "$ct_max" -gt 0 ]]; then
  pct=$(( ct_count * 100 / ct_max ))
  echo "  ocupação           = ${pct}%"
  if   (( pct >= 80 )); then bad "Tabela de conntrack acima de 80% — forte candidata à causa das quedas."
  elif (( pct >= 50 )); then warn "Tabela de conntrack acima de 50% — acompanhe sob carga."
  else                       ok "Ocupação de conntrack saudável no momento desta coleta."
  fi
fi

echo
echo "  Timeouts UDP (segundos):"
for f in nf_conntrack_udp_timeout nf_conntrack_udp_timeout_stream; do
  [[ -f "/proc/sys/net/netfilter/$f" ]] && echo "    $f = $(cat "/proc/sys/net/netfilter/$f")"
done

echo
echo "  Evidência de saturação no log do kernel (vazio = nunca lotou desde o boot):"
dmesg 2>/dev/null | grep -i "conntrack.*table full" | tail -5 | sed 's/^/    /' || true

# ── 9. Bloqueios registrados ─────────────────────────────────────────
section "9. Bloqueios registrados no kernel"

echo "  Prefixo EASYPHONE-WL-DROP (whitelist oficial) — últimas 20:"
journalctl -k --no-pager 2>/dev/null | grep "EASYPHONE-WL-DROP" | tail -20 | sed 's/^/    /' || true
echo
echo "  Prefixo 'FIREWALL DROP' (firewall OBSOLETO do doc) — últimas 10:"
fw_drop=$(journalctl -k --no-pager 2>/dev/null | grep "FIREWALL DROP" | tail -10)
if [[ -n "$fw_drop" ]]; then
  bad "O firewall obsoleto ESTÁ rodando neste host:"
  echo "$fw_drop" | sed 's/^/    /'
else
  ok "Nenhum log com o prefixo do firewall obsoleto."
fi

# ── 10. Recursos e Docker ────────────────────────────────────────────
section "10. Recursos do host (descarta OOM / disco cheio como causa das quedas)"
run free -h
run df -h /
echo "  OOM killer no log do kernel (vazio = nunca disparou desde o boot):"
dmesg 2>/dev/null | grep -i "out of memory\|oom-killer" | tail -5 | sed 's/^/    /' || true

section "11. Containers"
run docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RestartCount}}"
echo "  Uptime do daemon Docker:"
systemctl show docker --property=ActiveEnterTimestamp 2>/dev/null | sed 's/^/    /'

# ── 12. Asterisk ─────────────────────────────────────────────────────
section "12. Asterisk (PJSIP)"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^easyphone-asterisk$'; then
  run docker exec easyphone-asterisk asterisk -rx "pjsip show transports"
  run docker exec easyphone-asterisk asterisk -rx "pjsip show endpoints"
  run docker exec easyphone-asterisk asterisk -rx "pjsip show aors"

  # Descritores abertos: crescimento contínuo entre coletas indica vazamento,
  # que também se manifesta como falha ao criar requisições de saída.
  ast_pid=$(docker inspect -f '{{.State.Pid}}' easyphone-asterisk 2>/dev/null)
  if [[ -n "${ast_pid:-}" && -d "/proc/$ast_pid/fd" ]]; then
    echo "  Descritores abertos pelo Asterisk (pid $ast_pid): $(ls "/proc/$ast_pid/fd" 2>/dev/null | wc -l)"
    echo "  Limite (nofile): $(grep 'Max open files' "/proc/$ast_pid/limits" 2>/dev/null | awk '{print $4" (soft) / "$5" (hard)"}')"
  fi

  echo
  echo "  Erros recentes no log do Asterisk:"
  docker logs --tail 200 easyphone-asterisk 2>&1 | grep -i "ERROR\|WARNING" | tail -20 | sed 's/^/    /' || true
else
  warn "Container easyphone-asterisk não está rodando."
fi

section "Fim do diagnóstico"
echo "  Guarde esta saída. Colete de novo DURANTE uma queda e compare —"
echo "  especialmente as seções 3, 6, 8 e 10."
echo
