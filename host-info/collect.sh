#!/bin/sh
# Coletor das informações do HOST exibidas no Dashboard (card "Informações do
# Servidor"). A API roda na bridge do compose e, de dentro do container, só
# enxerga o próprio container: hostname = ID, SO = Alpine, rede = eth0 172.x.
# Este serviço roda com a rede e o UTS do host e grava o que ela precisa num
# volume compartilhado, lido em HOST_INFO_PATH.
#
# Busybox puro (alpine sem pacotes extras): nada a instalar no boot, que
# falharia em servidor sem saída para a internet.

set -eu

OUTPUT_DIRECTORY=/host-info
OUTPUT_FILE="$OUTPUT_DIRECTORY/host-info.json"
OS_RELEASE_FILE=/host/os-release
INTERVAL_IN_SECONDS="${HOST_INFO_INTERVAL_SECONDS:-60}"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

operating_system() {
  if [ -r "$OS_RELEASE_FILE" ]; then
    # PRETTY_NAME="Ubuntu 24.04.1 LTS" → Ubuntu 24.04.1 LTS
    sed -n 's/^PRETTY_NAME=//p' "$OS_RELEASE_FILE" | tr -d '"' | head -n 1
  fi
}

# IPv4 de cada interface, sem loopback nem as interfaces que o próprio Docker
# cria no host (docker0, bridges br-*, pares veth) — elas não dizem nada sobre
# a máquina e eram justamente o que o card mostrava errado.
network_json() {
  ip -o -4 addr show | awk '
    {
      name = $2
      sub(/@.*/, "", name)
      if (name == "lo" || name ~ /^(docker|br-|veth)/) next
      address = $4
      sub(/\/.*/, "", address)
      printf "%s{\"name\":\"%s\",\"address\":\"%s\"}", separator, name, address
      separator = ","
    }'
}

write_host_info() {
  temporary_file="$OUTPUT_FILE.tmp"

  printf '{"hostname":"%s","operatingSystem":"%s","network":[%s],"collectedAt":"%s"}\n' \
    "$(json_escape "$(hostname)")" \
    "$(json_escape "$(operating_system)")" \
    "$(network_json)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$temporary_file"

  chmod 644 "$temporary_file"
  # mv no mesmo diretório é atômico: a API nunca lê um JSON pela metade.
  mv "$temporary_file" "$OUTPUT_FILE"
}

mkdir -p "$OUTPUT_DIRECTORY"

while true; do
  write_host_info || echo "host-info: falha ao coletar; nova tentativa em ${INTERVAL_IN_SECONDS}s" >&2
  sleep "$INTERVAL_IN_SECONDS"
done
