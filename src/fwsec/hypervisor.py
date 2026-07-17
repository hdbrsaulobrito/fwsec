# SPDX-License-Identifier: GPL-2.0-only

"""
Hypervisor and bridge detection (KVM/libvirt, Proxmox VE, Xen).

Bridged VM traffic is layer 2 and only traverses the nftables L3 hooks when
the br_netfilter module is loaded with bridge-nf-call-iptables=1 — this module
reports that state so fwsec can tell the operator whether bridged VMs are
actually subject to the firewall. NAT/routed VM traffic (libvirt's default
virbr0 network) always traverses the forward hook.

Everything is best-effort: missing binaries yield empty results.
"""
from __future__ import annotations

import ipaddress
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

# Bridge name prefixes owned by container runtimes, not hypervisors
_CONTAINER_BRIDGES = ("docker", "podman", "cni", "br-")


def _run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.SubprocessError):
        return 1, "", ""


def detect_hypervisors() -> list[str]:
    """Hypervisor stacks present on this host."""
    found = []
    if Path("/etc/pve").is_dir() or shutil.which("pveversion"):
        found.append("proxmox")
    if shutil.which("virsh"):
        found.append("libvirt")
    if shutil.which("xl") and Path("/proc/xen").exists():
        found.append("xen")
    return found


# ---------------------------------------------------------------------------
# Bridges
# ---------------------------------------------------------------------------

@dataclass
class Bridge:
    name: str
    kind: str  # "vm" | "container"


def bridges() -> list[Bridge]:
    """Active bridge interfaces, classified as VM or container bridges."""
    rc, out, _ = _run(["ip", "-o", "link", "show", "type", "bridge"])
    if rc != 0:
        return []
    result = []
    for line in out.splitlines():
        m = re.match(r"\d+:\s*([^:@]+)", line)
        if not m:
            continue
        name = m.group(1).strip()
        kind = "container" if name.startswith(_CONTAINER_BRIDGES) else "vm"
        result.append(Bridge(name=name, kind=kind))
    return result


def vm_bridges() -> list[str]:
    return [b.name for b in bridges() if b.kind == "vm"]


def br_netfilter_active() -> bool:
    """True when bridged traffic traverses the L3 netfilter hooks."""
    p = Path("/proc/sys/net/bridge/bridge-nf-call-iptables")
    try:
        return p.read_text().strip() == "1"
    except OSError:
        return False


# ---------------------------------------------------------------------------
# libvirt NAT/routed networks
# ---------------------------------------------------------------------------

def vm_networks() -> list[str]:
    """Subnets (CIDR) of libvirt-managed networks (NAT/routed VMs)."""
    if not shutil.which("virsh"):
        return []
    rc, out, _ = _run(["virsh", "net-list", "--name"])
    if rc != 0:
        return []
    subnets = []
    for net in out.split():
        rc, xml, _ = _run(["virsh", "net-dumpxml", net])
        if rc != 0:
            continue
        for m in re.finditer(r"<ip[^>]*address='([^']+)'[^>]*netmask='([^']+)'", xml):
            try:
                iface = ipaddress.ip_interface(f"{m.group(1)}/{m.group(2)}")
                subnets.append(str(iface.network))
            except ValueError:
                continue
        for m in re.finditer(r"<ip[^>]*address='([^']+)'[^>]*prefix='(\d+)'", xml):
            try:
                iface = ipaddress.ip_interface(f"{m.group(1)}/{m.group(2)}")
                subnets.append(str(iface.network))
            except ValueError:
                continue
    return sorted(set(subnets))


# ---------------------------------------------------------------------------
# Competing hypervisor firewalls
# ---------------------------------------------------------------------------

def pve_firewall_active() -> bool:
    rc, out, _ = _run(["systemctl", "is-active", "pve-firewall"])
    return rc == 0 and out.strip() == "active"
