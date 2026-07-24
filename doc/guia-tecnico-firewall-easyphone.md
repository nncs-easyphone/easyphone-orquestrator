# Guia Técnico - Firewall EasyPhone (iptables + systemd)

**Versão:** 1.0  
**Objetivo:** Implantar um firewall baseado em whitelist utilizando `iptables`, com inicialização automática via `systemd`.

## Índice

1. Visão geral
2. Estrutura
3. Instalação
4. Configuração do serviço systemd
5. Inicialização do serviço
6. Operação
7. Troubleshooting
8. Boas práticas
9. Histórico

---

# 1. Visão geral

Fluxo de funcionamento:

```text
Boot
 │
 ▼
systemd
 │
 ▼
easyphone-firewall.service
 │
 ▼
/opt/easyphone/firewall/firewall.sh
 │
 ├─ limpa regras INPUT
 ├─ permite loopback
 ├─ permite ESTABLISHED,RELATED
 ├─ aplica whitelist
 ├─ permite ICMP
 ├─ registra bloqueios (LOG)
 └─ bloqueia todo o restante
```

---

# 2. Estrutura

```text
/opt/easyphone/firewall/
├── firewall.sh
├── disable.sh
├── whitelist.conf   (opcional)
├── backup/
└── README.md
```

---

# 3. Instalação

## 3.1 Criar a estrutura

```bash
mkdir -p /opt/easyphone/firewall
```

---

## 3.2 Criar o firewall.sh

```bash
nano /opt/easyphone/firewall/firewall.sh
```

Conteúdo:

```bash
#!/bin/bash

# Redes/IPs autorizados
ALLOWED=(
    "127.0.0.1/32"
    "172.16.0.0/14"
    "192.168.0.0/16"
    "191.252.179.0/24"
    "45.7.56.214/32"
    "186.228.228.250/32"
)

echo "Configurando Firewall..."

# Limpa regras existentes
iptables -F INPUT

# Loopback
iptables -A INPUT -i lo -j ACCEPT

# Conexões já estabelecidas
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Redes autorizadas
for IP in "${ALLOWED[@]}"; do
    iptables -A INPUT -s "$IP" -j ACCEPT
done

# Permite ICMP (Ping)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Log de tentativas bloqueadas
iptables -A INPUT -m limit --limit 5/min \
-j LOG --log-prefix "FIREWALL DROP: "

# Bloqueia todo o restante
iptables -A INPUT -j DROP

echo
echo "Firewall carregado."

iptables -L INPUT -n --line-numbers
```

---

## 3.3 Criar o disable.sh

```bash
nano /opt/easyphone/firewall/disable.sh
```

Conteúdo:

```bash
#!/bin/bash

echo "Desabilitando Firewall..."

iptables -F
iptables -X

iptables -t nat -F
iptables -t nat -X

iptables -t mangle -F
iptables -t mangle -X

iptables -t raw -F
iptables -t raw -X

iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

echo
echo "Firewall desabilitado."

iptables -L -n
```

---

## 3.4 Dar permissão de execução

```bash
chmod +x /opt/easyphone/firewall/firewall.sh
chmod +x /opt/easyphone/firewall/disable.sh
```

---

# 4. Configuração do serviço systemd

Crie o arquivo:

```bash
nano /etc/systemd/system/easyphone-firewall.service
```

Conteúdo:

```ini
[Unit]
Description=EasyPhone Firewall
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/easyphone/firewall/firewall.sh
ExecStop=/opt/easyphone/firewall/disable.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

---

# 5. Inicialização do serviço

Atualize o systemd:

```bash
systemctl daemon-reload
```

Habilite a inicialização automática:

```bash
systemctl enable easyphone-firewall
```

Inicie o serviço:

```bash
systemctl start easyphone-firewall
```

Verifique se iniciou corretamente:

```bash
systemctl status easyphone-firewall
```

---

# 6. Operação

Aplicar o firewall:

```bash
systemctl start easyphone-firewall
```

Reaplicar regras:

```bash
systemctl restart easyphone-firewall
```

Desabilitar o firewall:

```bash
systemctl stop easyphone-firewall
```

Verificar regras carregadas:

```bash
iptables -L INPUT -n -v --line-numbers
```

Verificar status do serviço:

```bash
systemctl status easyphone-firewall
```

---

# 7. Troubleshooting

## Backup das regras

```bash
iptables-save > /root/iptables-backup.rules
```

## Restaurar regras

```bash
iptables-restore < /root/iptables-backup.rules
```

## Visualizar logs

```bash
journalctl -u easyphone-firewall
```

ou

```bash
dmesg | grep "FIREWALL DROP"
```

---

# 8. Boas práticas

- Inclua sempre o IP de administração na whitelist.
- Teste alterações mantendo uma segunda sessão SSH aberta.
- Faça backup das regras antes de qualquer alteração.
- Documente todas as mudanças na whitelist.
- Revise periodicamente os IPs autorizados.
- Após qualquer alteração, valide o acesso remoto antes de encerrar a sessão SSH.
- Mantenha os scripts em `/opt/easyphone/firewall`, facilitando futuras manutenções.

---

# 9. Histórico

| Versão | Data | Alteração |
|--------:|------------|----------------------|
| 1.0 | 2026-07-24 | Primeira versão |