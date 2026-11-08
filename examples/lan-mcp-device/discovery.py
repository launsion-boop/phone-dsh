# SPDX-License-Identifier: MIT
"""Reference DNS-SD profile encoder/decoder; discovery is never authentication."""
import re
from urllib.parse import urlunsplit

PROFILE = "pdsh-mcp-1"
SERVICE = "_pdsh-mcp._tcp"


def txt_bytes(records):
    out = bytearray()
    for record in records:
        raw = record.encode("utf-8")
        if len(raw) > 255:
            raise ValueError("TXT entry too long")
        out.append(len(raw))
        out.extend(raw)
    return bytes(out)


def canonical_hostname(host):
    """Return lan-mcp.md canon(host), or None. No IDNA mapping is performed."""
    # Validate the original input before lowercasing: Unicode characters such
    # as the Kelvin sign otherwise normalize into an ASCII-looking hostname.
    if not isinstance(host, str) or not host.isascii() or len(host) > 254:
        return None
    host = host[:-1] if host.endswith(".") else host
    host = host.lower()
    if not host or len(host) > 253:
        return None
    labels = host.split(".")
    if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in labels):
        return None
    # A-labels are excluded: their validity differs across URL/IDNA runtimes.
    if any(x.startswith("xn--") for x in labels):
        return None
    # Follow the shared final-label rule, including the bare 0x prefix.
    if re.fullmatch(r"(?:[0-9]+|0x[0-9a-f]*)", labels[-1]):
        return None
    return host


def candidate(service, host, port, raw):
    if not isinstance(service, str):
        return None
    try:
        service_length = len(service.encode("utf-8"))
    except UnicodeEncodeError:
        return None
    if not 1 <= service_length <= 63:
        return None
    if type(port) is not int or not 1 <= port <= 65535:
        return None
    host = canonical_hostname(host)
    if host is None:
        return None
    i = 0
    seen = False
    valid = False
    while i < len(raw):
        size = raw[i]
        i += 1
        if i + size > len(raw):
            return None
        entry = raw[i:i + size]
        i += size
        key, sep, value = entry.partition(b"=")
        if key.lower() == b"profile":
            if seen or not sep:
                return None
            seen = True
            valid = value == PROFILE.encode()
    if not seen or not valid:
        return None
    authority = host if port == 443 else f"{host}:{port}"
    return urlunsplit(("https", authority, "/mcp", "", ""))


def certificate_names_host(hostname, dns_names):
    """True when a non-wildcard ASCII dNSName equals canonical `hostname`."""
    for name in dns_names:
        if not isinstance(name, str) or not name.isascii() or "*" in name:
            continue
        if (name[:-1] if name.endswith(".") else name).lower() == hostname:
            return True
    return False


def publication_check(hostname, dns_names, srv_target, srv_port, port):
    """Static name-consistency check of lan-mcp.md; returns 'consistent' or the first failure."""
    canonical = canonical_hostname(hostname)
    if canonical is None:
        return "hostname_invalid"
    if not certificate_names_host(canonical, dns_names):
        return "certificate_name_missing"
    url = candidate("check", srv_target, srv_port, txt_bytes(["profile=" + PROFILE]))
    if url is None:
        return "srv_target_invalid"
    if canonical_hostname(srv_target) != canonical:
        return "srv_target_mismatch"
    if srv_port != port:
        return "srv_port_mismatch"
    return "consistent"
