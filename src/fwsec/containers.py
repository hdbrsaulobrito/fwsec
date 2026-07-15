# SPDX-License-Identifier: GPL-2.0-only

"""
Container runtime detection and inspection (Docker / Podman / nerdctl).

Everything here is best-effort: any runtime error or missing binary simply
yields empty results so the rest of fwsec keeps working on hosts without
containers.
"""
from __future__ import annotations

import ipaddress
import json
import re
import shutil
import subprocess
from dataclasses import dataclass

RUNTIMES = ("docker", "podman", "nerdctl")

# Matches "0.0.0.0:8080->80/tcp", ":::8080->80/tcp", "127.0.0.1:5432->5432/tcp"
_PORT_RE = re.compile(
    r"(?P<hip>[^\s,]*?):(?P<hport>\d+)->(?P<cport>\d+)/(?P<proto>tcp|udp)"
)


def _run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.SubprocessError):
        return 1, "", ""


def detect_runtimes() -> list[str]:
    """Runtimes whose CLI is installed AND can talk to its engine."""
    found = []
    for rt in RUNTIMES:
        if not shutil.which(rt):
            continue
        rc, _, _ = _run([rt, "ps", "-q"])
        if rc == 0:
            found.append(rt)
    return found


def installed_runtimes() -> list[str]:
    """Runtimes whose CLI is installed (engine may be stopped)."""
    return [rt for rt in RUNTIMES if shutil.which(rt)]


# ---------------------------------------------------------------------------
# Published ports
# ---------------------------------------------------------------------------

@dataclass
class PublishedPort:
    runtime: str
    container: str
    host_ip: str
    host_port: int
    proto: str
    container_port: int


def published_ports() -> list[PublishedPort]:
    """Ports published to the host (-p) by running containers, all runtimes."""
    result: list[PublishedPort] = []
    seen: set[tuple[str, int, str]] = set()
    for rt in detect_runtimes():
        rc, out, _ = _run([rt, "ps", "--format", "{{.Names}}\t{{.Ports}}"])
        if rc != 0:
            continue
        for line in out.splitlines():
            name, _, ports = line.partition("\t")
            for m in _PORT_RE.finditer(ports):
                key = (name, int(m.group("hport")), m.group("proto"))
                if key in seen:  # v4 + v6 bindings of the same port
                    continue
                seen.add(key)
                result.append(PublishedPort(
                    runtime=rt,
                    container=name.strip(),
                    host_ip=m.group("hip"),
                    host_port=int(m.group("hport")),
                    proto=m.group("proto"),
                    container_port=int(m.group("cport")),
                ))
    return result


def externally_published_ports() -> list[PublishedPort]:
    """Published ports reachable from outside (skip 127.0.0.1/::1 bindings)."""
    return [
        p for p in published_ports()
        if p.host_ip not in ("127.0.0.1", "::1", "[::1]")
    ]


# ---------------------------------------------------------------------------
# Container networks
# ---------------------------------------------------------------------------

def container_networks() -> list[str]:
    """Subnets (CIDR) of every container network across all runtimes."""
    subnets: list[str] = []
    for rt in detect_runtimes():
        rc, out, _ = _run([rt, "network", "ls", "-q"])
        if rc != 0 or not out.strip():
            continue
        rc, out, _ = _run([rt, "network", "inspect", *out.split()])
        if rc != 0:
            continue
        try:
            raw = json.loads(out)
        except json.JSONDecodeError:
            continue
        for net in raw or []:
            # Docker/nerdctl: IPAM.Config[].Subnet — Podman: subnets[].subnet
            for c in (net.get("IPAM") or {}).get("Config") or []:
                if c.get("Subnet"):
                    subnets.append(c["Subnet"])
            for c in net.get("subnets") or []:
                if c.get("subnet"):
                    subnets.append(c["subnet"])
    valid = []
    for s in subnets:
        try:
            ipaddress.ip_network(s, strict=False)
            valid.append(s)
        except ValueError:
            pass
    return sorted(set(valid))


# ---------------------------------------------------------------------------
# IP lookup (fwsec -g)
# ---------------------------------------------------------------------------

def find_ip(ip: str) -> list[str]:
    """Human-readable matches tying an IP to containers or their networks."""
    matches: list[str] = []
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return matches

    for subnet in container_networks():
        try:
            if addr in ipaddress.ip_network(subnet, strict=False):
                matches.append(f"Inside container network {subnet}")
                break
        except ValueError:
            continue

    for rt in detect_runtimes():
        rc, out, _ = _run([
            rt, "ps", "--format",
            "{{.Names}}",
        ])
        if rc != 0:
            continue
        names = out.split()
        if not names:
            continue
        rc, out, _ = _run([
            rt, "inspect", "--format",
            '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}',
            *names,
        ])
        if rc != 0:
            continue
        for line in out.splitlines():
            parts = line.replace("/", " ").split()
            if len(parts) >= 2 and ip in parts[1:]:
                matches.append(f"IP of container '{parts[0]}' ({rt})")
    return matches
