# EasyPhone Orchestrator

Provisionamento e inicialização da stack EasyPhone (Postgres, PgBouncer, API, Web, Asterisk, Coturn) em uma VM vazia.

## Requisitos

- **SO:** Ubuntu 22.04+ ou Debian 12+
- **Arquitetura:** x86_64
- **Mínimo:** 2 vCPU, 4 GB RAM
- **Acesso root** via `sudo`
- **Domínio público** apontado para a VM. Três subdomínios precisam resolver para o IP da VM **antes** do primeiro `docker compose up` (o Traefik emite os certificados via desafio TLS-ALPN na porta 443):

| Subdomínio | Serviço |
|---|---|
| `app.${DOMAIN}` | Interface web |
| `api.${DOMAIN}` | API REST |
| `pbx.${DOMAIN}` | WebSocket SIP (WebRTC) e realm do Coturn |

## 1. Clone o repositório

```bash
git clone <URL_DO_REPOSITORIO> /opt/easyphone
cd /opt/easyphone/easyphone-orquestrator
```

## 2. Execute o init

```bash
sudo bash init.sh
```

O script interativamente:

| Etapa | O que faz |
|---|---|
| **0/6** | Configura o arquivo `.env` com perguntas sobre domínio, email Let's Encrypt, porta de gestão (SSH), Postgres, API, Coturn, Asterisk e Firebase |
| **0b/6** | Gera `traefik/conf/wss.yml` e `coturn/turnserver.conf` a partir dos templates `.example`, substituindo domínio e credenciais do `.env` |
| **1/6** | Instala Docker via `get.docker.com` e configura para iniciar no boot |
| **2/6** | Autentica no ghcr.io (valida o token com um pull real) |
| **3/6** | Instala iptables e iptables-persistent |
| **4/6** | Instala o serviço `easyphone-firewall` (reaplica o firewall a cada boot, depois do Docker) e aplica as regras (chain dedicada `EASYPHONE_INPUT`) |
| **5/6** | Instala Docker Compose, faz pull das imagens e pergunta se quer subir a stack |

> **Importante:** Na etapa 0/6, altere `JWT_SECRET`, `DATA_SECRET_CRYPTOGRAPHY_KEY` e a senha do banco (`POSTGRES_PASSWORD`) para valores seguros — o script já sugere valores aleatórios.

> **DNS do Traefik:** na etapa 0/6 o `init.sh` pergunta os dois servidores DNS usados pelo container do Traefik (`DNS_SERVER_1`/`DNS_SERVER_2`, padrão `8.8.8.8`/`1.1.1.1`). Isso afeta apenas a resolução externa do Traefik — a resolução de nomes de serviço do Docker (embedded DNS) não muda.

> **Porta de gestão (SSH):** na etapa 0/6 o `init.sh` pergunta a porta de gestão (padrão `22`) e grava em `SSH_PORT` no `.env`. O firewall libera **apenas** essa porta — inclusive no boot (via `easyphone-firewall.service`). O script **não** altera o `sshd`: se você escolher uma porta diferente de 22, configure antes o `/etc/ssh/sshd_config.d/` (`Port <SSH_PORT>`, valide com `sshd -t && systemctl restart ssh`) ou você perderá o acesso. O `diagnose-firewall.sh` compara a porta liberada no firewall com a que o `sshd` escuta e avisa em caso de divergência.

### Pré-requisito: Token GHCR

As imagens da stack estão no GitHub Container Registry (`ghcr.io/nncs-easyphone/*`). Você precisa de um **Personal Access Token (PAT)** do GitHub com escopo `read:packages`:

1. Acesse https://github.com/settings/tokens
2. Gere um token clássico com escopo `read:packages`
3. Guarde o token — o `init.sh` vai pedi-lo durante a execução

Cada instalação exibe o log completo dentro de uma caixa `┌─ ─┐`.  
O log completo da execução fica salvo em **`logs/install-<data-hora>.log`**, na
pasta do orquestrador. Cada execução gera um arquivo novo (com timestamp),
preservando o histórico — o mesmo vale para `logs/run-<data-hora>.log` e
`logs/migrate-<data-hora>.log`. Esses arquivos não são versionados (ver `.gitignore`).

> Se o Docker já estiver instalado, o script pergunta se deseja reinstalar.  
> O `systemctl enable docker` é executado **sempre** que o Docker está presente.

## 3. Suba a stack

```bash
bash run.sh
```

Ou, se pulou essa etapa no `init.sh`:

```bash
docker compose up -d
```

A stack inclui:

| Serviço | Portas Externas | Descrição |
|---|---|---|
| **Traefik** | `80/443` (HTTP/HTTPS) | Proxy reverso com SSL automático (Let's Encrypt) — rotas: `app.${DOMAIN}`, `api.${DOMAIN}`, `pbx.${DOMAIN}` |
| **Web** | — | Interface gráfica em `https://app.exemplo.com` |
| **API** | — | Backend REST em `https://api.exemplo.com` |
| **Postgres** | — | Banco de dados (acesso interno apenas) |
| **PgBouncer** | — | Pool de conexões (acesso interno apenas) |
| **certs-dumper** | — | Extrai o certificado de `pbx.${DOMAIN}` do `acme.json` do Traefik para o Coturn usar no TURNS |
| **Coturn** | STUN `3478/udp`, TURN `3478/tcp+udp`, TURNS `5349/tcp+udp`, relay `49152-65535/udp` | STUN/TURN para WebRTC (NAT traversal) |
| **Asterisk** | SIP `5060/udp`, SIP TLS `5061/tcp`, RTP `10000-20000/udp` | PBX (AMI `5038`, ARI `8088` e WSS `8089` são internos — só acessíveis pela bridge do Docker; a 8088 escuta por padrão só na docker0, `172.17.0.1`; `ASTERISK_HTTP_BIND_ADDR` sobrepõe, ver `.env.example`) |

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
| `init.sh` | Script de provisionamento (Docker, ghcr, iptables, firewall, compose) |
| `run.sh` | Script para subir a stack |
| `migrate-to-easyphone.sh` | Migra uma instalação antiga (`easyfone` → `easyphone`): volumes, role/db e firewall, alinhando a senha do Postgres ao `.env` |
| `firewall-rules.sh` | Regras de firewall com chain dedicada `EASYPHONE_INPUT` |
| `systemd/easyphone-firewall.service.example` | Template do serviço que reaplica o firewall a cada boot, depois do `docker.service` — o unit final é gerado pelo `init.sh` |
| `whitelist-rules.sh` | Whitelist opcional de origens (chain `EASYPHONE_WHITELIST`), encadeada pelo `firewall-rules.sh` |
| `whitelist.conf.example` | Template da lista de origens permitidas — copie para `whitelist.conf` para ativar |
| `.env` | Configuração de ambiente (copie de `.env.example`) |
| `.env.example` | Template do ambiente |
| `docker-compose.yml` | Definição dos serviços |
| `traefik/conf/wss.yml.example` | Template do proxy WSS (router `pbx.${DOMAIN}`) — o `.yml` é gerado pelo `init.sh` |
| `coturn/turnserver.conf.example` | Template do Coturn — o `.conf` é gerado pelo `init.sh` |

## Comandos úteis

```bash
# Subir a stack
docker compose up -d

# Parar a stack
docker compose down

# Ver logs de todos os serviços
docker compose logs -f

# Ver logs de um serviço específico
docker compose logs -f api

# Reaplicar regras de firewall
sudo bash firewall-rules.sh

# Executar init novamente (já instalado, apenas configura)
sudo bash init.sh

# Forçar renovação do certificado SSL do Traefik
docker compose exec traefik traefik healthcheck
```

## Whitelist de origens (opcional)

Por padrão as portas do projeto ficam abertas a qualquer origem. Para restringir por IP, ative a whitelist:

```bash
cp whitelist.conf.example whitelist.conf
# revise a lista ANTES de aplicar
sudo bash firewall-rules.sh
```

A existência do `whitelist.conf` é o que ativa — sem ele o `whitelist-rules.sh` não faz nada. O `firewall-rules.sh` o encadeia automaticamente, então a whitelist também é reaplicada no boot pelo `easyphone-firewall.service`.

**Como funciona.** Uma chain `EASYPHONE_WHITELIST` é avaliada **antes** da `EASYPHONE_INPUT`: a primeira filtra por **origem**, a segunda por **porta**.

```
INPUT (policy DROP)
  1  ESTABLISHED,RELATED  → ACCEPT
  2  -i lo                → ACCEPT
  3  icmp echo-request    → ACCEPT
  4  -j EASYPHONE_WHITELIST   ← origem do ALLOWED faz ACCEPT; o resto vai para LOG + DROP
  5  -j EASYPHONE_INPUT       ← filtro por porta (só para quem não é do ALLOWED)
```

**⚠️ Origem no `ALLOWED` = acesso total.** A chain faz `ACCEPT`, então esses IPs saem da INPUT ali mesmo e **não** passam pelo filtro de portas: alcançam qualquer porta do host, inclusive AMI (5038), ARI (8088), WSS (8089) e Postgres (7001). Para eles, a proteção do AMI passa a ser apenas a ACL do `manager.conf`.

Isso é deliberado. A `EASYPHONE_INPUT` libera um conjunto fixo de portas (a porta de gestão `SSH_PORT` — 22 por padrão —, 80, 443, 5061, 3478, 5349, UDP 5060 e as faixas de RTP/TURN) e **não** cobre SIP em TCP/5060 nem portas 50xx alternativas — com `RETURN`, um tronco já presente na whitelist continuava sendo descartado por falar numa porta fora dessa lista, uma falha silenciosa e difícil de diagnosticar. Trate o `whitelist.conf` como lista de **hosts confiáveis**, não como filtro de borda.

As bridges do Docker (`-i br+`) continuam com `RETURN`: os containers seguem restritos às portas da `EASYPHONE_INPUT`.

**O que a whitelist NÃO alcança:** as portas 80/443 do Traefik. Tráfego de container publicado não passa pela INPUT — vai por `nat/PREROUTING` → `FORWARD` → chains `DOCKER-*`. `app.`, `api.` e o desafio TLS do Let's Encrypt seguem abertos ao mundo, de propósito.

**Antes de ativar, confira que a lista cobre:**

- o IP de onde você administra o servidor — o script recusa aplicar se detectar que a origem do seu SSH está fora da lista (use `--force` para ignorar);
- os IPs de sinalização **e de mídia (RTP)** das operadoras dos troncos. Se só a sinalização estiver liberada, a chamada completa e fica muda — sintoma que não aponta para o firewall;
- as redes dos ramais e dos clientes WebRTC (STUN/TURN).

```bash
# Ver a chain e o que ela está bloqueando
sudo iptables -L EASYPHONE_WHITELIST -n -v --line-numbers
sudo journalctl -k | grep EASYPHONE-WL-DROP

# Desfazer
sudo bash whitelist-rules.sh --remove
```

## Solução de problemas

### Diagnóstico rápido

Antes de mexer em qualquer regra, colete o estado do host:

```bash
sudo bash diagnose-firewall.sh > diagnostico-$(date +%F-%H%M).txt
```

O script é **somente leitura**. Ele verifica firewalls concorrentes, a integridade das chains `DOCKER-*` e `EASYPHONE_*`, a ocupação da tabela de conntrack, os bloqueios registrados no kernel e o estado do PJSIP. Se o problema for intermitente, colete também **durante** a queda e compare as duas saídas.

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
sudo bash firewall-rules.sh
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
bash firewall-rules.sh           # recria a EASYPHONE_INPUT e o jump da INPUT
docker compose up -d
```

**Se o problema voltar após um reboot**, a causa é a persistência por snapshot: o `iptables-restore` do boot flusha a tabela antes de aplicar `/etc/iptables/rules.v4`, e um snapshot gravado sem as chains do Docker as apaga. Verifique e corrija:

```bash
grep -c DOCKER /etc/iptables/rules.v4          # 0 = snapshot incompleto
systemctl is-enabled easyphone-firewall         # deve estar "enabled"
systemctl disable netfilter-persistent         # o unit acima substitui a função
```

O `easyphone-firewall.service` (instalado na etapa 4/6 do `init.sh`) roda depois do `docker.service` e reaplica o `firewall-rules.sh` a cada boot, dispensando o snapshot.

### ⚠️ Nunca rode `iptables -F` neste host

Nem `iptables -F INPUT`. A INPUT termina em DROP e carrega o jump para a `EASYPHONE_INPUT`: esvaziá-la derruba SIP, RTP e AMI na hora, porque Asterisk e Coturn rodam em `network_mode: host` e o tráfego deles chega pela INPUT. Scripts de whitelist que começam com `-F INPUT` quebram o PBX toda vez que rodam — regras extras devem ser **acrescentadas** (na `EASYPHONE_INPUT` para host networking, ou na `DOCKER-USER` para o tráfego dos containers). Para alterar o firewall, edite o `firewall-rules.sh` e rode-o de novo; ele é idempotente.

### `docker compose pull` falha com "unauthorized"

O token ghcr expirou ou não tem permissão. Reexecute o `sudo bash init.sh` e faça login novamente na etapa 2/6.

### Portas não respondendo

Verifique se o firewall foi aplicado:

```bash
sudo iptables -L EASYPHONE_INPUT -n --line-numbers
```

Se a chain estiver vazia, reaplique:

```bash
sudo bash firewall-rules.sh
```

### Container Asterisk não sobe

O Asterisk e o Coturn usam `network_mode: host`. Verifique se as portas não estão ocupadas:

```bash
sudo ss -tulpn | grep -E '5060|5038|8088|3478|5349'
```

### Certificado SSL não gerado

O Traefik usa desafio TLS (porta 443). Certifique-se de que:
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

Se o passo 3 falhar com 502, quase sempre é o firewall: a porta 8089 precisa estar liberada na chain `EASYPHONE_INPUT` via interface de bridge. Reaplique com `sudo bash firewall-rules.sh`.

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
| 7 sem a regra | Firewall não reaplicado | `sudo bash firewall-rules.sh` |

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

## Migração de instalação antiga (`easyfone` → `easyphone`)

Em uma instalação criada pelo orquestrador antigo, rode **depois do `git pull`** e
**antes** de subir a stack:

```bash
sudo bash migrate-to-easyphone.sh --dry-run   # confere o plano (nada é alterado)
sudo bash migrate-to-easyphone.sh             # executa a migração
./run.sh                                       # sobe a stack
sudo bash migrate-to-easyphone.sh --cleanup    # remove o resíduo antigo (após validar)
```

O script detecta o projeto/volumes reais pelo Docker, copia os volumes para os
nomes-alvo, renomeia banco/role e **alinha a senha da role ao `POSTGRES_PASSWORD`
do `.env`** — regenerando-a em hex automaticamente se tiver caracteres que quebram
ODBC/URL (ex.: `+`) — e valida o login TCP antes de encerrar.

Segurança de dados: nunca usa `down -v`/`volume prune`; faz backup (`.env` +
`pg_dump` + snapshot dos volumes) **antes** de qualquer mutação; não sobrescreve
volumes com dados; exige `PG_VERSION` no volume (nunca inicializa banco vazio);
aborta se o volume estiver em uso ou sem espaço; e nada antigo é apagado antes do
sucesso (`--cleanup` explícito, pede digitar `APAGAR`).

Tudo (log, estado e backups) fica em `logs/`: `logs/migrate.state`,
`logs/backups/<RUN_ID>/` e `logs/migrate-<data>.log`.

O script é **idempotente e retomável**: se for interrompido, basta rodar de novo —
ele detecta o estado (inclusive o deixado pelo script antigo) e continua de onde
parou. Para recomeçar do zero use `--restart`. Flags: `--dry-run`, `--yes`,
`--restart`, `--resume`, `--skip-volume-backup`, `--password <valor>`,
`--keep-db-password`, `--skip-db`, `--skip-firewall`, `--cleanup`, `--force`,
`--old-project <nome>`.

## TODO

- [ ] **Migrar volumes nomeados para bind mount em `/opt/easyphone-data/`**
  Substituir volumes nomeados do Docker (`pgdata`, `traefik_data`, `coturn_certs`,
  `asterisk_config`, `asterisk_lib`, `asterisk_log`, `asterisk_monitor`) por bind
  mounts em `/opt/easyphone-data/` para facilitar backups com `rsync`/`tar`.
