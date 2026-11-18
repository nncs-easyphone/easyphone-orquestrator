# EasyPhone Orchestrator

Provisionamento e inicialização da stack EasyPhone (Postgres, PgBouncer, API, Web, Asterisk, Coturn) em uma VM vazia.

## Arquitetura on-premise

Esta stack é **on-premise, single-tenant e single-node**:

- Todos os serviços deste repositório rodam na mesma VM, na infraestrutura do cliente.
- Não há alta disponibilidade, failover automático nem múltiplas réplicas.
- Manutenções e restarts podem interromper chamadas, ramais e a interface durante a janela de execução.
- O RPO assumido é o **backup diário**; não há PITR nem replicação contínua.
- O chat em nuvem (`chat-backend`) é um serviço separado, **multi-tenant e multi-grupo**, e não roda nesta stack.

## Requisitos

- **SO:** Ubuntu 22.04+ ou Debian 12+
- **Arquitetura:** x86_64
- **Mínimo:** 2 vCPU, 4 GB RAM
- **Acesso root** via `sudo`
- **Domínio público** apontado para a VM. Três subdomínios precisam resolver para o IP da VM **antes** do primeiro `docker compose up` (o Traefik emite os certificados via desafio DNS-01/HTTPREQ):

| Subdomínio | Serviço |
|---|---|
| `app.${DOMAIN}` | Interface web |
| `api.${DOMAIN}` | API REST |
| `pbx.${DOMAIN}` | WebSocket SIP (WebRTC) e realm do Coturn |

## 1. Instale com o instalador público

Em uma máquina limpa, não é preciso clonar o repositório:

```bash
curl -fsSL https://install.easyphone.com.br | sudo bash
```

O instalador:

- valida SO/arquitetura e instala Docker, Compose e iptables quando necessário;
- solicita usuário e PAT do GitHub com `read:packages`;
- autentica no `ghcr.io` e baixa a imagem privada `ghcr.io/nncs-easyphone/easyphone-orquestrator:main`;
- extrai os arquivos em `/opt/easyphone-orquestrator`;
- executa o `init.sh` interativo.

O PAT fica somente na máquina local, no `~/.docker/config.json` do root.

### Pré-requisito: Token GHCR

As imagens da stack estão no GitHub Container Registry (`ghcr.io/nncs-easyphone/*`). Você precisa de um **Personal Access Token (PAT)** do GitHub com escopo `read:packages`:

1. Acesse https://github.com/settings/tokens
2. Gere um token clássico com escopo `read:packages`
3. Informe usuário e token quando o instalador solicitar. A credencial é usada para baixar o bundle do orquestrador e as imagens da stack.

> Para automação sem terminal interativo:
>
> ```bash
> curl -fsSL https://install.easyphone.com.br \
>   | sudo GHCR_USER=seu-usuario GHCR_TOKEN=seu-pat bash
> ```

## 2. O que o init.sh faz

O `init.sh` é executado pelo instalador e também pode ser rodado manualmente em `/opt/easyphone-orquestrator`:

```bash
sudo bash /opt/easyphone-orquestrator/init.sh
```

O script interativamente:

| Etapa | O que faz |
|---|---|
| **0/7** | Configura o arquivo `.env` com perguntas sobre domínio, email Let's Encrypt, porta de gestão (SSH), Postgres, API, Coturn, Asterisk e Firebase |
| **0b/7** | Gera `traefik/conf/wss.yml` e `coturn/turnserver.conf` a partir dos templates `.example`, substituindo domínio e credenciais do `.env` |
| **1/7** | Instala Docker via `get.docker.com` e configura para iniciar no boot |
| **2/7** | Autentica no ghcr.io (valida o token com um pull real) |
| **3/7** | Instala iptables |
| **4/7** | Instala o `easyphone-firewall` (reaplica as regras de porta a cada boot, depois do Docker), o `easyphone-whitelist-watch` (reaplica a whitelist quando containers sobem) e o `easyphone-image-prune.timer` (limpeza diária de imagens Docker não usadas), desabilita firewalls concorrentes (`netfilter-persistent`, `ufw`) e aplica as regras (chain dedicada `EASYPHONE_INPUT`) |
| **5/7** | Instala Docker Compose e, quando `USE_BUILD=false`, pergunta se quer fazer pull das imagens |
| **6/7** | Pergunta se deseja instalar (ou reinstalar) o logo do EasyPhone no console (`/etc/issue`) e no MOTD do SSH (`/etc/update-motd.d/01-easyphone`) |

> Em instalação nova, o instalador público chama o init com
> `--skip-docker --skip-registry-login`, porque Docker e login no GHCR já foram
> feitos por ele. Em atualização, chama com `--refresh`, que mantém o `.env` e
> reaplica apenas a configuração. O `scripts/update.sh` usa o mesmo `--refresh`.

> **Importante:** Na etapa 0/7, altere `JWT_SECRET`, `DATA_SECRET_CRYPTOGRAPHY_KEY` e a senha do banco (`POSTGRES_PASSWORD`) para valores seguros — o script já sugere valores aleatórios.

> **DNS do Traefik:** na etapa 0/7 o `init.sh` pergunta os dois servidores DNS usados pelo container do Traefik (`DNS_SERVER_1`/`DNS_SERVER_2`, padrão `8.8.8.8`/`1.1.1.1`). Isso afeta apenas a resolução externa do Traefik — a resolução de nomes de serviço do Docker (embedded DNS) não muda.
>
> **AMI/ARI:** o `init.sh`/`scripts/run.sh` gera `ASTERISK_AMI_PASSWORD` automaticamente no `.env`; a mesma credencial é renderizada em `manager.conf`/`ari.conf` e usada por seed/API.
>
> **DNS challenge:** o `init.sh`/`scripts/run.sh` gera `DNS_CHALLENGE_API_KEY` automaticamente no `.env`. O compose injeta a mesma chave na API e na URL `HTTPREQ_ENDPOINT` do Traefik; não há configuração em dois lugares.

> **Porta de gestão (SSH):** na etapa 0/7 o `init.sh` pergunta a porta de gestão (padrão `22`) e grava em `SSH_PORT` no `.env`. O firewall libera **apenas** essa porta — inclusive no boot (via `easyphone-firewall.service`). O script **não** altera o `sshd`: se você escolher uma porta diferente de 22, configure antes o `/etc/ssh/sshd_config.d/` (`Port <SSH_PORT>`, valide com `sshd -t && systemctl restart ssh`) ou você perderá o acesso. O `scripts/diagnose-firewall.sh` compara a porta liberada no firewall com a que o `sshd` escuta e avisa em caso de divergência.

> **Atualização:** para atualizar uma máquina já instalada:
>
> ```bash
> sudo bash /opt/easyphone-orquestrator/scripts/update.sh
> sudo bash /opt/easyphone-orquestrator/scripts/update.sh --check
> sudo bash /opt/easyphone-orquestrator/scripts/update.sh --rollback
> ```
>
> O update compara o digest da tag `main` com `.installed-image`, preserva
> `.env`, `logs/`, `states/`, `safety/`, `whitelist.conf` e os arquivos gerados,
> e reaplica a configuração do host. O `--rollback` restaura os arquivos do
> orquestrador do backup anterior; as imagens da stack continuam na tag `main`.

### Compatibilidade com instalações antigas

O fluxo antigo continua funcionando:

```bash
git clone <URL_PRIVADA> /opt/easyphone-orquestrator
cd /opt/easyphone-orquestrator
sudo bash init.sh
sudo bash scripts/run.sh
```

Ao rodar o instalador em uma máquina já configurada, ele:

- detecta a instalação em `/opt/easyphone-orquestrator` ou `/opt/easyphone/easyphone-orquestrator` (ou no caminho de `--dir`/`EASYPHONE_DIR`);
- atualiza **no mesmo diretório**, sem mover arquivos nem parar a stack para copiar;
- preserva `.env`, `env-*.bkp`, `.git`, `logs/`, `states/`, `safety/`, `data/`, `whitelist.conf`, `wss.yml`, `turnserver.conf`, `docker-compose.override.yml` e arquivos customizados;
- sobrescreve apenas os arquivos entregues no bundle (o instalador informa quantos arquivos existentes serão sobrescritos);
- cria um backup em `.backup/<data>-<versão>/bundle-before-update.tar.gz` com permissão root-only, incluindo `.env` e configs que podem ser regeneradas;
- se `.git` existir e houver alterações em arquivos versionados, lista os arquivos e pede confirmação (ou use `--force`);
- roda `init.sh --refresh` no mesmo diretório; firewall, watcher e logo só são reaplicados se já estavam instalados (`sudo bash init.sh --refresh --assume-yes` força a instalação dos ausentes).

> Em clones antigos, `.backup/` e `.installed-image` podem aparecer como
> arquivos não versionados. Eles são criados pela atualização e não fazem parte
> do bundle.

Depois da primeira atualização via bundle, o `.git` é preservado, mas o diretório deixa de ser um checkout git limpo. A partir daí, use `scripts/update.sh`; o `git pull` continua disponível apenas para quem permanecer no fluxo antigo sem usar o instalador.

Para desfazer a última atualização:

```bash
sudo bash scripts/update.sh --rollback
```

O rollback restaura os arquivos do orquestrador e o `.env` do backup; as configs geradas (`wss.yml`, `turnserver.conf`) são recriadas a partir do `.env`. As imagens da stack continuam na tag `main`.

Se a atualização falhar antes de o novo `scripts/update.sh` ser extraído, o backup ainda pode ser restaurado manualmente:

```bash
sudo tar -C /opt/easyphone-orquestrator \
  -xzf /opt/easyphone-orquestrator/.backup/<data>-<versão>/bundle-before-update.tar.gz
```

Cada instalação exibe o log completo dentro de uma caixa `┌─ ─┐`.  
O log completo da execução fica salvo em **`logs/install-<data-hora>.log`**, na
pasta do orquestrador. Cada execução gera um arquivo novo (com timestamp),
preservando o histórico — o mesmo vale para `logs/run-<data-hora>.log`. Esses
arquivos não são versionados (ver `.gitignore`).

> Em uma instalação manual, se o Docker já estiver instalado, o script pergunta
> se deseja reinstalar. No instalador público essa etapa é pulada e o
> `systemctl enable docker` é executado **sempre** que o Docker está presente.

## 3. Suba a stack

```bash
sudo bash /opt/easyphone-orquestrator/scripts/run.sh
```

Ou, a partir de `/opt/easyphone-orquestrator`:

```bash
docker compose up -d
```

A stack inclui:

| Serviço | Portas Externas | Descrição |
|---|---|---|
| **Traefik** | `80/443` (HTTP/HTTPS) | Proxy reverso com SSL automático (Let's Encrypt) — rotas: `app.${DOMAIN}`, `api.${DOMAIN}`, `pbx.${DOMAIN}` |
| **Web** | — | Interface gráfica em `https://app.exemplo.com` |
| **API** | — | Backend REST em `https://api.exemplo.com` |
| **Postgres** | — (opcional: `7001` com `POSTGRES_BIND_ADDR=0.0.0.0`) | Banco de dados (loopback por padrão; externo apenas em testes) |
| **PgBouncer** | — | Pool de conexões (acesso interno apenas) |
| **certs-dumper** | — | Extrai o certificado de `pbx.${DOMAIN}` do `acme.json` do Traefik para o Coturn usar no TURNS |
| **Coturn** | STUN `3478/udp`, TURN `3478/tcp+udp`, TURNS `5349/tcp+udp`, relay `49152-65535/udp` | STUN/TURN para WebRTC (NAT traversal) |
| **Asterisk** | SIP `5060/udp`, SIP TLS `5061/tcp`, RTP `10000-20000/udp` | PBX (AMI `5038`, ARI `8088` e WSS `8089` são internos — só acessíveis pela bridge do Docker; a 8088 escuta por padrão só na docker0, `172.17.0.1`; `ASTERISK_HTTP_BIND_ADDR` sobrepõe, ver `.env.example`) |
| **Backup** | — | Backup para S3 (dump do Postgres, gravações e assets). Staging no volume `easyphone_backup_data:/app/backup`; estado e logs de execução em `./states` (bind mount em `/app/states`) |
| **docker-proxy** | — | Único serviço com acesso ao `docker.sock`. Expõe uma allowlist exata de GETs em socket Unix; não tem rede, porta nem escrita |
| **host-info** | — | Coleta dados do host e, a cada 10 min, envia ao Firebase a versão do orquestrador, containers e imagens. Também mantém o `host-info.json` do card "Informações do Servidor" |

## 4. Acesse

```
https://app.exemplo.com
```

## 5. WebRTC — habilitar o softphone

O softphone desktop (EasyVoice) fala SIP sobre WebSocket seguro em `wss://pbx.${DOMAIN}`. O Traefik termina o TLS e reescreve qualquer caminho para `/ws`, único URI aceito pelo Asterisk — por isso o cliente **não precisa informar caminho**.

Depois que a stack subir, dois passos na interface web. **Ambos são obrigatórios e a falha em qualquer um deles é silenciosa** (o ramal simplesmente não registra):

### 5.1 Criar o transporte PJSIP `wss`

Em **Transportes PJSIP → Novo**, crie um transporte com protocolo `wss`. A API preenche sozinha `bind=0.0.0.0:8089`, `method=tlsv1_2` e os caminhos de certificado, e grava `dialplan/ep-pjsip-transports.conf`.

Em seguida **reinicie o Asterisk** — este passo não é opcional:

```bash
docker compose restart asterisk
docker exec easyphone-asterisk asterisk -rx 'pjsip show transports'   # transport-wss deve aparecer
```

A API executa `module reload res_pjsip` após gravar o arquivo, mas o reload do PJSIP recarrega endpoints, AORs e auths e **não cria transportes** — transporte novo só entra em memória com restart. Sem isso o `[transport-wss]` existe no arquivo e no banco, mas não no Asterisk, e nenhum ramal WebRTC registra.

### 5.2 Criar o ramal com tecnologia WebRTC

Em **Ramais → Novo**, com tecnologia `web-rtc`. Três campos exigem atenção:

| Campo | Valor | Por quê |
|---|---|---|
| **Redes** | `0.0.0.0/0` (ou a faixa da bridge Docker) | Como o WSS passa pelo Traefik, o Asterisk vê sempre o IP do container do proxy (`172.x`) como origem, nunca o IP real do ramal. O ramal é criado com `deny=0.0.0.0/0.0.0.0` + `permit=<redes>`; se a faixa do proxy não estiver liberada, o REGISTER toma **403**. A autenticação continua sendo feita por digest sobre TLS. |
| **DTMF** | `info` | O softphone desktop envia DTMF via `INFO application/dtmf-relay`. |
| **Codecs** | `opus, ulaw, alaw` | `opus` é o codec nativo do WebRTC; `ulaw`/`alaw` garantem interoperabilidade com troncos e ramais tradicionais. |

### 5.3 Configurar o softphone

No EasyVoice, em Configurações: servidor `pbx.${DOMAIN}`, porta `443`, protocolo `wss`; usuário e senha do ramal; e as credenciais TURN iguais a `COTURN_USER` / `COTURN_PASS` do `.env`.

## Arquivos do orquestrador

| Arquivo | Descrição |
|---|---|
| `Dockerfile` / `.dockerignore` | Imagem privada usada apenas como transporte dos arquivos do orquestrador para `/opt/easyphone-orquestrator`; inclui `manifest.txt` com a lista de arquivos entregues |
| `docker-compose.build.yml` | Override de desenvolvimento para recompilar as imagens a partir dos repositórios irmãos; não é incluído no bundle |
| `init.sh` | Wrapper na raiz que chama `scripts/init.sh` — mantém o comando `sudo bash init.sh` |
| `update.sh` | Wrapper na raiz que chama `scripts/update.sh` |
| `install-terminal-logo.sh` | Instala/reinstala o banner do console e o MOTD do SSH em máquinas que já rodaram o `init.sh` (`--console`, `--ssh` ou `--all`) |
| `install-whitelist-watch.sh` | Instala/reinstala o watcher da whitelist em máquinas que já rodaram o `init.sh` (`--remove` desativa o serviço) |
| `install-image-prune.sh` | Instala/reinstala o timer da limpeza diária de imagens Docker em máquinas que já rodaram o `init.sh` (`--remove` desativa o serviço) |
| `scripts/init.sh` | Implementação do provisionamento (Docker, ghcr, iptables, firewall, watcher da whitelist, limpeza de imagens, compose e logo do terminal). Aceita `--refresh`, `--skip-docker` e `--skip-registry-login` |
| `scripts/run.sh` | Script para subir a stack e reaplicar a whitelist ao final, quando configurada |
| `scripts/update.sh` | Atualiza a máquina já instalada a partir da imagem `:main`, preservando `.env` e dados; aceita `--check`, `--rollback` e `--force` |
| `scripts/firewall-rules.sh` | Regras de firewall com chain dedicada `EASYPHONE_INPUT` |
| `scripts/whitelist-rules.sh` | Whitelist opcional de origens (chain `EASYPHONE_WHITELIST`), encadeada pelo `scripts/firewall-rules.sh`; aceita loopback e `ESTABLISHED,RELATED` para não derrubar respostas de conexões de saída |
| `scripts/whitelist-watch.sh` | Watcher systemd: escuta `docker events` (`start`/`restart`) dos containers `easyphone-*` e reaplica a whitelist com debounce e lock |
| `scripts/install-whitelist-watch.sh` | Implementação do instalador do `easyphone-whitelist-watch.service` |
| `scripts/docker-image-prune.sh` | Remove imagens Docker não usadas mais antigas que `DOCKER_IMAGE_PRUNE_RETENTION` (padrão: 24h); executado pelo `easyphone-image-prune.timer` ou manualmente |
| `scripts/install-image-prune.sh` | Implementação do instalador do `easyphone-image-prune.service` e do `easyphone-image-prune.timer` |
| `scripts/diagnose-firewall.sh` | Diagnóstico somente leitura de firewall, Docker e rede |
| `scripts/banner-easyphone.sh` | Instala o logo do EasyPhone no `/etc/issue` (login do console) |
| `scripts/motd-easyphone.sh` | Instala o logo e o resumo do host no `/etc/update-motd.d/01-easyphone` (login via SSH) |
| `init.sh`, `run.sh`, `update.sh`, `firewall-rules.sh`, `whitelist-rules.sh`, `diagnose-firewall.sh`, `banner-easyphone.sh`, `motd-easyphone.sh` | Wrappers na raiz que chamam a implementação correspondente em `scripts/` (mantêm os comandos antigos) |
| `systemd/easyphone-firewall.service.example` | Template do serviço que reaplica o firewall a cada boot, depois do `docker.service` — o unit final é gerado pelo `init.sh` |
| `systemd/easyphone-whitelist-watch.service.example` | Template do watcher que reaplica a whitelist em novos containers — o unit final é gerado pelo instalador |
| `systemd/easyphone-image-prune.service.example` | Template do serviço oneshot que executa a limpeza de imagens — o unit final é gerado pelo instalador |
| `systemd/easyphone-image-prune.timer.example` | Template do timer diário (03:30, com atraso aleatório) que dispara a limpeza de imagens |
| `whitelist.conf.example` | Template da lista de origens permitidas — copie para `whitelist.conf` para ativar |
| `.env` | Configuração de ambiente (copie de `.env.example`) |
| `.env.example` | Template do ambiente |
| `docker-compose.yml` | Definição dos serviços |
| `traefik/conf/wss.yml.example` | Template do proxy WSS (router `pbx.${DOMAIN}`) — o `.yml` é gerado pelo `init.sh` |
| `coturn/turnserver.conf.example` | Template do Coturn — o `.conf` é gerado pelo `init.sh` |
| `host-info/collect.mjs` | Coletor do serviço `host-info`: grava hostname, SO e redes do host (sem `docker0`/`br-*`/`veth*`) em `host-info.json` para o card "Informações do Servidor" e, a cada 10 min, envia ao Firebase o relatório de versão, containers e imagens |
| `docker-proxy/haproxy.cfg.template` | Allowlist exata do Docker: somente `GET /version`, `/containers/json`, `/containers/{id}/json` e `/images/json` |
| `VERSION` | Versão do orquestrador enviada no relatório de monitoramento |
| `.installed-image` | Digest da imagem bundle extraída (criado em tempo de execução; fora do Git) |
| `.backup/` | Backups root-only (`700`/`600`) dos arquivos e configs antes de cada atualização (fora do Git) |
| `doc/monitoramento.md` | Contrato do `system-report.json`, campos coletados e diagnóstico |

## Logo no terminal (opcional)

A etapa **6/7** do `init.sh` pergunta se deseja instalar (ou reinstalar) a
identidade visual do EasyPhone no terminal:

- **Console/TTY** — banner em `/etc/issue`, exibido antes do login local
  (Ctrl+Alt+F1). O instalador guarda o original em `/etc/issue.orig`.
- **SSH/MOTD** — logo e resumo do host em
  `/etc/update-motd.d/01-easyphone`, exibido após o login via SSH. O instalador
  também desativa as mensagens padrão do Ubuntu/Debian (`00-header`,
  `10-help-text`, `10-uname`, `50-motd-news`, `50-landscape-sysinfo`) para não
  poluir a tela.

Em máquinas que já passaram pelo `init.sh`, instale ou reinstale sem refazer o
provisionamento:

```bash
# Banner do console + MOTD do SSH
sudo bash install-terminal-logo.sh

# Apenas um dos dois
sudo bash install-terminal-logo.sh --console
sudo bash install-terminal-logo.sh --ssh
```

Os scripts também podem ser chamados diretamente:

```bash
sudo bash scripts/banner-easyphone.sh
sudo bash scripts/motd-easyphone.sh
```

Para ver o MOTD sem sair da sessão:

```bash
/etc/update-motd.d/01-easyphone
```

Para desfazer:

```bash
sudo cp /etc/issue.orig /etc/issue
sudo rm -f /etc/update-motd.d/01-easyphone
# Opcional: reativar as mensagens padrão do Ubuntu
sudo chmod +x /etc/update-motd.d/00-header \
              /etc/update-motd.d/10-help-text \
              /etc/update-motd.d/10-uname \
              /etc/update-motd.d/50-motd-news \
              /etc/update-motd.d/50-landscape-sysinfo 2>/dev/null || true
```

O banner do console só aparece em um TTY local (não em sessões SSH), e o MOTD
aparece em novos logins SSH.

## Monitoramento da instalação

O serviço `host-info` coleta os dados do host e mantém o comportamento original
do card "Informações do Servidor". A partir desta versão ele também grava
`system-report.json` no mesmo volume e, a cada **10 minutos**, envia ao Firebase:

- versão do orquestrador (`VERSION`);
- hostname, SO, kernel, CPU, memória, swap, disco e redes;
- versão do Docker Engine;
- containers do projeto `easyphone` e imagens usadas, com tag, digest e data de criação.

O envio usa apenas variáveis que já existem no `.env`: `FIREBASE_URL`,
`FIREBASE_SERVICE_ACCOUNT`, `LICENSE_CLIENT_ID` e `LICENSE_HARDWARE_ID`. Sem
elas, o coletor continua gravando os arquivos locais e não envia nada.

O `host-info` **não monta o `docker.sock`**. Ele fala com o serviço
`docker-proxy`, que é o único com o socket real. O proxy:

- não tem rede nem porta publicada (`network_mode: none`);
- expõe o socket em um volume acessível apenas ao `host-info`;
- só aceita `GET` nos endpoints `/version`, `/containers/json`,
  `/containers/{id}/json` e `/images/json`;
- retorna 403 para qualquer outro método ou endpoint (logs, export, exec,
  events, volumes, info, POST etc.).

A imagem do proxy é fixada por digest e roda com `read_only`,
`cap_drop: ALL` e `no-new-privileges`.

Para aplicar em uma instalação existente, sem reinstalar a stack:

```bash
cd /opt/easyphone-orquestrator
docker compose pull docker-proxy host-info
docker compose up -d docker-proxy host-info
```

Conferência:

```bash
docker logs -f easyphone-host-info
docker exec easyphone-host-info cat /host-info/host-info.json
docker exec easyphone-host-info cat /host-info/system-report.json
```

O contrato completo está em `doc/monitoramento.md`.

## Limpeza automática de imagens Docker

O `easyphone-image-prune.timer` executa uma vez ao dia (às `03:30`, com atraso
aleatório de até 30 minutos) o script `scripts/docker-image-prune.sh`. O timer
usa `Persistent=true`: se o host estiver desligado no horário, a execução
perdida é recuperada no próximo boot.

A limpeza remove apenas **imagens não usadas** criadas há mais de
`DOCKER_IMAGE_PRUNE_RETENTION` (padrão: `24h`):

```bash
docker image prune --all --force --filter "until=24h"
```

Ela não remove containers, volumes, redes nem cache de build. Como usa
`--all`, também remove imagens com tag que não estejam referenciadas por
nenhum container — inclusive a imagem bundle do orquestrador e imagens de
build local se a stack ficar parada além do período de retenção. A próxima
atualização ou `docker compose up` baixa/reconstrói o que for necessário.

Configuração no `.env` (lida a cada execução, sem reinstalar o timer):

```bash
DOCKER_IMAGE_PRUNE_ENABLED=true
DOCKER_IMAGE_PRUNE_RETENTION=24h
```

Comandos úteis:

```bash
# Executar a limpeza agora
sudo bash scripts/docker-image-prune.sh

# Ver o próximo agendamento
systemctl list-timers easyphone-image-prune.timer

# Acompanhar a última execução
journalctl -u easyphone-image-prune.service -f

# Instalar/reinstalar em uma máquina existente
sudo bash install-image-prune.sh

# Desativar e remover o timer (o script manual permanece)
sudo bash install-image-prune.sh --remove

# Desativar mantendo o timer instalado: DOCKER_IMAGE_PRUNE_ENABLED=false no .env
```

O `init.sh` instala o timer na etapa **4/7** (pergunta com padrão sim). O
`scripts/update.sh` chama `init.sh --refresh`, que instala/reinstala o timer
automaticamente em instalações que ainda não o tinham.

## Comandos úteis

Execute a partir de `/opt/easyphone-orquestrator`.

```bash
# Atualizar o orquestrador (imagem :main)
sudo bash scripts/update.sh

# Verificar se há uma versão nova, sem alterar nada
sudo bash scripts/update.sh --check

# Restaurar o backup anterior e subir a stack
sudo bash scripts/update.sh --rollback

# Forçar reextração do bundle (ignora alterações locais do git)
sudo bash scripts/update.sh --force

# Subir a stack (respeita o USE_BUILD do .env)
sudo bash scripts/run.sh

# Build local (dev; requer docker-compose.build.yml e os repositórios irmãos)
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build

# Parar a stack
docker compose down

# Ver logs de todos os serviços
docker compose logs -f

# Ver logs de um serviço específico
docker compose logs -f api

# Reaplicar regras de firewall
sudo bash scripts/firewall-rules.sh

# Reaplicar somente a whitelist de origens
sudo bash scripts/whitelist-rules.sh

# Reinstalar o watcher da whitelist
sudo bash install-whitelist-watch.sh

# Status e logs do watcher
systemctl status easyphone-whitelist-watch
journalctl -u easyphone-whitelist-watch -f

# Executar a limpeza de imagens Docker agora
sudo bash scripts/docker-image-prune.sh

# Status e logs da limpeza automática de imagens
systemctl list-timers easyphone-image-prune.timer
journalctl -u easyphone-image-prune.service -f

# Reinstalar o timer da limpeza de imagens
sudo bash install-image-prune.sh

# Reinstalar logo do EasyPhone no console e no SSH
sudo bash install-terminal-logo.sh

# Executar init novamente (já instalado, apenas configura)
sudo bash init.sh

# Forçar renovação do certificado SSL do Traefik
docker compose exec traefik traefik healthcheck
```

## Acesso externo ao Postgres (apenas ambiente de testes)

Por padrão o Postgres escuta apenas em `127.0.0.1:7001`. Para publicá-lo externamente, ajuste o `.env`:

```env
POSTGRES_BIND_ADDR=0.0.0.0
```

Depois recrie o container:

```bash
docker compose up -d postgres
```

O `docker compose up` já aplica o novo bind (o volume `easyphone_pgdata` é preservado).

- Com `whitelist.conf` ativo, a porta `7001` é filtrada pela mesma lista de origens (`DOCKER-USER`, chain `EASYPHONE_DB`). Rode `sudo bash scripts/firewall-rules.sh` uma vez após atualizar o repositório para instalar essa chain; depois disso, alternar a env não exige reaplicar o firewall.
- Sem `whitelist.conf`, a porta fica aberta a qualquer origem, como as demais portas públicas.

Conexão:

```bash
psql "host=<IP> port=7001 user=$POSTGRES_USER dbname=$POSTGRES_DB"
```

Para reverter:

```env
POSTGRES_BIND_ADDR=127.0.0.1
```

```bash
docker compose up -d postgres
```

> ⚠️ A liberação é exclusiva para o ambiente de testes. O Postgres não tem TLS terminado pelo host; use apenas com rede/credenciais controladas.

## Whitelist de origens (opcional)

Por padrão as portas do projeto ficam abertas a qualquer origem. Para restringir por IP, ative a whitelist:

```bash
cp whitelist.conf.example whitelist.conf
# revise a lista ANTES de aplicar
sudo bash scripts/firewall-rules.sh
```

A existência do `whitelist.conf` é o que ativa — sem ele o `scripts/whitelist-rules.sh` não faz nada. O `scripts/firewall-rules.sh` o encadeia automaticamente no boot. Além disso, o `easyphone-whitelist-watch.service` escuta os eventos `start`/`restart` dos containers `easyphone-*` e reaplica a whitelist sempre que a stack sobe. Sem `whitelist.conf`, o watcher fica ocioso e não loga.

### Reaplicação automática

O watcher usa `docker events` com debounce de ~2s e um lock em `/run/easyphone-whitelist.lock`, então um `docker compose up -d` com vários containers gera uma única reaplicação. Ele também aplica a whitelist uma vez ao iniciar e após reconexão com o Docker (restart do daemon).

Em máquinas já provisionadas:

```bash
# Instalar/reinstalar e iniciar o watcher
sudo bash install-whitelist-watch.sh

# Status e logs
systemctl status easyphone-whitelist-watch
journalctl -u easyphone-whitelist-watch -f

# Desativar o watcher (não remove as regras de iptables)
sudo bash install-whitelist-watch.sh --remove
```

O `init.sh` instala o watcher na etapa **4/7** (pergunta com padrão sim). O `scripts/run.sh` também reaplica a whitelist ao final do `docker compose up` para aplicação imediata; o watcher cobre os demais caminhos (`docker compose up` manual, `restart`, `docker start` e restarts automáticos).

> ⚠️ O watcher roda como root e aplica o `whitelist.conf` **sem** a checagem de origem do SSH feita pelo modo manual. Antes de confiar apenas nele, valide a lista com `sudo bash scripts/whitelist-rules.sh` para garantir que o seu IP de administração está incluído.

**Como funciona.** Uma chain `EASYPHONE_WHITELIST` é avaliada **antes** da `EASYPHONE_INPUT`: a primeira filtra por **origem**, a segunda por **porta**.

```
INPUT (policy DROP)
  1  ESTABLISHED,RELATED  → ACCEPT
  2  -i lo                → ACCEPT
  3  icmp echo-request    → ACCEPT
  4  -j EASYPHONE_WHITELIST   ← origem do ALLOWED faz ACCEPT; o resto vai para LOG + DROP
  5  -j EASYPHONE_INPUT       ← filtro por porta (só para quem não é do ALLOWED)

EASYPHONE_WHITELIST:
  -i lo                    → ACCEPT
  ESTABLISHED,RELATED      → ACCEPT
  -i br+                   → RETURN (containers novos seguem para EASYPHONE_INPUT)
  ALLOWED                  → ACCEPT
  LOG + DROP
```

As regras de `loopback` e `ESTABLISHED,RELATED` na própria whitelist são essenciais: respostas de conexões iniciadas pelo host (`apt`, DNS, atualizações) chegam como `ESTABLISHED`/`RELATED`. Sem elas, se a regra equivalente da `INPUT` estiver ausente ou depois do jump (instalação antiga ou snapshot restaurado), o `DROP` no fim da chain derruba a resposta e o `apt` parece “sair mas não voltar”.

**⚠️ Origem no `ALLOWED` = acesso total.** A chain faz `ACCEPT`, então esses IPs saem da INPUT ali mesmo e **não** passam pelo filtro de portas: alcançam qualquer porta do host, inclusive AMI (5038), ARI (8088) e WSS (8089). O PgBouncer fica em loopback. O Postgres fica em loopback por padrão, mas quando publicado externamente (`POSTGRES_BIND_ADDR=0.0.0.0`) a whitelist também é aplicada a ele na `DOCKER-USER` (chain `EASYPHONE_DB`). Para as origens do `ALLOWED`, a proteção do AMI passa a ser apenas a ACL do `manager.conf`.

Isso é deliberado. A `EASYPHONE_INPUT` libera um conjunto fixo de portas (a porta de gestão `SSH_PORT` — 22 por padrão —, 80, 443, 5061, 3478, 5349, UDP 5060 e as faixas de RTP/TURN) e **não** cobre SIP em TCP/5060 nem portas 50xx alternativas — com `RETURN`, um tronco já presente na whitelist continuava sendo descartado por falar numa porta fora dessa lista, uma falha silenciosa e difícil de diagnosticar. Trate o `whitelist.conf` como lista de **hosts confiáveis**, não como filtro de borda.

Para conexões novas, as bridges do Docker (`-i br+`) continuam com `RETURN`: os containers seguem restritos às portas da `EASYPHONE_INPUT`.

**O que a whitelist NÃO alcança:** as portas 80/443 do Traefik. Tráfego de container publicado não passa pela INPUT — vai por `nat/PREROUTING` → `FORWARD` → chains `DOCKER-*`. `app.`, `api.` e o desafio TLS do Let's Encrypt seguem abertos ao mundo, de propósito. A exceção é o Postgres publicado: ele também passa por `DOCKER-USER`, e o `scripts/whitelist-rules.sh` aplica a lista na chain `EASYPHONE_DB`.

**Antes de ativar, confira que a lista cobre:**

- o IP de onde você administra o servidor — o script recusa aplicar se detectar que a origem do seu SSH está fora da lista (use `--force` para ignorar);
- os IPs de sinalização **e de mídia (RTP)** das operadoras dos troncos. Se só a sinalização estiver liberada, a chamada completa e fica muda — sintoma que não aponta para o firewall;
- as redes dos ramais e dos clientes WebRTC (STUN/TURN).

```bash
# Ver a chain e o que ela está bloqueando
sudo iptables -L EASYPHONE_WHITELIST -n -v --line-numbers
# Postgres publicado (quando POSTGRES_BIND_ADDR=0.0.0.0)
sudo iptables -L EASYPHONE_DB -n -v --line-numbers
sudo journalctl -k | grep EASYPHONE-WL-DROP

# Desfazer: desative o watcher primeiro; com whitelist.conf presente ele
# reaplicaria a whitelist no próximo start de container.
sudo bash install-whitelist-watch.sh --remove
sudo bash scripts/whitelist-rules.sh --remove
```

> ⚠️ Apagar apenas o `whitelist.conf` não remove as regras atuais: o watcher fica ocioso, mas a chain existente continua até um `--remove` manual.

## Solução de problemas

### Diagnóstico rápido

Antes de mexer em qualquer regra, colete o estado do host:

```bash
sudo bash scripts/diagnose-firewall.sh > diagnostico-$(date +%F-%H%M).txt
```

O script é **somente leitura**. Ele verifica firewalls concorrentes, a integridade das chains `DOCKER-*` e `EASYPHONE_*`, a ocupação da tabela de conntrack, os bloqueios registrados no kernel e o estado do PJSIP. Se o problema for intermitente, colete também **durante** a queda e compare as duas saídas.

### `apt update`/DNS/curl saem mas não recebem resposta com whitelist ativa

Sintoma clássico: a requisição sai, mas a resposta não volta; durante o `apt update`, o contador da regra de `DROP` da whitelist sobe. A causa é a whitelist terminar em `DROP` sem aceitar `ESTABLISHED,RELATED` — ou a regra equivalente da `INPUT` estar ausente/depois do jump (instalação antiga ou snapshot restaurado).

Confira a ordem e os contadores:

```bash
sudo iptables -L INPUT -n -v --line-numbers
sudo iptables -L EASYPHONE_WHITELIST -n -v --line-numbers
sudo iptables -S EASYPHONE_WHITELIST
```

A versão atual da chain deve mostrar, antes do `DROP` (o `iptables -S` pode exibir os estados como `RELATED,ESTABLISHED`):

```
-A EASYPHONE_WHITELIST -i lo -j ACCEPT
-A EASYPHONE_WHITELIST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A EASYPHONE_WHITELIST -i br+ -j RETURN
```

Se não aparecerem, reaplique:

```bash
sudo bash scripts/whitelist-rules.sh
# ou, para reaplicar também as regras de porta:
sudo bash scripts/firewall-rules.sh
```

O `scripts/diagnose-firewall.sh` aponta automaticamente quando a whitelist está sem essas regras.

### Tudo cai (web, SIP e SSH) e só volta reiniciando o Docker

Duas causas conhecidas, nessa ordem de probabilidade:

**1. Firewall concorrente no host.** Qualquer serviço que rode `iptables -t nat -F` ou `iptables -F INPUT` apaga o DNAT do Docker — as portas publicadas só voltam com `systemctl restart docker` — e derruba os jumps das chains `EASYPHONE_*`. Verifique `ufw`, `firewalld`, `netfilter-persistent` e resíduos de guias antigos:

```bash
for u in ufw firewalld netfilter-persistent; do
  printf '%-22s enabled=%s active=%s\n' "$u" \
    "$(systemctl is-enabled "$u" 2>/dev/null)" "$(systemctl is-active "$u" 2>/dev/null)"
done
ls -l /opt/easyphone/firewall/ 2>/dev/null     # resíduo de guia antigo
journalctl -k | grep "FIREWALL DROP"           # qualquer linha confirma que um firewall antigo rodou

sudo systemctl disable --now <servico-concorrente>
sudo bash scripts/firewall-rules.sh
```

**2. Tabela de conntrack saturada.** Asterisk e Coturn rodam em `network_mode: host`; RTP (10000-20000) e o relay TURN (49152-65535) geram dezenas de milhares de fluxos UDP rastreados. Quando a tabela lota, a regra `ESTABLISHED,RELATED` — primeira da INPUT, sob policy `DROP` — deixa de casar e **toda** conexão nova cai, SSH inclusive. Reiniciar o Docker mata os containers, libera as entradas e mascara o problema.

```bash
cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max
dmesg | grep -i "conntrack.*table full"
```

Se a ocupação passar de ~80% sob carga, eleve o limite e reduza os timeouts UDP em `/etc/sysctl.d/99-easyphone-conntrack.conf`, ajustando os valores à RAM do host (cada entrada custa ~300 bytes).

### `docker compose up` falha com `iptables: No chain/target/match by that name`

```
Failed to Setup IP tables: Unable to enable ACCEPT OUTGOING rule:
iptables --wait -t filter -A DOCKER-FORWARD -i br-xxxxxxxx -j ACCEPT
```

As chains que o `dockerd` cria (`DOCKER`, `DOCKER-USER`, `DOCKER-FORWARD`, `DOCKER-ISOLATION-*`) foram apagadas do netfilter. Ele as cria **apenas na inicialização do daemon**, então nenhum `docker network create` volta a funcionar até reiniciar o Docker:

```bash
iptables -S | grep -c DOCKER     # 0 confirma o diagnóstico

cd /opt/easyphone-orquestrator
docker compose down --remove-orphans
docker network prune -f
systemctl restart docker         # ⚠ derruba containers e chamadas em curso
bash scripts/firewall-rules.sh    # recria a EASYPHONE_INPUT e o jump da INPUT
docker compose up -d
```

**Se o problema voltar após um reboot**, confira se algum mecanismo de snapshot ficou ativo (instalações antigas): o `iptables-restore` do boot flusha a tabela antes de aplicar `/etc/iptables/rules.v4` e apaga as chains do Docker. O projeto **não usa mais snapshot** — o `easyphone-firewall.service` é o único mecanismo de persistência das regras de porta, e a whitelist também é reaplicada em novos containers pelo `easyphone-whitelist-watch.service`. O `init.sh` (etapa 4/7) desabilita o `netfilter-persistent`:

```bash
systemctl is-enabled easyphone-firewall         # deve estar "enabled"
systemctl disable netfilter-persistent          # legado; o init.sh já desabilita
```

O `easyphone-firewall.service` roda depois do `docker.service` e reaplica o `scripts/firewall-rules.sh` a cada boot. A whitelist de origens também é reaplicada pelo `easyphone-whitelist-watch.service` sempre que containers `easyphone-*` sobem.

### ⚠️ Nunca rode `iptables -F` neste host

Nem `iptables -F INPUT`. A INPUT termina em DROP e carrega o jump para a `EASYPHONE_INPUT`: esvaziá-la derruba SIP, RTP e AMI na hora, porque Asterisk e Coturn rodam em `network_mode: host` e o tráfego deles chega pela INPUT. Scripts de whitelist que começam com `-F INPUT` quebram o PBX toda vez que rodam — regras extras devem ser **acrescentadas** (na `EASYPHONE_INPUT` para host networking, ou na `DOCKER-USER` para o tráfego dos containers). Para alterar o firewall, edite o `scripts/firewall-rules.sh` e rode-o de novo; ele é idempotente.

### `docker compose pull` falha com "unauthorized"

O token ghcr expirou ou não tem permissão. Rode `sudo bash scripts/update.sh` (ele solicita o PAT novamente) ou refaça o login com `docker login ghcr.io`.

### Portas não respondendo

Verifique se o firewall foi aplicado:

```bash
sudo iptables -L EASYPHONE_INPUT -n --line-numbers
```

Se a chain estiver vazia, reaplique:

```bash
sudo bash scripts/firewall-rules.sh
```

### Container Asterisk não sobe

O Asterisk e o Coturn usam `network_mode: host`. Verifique se as portas não estão ocupadas:

```bash
sudo ss -tulpn | grep -E '5060|5038|8088|3478|5349'
```

### Certificado SSL não gerado

O Traefik usa desafio DNS-01 via provider `httpreq` (a chave é gerada automaticamente e injetada na URL). Certifique-se de que:
1. O DNS de `app.exemplo.com`, `api.exemplo.com` e `pbx.exemplo.com` apontem para o IP da VM
2. A porta 443 esteja liberada no firewall da VM e no provedor de nuvem
3. O email `LETSENCRYPT_EMAIL` no `.env` esteja correto

### Ramal WebRTC não registra

Na ordem:

```bash
# 1. O proxy WSS foi gerado? (o init.sh cria a partir do .example)
cat traefik/conf/wss.yml

# 2. O certificado de pbx.${DOMAIN} foi emitido? Não pode ser "TRAEFIK DEFAULT CERT"
openssl s_client -connect pbx.exemplo.com:443 -servername pbx.exemplo.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates

# 3. O handshake WebSocket chega ao Asterisk? (101, não 404/502)
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     -H "Sec-WebSocket-Protocol: sip" https://pbx.exemplo.com/

# 4. O transporte wss existe no Asterisk?
docker exec easyphone-asterisk asterisk -rx 'pjsip show transports'

# 5. O ramal tem os atributos WebRTC?
docker exec easyphone-asterisk asterisk -rx 'pjsip show endpoint 1001' | grep -Ei 'webrtc|ice|avpf|dtls'

# 6. SIP ao vivo — 403 aqui significa ACL: veja a seção 5.2 (campo Redes)
docker exec easyphone-asterisk asterisk -rx 'pjsip set logger on'
docker logs -f easyphone-asterisk
```

Se o passo 3 falhar com 502, quase sempre é o firewall: a porta 8089 precisa estar liberada na chain `EASYPHONE_INPUT` via interface de bridge. Reaplique com `sudo bash scripts/firewall-rules.sh`.

### STUN não responde

O STUN é UDP puro na 3478 — não depende de certificado, Traefik nem Asterisk. Rode na ordem; **a primeira coisa que falhar é a causa**:

```bash
# 1. DNS: se falhar aqui, explica STUN, certificado e WSS de uma vez só
dig +short pbx.exemplo.com
curl -4 -s ifconfig.me; echo          # tem que ser o mesmo IP

# 2. O Coturn está escutando na 3478 do host?
sudo ss -ulpn | grep 3478
systemctl status coturn 2>/dev/null | head -3   # coturn do apt disputando a porta?

# 3. O que o Coturn diz ao subir?
docker logs easyphone-coturn --tail 80

# 4. A config foi montada como ARQUIVO e não como diretório?
#    Bind mount de caminho inexistente faz o Docker criar um diretório, e aí o
#    Coturn sobe com defaults — sem realm e sem credenciais.
docker exec easyphone-coturn ls -la /etc/coturn/turnserver.conf
docker exec easyphone-coturn head -20 /etc/coturn/turnserver.conf

# 5. STUN de dentro da VM (separa "problema do Coturn" de "problema de rede")
docker exec easyphone-coturn turnutils_stunclient 127.0.0.1

# 6. STUN de fora (outra máquina)
turnutils_stunclient pbx.exemplo.com

# 7. A regra de firewall existe e está contando pacotes?
sudo iptables -L EASYPHONE_INPUT -n -v --line-numbers | grep -E '3478|5349'
```

| Onde falha | Causa provável | Ação |
|---|---|---|
| 1 | DNS de `pbx` ausente ou apontando errado | Corrigir o registro A — é pré-requisito de tudo |
| 2 sem bind | Porta tomada por um coturn do sistema | `sudo systemctl disable --now coturn` |
| 4 mostra diretório | `init.sh` não foi reexecutado | `sudo bash init.sh && docker compose up -d` |
| 5 falha | Config do Coturn | Ver o erro no passo 3 |
| **5 OK, 6 falha** | **Rede** | Passo 7: regra presente com contador zerado ⇒ o bloqueio é do **provedor de nuvem**. Abrir 3478/UDP, 5349/TCP+UDP e 49152-65535/UDP no painel |
| 7 sem a regra | Firewall não reaplicado | `sudo bash scripts/firewall-rules.sh` |

O par 5/6 é o que decide entre Coturn e rede — se quiser encurtar, comece por ele.

### TURNS (5349) não conecta, mas STUN/TURN funcionam

Esperado até o certificado de `pbx.${DOMAIN}` existir. O Coturn **não** aborta sem certificado: loga `cannot start TLS and DTLS listeners` e segue servindo STUN e TURN na 3478.

```bash
docker exec easyphone-certs-dumper ls -l /certs/pbx.exemplo.com/   # certificate.pem + privatekey.pem
docker logs easyphone-coturn | grep -Ei 'realm|listener|TLS'
```

O Coturn lê o certificado **apenas no arranque**. Depois que os arquivos aparecerem, é preciso reiniciá-lo uma vez — e o mesmo vale a cada renovação do Let's Encrypt:

```bash
docker compose restart coturn
```

Se os arquivos não aparecerem, confira se `coturn/turnserver.conf` foi gerado (`sudo bash init.sh` regenera).

### Áudio só em um sentido / chamada cai após atender

Problema de mídia (ICE/RTP), não de sinalização:

```bash
# stunaddr deve apontar para o Coturn público, nunca 127.0.0.1
docker exec easyphone-asterisk grep stunaddr /etc/asterisk/rtp.conf

# TURN autenticando com as credenciais do .env
turnutils_uclient -T -u easyphone -w "$COTURN_PASS" pbx.exemplo.com
```

Verifique também se a faixa de relay `49152-65535/udp` e a faixa de RTP `10000-20000/udp` estão liberadas no firewall do provedor de nuvem (além do da VM).

## TODO

- [ ] **Migrar volumes nomeados para bind mount em `/opt/easyphone-data/`**
  Substituir volumes nomeados do Docker (`pgdata`, `traefik_data`, `coturn_certs`,
  `asterisk_config`, `asterisk_lib`, `asterisk_log`, `asterisk_monitor`,
  `backup_data`) por bind mounts em `/opt/easyphone-data/` para facilitar backups
  com `rsync`/`tar`. O estado/logs do backup já usam bind mount (`./states` em
  `/app/states`); o volume `backup_data` guarda só o staging do dump.
