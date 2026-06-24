# EasyFone Orchestrator

Provisionamento e inicialização da stack EasyFone (Postgres, PgBouncer, API, Web, Asterisk) em uma VM vazia.

## Requisitos

- **SO:** Ubuntu 22.04+ ou Debian 12+
- **Arquitetura:** x86_64
- **Mínimo:** 2 vCPU, 4 GB RAM
- **Acesso root** via `sudo`
- **Domínio ou IP público** apontado para a VM (para acessar a interface Web)

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
| **0/6** | Configura o arquivo `.env` com perguntas sobre domínio, email Let's Encrypt, Postgres, API, Asterisk e Firebase |
| **1/6** | Instala Docker via `get.docker.com` e configura para iniciar no boot |
| **2/6** | Autentica no ghcr.io (valida o token com um pull real) |
| **3/6** | Instala iptables e iptables-persistent |
| **4/6** | Aplica as regras de firewall (chain dedicada `EASYFONE_INPUT`) |
| **5/6** | Instala Docker Compose, faz pull das imagens e pergunta se quer subir a stack |

> **Importante:** Na etapa 0/6, altere `JWT_SECRET`, `DATA_SECRET_CRYPTOGRAPHY_KEY` e as senhas do banco (`POSTGRES_PASSWORD`, `ASTERISK_DB_PASS`) para valores seguros — o script já sugere valores aleatórios.

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
| **Traefik** | `80/443` (HTTP/HTTPS) | Proxy reverso com SSL automático (Let's Encrypt) |
| **Web** | — | Interface gráfica em `https://app.exemplo.com` |
| **API** | — | Backend REST em `https://api.exemplo.com` |
| **Postgres** | — | Banco de dados (acesso interno apenas) |
| **PgBouncer** | — | Pool de conexões (acesso interno apenas) |
| **Asterisk** | SIP `5060/udp`, RTP `10000-20000/udp` | PBX (AMI/ARI internos, acessados só pela API) |

## 4. Acesse

```
https://app.exemplo.com
```

## Arquivos do orquestrador

| Arquivo | Descrição |
|---|---|
| `init.sh` | Script de provisionamento (Docker, ghcr, iptables, firewall, compose) |
| `run.sh` | Script para subir a stack |
| `firewall-rules.sh` | Regras de firewall com chain dedicada `EASYFONE_INPUT` |
| `.env` | Configuração de ambiente (copie de `.env.example`) |
| `.env.example` | Template do ambiente |
| `docker-compose.yml` | Definição dos serviços |

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

O Asterisk usa `network_mode: host`. Verifique se as portas (5060, 5038, 8088, 10000-20000) não estão ocupadas:

```bash
sudo ss -tulpn | grep -E '5060|5038|8088'
```

### Certificado SSL não gerado

O Traefik usa desafio TLS (porta 443). Certifique-se de que:
1. O DNS de `app.exemplo.com` e `api.exemplo.com` aponte para o IP da VM
2. A porta 443 esteja liberada no firewall da VM e no provedor de nuvem
3. O email `LETSENCRYPT_EMAIL` no `.env` esteja correto
