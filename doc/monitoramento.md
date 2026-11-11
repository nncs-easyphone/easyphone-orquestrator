# Monitoramento da instalação

O serviço `host-info` é o coletor único do host. Ele mantém o contrato antigo do
card "Informações do Servidor" e acrescenta o relatório de versão e execução
enviado ao Firebase.

## Arquivos

Ambos ficam no volume `easyphone_host_info`, montado em `/host-info`:

| Arquivo | Frequência | Consumidor |
|---|---|---|
| `host-info.json` | 60s | API (`HOST_INFO_PATH`) e dashboard |
| `system-report.json` | 10min | `reportSystemHealth` no Firebase |

`host-info.json` continua exatamente com os campos antigos:

```json
{
  "hostname": "pbx-01",
  "operatingSystem": "Ubuntu 24.04.1 LTS",
  "network": [{ "name": "eth0", "address": "203.0.113.10" }],
  "collectedAt": "2026-11-11T12:00:00.000Z"
}
```

`system-report.json` contém:

- `schemaVersion`, `reportedAt` e `orchestrator.version`;
- `server`: hostname, SO, kernel, arquitetura, uptime, load, CPU, memória, swap,
  disco do host e redes;
- `docker`: disponibilidade, versão do Engine, containers do projeto `easyphone`
  e imagens usadas (tag, digest, data de criação, tamanho e serviços).

## Variáveis usadas

Nenhuma variável nova foi criada. O relatório usa:

```env
FIREBASE_URL=
FIREBASE_SERVICE_ACCOUNT=
LICENSE_CLIENT_ID=
LICENSE_HARDWARE_ID=
```

Com qualquer uma vazia, o coletor grava os arquivos locais e **não envia** ao
Firebase. Isso permite instalações sem licença ou sem Firebase sem quebrar o
dashboard.

## Autenticação

O coletor assina um JWT RS256 com a service account e envia:

```text
POST ${FIREBASE_URL}/reportSystemHealth
Authorization: Bearer <jwt>
```

O token tem escopo `system:report`, `aud: ivr-api-v1` e validade de 5 minutos.
A função aceita instalações com licença expirada/bloqueada, mas exige que o
tenant exista e que a service account esteja na whitelist.

## Aplicação em instalações existentes

```bash
git pull
docker compose pull docker-proxy host-info
docker compose up -d docker-proxy host-info
```

Somente o `docker-proxy` e o `host-info` são criados/recriados.

## Conferência

```bash
docker logs -f easyphone-host-info
docker exec easyphone-host-info cat /host-info/host-info.json
docker exec easyphone-host-info cat /host-info/system-report.json
```

No Firebase, o último relatório fica em `installations/{LICENSE_CLIENT_ID}`. O
estado calculado (online/offline/desatualizada) fica em
`installationHealth/{LICENSE_CLIENT_ID}`.

## Segurança do acesso ao Docker

O `host-info` não monta o `docker.sock`. O único container com o socket real é o
`docker-proxy`:

```text
docker.sock (host, :ro)
   └─ docker-proxy (network_mode: none)
        └─ socket Unix em volume
             └─ host-info
```

O HAProxy do proxy aceita somente:

- `GET /version`
- `GET /containers/json`
- `GET /containers/{id}/json`
- `GET /images/json`

Qualquer outro método ou endpoint retorna 403. O socket fica em um volume
compartilhado apenas entre o proxy e o `host-info`; não há porta TCP. O proxy
roda com `read_only`, `cap_drop: ALL` e `no-new-privileges`, e a imagem é fixada
por digest.

Para conferir:

```bash
docker exec easyphone-docker-proxy ls -l /run/proxy/docker.sock
docker inspect easyphone-host-info --format '{{json .Mounts}}'   # sem docker.sock
docker inspect easyphone-docker-proxy \
  --format '{{json .HostConfig.NetworkMode}} {{json .HostConfig.PortBindings}}'
docker logs easyphone-docker-proxy
```

## Limitações da fase

- As imagens ainda não têm labels OCI de commit; a identificação é por digest e
  data de criação.
- O relatório é enviado a cada 10 minutos; não há fila offline. Uma falha de rede
  é registrada e o próximo ciclo tenta novamente.
- O `docker-proxy` ainda é privilegiado por natureza: se a imagem do proxy for
  comprometida, o impacto é root no host. Ele deve ser atualizado de forma
  controlada e mantido fixado por digest.
- O `host-info` mantém leitura do `/` do host para medir disco. É um risco
  separado do socket e pode ser removido numa evolução futura com coleta de
  disco no host.
