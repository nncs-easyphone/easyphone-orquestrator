
# Arquitetura para HTTPS On-Premise

## Objetivo

Permitir que uma instalação **on-premise do EasyPhone** utilize HTTPS com um certificado válido emitido pelo Let's Encrypt, sem exigir que as credenciais da AWS ou do Route 53 sejam disponibilizadas no ambiente do cliente.

A solução utiliza o **Traefik + Lego + HTTPREQ**, mantendo o gerenciamento do certificado dentro do Traefik.

### Arquitetura geral

```text
┌──────────────────────────────┐
│       Servidor do Cliente    │
│                              │
│  ┌────────────┐              │
│  │   Traefik  │              │
│  │            │              │
│  │    Lego    │              │
│  │     │      │              │
│  │  HTTPREQ   │              │
│  └─────┬──────┘              │
└────────┼─────────────────────┘
         │ HTTPS
         │
         ▼
┌──────────────────────────────┐
│        Firebase              │
│                              │
│  /acme/dns/present            │
│  /acme/dns/cleanup            │
│                              │
│  • autenticação               │
│  • autorização                │
│  • validação do domínio       │
└──────────────┬───────────────┘
               │
               │ AWS SDK
               ▼
┌──────────────────────────────┐
│          AWS Route 53        │
│                              │
│  TXT _acme-challenge...      │
└──────────────┬───────────────┘
               │
               ▼
       Let's Encrypt
```

---

# 1. Cadastro do domínio

Para cada empresa, será criado um subdomínio específico dentro do domínio EasyPhone.

Exemplo:

```text
xxx.empresa.easyphone.com.br
```

Esse domínio deverá ser cadastrado no servidor DNS utilizado pela empresa.

O DNS interno deverá resolver:

```text
xxx.empresa.easyphone.com.br
        │
        ▼
IP interno do servidor EasyPhone
```

Por exemplo:

```text
xxx.empresa.easyphone.com.br
        ↓
192.168.1.100
```

Dessa forma, o domínio é utilizado internamente pelo navegador, mas continua sendo um domínio pertencente à infraestrutura EasyPhone.

### Importante

O certificado será emitido para:

```text
xxx.empresa.easyphone.com.br
```

O fato de o domínio apontar para um IP privado **não impede o uso do certificado Let's Encrypt**.

A validação do domínio será realizada através do desafio **DNS-01**, e não através de uma conexão HTTP pública com o servidor.

---

# 2. Endpoints ACME no Firebase

O servidor on-premise não terá acesso direto às credenciais AWS.

Em vez disso, serão disponibilizados dois endpoints no backend EasyPhone:

```http
POST /acme/dns/present
POST /acme/dns/cleanup
```

Esses endpoints serão utilizados pelo provider `httpreq` do Lego.

### `present`

Responsável por criar o registro TXT necessário para o desafio DNS-01.

Fluxo:

```text
Traefik
   │
   │ POST /acme/dns/present
   ▼
Firebase
   │
   │ valida requisição
   ▼
Route 53
   │
   │ cria TXT
   ▼
_acme-challenge.xxx.empresa.easyphone.com.br
```

### `cleanup`

Após a validação do certificado, o Lego solicita a remoção do registro temporário.

```text
Traefik
   │
   │ POST /acme/dns/cleanup
   ▼
Firebase
   │
   │ valida requisição
   ▼
Route 53
   │
   │ remove TXT
   ▼
_acme-challenge.xxx.empresa.easyphone.com.br
```

---

# 3. Configuração do Traefik

O Traefik continuará utilizando o ACME normalmente.

A diferença será o provider DNS utilizado pelo Lego.

```yaml
certificatesResolvers:
  easyphone:
    acme:
      email: admin@empresa.com.br
      storage: /data/acme.json

      dnsChallenge:
        provider: httpreq
```

O `httpreq` fará a comunicação com os endpoints disponibilizados pelo EasyPhone.

Conceitualmente:

```text
Traefik
   │
   ▼
Lego
   │
   ▼
HTTPREQ
   │
   │ HTTPS
   ▼
Firebase
```

Assim, **não será necessário criar um provider customizado do Lego**.

---

# 4. Autenticação da requisição

As requisições recebidas pelo Firebase deverão ser autenticadas.

O objetivo é impedir que terceiros utilizem a API EasyPhone para criar registros DNS arbitrários no Route 53.

Fluxo:

```text
Traefik
   │
   │ credencial EasyPhone
   ▼
Firebase
   │
   ├── autenticar cliente
   │
   ├── validar credencial
   │
   ├── identificar empresa
   │
   └── validar domínio
   │
   ▼
Route 53
```

A credencial utilizada pelo Traefik deve permitir somente as operações necessárias para o ACME.

O servidor on-premise **não deverá possuir credenciais AWS**.

---

# 5. Acesso ao AWS Route 53

O Firebase será responsável por realizar as operações no Route 53 utilizando as SDKs oficiais da AWS.

```text
Firebase
    │
    │ AWS SDK
    ▼
AWS Route 53
```

As credenciais AWS permanecem exclusivamente no ambiente controlado pela EasyPhone.

Isso cria uma separação importante:

| Componente    | Responsabilidade                       |
| ------------- | -------------------------------------- |
| Traefik       | Gerenciar HTTPS e ACME                 |
| Lego          | Executar o DNS-01                      |
| HTTPREQ       | Encaminhar operações DNS para a API    |
| Firebase      | Autenticar e autorizar requisições     |
| AWS SDK       | Comunicação com AWS                    |
| Route 53      | Criar/remover registros DNS            |
| Let's Encrypt | Validar o domínio e emitir certificado |

---

# 6. Encaminhamento do registro para o Route 53

Quando o Lego solicitar a criação do challenge, a API receberá as informações necessárias para criar o registro TXT.

Exemplo conceitual:

```json
{
  "fqdn": "_acme-challenge.xxx.empresa.easyphone.com.br",
  "value": "..."
}
```

O Firebase identifica a zona DNS correspondente e utiliza o AWS SDK para criar o registro no Route 53.

```text
_acme-challenge.xxx.empresa.easyphone.com.br
                         │
                         ▼
                    Route 53
                         │
                         ▼
                    Registro TXT
```

O Let's Encrypt então consulta o DNS público e encontra o valor esperado.

---

# 7. Fluxo completo da emissão

O processo completo será:

```text
                 1. HTTPS solicitado
                        │
                        ▼
                  ┌───────────┐
                  │  Traefik  │
                  └─────┬─────┘
                        │
                        ▼
                     Lego
                        │
                        │ DNS-01
                        ▼
                    HTTPREQ
                        │
                        │ HTTPS
                        ▼
               ┌─────────────────┐
               │    Firebase     │
               │                 │
               │ Authenticate    │
               │ Authorize       │
               └────────┬────────┘
                        │
                        │ AWS SDK
                        ▼
                 ┌─────────────┐
                 │   Route 53  │
                 └──────┬──────┘
                        │
                        │ TXT
                        ▼
             _acme-challenge.xxx...
                        │
                        ▼
                 Let's Encrypt
                        │
                        │ valida
                        ▼
                 Certificado
                        │
                        ▼
                    Traefik
                        │
                        ▼
                     HTTPS
```

---

# 8. Renovação automática

Uma das principais vantagens dessa arquitetura é que **não é necessário repetir o processo manualmente**.

O Traefik continuará responsável pela renovação do certificado.

Quando chegar o momento de renovar:

```text
Traefik
   ↓
Lego
   ↓
HTTPREQ
   ↓
Firebase
   ↓
Route 53
   ↓
Let's Encrypt
   ↓
novo certificado
   ↓
Traefik
```

Portanto, depois da instalação inicial, o processo deverá ser automático.

---

# 9. Segurança

A arquitetura foi escolhida principalmente para evitar a distribuição de credenciais AWS para os clientes.

### Não fazer

```text
Servidor do cliente
    │
    ├── AWS_ACCESS_KEY_ID
    └── AWS_SECRET_ACCESS_KEY
```

### Fazer

```text
Servidor do cliente
    │
    └── credencial EasyPhone
             │
             ▼
        Firebase
             │
             ▼
        AWS Route 53
```

Isso permite que a EasyPhone mantenha o controle sobre:

* quais clientes podem utilizar o serviço;
* quais domínios cada cliente pode modificar;
* quais registros podem ser criados;
* revogação de acesso;
* auditoria das operações;
* credenciais AWS.

---

# 10. Decisão arquitetural

A solução escolhida será baseada em:

> **Traefik + Lego + HTTPREQ + Firebase + AWS Route 53**

em vez de desenvolver um provider customizado do Lego.

A configuração do cliente permanece simples:

```yaml
dnsChallenge:
  provider: httpreq
```

Enquanto a complexidade de segurança e integração com a AWS fica concentrada na infraestrutura EasyPhone.

### Resultado

O servidor do cliente precisa conhecer apenas:

```text
Domínio:
xxx.empresa.easyphone.com.br

Endpoint:
https://<api-easyphone>/acme/dns

Credencial:
<credencial-do-cliente>
```

E **não precisa conhecer ou armazenar nenhuma credencial AWS**.
