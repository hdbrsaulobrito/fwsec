#!/usr/bin/env bash
# =============================================================================
# fwsec installer
# Suporta: Ubuntu 24+ | Rocky Linux 8 / 9 / 10
# =============================================================================
set -euo pipefail

FWSEC_VERSION="1.0.0"
INSTALL_DIR="/opt/fwsec"
CONFIG_DIR="/etc/fwsec"
BIN="/usr/local/bin/fwsec"
SERVICE="/etc/systemd/system/fwsec.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cores
RED='\033[91m'; GREEN='\033[92m'; YELLOW='\033[93m'; CYAN='\033[96m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { err "$*"; exit 1; }

# =============================================================================
# Verificações iniciais
# =============================================================================
[[ "$(id -u)" -eq 0 ]] || die "Execute como root: sudo bash install.sh"

# =============================================================================
# Detectar instalação existente
# =============================================================================
check_already_installed() {
    local installed_version=""

    if command -v fwsec &>/dev/null; then
        installed_version=$(fwsec -v 2>/dev/null | grep '^fwsec' | awk '{print $2}' || true)
    fi

    if [[ -z "$installed_version" ]]; then
        return 0  # não instalado, prosseguir
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}============================================${NC}"
    echo -e "${BOLD}${YELLOW}  fwsec já está instalado!${NC}"
    echo -e "${BOLD}${YELLOW}============================================${NC}"
    echo -e "  Versão instalada : ${BOLD}${installed_version}${NC}"
    echo -e "  Versão do pacote : ${BOLD}${FWSEC_VERSION}${NC}"
    echo -e "  Binário          : $(command -v fwsec)"
    echo -e "  Config           : ${CONFIG_DIR}/"
    echo ""

    if [[ "$installed_version" == "$FWSEC_VERSION" ]]; then
        echo -e "${GREEN}[OK]${NC} Mesma versão. Nada a fazer."
        echo ""
        echo -e "  Para forçar reinstalação: ${BOLD}bash install.sh --force${NC}"
        echo -e "  Para atualizar           : ${BOLD}bash install.sh --upgrade${NC}"
        echo ""
        exit 0
    else
        echo -e "${YELLOW}[!]${NC} Versão diferente detectada."
        echo ""
        echo -e "  Para atualizar  : ${BOLD}bash install.sh --upgrade${NC}"
        echo -e "  Para reinstalar : ${BOLD}bash install.sh --force${NC}"
        echo ""
        exit 0
    fi
}

# =============================================================================
# Detecção de OS
# =============================================================================
detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release não encontrado."
    . /etc/os-release

    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

    case "$OS_ID" in
        ubuntu)
            [[ "$OS_MAJOR" -ge 24 ]] || die "Ubuntu ${OS_VERSION} não suportado. Mínimo: 24."
            OS_FAMILY="debian"
            ok "Ubuntu ${OS_VERSION} detectado."
            ;;
        rocky)
            [[ "$OS_MAJOR" -ge 8 ]] || die "Rocky Linux ${OS_VERSION} não suportado. Mínimo: 8."
            OS_FAMILY="rhel"
            ok "Rocky Linux ${OS_VERSION} detectado."
            ;;
        rhel|almalinux|ol)
            [[ "$OS_MAJOR" -ge 8 ]] || die "${PRETTY_NAME} não suportado. Mínimo: 8."
            OS_FAMILY="rhel"
            warn "Distro similar a Rocky detectada (${PRETTY_NAME}). Continuando..."
            ;;
        *)
            die "Sistema operacional '${OS_ID}' não suportado. Use Ubuntu 24+ ou Rocky Linux 8+."
            ;;
    esac
}

# =============================================================================
# Instalação de dependências base
# =============================================================================
install_base_deps() {
    info "Instalando dependências base..."
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                curl tar gzip ca-certificates gnupg \
                nftables \
                python3 python3-pip \
                2>/dev/null
            ;;
        rhel)
            dnf install -y -q \
                curl tar gzip ca-certificates \
                nftables \
                2>/dev/null
            ;;
    esac
    ok "Dependências base instaladas."
}

# =============================================================================
# Python 3.11+
# =============================================================================
install_python() {
    info "Verificando Python 3.11+..."

    # Tentar encontrar Python >= 3.11 já instalado
    PYTHON=""
    for py in python3.13 python3.12 python3.11; do
        if command -v "$py" &>/dev/null; then
            PYTHON=$(command -v "$py")
            break
        fi
    done

    if [[ -n "$PYTHON" ]]; then
        PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        ok "Python ${PY_VER} encontrado em ${PYTHON}."
        return
    fi

    info "Python 3.11+ não encontrado. Instalando..."
    case "$OS_FAMILY" in
        debian)
            # Ubuntu 24 tem python3.12 no apt
            apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null || \
            apt-get install -y -qq python3.11 python3.11-venv 2>/dev/null || \
            die "Não foi possível instalar Python 3.11+."
            ;;
        rhel)
            case "$OS_MAJOR" in
                8)
                    # Rocky 8 — python3.11 via AppStream
                    dnf module reset python39 -y -q 2>/dev/null || true
                    dnf install -y -q python3.11 python3.11-pip 2>/dev/null || {
                        # Fallback: EPEL
                        dnf install -y -q epel-release 2>/dev/null || true
                        dnf install -y -q python3.11 2>/dev/null || \
                        die "Não foi possível instalar Python 3.11 no Rocky 8."
                    }
                    ;;
                9|10)
                    # Rocky 9/10 — python3.11 no AppStream
                    dnf install -y -q python3.11 python3.11-pip 2>/dev/null || \
                    dnf install -y -q python3.12 python3.12-pip 2>/dev/null || \
                    die "Não foi possível instalar Python 3.11+ no Rocky ${OS_MAJOR}."
                    ;;
            esac
            ;;
    esac

    # Re-detectar após instalação
    for py in python3.13 python3.12 python3.11; do
        if command -v "$py" &>/dev/null; then
            PYTHON=$(command -v "$py")
            break
        fi
    done
    [[ -n "$PYTHON" ]] || die "Python 3.11+ não encontrado após instalação."

    PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    ok "Python ${PY_VER} instalado em ${PYTHON}."
}

# =============================================================================
# uv (gerenciador de pacotes/venvs)
# =============================================================================
install_uv() {
    if command -v uv &>/dev/null; then
        ok "uv já instalado: $(uv --version)."
        return
    fi

    info "Instalando uv..."

    # Garantir que tar está disponível (pode faltar em containers mínimos)
    case "$OS_FAMILY" in
        debian) command -v tar &>/dev/null || apt-get install -y -qq tar ;;
        rhel)   command -v tar &>/dev/null || dnf install -y -q tar ;;
    esac

    curl -fsSL https://astral.sh/uv/install.sh | env HOME=/root sh >/dev/null 2>&1
    export PATH="/root/.local/bin:$PATH"

    command -v uv &>/dev/null || die "uv não encontrado após instalação."
    ok "uv instalado: $(uv --version)."
}

# =============================================================================
# CrowdSec
# =============================================================================
install_crowdsec() {
    if command -v crowdsec &>/dev/null; then
        ok "CrowdSec já instalado."
    else
        info "Instalando CrowdSec..."
        case "$OS_FAMILY" in
            debian)
                curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash >/dev/null 2>&1
                apt-get install -y -qq crowdsec
                ;;
            rhel)
                curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash >/dev/null 2>&1
                dnf install -y -q crowdsec
                ;;
        esac
        ok "CrowdSec instalado."
    fi

    if command -v crowdsec-firewall-bouncer &>/dev/null || \
       [[ -f /usr/bin/crowdsec-firewall-bouncer ]]; then
        ok "CrowdSec firewall bouncer já instalado."
    else
        info "Instalando CrowdSec nftables bouncer..."
        case "$OS_FAMILY" in
            debian) apt-get install -y -qq crowdsec-firewall-bouncer-nftables ;;
            rhel)   dnf install -y -q crowdsec-firewall-bouncer-nftables ;;
        esac
        ok "CrowdSec nftables bouncer instalado."
    fi

    # Habilitar e iniciar CrowdSec
    systemctl enable crowdsec --now 2>/dev/null || true

    # Configurar bouncer se não estiver rodando
    _configure_crowdsec_bouncer
}

_configure_crowdsec_bouncer() {
    local bouncer_conf="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    [[ -f "$bouncer_conf" ]] || { warn "Config do bouncer não encontrada."; return; }

    # Gerar key apenas se o bouncer ainda não tem key válida
    if grep -qE '^api_key:\s*$' "$bouncer_conf" 2>/dev/null || \
       ! grep -qE '^api_key:\s+\S+' "$bouncer_conf" 2>/dev/null; then

        if cscli bouncers list 2>/dev/null | grep -q "nftables-bouncer"; then
            cscli bouncers delete nftables-bouncer 2>/dev/null || true
        fi
        local api_key
        api_key=$(cscli bouncers add nftables-bouncer 2>&1 | \
                  grep -v '^$' | grep -v 'API key' | grep -v 'Please' | tr -d ' ')

        cat > "$bouncer_conf" << BCEOF
mode: nftables
update_frequency: 10s
log_mode: file
log_dir: /var/log/crowdsec/
log_level: info

api_url: http://127.0.0.1:8080/
api_key: ${api_key}

disable_ipv6: false
deny_action: DROP
deny_log: false

supported_decisions_types:
  - ban

nftables:
  ipv4:
    enabled: true
    set-only: true
    table: filter
    chain: input
    set: crowdsec-blacklists
  ipv6:
    enabled: true
    set-only: true
    table: filter
    chain: input
    set: crowdsec6-blacklists
BCEOF
    fi

    systemctl enable crowdsec-firewall-bouncer --now 2>/dev/null || \
    systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
    ok "CrowdSec bouncer configurado."
}

# =============================================================================
# SELinux (Rocky 8/9/10)
# =============================================================================
configure_selinux() {
    [[ "$OS_FAMILY" == "rhel" ]] || return 0
    command -v sestatus &>/dev/null || return 0
    sestatus 2>/dev/null | grep -q "enabled" || return 0

    info "Configurando SELinux para nftables + Python..."

    if ! command -v semanage &>/dev/null; then
        dnf install -y -q policycoreutils-python-utils 2>/dev/null || true
    fi

    # Detectar porta SSH configurada
    local ssh_port
    ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo "22")

    if [[ "$ssh_port" != "22" ]]; then
        semanage port -a -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null || true
    fi

    ok "SELinux configurado."
}

# =============================================================================
# AppArmor (Ubuntu)
# =============================================================================
configure_apparmor() {
    [[ "$OS_FAMILY" == "debian" ]] || return 0
    command -v aa-status &>/dev/null || return 0
    aa-status --enabled 2>/dev/null || return 0

    info "Verificando AppArmor..."
    # nftables e fwsec não requerem perfil especial; apenas garantir que
    # não há perfil em enforce que bloqueie o Python
    if aa-status 2>/dev/null | grep -q "python"; then
        warn "AppArmor tem perfil para Python. Verifique se há conflitos."
    else
        ok "AppArmor: sem perfil conflitante."
    fi
}

# =============================================================================
# Desabilitar firewalls concorrentes
# =============================================================================
disable_competing_firewalls() {
    info "Verificando firewalls concorrentes..."
    case "$OS_FAMILY" in
        rhel)
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                systemctl stop firewalld
                systemctl disable firewalld
                ok "firewalld desabilitado (fwsec/nftables assumirá o controle)."
            else
                ok "firewalld não está ativo."
            fi
            ;;
        debian)
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
                ufw disable 2>/dev/null || true
                ok "UFW desabilitado (fwsec/nftables assumirá o controle)."
            else
                ok "UFW não está ativo."
            fi
            ;;
    esac
}

# =============================================================================
# Instalar pacote fwsec no virtualenv
# =============================================================================
install_fwsec_package() {
    info "Criando virtualenv em ${INSTALL_DIR}..."
    export PATH="/root/.local/bin:$PATH"

    rm -rf "${INSTALL_DIR}/venv"
    uv venv "${INSTALL_DIR}/venv" --python "$PYTHON" --quiet

    info "Instalando fwsec ${FWSEC_VERSION}..."
    uv pip install --quiet "${SCRIPT_DIR}" \
        --python "${INSTALL_DIR}/venv/bin/python"

    ok "fwsec instalado no virtualenv."
}

# =============================================================================
# Arquivos de configuração
# =============================================================================
install_config_files() {
    info "Instalando arquivos de configuração em ${CONFIG_DIR}..."
    mkdir -p "$CONFIG_DIR"

    for f in fwsec.conf fwsec.allow fwsec.deny fwsec.ignore; do
        local src="${SCRIPT_DIR}/etc/fwsec/${f}"
        local dst="${CONFIG_DIR}/${f}"
        if [[ -f "$dst" ]]; then
            ok "  ${f}: mantido (já existe)."
        elif [[ -f "$src" ]]; then
            cp "$src" "$dst"
            ok "  ${f}: instalado."
        else
            warn "  ${f}: arquivo fonte não encontrado em ${src}."
        fi
    done

    chmod 750 "$CONFIG_DIR"
    chmod 640 "${CONFIG_DIR}"/*.conf \
              "${CONFIG_DIR}"/*.allow \
              "${CONFIG_DIR}"/*.deny \
              "${CONFIG_DIR}"/*.ignore 2>/dev/null || true
}

# =============================================================================
# Wrapper /usr/local/bin/fwsec
# =============================================================================
install_binary() {
    info "Instalando binário em ${BIN}..."
    cat > "$BIN" << WRAPPER
#!/usr/bin/env bash
exec "${INSTALL_DIR}/venv/bin/python" -m fwsec "\$@"
WRAPPER
    chmod +x "$BIN"
    ok "Binário instalado: ${BIN}."
}

# =============================================================================
# Serviço systemd
# =============================================================================
install_service() {
    info "Instalando serviço systemd fwsec.service..."
    cat > "$SERVICE" << UNIT
[Unit]
Description=fwsec - nftables + CrowdSec firewall manager
Documentation=https://github.com/HostDimeBR/fwsec
After=network.target nftables.service crowdsec.service crowdsec-firewall-bouncer.service
Wants=crowdsec.service crowdsec-firewall-bouncer.service

[Service]
Type=oneshot
ExecStart=${BIN} -s
ExecStop=${BIN} -f
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable fwsec.service
    ok "fwsec.service instalado e habilitado no boot."
}

# =============================================================================
# nftables — garantir que o serviço está habilitado no boot
# =============================================================================
enable_nftables() {
    systemctl enable nftables 2>/dev/null || true
    ok "nftables habilitado no boot."
}

# =============================================================================
# Verificação pós-instalação
# =============================================================================
post_install_check() {
    info "Verificando instalação..."
    local issues=0

    command -v fwsec &>/dev/null          && ok "  fwsec: OK" || { err "  fwsec: NÃO ENCONTRADO"; ((issues++)); }
    [[ -f "${CONFIG_DIR}/fwsec.conf" ]]   && ok "  fwsec.conf: OK" || { err "  fwsec.conf: NÃO ENCONTRADO"; ((issues++)); }
    command -v nft &>/dev/null            && ok "  nft: OK" || { warn "  nft: não encontrado"; }
    command -v crowdsec &>/dev/null       && ok "  crowdsec: OK" || { warn "  crowdsec: não encontrado"; }
    command -v cscli &>/dev/null          && ok "  cscli: OK" || { warn "  cscli: não encontrado"; }
    systemctl is-enabled fwsec &>/dev/null && ok "  fwsec.service: habilitado" || { warn "  fwsec.service: não habilitado"; }

    return $issues
}

# =============================================================================
# Main
# =============================================================================
main() {
    # Parsing de flags
    FORCE=0
    UPGRADE=0
    for arg in "$@"; do
        case "$arg" in
            --force)   FORCE=1 ;;
            --upgrade) UPGRADE=1 ;;
        esac
    done

    echo ""
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  fwsec ${FWSEC_VERSION} — Installer${NC}"
    echo -e "${BOLD}${CYAN}  nftables + CrowdSec firewall manager${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo ""

    # Skip se já instalado (a menos que --force ou --upgrade)
    if [[ "$FORCE" -eq 0 && "$UPGRADE" -eq 0 ]]; then
        check_already_installed
    elif [[ "$FORCE" -eq 1 ]]; then
        warn "Modo --force: reinstalando sobre instalação existente."
    elif [[ "$UPGRADE" -eq 1 ]]; then
        info "Modo --upgrade: atualizando fwsec..."
    fi

    detect_os

    # Upgrade: só reinstala o pacote e o binário, preserva tudo mais
    if [[ "$UPGRADE" -eq 1 ]]; then
        install_python
        install_uv
        install_fwsec_package
        install_binary
        echo ""
        info "Recarregando regras com nova versão..."
        fwsec -r 2>/dev/null || true
        ok "fwsec atualizado para ${FWSEC_VERSION}."
        fwsec -v
        echo ""
        exit 0
    fi

    install_base_deps
    install_python
    install_uv
    configure_selinux
    configure_apparmor
    disable_competing_firewalls
    install_crowdsec
    enable_nftables
    install_fwsec_package
    install_config_files
    install_binary
    install_service

    echo ""
    info "Iniciando fwsec pela primeira vez..."
    if fwsec -s; then
        ok "fwsec iniciado com sucesso."
    else
        warn "Falha ao iniciar fwsec. Execute manualmente: fwsec -s"
    fi

    echo ""
    info "Verificação pós-instalação..."
    post_install_check || true

    local ssh_port
    ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo "22")

    echo ""
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "${BOLD}${GREEN}  fwsec instalado com sucesso!${NC}"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "  Config dir  : ${CONFIG_DIR}/"
    echo -e "  Binário     : ${BIN}"
    echo -e "  Porta SSH   : ${ssh_port}"
    echo ""
    echo -e "  ${BOLD}Comandos úteis:${NC}"
    echo -e "    fwsec -s              Iniciar firewall"
    echo -e "    fwsec -r              Recarregar regras"
    echo -e "    fwsec -l              Listar regras"
    echo -e "    fwsec -c              Verificar configuração"
    echo -e "    fwsec -d IP [motivo]  Bloquear IP"
    echo -e "    fwsec -a IP [motivo]  Liberar IP"
    echo -e "    fwsec -g IP           Buscar IP nas listas"
    echo -e "    fwsec -h              Ajuda completa"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo ""
}

main "$@"
