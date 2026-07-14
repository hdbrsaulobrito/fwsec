# fwsec

**nftables + CrowdSec firewall manager** — a CSF-style command-line interface for managing a modern Linux firewall.

fwsec is distributed and maintained as an independent project. This repository contains all source code, configuration templates, and installation resources required to use it.

> Supported systems: Ubuntu 24+ · Rocky Linux 8 / 9 / 10

## Installation

```bash
git clone https://github.com/hdbrsaulobrito/fwsec.git
cd fwsec
sudo bash install.sh
```

| Flag | Behavior |
|---|---|
| *(no flags)* | Installs fwsec. If it is already installed, displays its status and exits. |
| `--upgrade` | Upgrades the package and executable while preserving configuration files. |
| `--force` | Performs a complete reinstallation. |

## Quick reference

### Firewall lifecycle

```bash
fwsec -s          # Start the firewall
fwsec -f          # Stop the firewall and flush its rules
fwsec -r          # Restart or reload the rules
fwsec -e          # Enable fwsec
fwsec -x          # Disable fwsec
fwsec -c          # Validate the configuration
fwsec -l          # List loaded rules
fwsec -v          # Show fwsec, CrowdSec, and nftables versions
```

### Deny IP addresses

```bash
# Block permanently
fwsec -d 1.2.3.4
fwsec -d 1.2.3.4 "SSH attack"
fwsec -d 192.168.0.0/24 "Suspicious network"

# Block temporarily
fwsec -td 1.2.3.4 3600                  # 1 hour
fwsec -td 1.2.3.4 86400 "Brute force"  # 24 hours
fwsec -td 1.2.3.4 300 "Port scan"      # 5 minutes

# Remove a permanent block
fwsec -dr 1.2.3.4

# Remove a temporary block
fwsec -tr 1.2.3.4

# Show active temporary blocks
fwsec -t
```

### Allow IP addresses

```bash
# Add to the allow list
fwsec -a 1.2.3.4
fwsec -a 1.2.3.4 "São Paulo office"
fwsec -a 10.0.0.0/8 "Internal network"

# Remove from the allow list
fwsec -ar 1.2.3.4
```

> Allow-listed IP addresses have the highest priority and are accepted before every blocking rule, including CrowdSec rules.

### Search for an IP address or domain

```bash
fwsec -g 1.2.3.4         # Search every list and CrowdSec
fwsec -g 192.168.1.0/24  # Search for a CIDR range
fwsec -g example.com     # Resolve the domain and search for its IP addresses
```

The result identifies whether the address appears in `fwsec.allow`, `fwsec.deny`, temporary blocks, or CrowdSec decisions.

## Command reference

| Command | Description |
|---|---|
| `fwsec -v` | Show version information |
| `fwsec -l` | Show loaded rules |
| `fwsec -s` | Start the firewall |
| `fwsec -f` | Stop the firewall |
| `fwsec -x` | Disable fwsec |
| `fwsec -e` | Enable fwsec |
| `fwsec -r` | Restart or reload the rules |
| `fwsec -c` | Validate the configuration |
| `fwsec -d IP` | Block an IP address permanently |
| `fwsec -d IP "reason"` | Block an IP address with a comment |
| `fwsec -td IP seconds "reason"` | Block an IP address temporarily |
| `fwsec -t` | Show temporary blocks |
| `fwsec -tr IP` | Remove a temporary block |
| `fwsec -dr IP` | Remove a permanent block |
| `fwsec -a IP` | Add an IP address to the allow list |
| `fwsec -a IP "reason"` | Add an IP address to the allow list with a comment |
| `fwsec -ar IP` | Remove an IP address from the allow list |
| `fwsec -g IP` | Search for an IP address in lists and rules |
| `fwsec -g domain` | Search for a domain |

## Configuration files

| File | Description |
|---|---|
| `/etc/fwsec/fwsec.conf` | Main configuration: ports, CrowdSec, and logging |
| `/etc/fwsec/fwsec.allow` | Permanent allow list containing IP addresses and CIDR ranges |
| `/etc/fwsec/fwsec.deny` | Permanent deny list containing IP addresses and CIDR ranges |
| `/etc/fwsec/fwsec.ignore` | IP addresses exempt from automatic bans |
| `/etc/fwsec/fwsec.state.json` | Internal state for temporary blocks and metadata |
| `/var/log/fwsec.log` | Operation log |

### Main `fwsec.conf` options

```ini
[firewall]
ENABLED    = 1           # 1 = enabled, 0 = disabled
TCP_IN     = 1157        # Allowed inbound TCP ports
TCP_OUT    = 80,443,53   # Allowed outbound TCP ports
UDP_IN     = 53          # Allowed inbound UDP ports
UDP_OUT    = 53,123      # Allowed outbound UDP ports
ICMP_IN    = 1           # Allow inbound ping
IPV6       = 1           # Enable IPv6 support

[crowdsec]
ENABLED    = 1           # Enable CrowdSec integration
SYNC_DENY  = 1           # Synchronize fwsec -d bans with CrowdSec decisions
```

## nftables architecture

fwsec operates with two parallel nftables tables:

```text
Inbound packet
      |
      v
+---------------------------------------------+
| table inet fwsec / chain whitelist          | priority -100
| ip saddr @allow4 -> ACCEPT immediately      |
+---------------------------------------------+
      | (not allow-listed)
      v
+---------------------------------------------+
| table inet fwsec / chain blacklist          | priority -50
| ip saddr @deny4 -> DROP                     |
+---------------------------------------------+
      | (not deny-listed)
      v
+---------------------------------------------+
| table inet filter / chain input             | priority 0
| established/related -> ACCEPT               |
| @crowdsec-blacklists -> DROP                |
| tcp dport <SSH> -> ACCEPT                   |
| policy: DROP                                |
+---------------------------------------------+
```

- **`@allow4` / `@allow6`** — sets managed by `fwsec -a`
- **`@deny4` / `@deny6`** — sets managed by `fwsec -d` and `fwsec -td`, with native timeouts
- **`@crowdsec-blacklists`** — sets managed automatically by the CrowdSec bouncer

## CrowdSec integration

When `SYNC_DENY = 1` (the default), `fwsec -d` and `fwsec -td` also create CrowdSec decisions:

```bash
fwsec -d 1.2.3.4 "SSH attack"
# -> nftables set deny4: immediate block
# -> cscli decisions add --ip 1.2.3.4: propagated to the bouncer

fwsec -td 1.2.3.4 3600 "Brute force"
# -> nftables set deny4 timeout 3600s: expires automatically
# -> cscli decisions add --duration 3600s
```

Show active CrowdSec decisions:

```bash
cscli decisions list
cscli alerts list
cscli metrics
```

## systemd service

```bash
systemctl status fwsec        # Show service status
systemctl start fwsec         # Start
systemctl stop fwsec          # Stop
systemctl restart fwsec       # Restart
systemctl enable fwsec        # Enable at boot
systemctl disable fwsec       # Disable at boot
journalctl -u fwsec -f        # Follow logs
```

## Practical examples

```bash
# Block an attacker for 24 hours and record the reason
fwsec -td 203.0.113.99 86400 "SSH brute force detected"

# Permanently allow an office IP address
fwsec -a 177.20.10.5 "Rio de Janeiro office"

# Check every list before allowing an IP address
fwsec -g 203.0.113.99

# Permanently block the address after investigation
fwsec -d 203.0.113.99 "Confirmed malicious"

# Reload every rule after manually editing fwsec.allow
fwsec -r

# Show the complete firewall state
fwsec -c && fwsec -l
```

## Development and governance

See [CONTRIBUTING.md](CONTRIBUTING.md) before preparing a change. The `main` branch is protected: every change must be submitted through a pull request and requires approval from `@hdbrsaulobrito`. Direct pushes and merges without that approval are not permitted.

Do not disclose security vulnerabilities in public issues. Use **Security → Report a vulnerability** and follow [SECURITY.md](SECURITY.md).

## License

fwsec is licensed under the [GNU General Public License version 2 only](LICENSE), identified by the SPDX expression `GPL-2.0-only`. This is the same base license used by the Linux kernel; the kernel-specific syscall exception is not part of this project.
