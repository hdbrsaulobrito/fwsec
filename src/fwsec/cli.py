# SPDX-License-Identifier: GPL-2.0-only

"""
fwsec — nftables + CrowdSec firewall manager
CSF-style CLI interface
"""
from __future__ import annotations

import argparse
import datetime
import ipaddress
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

from fwsec import __version__
from fwsec import config as cfg
from fwsec import containers, crowdsec, nft, rules, state

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"


def _ok(msg: str) -> None:
    print(f"{GREEN}[OK]{RESET} {msg}")


def _err(msg: str) -> None:
    print(f"{RED}[ERR]{RESET} {msg}", file=sys.stderr)


def _info(msg: str) -> None:
    print(f"{CYAN}[*]{RESET} {msg}")


def _warn(msg: str) -> None:
    print(f"{YELLOW}[!]{RESET} {msg}")


def _header(title: str) -> None:
    print(f"\n{BOLD}{CYAN}{'─' * 60}{RESET}")
    print(f"{BOLD}{CYAN}  {title}{RESET}")
    print(f"{BOLD}{CYAN}{'─' * 60}{RESET}")


def _require_root() -> None:
    import os
    if os.geteuid() != 0:
        _err("fwsec requires root. Run with sudo or as root.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# SSH port detection
# ---------------------------------------------------------------------------

def _detect_ssh_port() -> int:
    sshd_conf = Path("/etc/ssh/sshd_config")
    if sshd_conf.exists():
        for line in sshd_conf.read_text().splitlines():
            if re.match(r"^Port\s+\d+", line):
                return int(line.split()[1])
    return 22


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_version(_args: argparse.Namespace) -> None:
    print(f"fwsec {__version__}")
    if crowdsec.available():
        print(f"crowdsec {crowdsec.version()}")
    rc, out, _ = nft._run("--version")
    if rc == 0:
        print(out.strip())


def cmd_start(_args: argparse.Namespace) -> None:
    _require_root()
    _info("Starting fwsec firewall...")
    c = cfg.load_config()
    ssh_port = _detect_ssh_port()

    # Build and apply filter table
    filter_script = rules.generate_filter_table(c, ssh_port)
    try:
        nft._run_script(filter_script)
        _ok(f"inet filter table loaded (SSH port {ssh_port}).")
    except RuntimeError as e:
        _err(f"Failed to load filter table: {e}")
        sys.exit(1)

    # Build and apply fwsec table (flush first to avoid set conflicts on re-start)
    if nft.table_exists():
        nft.flush_table()
    fwsec_script = rules.generate_fwsec_table()
    try:
        nft._run_script(fwsec_script)
        _ok("inet fwsec table loaded.")
    except RuntimeError as e:
        _err(f"Failed to load fwsec table: {e}")
        sys.exit(1)

    # Populate sets from config files
    allow_entries = cfg.read_allow()
    deny_entries = cfg.read_deny()
    nft.load_allow_list([e.ip for e in allow_entries])
    nft.load_deny_list([e.ip for e in deny_entries])

    # Restore temp blocks that are still active
    temp = state.list_temp_blocks()
    for t in temp:
        remaining = int(t.expires_at - time.time())
        if remaining > 0:
            try:
                nft.deny(t.ip, remaining)
            except (ValueError, RuntimeError):
                pass

    _ok(f"Allow list: {len(allow_entries)} IPs, Deny list: {len(deny_entries)} IPs, "
        f"Temp blocks: {len(temp)} IPs.")

    # Container support
    runtimes = containers.detect_runtimes()
    if runtimes and not c.container_mode:
        _warn(f"Container runtime detected ({', '.join(runtimes)}) but CONTAINER_MODE = 0.")
        _warn("The forward chain drops everything — container networking will break.")
        _warn(f"Set CONTAINER_MODE = 1 in {cfg.CONF_FILE} and run: fwsec -r")
    elif c.container_mode:
        _ok(f"Container mode enabled (policy: {c.container_policy}).")
        if c.container_policy == "filtered":
            _apply_container_filter()

    # Mark enabled
    cfg.set_enabled(True)

    # Persist ruleset
    _persist_nftables()
    _ok("fwsec started.")


def _apply_container_filter() -> None:
    """Build the `containers` chain restricting published ports to the allow list."""
    published = containers.externally_published_ports()
    tcp_ports = [p.host_port for p in published if p.proto == "tcp"]
    udp_ports = [p.host_port for p in published if p.proto == "udp"]
    subnets = containers.container_networks()

    if not tcp_ports and not udp_ports:
        _info("No externally published container ports to filter.")
        return

    script = rules.generate_container_filter(tcp_ports, udp_ports, subnets)
    try:
        nft._run_script(script)
        plist = ", ".join(
            f"{p.host_port}/{p.proto} ({p.container})" for p in published
        )
        _ok(f"Published container ports restricted to the allow list: {plist}")
    except RuntimeError as e:
        _warn(f"Could not apply the container port filter: {e}")


def cmd_stop(_args: argparse.Namespace) -> None:
    _require_root()
    _info("Stopping fwsec (flushing fwsec table, restoring permissive filter)...")
    nft.flush_table()

    # Replace filter table with a permissive ruleset (keeps SSH open)
    ssh_port = _detect_ssh_port()
    permissive = f"""
flush table inet filter
table inet filter {{
    chain input {{
        type filter hook input priority filter; policy accept;
    }}
    chain forward {{
        type filter hook forward priority filter; policy accept;
    }}
    chain output {{
        type filter hook output priority filter; policy accept;
    }}
}}
"""
    try:
        nft._run_script(permissive)
    except RuntimeError as e:
        _warn(f"Could not flush filter table: {e}")

    _ok("fwsec stopped. All traffic is now allowed.")


def cmd_disable(_args: argparse.Namespace) -> None:
    _require_root()
    cmd_stop(_args)
    cfg.set_enabled(False)
    _ok("fwsec disabled. It will not start automatically.")


def cmd_enable(_args: argparse.Namespace) -> None:
    _require_root()
    cfg.set_enabled(True)
    _ok("fwsec enabled.")
    cmd_start(_args)


def cmd_restart(_args: argparse.Namespace) -> None:
    _require_root()
    _info("Restarting fwsec...")
    nft.flush_table()
    cmd_start(_args)
    _ok("fwsec restarted.")


def cmd_check(_args: argparse.Namespace) -> None:
    _header("fwsec configuration check")
    c = cfg.load_config()
    issues = 0

    # Config file
    if not cfg.CONF_FILE.exists():
        _warn(f"Config file not found: {cfg.CONF_FILE}  (defaults will be used)")
    else:
        _ok(f"Config: {cfg.CONF_FILE}")

    # Enabled?
    if not c.enabled:
        _warn("ENABLED = 0 — firewall is disabled.")
        issues += 1
    else:
        _ok("ENABLED = 1")

    # TCP_IN ports
    _ok(f"TCP_IN  : {', '.join(c.tcp_in) or '(none)'}")
    _ok(f"TCP_OUT : {', '.join(c.tcp_out) or '(none)'}")

    # Allow/deny files
    allow_list = cfg.read_allow()
    deny_list = cfg.read_deny()
    _ok(f"Allow list: {len(allow_list)} entries ({cfg.ALLOW_FILE})")
    _ok(f"Deny list : {len(deny_list)} entries ({cfg.DENY_FILE})")

    # nftables table
    if nft.table_exists():
        _ok("fwsec nftables table: LOADED")
    else:
        _warn("fwsec nftables table: NOT LOADED (run: fwsec -s)")
        issues += 1

    # CrowdSec
    if crowdsec.available():
        _ok("CrowdSec: available")
        bouncers = crowdsec.list_bouncers()
        _ok(f"CrowdSec bouncers: {len(bouncers)} registered")
    else:
        _warn("CrowdSec: not available (cscli not found)")

    # Containers
    runtimes = containers.detect_runtimes()
    if runtimes:
        _ok(f"Container runtime(s): {', '.join(runtimes)}")
        if not c.container_mode:
            _warn("CONTAINER_MODE = 0 — container networking is blocked by the "
                  "forward chain. Set CONTAINER_MODE = 1 and run: fwsec -r")
            issues += 1
        else:
            _ok(f"Container mode: enabled (policy: {c.container_policy})")
        published = containers.externally_published_ports()
        if published:
            plist = ", ".join(f"{p.host_port}/{p.proto}→{p.container}" for p in published)
            _ok(f"Published container ports: {plist}")
            if c.container_policy != "filtered":
                _info("CONTAINER_POLICY = open — published ports accept any source. "
                      "Use 'filtered' to restrict them to the allow list.")
    elif c.container_mode:
        _info("CONTAINER_MODE = 1 but no running container runtime was found.")

    # SSH port
    ssh_port = _detect_ssh_port()
    _ok(f"SSH port detected: {ssh_port}")

    print()
    if issues == 0:
        _ok("Configuration OK.")
    else:
        _warn(f"{issues} issue(s) found.")


def cmd_list(_args: argparse.Namespace) -> None:
    _header("fwsec — loaded rules")

    if not nft.table_exists():
        _warn("fwsec table not loaded. Run: fwsec -s")
        return

    summary = nft.get_summary()
    c_deny = crowdsec.list_decisions() if crowdsec.available() else []

    state_data = state.load()

    def _comment(ip: str) -> str:
        c = state.get_comment(ip)
        return f"  # {c}" if c else ""

    print(f"\n{BOLD}Allow list (fwsec-allow){RESET} — {len(summary.allow4) + len(summary.allow6)} IPs")
    for ip in summary.allow4 + summary.allow6:
        print(f"  {GREEN}{ip}{RESET}{_comment(ip)}")

    print(f"\n{BOLD}Deny list (fwsec-deny){RESET} — {len(summary.deny4) + len(summary.deny6)} IPs")
    for ip in summary.deny4 + summary.deny6:
        print(f"  {RED}{ip}{RESET}{_comment(ip)}")

    print(f"\n{BOLD}CrowdSec decisions{RESET} — {len(c_deny)} active bans")
    for d in c_deny[:20]:
        print(f"  {RED}{d.ip}{RESET}  [{d.duration}]  {d.reason}")
    if len(c_deny) > 20:
        print(f"  ... and {len(c_deny) - 20} more")

    published = containers.published_ports()
    if published:
        print(f"\n{BOLD}Published container ports{RESET} — {len(published)} mappings")
        for p in published:
            local = "  (local only)" if p.host_ip in ("127.0.0.1", "::1", "[::1]") else ""
            print(f"  {CYAN}{p.host_port}/{p.proto}{RESET} → "
                  f"{p.container}:{p.container_port} [{p.runtime}]{local}")

    print()


def cmd_deny(args: argparse.Namespace) -> None:
    _require_root()
    ip = _resolve(args.ip)
    comment = args.comment or ""

    _info(f"Blocking {ip} permanently...")
    try:
        nft.deny(ip)
    except RuntimeError as e:
        _err(f"nftables: {e}")
        sys.exit(1)

    cfg.add_deny(ip, comment)
    state.add_deny_meta(ip, comment)

    c = cfg.load_config()
    if c.crowdsec_enabled and c.crowdsec_sync_deny and crowdsec.available():
        crowdsec.add_decision(ip, reason=comment or "fwsec manual ban")

    _ok(f"Blocked: {ip}{f'  ({comment})' if comment else ''}")


def cmd_deny_remove(args: argparse.Namespace) -> None:
    _require_root()
    ip = _resolve(args.ip)
    _info(f"Removing block for {ip}...")

    nft.undeny(ip)
    cfg.remove_deny(ip)
    state.remove_deny_meta(ip)

    c = cfg.load_config()
    if c.crowdsec_enabled and crowdsec.available():
        crowdsec.delete_decision(ip)

    _ok(f"Block removed: {ip}")


def cmd_temp_deny(args: argparse.Namespace) -> None:
    _require_root()
    ip = _resolve(args.ip)
    duration_sec = int(args.duration)
    comment = args.comment or ""

    _info(f"Temporarily blocking {ip} for {_fmt_duration(duration_sec)}...")
    try:
        nft.deny(ip, timeout_sec=duration_sec)
    except RuntimeError as e:
        _err(f"nftables: {e}")
        sys.exit(1)

    state.add_temp_block(ip, duration_sec, comment)
    cfg.add_deny(ip, comment)

    c = cfg.load_config()
    if c.crowdsec_enabled and c.crowdsec_sync_deny and crowdsec.available():
        crowdsec.add_decision(ip, reason=comment or "fwsec temp ban", duration=f"{duration_sec}s")

    expires = datetime.datetime.fromtimestamp(time.time() + duration_sec)
    _ok(f"Temp blocked: {ip} until {expires:%Y-%m-%d %H:%M:%S}{f'  ({comment})' if comment else ''}")


def cmd_temp_list(_args: argparse.Namespace) -> None:
    _header("Temporary blocks")
    blocks = state.list_temp_blocks()
    if not blocks:
        print("  No active temporary blocks.")
        return

    now = time.time()
    print(f"\n  {'IP':<20} {'Expires':<22} {'Remaining':<14} Comment")
    print(f"  {'─'*20} {'─'*22} {'─'*14} {'─'*20}")
    for b in sorted(blocks, key=lambda x: x.expires_at):
        remaining = b.expires_at - now
        exp = datetime.datetime.fromtimestamp(b.expires_at).strftime("%Y-%m-%d %H:%M:%S")
        rem = _fmt_duration(int(remaining))
        print(f"  {RED}{b.ip:<20}{RESET} {exp:<22} {rem:<14} {b.comment}")
    print()


def cmd_temp_remove(args: argparse.Namespace) -> None:
    _require_root()
    ip = _resolve(args.ip)
    _info(f"Removing temporary block for {ip}...")

    nft.undeny(ip)
    state.remove_temp_block(ip)
    cfg.remove_deny(ip)

    c = cfg.load_config()
    if c.crowdsec_enabled and crowdsec.available():
        crowdsec.delete_decision(ip)

    _ok(f"Temporary block removed: {ip}")


def cmd_allow(args: argparse.Namespace) -> None:
    _require_root()
    ip = _resolve(args.ip)
    comment = args.comment or ""

    _info(f"Whitelisting {ip}...")
    try:
        nft.allow(ip)
    except RuntimeError as e:
        _err(f"nftables: {e}")
        sys.exit(1)

    cfg.add_allow(ip, comment)
    state.add_allow_meta(ip, comment)

    # Remove from deny if present
    nft.undeny(ip)
    cfg.remove_deny(ip)

    # Remove CrowdSec ban if any
    c = cfg.load_config()
    if c.crowdsec_enabled and crowdsec.available():
        crowdsec.delete_decision(ip)

    _ok(f"Allowed: {ip}{f'  ({comment})' if comment else ''}")


def cmd_allow_remove(args: argparse.Namespace) -> None:
    _require_root()
    ip = _resolve(args.ip)
    _info(f"Removing {ip} from whitelist...")

    nft.unallow(ip)
    cfg.remove_allow(ip)
    state.remove_allow_meta(ip)

    _ok(f"Removed from whitelist: {ip}")


def cmd_grep(args: argparse.Namespace) -> None:
    target = args.target

    # Resolve domain to IPs if needed
    ips_to_check: list[str] = []
    try:
        ipaddress.ip_address(target)
        ips_to_check = [target]
    except ValueError:
        # It's a hostname — resolve it
        try:
            infos = socket.getaddrinfo(target, None)
            ips_to_check = list({i[4][0] for i in infos})
            _info(f"Resolved {target} → {', '.join(ips_to_check)}")
        except socket.gaierror:
            _err(f"Could not resolve: {target}")
            sys.exit(1)

    _header(f"Search: {target}")
    found = False

    for ip in ips_to_check:
        print(f"\n{BOLD}IP: {ip}{RESET}")

        # nftables allow set
        if nft.table_exists():
            if nft.is_allowed(ip):
                _ok(f"  In fwsec ALLOW list")
                found = True
            if nft.is_denied(ip):
                _warn(f"  In fwsec DENY list")
                found = True

        # Config files
        allow_list = cfg.read_allow()
        deny_list = cfg.read_deny()
        ignore_list = cfg.read_ignore()

        if any(e.ip == ip for e in allow_list):
            _ok(f"  In {cfg.ALLOW_FILE}")
            found = True
        if any(e.ip == ip for e in deny_list):
            _warn(f"  In {cfg.DENY_FILE}")
            found = True
        if any(e.ip == ip for e in ignore_list):
            _info(f"  In {cfg.IGNORE_FILE}")
            found = True

        # Temp blocks
        for t in state.list_temp_blocks():
            if t.ip == ip:
                exp = datetime.datetime.fromtimestamp(t.expires_at).strftime("%Y-%m-%d %H:%M:%S")
                _warn(f"  In TEMP BLOCK list (expires {exp}) — {t.comment}")
                found = True

        # CrowdSec
        if crowdsec.available():
            decisions = crowdsec.grep_ip(ip)
            for d in decisions:
                _warn(f"  CrowdSec decision: {d.type}  reason={d.reason}  duration={d.duration}")
                found = True

        # Containers
        for match in containers.find_ip(ip):
            _info(f"  {match}")
            found = True

        if not found:
            _info(f"  {ip} not found in any fwsec or CrowdSec list.")

    print()


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def _resolve(ip_or_host: str) -> str:
    """Resolve hostname to IP, or return IP as-is."""
    try:
        ipaddress.ip_network(ip_or_host, strict=False)
        return ip_or_host
    except ValueError:
        try:
            return socket.gethostbyname(ip_or_host)
        except socket.gaierror:
            _err(f"Cannot resolve: {ip_or_host}")
            sys.exit(1)


def _fmt_duration(sec: int) -> str:
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m {sec % 60}s"
    h = sec // 3600
    m = (sec % 3600) // 60
    return f"{h}h {m}m"


def _persist_nftables() -> None:
    """Save fwsec's tables to /etc/nftables.conf for persistence across reboots.

    Only the tables fwsec owns are saved — persisting the full ruleset would
    freeze dynamic rules from other owners (Docker, Podman, libvirt) and
    restore stale copies of them at boot.
    """
    out = nft.list_fwsec_tables()
    if out:
        Path("/etc/nftables.conf").write_text(
            "#!/usr/sbin/nft -f\nflush ruleset\n\n" + out
        )


# ---------------------------------------------------------------------------
# CLI parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fwsec",
        description="nftables + CrowdSec firewall manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  fwsec -s                          Start firewall
  fwsec -r                          Reload rules
  fwsec -l                          List loaded rules
  fwsec -d 1.2.3.4                  Block IP permanently
  fwsec -d 1.2.3.4 "SSH attack"    Block with comment
  fwsec -td 1.2.3.4 3600 "Brute"   Temp block for 1 hour
  fwsec -t                          List temporary blocks
  fwsec -tr 1.2.3.4                 Remove temp block
  fwsec -dr 1.2.3.4                 Remove permanent block
  fwsec -a 1.2.3.4 "Office"        Whitelist IP
  fwsec -ar 1.2.3.4                 Remove from whitelist
  fwsec -g 1.2.3.4                  Search IP in all lists
  fwsec -g example.com              Search domain
""",
    )

    g = p.add_mutually_exclusive_group()

    g.add_argument("-v", "--version",   action="store_true", help="Show version")
    g.add_argument("-l", "--list",      action="store_true", help="List loaded rules")
    g.add_argument("-s", "--start",     action="store_true", help="Start firewall")
    g.add_argument("-f", "--stop",      action="store_true", help="Stop firewall (flush rules)")
    g.add_argument("-x", "--disable",   action="store_true", help="Disable fwsec")
    g.add_argument("-e", "--enable",    action="store_true", help="Enable fwsec")
    g.add_argument("-r", "--restart",   action="store_true", help="Restart / reload rules")
    g.add_argument("-c", "--check",     action="store_true", help="Check configuration")

    # Deny
    g.add_argument("-d", "--deny",      nargs="+", metavar=("IP", "COMMENT"),
                   help="Block IP permanently: -d IP [comment]")
    g.add_argument("-dr", "--deny-remove", dest="deny_remove", metavar="IP",
                   help="Remove permanent block")

    # Temp deny
    g.add_argument("-td", "--temp-deny", dest="temp_deny", nargs="+",
                   metavar=("IP", "SECONDS"),
                   help="Block IP temporarily: -td IP SECONDS [comment]")
    g.add_argument("-t",  "--temp-list",   dest="temp_list",   action="store_true",
                   help="List temporary blocks")
    g.add_argument("-tr", "--temp-remove", dest="temp_remove", metavar="IP",
                   help="Remove temporary block")

    # Allow
    g.add_argument("-a",  "--allow",        nargs="+", metavar=("IP", "COMMENT"),
                   help="Whitelist IP: -a IP [comment]")
    g.add_argument("-ar", "--allow-remove", dest="allow_remove", metavar="IP",
                   help="Remove IP from whitelist")

    # Grep
    g.add_argument("-g", "--grep", metavar="IP_OR_DOMAIN",
                   help="Search IP or domain in all lists")

    return p


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    # Map parsed args to command functions
    if args.version:
        cmd_version(args)

    elif args.list:
        cmd_list(args)

    elif args.start:
        cmd_start(args)

    elif args.stop:
        cmd_stop(args)

    elif args.disable:
        cmd_disable(args)

    elif args.enable:
        cmd_enable(args)

    elif args.restart:
        cmd_restart(args)

    elif args.check:
        cmd_check(args)

    elif args.deny:
        ns = argparse.Namespace(ip=args.deny[0], comment=" ".join(args.deny[1:]) if len(args.deny) > 1 else "")
        cmd_deny(ns)

    elif args.deny_remove:
        cmd_deny_remove(argparse.Namespace(ip=args.deny_remove))

    elif args.temp_deny:
        if len(args.temp_deny) < 2:
            parser.error("-td requires IP and SECONDS: fwsec -td 1.2.3.4 3600 [comment]")
        ns = argparse.Namespace(
            ip=args.temp_deny[0],
            duration=args.temp_deny[1],
            comment=" ".join(args.temp_deny[2:]) if len(args.temp_deny) > 2 else "",
        )
        cmd_temp_deny(ns)

    elif args.temp_list:
        cmd_temp_list(args)

    elif args.temp_remove:
        cmd_temp_remove(argparse.Namespace(ip=args.temp_remove))

    elif args.allow:
        ns = argparse.Namespace(ip=args.allow[0], comment=" ".join(args.allow[1:]) if len(args.allow) > 1 else "")
        cmd_allow(ns)

    elif args.allow_remove:
        cmd_allow_remove(argparse.Namespace(ip=args.allow_remove))

    elif args.grep:
        cmd_grep(argparse.Namespace(target=args.grep))

    else:
        parser.print_help()
