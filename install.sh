#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
# fwsec installer
# Supported systems: Ubuntu 24+ | Rocky Linux 8 / 9 / 10
# =============================================================================
set -euo pipefail

FWSEC_VERSION="1.0.0"
INSTALL_DIR="/opt/fwsec"
CONFIG_DIR="/etc/fwsec"
BIN="/usr/local/bin/fwsec"
SERVICE="/etc/systemd/system/fwsec.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[91m'; GREEN='\033[92m'; YELLOW='\033[93m'; CYAN='\033[96m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { err "$*"; exit 1; }

# =============================================================================
# Initial checks
# =============================================================================
[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash install.sh"

# =============================================================================
# Detect an existing installation
# =============================================================================
check_already_installed() {
    local installed_version=""

    if command -v fwsec &>/dev/null; then
        installed_version=$(fwsec -v 2>/dev/null | grep '^fwsec' | awk '{print $2}' || true)
    fi

    if [[ -z "$installed_version" ]]; then
        return 0  # Not installed; continue
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}============================================${NC}"
    echo -e "${BOLD}${YELLOW}  fwsec is already installed!${NC}"
    echo -e "${BOLD}${YELLOW}============================================${NC}"
    echo -e "  Installed version : ${BOLD}${installed_version}${NC}"
    echo -e "  Package version   : ${BOLD}${FWSEC_VERSION}${NC}"
    echo -e "  Executable        : $(command -v fwsec)"
    echo -e "  Config           : ${CONFIG_DIR}/"
    echo ""

    if [[ "$installed_version" == "$FWSEC_VERSION" ]]; then
        echo -e "${GREEN}[OK]${NC} The installed version is current. Nothing to do."
        echo ""
        echo -e "  Force reinstallation : ${BOLD}bash install.sh --force${NC}"
        echo -e "  Upgrade             : ${BOLD}bash install.sh --upgrade${NC}"
        echo ""
        exit 0
    else
        echo -e "${YELLOW}[!]${NC} A different version is installed."
        echo ""
        echo -e "  Upgrade   : ${BOLD}bash install.sh --upgrade${NC}"
        echo -e "  Reinstall : ${BOLD}bash install.sh --force${NC}"
        echo ""
        exit 0
    fi
}

# =============================================================================
# Operating system detection
# =============================================================================
detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release was not found."
    . /etc/os-release

    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)

    case "$OS_ID" in
        ubuntu)
            [[ "$OS_MAJOR" -ge 24 ]] || die "Ubuntu ${OS_VERSION} is not supported. Minimum version: 24."
            OS_FAMILY="debian"
            ok "Detected Ubuntu ${OS_VERSION}."
            ;;
        rocky)
            [[ "$OS_MAJOR" -ge 8 ]] || die "Rocky Linux ${OS_VERSION} is not supported. Minimum version: 8."
            OS_FAMILY="rhel"
            ok "Detected Rocky Linux ${OS_VERSION}."
            ;;
        rhel|almalinux|ol)
            [[ "$OS_MAJOR" -ge 8 ]] || die "${PRETTY_NAME} is not supported. Minimum version: 8."
            OS_FAMILY="rhel"
            warn "Detected a Rocky-compatible distribution (${PRETTY_NAME}). Continuing..."
            ;;
        *)
            die "Operating system '${OS_ID}' is not supported. Use Ubuntu 24+ or Rocky Linux 8+."
            ;;
    esac
}

# =============================================================================
# Base dependency installation
# =============================================================================
install_base_deps() {
    info "Installing base dependencies..."
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
    ok "Base dependencies installed."
}

# =============================================================================
# Python 3.11+
# =============================================================================
install_python() {
    info "Checking for Python 3.11+..."

    # Find an installed Python version >= 3.11
    PYTHON=""
    for py in python3.13 python3.12 python3.11; do
        if command -v "$py" &>/dev/null; then
            PYTHON=$(command -v "$py")
            break
        fi
    done

    if [[ -n "$PYTHON" ]]; then
        PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        ok "Found Python ${PY_VER} at ${PYTHON}."
        return
    fi

    info "Python 3.11+ was not found. Installing it..."
    case "$OS_FAMILY" in
        debian)
            # Ubuntu 24 provides Python 3.12 through apt
            apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null || \
            apt-get install -y -qq python3.11 python3.11-venv 2>/dev/null || \
            die "Could not install Python 3.11+."
            ;;
        rhel)
            case "$OS_MAJOR" in
                8)
                    # Rocky 8 provides Python 3.11 through AppStream
                    dnf module reset python39 -y -q 2>/dev/null || true
                    dnf install -y -q python3.11 python3.11-pip 2>/dev/null || {
                        # Fallback: EPEL
                        dnf install -y -q epel-release 2>/dev/null || true
                        dnf install -y -q python3.11 2>/dev/null || \
                        die "Could not install Python 3.11 on Rocky Linux 8."
                    }
                    ;;
                9|10)
                    # Rocky 9/10 provide Python 3.11 through AppStream
                    dnf install -y -q python3.11 python3.11-pip 2>/dev/null || \
                    dnf install -y -q python3.12 python3.12-pip 2>/dev/null || \
                    die "Could not install Python 3.11+ on Rocky Linux ${OS_MAJOR}."
                    ;;
            esac
            ;;
    esac

    # Detect Python again after installation
    for py in python3.13 python3.12 python3.11; do
        if command -v "$py" &>/dev/null; then
            PYTHON=$(command -v "$py")
            break
        fi
    done
    [[ -n "$PYTHON" ]] || die "Python 3.11+ was not found after installation."

    PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    ok "Installed Python ${PY_VER} at ${PYTHON}."
}

# =============================================================================
# uv package and virtual environment manager
# =============================================================================
install_uv() {
    if command -v uv &>/dev/null; then
        ok "uv is already installed: $(uv --version)."
        return
    fi

    info "Installing uv..."

    # Ensure tar is available; minimal containers may omit it
    case "$OS_FAMILY" in
        debian) command -v tar &>/dev/null || apt-get install -y -qq tar ;;
        rhel)   command -v tar &>/dev/null || dnf install -y -q tar ;;
    esac

    curl -fsSL https://astral.sh/uv/install.sh | env HOME=/root sh >/dev/null 2>&1
    export PATH="/root/.local/bin:$PATH"

    command -v uv &>/dev/null || die "uv was not found after installation."
    ok "Installed uv: $(uv --version)."
}

# =============================================================================
# CrowdSec
# =============================================================================
install_crowdsec() {
    if command -v crowdsec &>/dev/null; then
        ok "CrowdSec is already installed."
    else
        info "Installing CrowdSec..."
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
        ok "CrowdSec installed."
    fi

    if command -v crowdsec-firewall-bouncer &>/dev/null || \
       [[ -f /usr/bin/crowdsec-firewall-bouncer ]]; then
        ok "The CrowdSec firewall bouncer is already installed."
    else
        info "Installing the CrowdSec nftables bouncer..."
        case "$OS_FAMILY" in
            debian) apt-get install -y -qq crowdsec-firewall-bouncer-nftables ;;
            rhel)   dnf install -y -q crowdsec-firewall-bouncer-nftables ;;
        esac
        ok "CrowdSec nftables bouncer installed."
    fi

    # Enable and start CrowdSec
    systemctl enable crowdsec --now 2>/dev/null || true

    # Configure the bouncer if it is not running
    _configure_crowdsec_bouncer
}

_configure_crowdsec_bouncer() {
    local bouncer_conf="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
    [[ -f "$bouncer_conf" ]] || { warn "Bouncer configuration was not found."; return; }

    # Generate a key only when the bouncer does not have a valid one
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
    ok "CrowdSec bouncer configured."
}

# =============================================================================
# SELinux (Rocky 8/9/10)
# =============================================================================
configure_selinux() {
    [[ "$OS_FAMILY" == "rhel" ]] || return 0
    command -v sestatus &>/dev/null || return 0
    sestatus 2>/dev/null | grep -q "enabled" || return 0

    info "Configuring SELinux for nftables and Python..."

    if ! command -v semanage &>/dev/null; then
        dnf install -y -q policycoreutils-python-utils 2>/dev/null || true
    fi

    # Detect the configured SSH port
    local ssh_port
    ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo "22")

    if [[ "$ssh_port" != "22" ]]; then
        semanage port -a -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null || true
    fi

    ok "SELinux configured."
}

# =============================================================================
# AppArmor (Ubuntu)
# =============================================================================
configure_apparmor() {
    [[ "$OS_FAMILY" == "debian" ]] || return 0
    command -v aa-status &>/dev/null || return 0
    aa-status --enabled 2>/dev/null || return 0

    info "Checking AppArmor..."
    # nftables and fwsec do not require a special profile. Check only for an
    # enforcing profile that might block Python.
    if aa-status 2>/dev/null | grep -q "python"; then
        warn "AppArmor has a Python profile. Check it for conflicts."
    else
        ok "AppArmor: no conflicting profile found."
    fi
}

# =============================================================================
# Disable competing firewalls
# =============================================================================
disable_competing_firewalls() {
    info "Checking for competing firewalls..."
    case "$OS_FAMILY" in
        rhel)
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                systemctl stop firewalld
                systemctl disable firewalld
                ok "firewalld disabled; fwsec/nftables will take control."
            else
                ok "firewalld is not active."
            fi
            ;;
        debian)
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
                ufw disable 2>/dev/null || true
                ok "UFW disabled; fwsec/nftables will take control."
            else
                ok "UFW is not active."
            fi
            ;;
    esac
}

# =============================================================================
# Install the fwsec package in a virtual environment
# =============================================================================
install_fwsec_package() {
    info "Creating a virtual environment at ${INSTALL_DIR}..."
    export PATH="/root/.local/bin:$PATH"

    rm -rf "${INSTALL_DIR}/venv"
    uv venv "${INSTALL_DIR}/venv" --python "$PYTHON" --quiet

    info "Installing fwsec ${FWSEC_VERSION}..."
    uv pip install --quiet "${SCRIPT_DIR}" \
        --python "${INSTALL_DIR}/venv/bin/python"

    ok "fwsec installed in the virtual environment."
}

# =============================================================================
# Configuration files
# =============================================================================
install_config_files() {
    info "Installing configuration files in ${CONFIG_DIR}..."
    mkdir -p "$CONFIG_DIR"

    for f in fwsec.conf fwsec.allow fwsec.deny fwsec.ignore; do
        local src="${SCRIPT_DIR}/etc/fwsec/${f}"
        local dst="${CONFIG_DIR}/${f}"
        if [[ -f "$dst" ]]; then
            ok "  ${f}: preserved (already exists)."
        elif [[ -f "$src" ]]; then
            cp "$src" "$dst"
            ok "  ${f}: installed."
        else
            warn "  ${f}: source file was not found at ${src}."
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
    info "Installing the executable at ${BIN}..."
    cat > "$BIN" << WRAPPER
#!/usr/bin/env bash
exec "${INSTALL_DIR}/venv/bin/python" -m fwsec "\$@"
WRAPPER
    chmod +x "$BIN"
    ok "Executable installed: ${BIN}."
}

# =============================================================================
# systemd service
# =============================================================================
install_service() {
    info "Installing the fwsec.service systemd unit..."
    cat > "$SERVICE" << UNIT
[Unit]
Description=fwsec - nftables + CrowdSec firewall manager
Documentation=https://github.com/hdbrsaulobrito/fwsec
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
    ok "fwsec.service installed and enabled at boot."
}

# =============================================================================
# Ensure the nftables service is enabled at boot
# =============================================================================
enable_nftables() {
    systemctl enable nftables 2>/dev/null || true
    ok "nftables enabled at boot."
}

# =============================================================================
# Post-installation check
# =============================================================================
post_install_check() {
    info "Checking the installation..."
    local issues=0

    command -v fwsec &>/dev/null          && ok "  fwsec: OK" || { err "  fwsec: NOT FOUND"; ((issues++)); }
    [[ -f "${CONFIG_DIR}/fwsec.conf" ]]   && ok "  fwsec.conf: OK" || { err "  fwsec.conf: NOT FOUND"; ((issues++)); }
    command -v nft &>/dev/null            && ok "  nft: OK" || { warn "  nft: not found"; }
    command -v crowdsec &>/dev/null       && ok "  crowdsec: OK" || { warn "  crowdsec: not found"; }
    command -v cscli &>/dev/null          && ok "  cscli: OK" || { warn "  cscli: not found"; }
    systemctl is-enabled fwsec &>/dev/null && ok "  fwsec.service: enabled" || { warn "  fwsec.service: not enabled"; }

    return $issues
}

# =============================================================================
# Main
# =============================================================================
main() {
    # Parse flags
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

    # Skip if already installed unless --force or --upgrade is set
    if [[ "$FORCE" -eq 0 && "$UPGRADE" -eq 0 ]]; then
        check_already_installed
    elif [[ "$FORCE" -eq 1 ]]; then
        warn "--force mode: reinstalling over the existing installation."
    elif [[ "$UPGRADE" -eq 1 ]]; then
        info "--upgrade mode: upgrading fwsec..."
    fi

    detect_os

    # Upgrade only the package and executable; preserve everything else
    if [[ "$UPGRADE" -eq 1 ]]; then
        install_python
        install_uv
        install_fwsec_package
        install_binary
        echo ""
        info "Reloading rules with the new version..."
        fwsec -r 2>/dev/null || true
        ok "fwsec upgraded to ${FWSEC_VERSION}."
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
    info "Starting fwsec for the first time..."
    if fwsec -s; then
        ok "fwsec started successfully."
    else
        warn "fwsec failed to start. Run it manually: fwsec -s"
    fi

    echo ""
    info "Running the post-installation check..."
    post_install_check || true

    local ssh_port
    ssh_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo "22")

    echo ""
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "${BOLD}${GREEN}  fwsec installed successfully!${NC}"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo -e "  Config dir  : ${CONFIG_DIR}/"
    echo -e "  Executable  : ${BIN}"
    echo -e "  SSH port    : ${ssh_port}"
    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "    fwsec -s              Start the firewall"
    echo -e "    fwsec -r              Reload rules"
    echo -e "    fwsec -l              List rules"
    echo -e "    fwsec -c              Validate the configuration"
    echo -e "    fwsec -d IP [reason]  Block an IP address"
    echo -e "    fwsec -a IP [reason]  Allow an IP address"
    echo -e "    fwsec -g IP           Search for an IP address"
    echo -e "    fwsec -h              Show full help"
    echo -e "${BOLD}${GREEN}============================================${NC}"
    echo ""
}

main "$@"
