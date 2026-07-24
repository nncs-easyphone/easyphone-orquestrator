# EasyFone Orchestrator

Provisionamento e inicialização da stack EasyFone (Postgres, PgBouncer, API, Web, Asterisk, Coturn) em uma VM vazia.

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
git clone <URL_DO_REPOSITORIO> /opt/easyfone
cd /opt/easyfone/easyphone-orquestrator
```

## 2. Execute o init

```bash
sudo bash init.sh
```

O script interativamente:

| Etapa | O que faz |
|---|---|
| **0/6** | Configura o arquivo `.env` com perguntas sobre domínio, email Let's Encrypt, Postgres, API, Coturn, Asterisk e Firebase |
| **0b/6** | Gera `traefik/conf/wss.yml` e `coturn/turnserver.conf` a partir dos templates `.example`, substituindo domínio e credenciais do `.env` |
| **1/6** | Instala Docker via `get.docker.com` e configura para iniciar no boot |
| **2/6** | Autentica no ghcr.io (valida o token com um pull real) |
| **3/6** | Instala iptables e iptables-persistent |
| **4/6** | Aplica as regras de firewall (chain dedicada `EASYFONE_INPUT`) |
| **5/6** | Instala Docker Compose, faz pull das imagens e pergunta se quer subir a stack |

> **Importante:** Na etapa 0/6, altere `JWT_SECRET`, `DATA_SECRET_CRYPTOGRAPHY_KEY` e a senha do banco (`POSTGRES_PASSWORD`) para valores seguros — o script já sugere valores aleatórios.

### Pré-requisito: Token GHCR

As imagens da stack estão no GitHub Container Registry (`ghcr.io/nncs-easyphone/*`). Você precisa de um **Personal Access Token (PAT)** do GitHub com escopo `read:packages`:

1. Acesse https://github.com/settings/tokens
2. Gere um token clássico com escopo `read:packages`
3. Guarde o token — o `init.sh` vai pedi-lo durante a execução

Cada instalação exibe o log completo dentro de uma caixa `┌─ ─┐`.  
O log completo da execução fica salvo em **`/tmp/easyfone-orquestrator-install.log`**.

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
| **Asterisk** | SIP `5060/udp`, SIP TLS `5061/tcp`, RTP `10000-20000/udp` | PBX (AMI `5038`, ARI `8088` e WSS `8089` são internos — só acessíveis pela bridge do Docker) |

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
docker exec easyfone-asterisk asterisk -rx 'pjsip show transports'   # transport-wss deve aparecer
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
| `firewall-rules.sh` | Regras de firewall com chain dedicada `EASYFONE_INPUT` |
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

## Solução de problemas

### `docker compose pull` falha com "unauthorized"

O token ghcr expirou ou não tem permissão. Reexecute o `sudo bash init.sh` e faça login novamente na etapa 2/6.

### Portas não respondendo

Verifique se o firewall foi aplicado:

```bash
sudo iptables -L EASYFONE_INPUT -n --line-numbers
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
docker exec easyfone-asterisk asterisk -rx 'pjsip show transports'

# 5. O ramal tem os atributos WebRTC?
docker exec easyfone-asterisk asterisk -rx 'pjsip show endpoint 1001' | grep -Ei 'webrtc|ice|avpf|dtls'

# 6. SIP ao vivo — 403 aqui significa ACL: veja a seção 5.2 (campo Redes)
docker exec easyfone-asterisk asterisk -rx 'pjsip set logger on'
docker logs -f easyfone-asterisk
```

Se o passo 3 falhar com 502, quase sempre é o firewall: a porta 8089 precisa estar liberada na chain `EASYFONE_INPUT` via interface de bridge. Reaplique com `sudo bash firewall-rules.sh`.

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
docker logs easyfone-coturn --tail 80

# 4. A config foi montada como ARQUIVO e não como diretório?
#    Bind mount de caminho inexistente faz o Docker criar um diretório, e aí o
#    Coturn sobe com defaults — sem realm e sem credenciais.
docker exec easyfone-coturn ls -la /etc/coturn/turnserver.conf
docker exec easyfone-coturn head -20 /etc/coturn/turnserver.conf

# 5. STUN de dentro da VM (separa "problema do Coturn" de "problema de rede")
docker exec easyfone-coturn turnutils_stunclient 127.0.0.1

# 6. STUN de fora (outra máquina)
turnutils_stunclient pbx.exemplo.com

# 7. A regra de firewall existe e está contando pacotes?
sudo iptables -L EASYFONE_INPUT -n -v --line-numbers | grep -E '3478|5349'
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
docker exec easyfone-certs-dumper ls -l /certs/pbx.exemplo.com/   # certificate.pem + privatekey.pem
docker logs easyfone-coturn | grep -Ei 'realm|listener|TLS'
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
docker exec easyfone-asterisk grep stunaddr /etc/asterisk/rtp.conf

# TURN autenticando com as credenciais do .env
turnutils_uclient -T -u easyphone -w "$COTURN_PASS" pbx.exemplo.com
```

Verifique também se a faixa de relay `49152-65535/udp` e a faixa de RTP `10000-20000/udp` estão liberadas no firewall do provedor de nuvem (além do da VM).

## TODO

- [ ] **Migrar volumes nomeados para bind mount em `/opt/easyphone-data/`**
  Substituir volumes nomeados do Docker (`pgdata`, `traefik_data`, `coturn_certs`,
  `asterisk_config`, `asterisk_lib`, `asterisk_log`, `asterisk_monitor`) por bind
  mounts em `/opt/easyphone-data/` para facilitar backups com `rsync`/`tar`.
