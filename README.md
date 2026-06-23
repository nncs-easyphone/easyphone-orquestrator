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

## 2. Configure o ambiente

```bash
cp .env.example .env
# Edite .env com suas credenciais e configurações
nano .env
```

> **Importante:** Altere `JWT_SECRET`, `DATA_SECRET_CRYPTOGRAPHY_KEY` e as senhas do banco (`POSTGRES_PASSWORD`, `ASTERISK_DB_PASS`) para valores seguros.

### Pré-requisito: Token GHCR

As imagens da stack estão no GitHub Container Registry (`ghcr.io/nncs-easyphone/*`). Você precisa de um **Personal Access Token (PAT)** do GitHub com escopo `read:packages`:

1. Acesse https://github.com/settings/tokens
2. Gere um token clássico com escopo `read:packages`
3. Guarde o token — o `init.sh` vai pedi-lo durante a execução

## 3. Execute o init

```bash
sudo bash init.sh
```

O script interativamente:

| Etapa | O que faz |
|---|---|
| **1/5** | Instala Docker via `get.docker.com` e configura para iniciar no boot |
| **2/5** | Autentica no ghcr.io (valida o token com um pull real) |
| **3/5** | Instala iptables e iptables-persistent |
| **4/5** | Aplica as regras de firewall (chain dedicada `EASYFONE_INPUT`) |
| **5/5** | Instala Docker Compose, faz pull das imagens e pergunta se quer subir a stack |

Cada instalação exibe o log completo dentro de uma caixa `┌─ ─┐`.  
O log completo da execução fica salvo em **`/tmp/easyfone-orquestrator-install.log`**.

> Se o Docker já estiver instalado, o script pergunta se deseja reinstalar.  
> O `systemctl enable docker` é executado **sempre** que o Docker está presente.

## 4. Suba a stack

```bash
bash run.sh
```

Ou, se pulou essa etapa no `init.sh`:

```bash
docker compose up -d
```

A stack inclui:

| Serviço | Porta | Descrição |
|---|---|---|
| **Web** | `7000` | Interface gráfica |
| **API** | `7002` | Backend REST |
| **Postgres** | `7001` | Banco de dados |
| **PgBouncer** | `7003` | Pool de conexões |
| **Asterisk** | SIP `5060/udp`, AMI `5038`, ARI `8088` | PBX |

## 5. Acesse

```
http://<IP_DA_VM>:7000
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
```

## Solução de problemas

### `docker compose pull` falha com "unauthorized"

O token ghcr expirou ou não tem permissão. Reexecute o `sudo bash init.sh` e faça login novamente na etapa 2/5.

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
