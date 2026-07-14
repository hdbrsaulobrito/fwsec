# fwsec

**nftables + CrowdSec firewall manager** — interface CLI estilo CSF para gerenciar um firewall moderno em Linux.

O fwsec é distribuído e mantido como um projeto independente. Todo o código, os arquivos de configuração e o instalador necessários estão neste repositório.

> Suporta: Ubuntu 24+ · Rocky Linux 8 / 9 / 10

---

## Instalação

```bash
git clone https://github.com/HostDimeBR/fwsec.git
cd fwsec
sudo bash install.sh
```

| Flag | Comportamento |
|---|---|
| *(sem flags)* | Instala. Se já instalado, exibe status e sai. |
| `--upgrade` | Atualiza pacote + binário, preserva configs. |
| `--force` | Reinstalação completa. |

---

## Cheatsheet

### Lifecycle do firewall

```bash
fwsec -s          # Iniciar firewall
fwsec -f          # Parar firewall (flush de regras)
fwsec -r          # Reiniciar / recarregar regras
fwsec -e          # Habilitar fwsec
fwsec -x          # Desabilitar fwsec
fwsec -c          # Verificar configuração
fwsec -l          # Listar regras carregadas
fwsec -v          # Ver versão (fwsec + CrowdSec + nftables)
```

---

### Bloquear IPs (deny)

```bash
# Bloquear permanentemente
fwsec -d 1.2.3.4
fwsec -d 1.2.3.4 "Ataque SSH"
fwsec -d 192.168.0.0/24 "Rede suspeita"

# Bloquear temporariamente
fwsec -td 1.2.3.4 3600              # 1 hora
fwsec -td 1.2.3.4 86400 "Brute force"  # 24 horas
fwsec -td 1.2.3.4 300 "Scan de porta"  # 5 minutos

# Remover bloqueio permanente
fwsec -dr 1.2.3.4

# Remover bloqueio temporário
fwsec -tr 1.2.3.4

# Ver bloqueios temporários ativos
fwsec -t
```

---

### Liberar IPs (allow / whitelist)

```bash
# Adicionar à whitelist
fwsec -a 1.2.3.4
fwsec -a 1.2.3.4 "Escritório SP"
fwsec -a 10.0.0.0/8 "Rede interna"

# Remover da whitelist
fwsec -ar 1.2.3.4
```

> IPs na whitelist têm prioridade máxima — passam antes de qualquer regra de bloqueio (inclusive CrowdSec).

---

### Pesquisar IP / domínio

```bash
fwsec -g 1.2.3.4        # Busca em todas as listas + CrowdSec
fwsec -g 192.168.1.0/24 # Busca por CIDR
fwsec -g example.com    # Resolve o domínio e busca os IPs
```

Exibe onde o IP aparece: `fwsec.allow`, `fwsec.deny`, bloqueios temporários, decisões CrowdSec.

---

## Referência de comandos

| Comando | Descrição |
|---|---|
| `fwsec -v` | Ver versão |
| `fwsec -l` | Ver regras carregadas |
| `fwsec -s` | Iniciar firewall |
| `fwsec -f` | Parar firewall |
| `fwsec -x` | Desabilitar fwsec |
| `fwsec -e` | Habilitar fwsec |
| `fwsec -r` | Reiniciar / recarregar regras |
| `fwsec -c` | Verificar configuração |
| `fwsec -d IP` | Bloquear IP permanente |
| `fwsec -d IP "motivo"` | Bloquear IP com comentário |
| `fwsec -td IP segundos "motivo"` | Bloquear IP temporariamente |
| `fwsec -t` | Ver bloqueios temporários |
| `fwsec -tr IP` | Remover bloqueio temporário |
| `fwsec -dr IP` | Remover bloqueio permanente |
| `fwsec -a IP` | Adicionar IP à whitelist |
| `fwsec -a IP "motivo"` | Adicionar à whitelist com comentário |
| `fwsec -ar IP` | Remover IP da whitelist |
| `fwsec -g IP` | Pesquisar IP nas listas e regras |
| `fwsec -g domínio` | Pesquisar domínio |

---

## Arquivos de configuração

| Arquivo | Descrição |
|---|---|
| `/etc/fwsec/fwsec.conf` | Configuração principal (portas, CrowdSec, log) |
| `/etc/fwsec/fwsec.allow` | Whitelist permanente (IPs/CIDRs) |
| `/etc/fwsec/fwsec.deny` | Blacklist permanente (IPs/CIDRs) |
| `/etc/fwsec/fwsec.ignore` | IPs imunes a auto-ban |
| `/etc/fwsec/fwsec.state.json` | Estado interno (temp blocks + metadados) |
| `/var/log/fwsec.log` | Log de operações |

### fwsec.conf — principais opções

```ini
[firewall]
ENABLED    = 1           # 1 = ativo, 0 = desabilitado
TCP_IN     = 1157        # Portas TCP inbound permitidas
TCP_OUT    = 80,443,53   # Portas TCP outbound permitidas
UDP_IN     = 53          # Portas UDP inbound
UDP_OUT    = 53,123      # Portas UDP outbound
ICMP_IN    = 1           # Permitir ping
IPV6       = 1           # Suporte IPv6

[crowdsec]
ENABLED    = 1           # Integração CrowdSec
SYNC_DENY  = 1           # Sincronizar fwsec -d com decisões CrowdSec
```

---

## Arquitetura nftables

O fwsec opera com duas tabelas nftables paralelas:

```
Pacote inbound
      │
      ▼
┌─────────────────────────────────────────────┐
│  table inet fwsec / chain whitelist         │  priority -100
│  ip saddr @allow4 → ACCEPT imediato         │
└─────────────────────────────────────────────┘
      │ (não whitelist)
      ▼
┌─────────────────────────────────────────────┐
│  table inet fwsec / chain blacklist         │  priority -50
│  ip saddr @deny4  → DROP                    │
└─────────────────────────────────────────────┘
      │ (não blacklist)
      ▼
┌─────────────────────────────────────────────┐
│  table inet filter / chain input            │  priority 0
│  established/related → ACCEPT               │
│  @crowdsec-blacklists → DROP                │
│  tcp dport <SSH> → ACCEPT                   │
│  policy: DROP                               │
└─────────────────────────────────────────────┘
```

- **`@allow4` / `@allow6`** — sets gerenciados por `fwsec -a`
- **`@deny4` / `@deny6`** — sets gerenciados por `fwsec -d` e `fwsec -td` (com timeout nativo)
- **`@crowdsec-blacklists`** — sets gerenciados automaticamente pelo CrowdSec bouncer

---

## Integração CrowdSec

Quando `SYNC_DENY = 1` (padrão), `fwsec -d` e `fwsec -td` também criam decisões no CrowdSec:

```bash
fwsec -d 1.2.3.4 "Ataque SSH"
# → nftables set deny4 ← bloqueio imediato
# → cscli decisions add --ip 1.2.3.4 ← propagado ao bouncer

fwsec -td 1.2.3.4 3600 "Brute force"
# → nftables set deny4 timeout 3600s ← expira automaticamente
# → cscli decisions add --duration 3600s
```

Ver decisões ativas do CrowdSec:

```bash
cscli decisions list
cscli alerts list
cscli metrics
```

---

## Serviço systemd

```bash
systemctl status fwsec        # Status do serviço
systemctl start fwsec         # Iniciar
systemctl stop fwsec          # Parar
systemctl restart fwsec       # Reiniciar
systemctl enable fwsec        # Habilitar no boot
systemctl disable fwsec       # Desabilitar no boot
journalctl -u fwsec -f        # Ver logs em tempo real
```

---

## Exemplos práticos

```bash
# Bloquear um atacante por 24h e registrar motivo
fwsec -td 203.0.113.99 86400 "Brute force SSH detectado"

# Liberar IP do escritório permanentemente
fwsec -a 177.20.10.5 "Escritório RJ"

# Verificar se um IP está em alguma lista antes de liberar
fwsec -g 203.0.113.99

# Após investigação, bloquear permanentemente
fwsec -d 203.0.113.99 "Confirmado malicioso"

# Recarregar todas as regras após editar fwsec.allow manualmente
fwsec -r

# Ver estado completo do firewall
fwsec -c && fwsec -l
```

---

## Desenvolvimento e governança

Consulte [CONTRIBUTING.md](CONTRIBUTING.md) para preparar alterações. A branch `main` é protegida: toda mudança deve ser enviada por pull request e depende da aprovação exclusiva de `@hdbrsaulobrito`. Push direto e merge sem essa aprovação não são permitidos.

Falhas de segurança não devem ser publicadas em issues. Use o recurso **Report a vulnerability** na aba **Security** do repositório, conforme [SECURITY.md](SECURITY.md).
