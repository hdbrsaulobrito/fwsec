# SPDX-License-Identifier: GPL-2.0-only

"""
nftables abstraction layer.

fwsec owns a dedicated table `inet fwsec` with two hook chains:
  - whitelist  priority -100  (accept before the main filter)
  - blacklist  priority  -50  (drop before the main filter)

The existing `inet filter` table (crowdsec + SSH allow) is left untouched.
"""
from __future__ import annotations

import ipaddress
import re
import subprocess
from dataclasses import dataclass
from typing import Optional

NFT_FAMILY = "inet"
NFT_TABLE = "fwsec"

SET_ALLOW4 = "allow4"
SET_ALLOW6 = "allow6"
SET_DENY4 = "deny4"
SET_DENY6 = "deny6"


# ---------------------------------------------------------------------------
# Low-level runner
# ---------------------------------------------------------------------------

def _run(*args: str, check: bool = False) -> tuple[int, str, str]:
    r = subprocess.run(["nft", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"nft {' '.join(args)}: {r.stderr.strip()}")
    return r.returncode, r.stdout, r.stderr


def _run_script(script: str, check: bool = True) -> tuple[int, str, str]:
    r = subprocess.run(["nft", "-f", "-"], input=script, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"nft script error: {r.stderr.strip()}")
    return r.returncode, r.stdout, r.stderr


# ---------------------------------------------------------------------------
# IP helpers
# ---------------------------------------------------------------------------

def _ip_version(ip: str) -> int:
    try:
        return ipaddress.ip_network(ip, strict=False).version
    except ValueError:
        raise ValueError(f"Invalid IP/CIDR: {ip}")


def _set_for(ip: str, kind: str) -> str:
    """Return the set name for the given IP and kind ('allow'|'deny')."""
    v = _ip_version(ip)
    return f"{kind}{v}"


# ---------------------------------------------------------------------------
# Table lifecycle
# ---------------------------------------------------------------------------

def table_exists() -> bool:
    rc, out, _ = _run("list", "table", NFT_FAMILY, NFT_TABLE)
    return rc == 0


def flush_table() -> None:
    if table_exists():
        _run("delete", "table", NFT_FAMILY, NFT_TABLE)


def create_table() -> None:
    """Create the fwsec table with sets and hook chains."""
    script = f"""
table {NFT_FAMILY} {NFT_TABLE} {{

    set {SET_ALLOW4} {{
        type ipv4_addr
        flags interval
        auto-merge
    }}

    set {SET_ALLOW6} {{
        type ipv6_addr
        flags interval
        auto-merge
    }}

    set {SET_DENY4} {{
        type ipv4_addr
        flags timeout
    }}

    set {SET_DENY6} {{
        type ipv6_addr
        flags timeout
    }}

    chain whitelist {{
        type filter hook input priority -100; policy accept;
        ip  saddr @{SET_ALLOW4} accept
        ip6 saddr @{SET_ALLOW6} accept
    }}

    chain blacklist {{
        type filter hook input priority -50; policy accept;
        ip  saddr @{SET_DENY4} drop
        ip6 saddr @{SET_DENY6} drop
    }}
}}
"""
    _run_script(script)


# ---------------------------------------------------------------------------
# Set element management
# ---------------------------------------------------------------------------

def add_element(set_name: str, ip: str, timeout_sec: Optional[int] = None) -> None:
    if timeout_sec is not None:
        element = f"{{ {ip} timeout {timeout_sec}s }}"
    else:
        element = f"{{ {ip} }}"
    _run("add", "element", NFT_FAMILY, NFT_TABLE, set_name, element, check=True)


def delete_element(set_name: str, ip: str) -> bool:
    rc, _, _ = _run("delete", "element", NFT_FAMILY, NFT_TABLE, set_name, f"{{ {ip} }}")
    return rc == 0


def list_elements(set_name: str) -> list[str]:
    rc, out, _ = _run("list", "set", NFT_FAMILY, NFT_TABLE, set_name)
    if rc != 0:
        return []
    # Parse: elements = { 1.2.3.4, 5.6.7.8 timeout 1h expires 59m58s, ... }
    m = re.search(r"elements\s*=\s*\{([^}]*)\}", out, re.DOTALL)
    if not m:
        return []
    raw = m.group(1)
    # Strip timeout/expires annotations, split by comma
    entries = []
    for token in raw.split(","):
        # Each token may be "1.2.3.4 timeout Xh expires Ym"
        ip_part = token.strip().split()[0] if token.strip() else ""
        if ip_part:
            entries.append(ip_part)
    return entries


def element_exists(set_name: str, ip: str) -> bool:
    return ip in list_elements(set_name)


# ---------------------------------------------------------------------------
# High-level operations
# ---------------------------------------------------------------------------

def allow(ip: str) -> None:
    set_name = _set_for(ip, "allow")
    add_element(set_name, ip)


def unallow(ip: str) -> bool:
    set_name = _set_for(ip, "allow")
    return delete_element(set_name, ip)


def deny(ip: str, timeout_sec: Optional[int] = None) -> None:
    set_name = _set_for(ip, "deny")
    add_element(set_name, ip, timeout_sec)


def undeny(ip: str) -> bool:
    set_name = _set_for(ip, "deny")
    return delete_element(set_name, ip)


def is_allowed(ip: str) -> bool:
    try:
        return element_exists(_set_for(ip, "allow"), ip)
    except (ValueError, RuntimeError):
        return False


def is_denied(ip: str) -> bool:
    try:
        return element_exists(_set_for(ip, "deny"), ip)
    except (ValueError, RuntimeError):
        return False


# ---------------------------------------------------------------------------
# List / status helpers
# ---------------------------------------------------------------------------

@dataclass
class SetSummary:
    allow4: list[str]
    allow6: list[str]
    deny4: list[str]
    deny6: list[str]


def get_summary() -> SetSummary:
    if not table_exists():
        return SetSummary([], [], [], [])
    return SetSummary(
        allow4=list_elements(SET_ALLOW4),
        allow6=list_elements(SET_ALLOW6),
        deny4=list_elements(SET_DENY4),
        deny6=list_elements(SET_DENY6),
    )


def list_ruleset() -> str:
    _, out, _ = _run("list", "ruleset")
    return out


def get_full_set_output(set_name: str) -> str:
    """Return raw nft output for a specific set (includes timeouts)."""
    rc, out, _ = _run("list", "set", NFT_FAMILY, NFT_TABLE, set_name)
    return out if rc == 0 else ""


# ---------------------------------------------------------------------------
# Populate sets from config lists on startup
# ---------------------------------------------------------------------------

def load_allow_list(ips: list[str]) -> None:
    for ip in ips:
        try:
            allow(ip)
        except (ValueError, RuntimeError):
            pass


def load_deny_list(ips: list[str]) -> None:
    for ip in ips:
        try:
            deny(ip)
        except (ValueError, RuntimeError):
            pass
