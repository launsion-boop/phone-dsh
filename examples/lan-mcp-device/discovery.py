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


def candidate(service, host, port, raw):
    if not isinstance(service, str) or not 1 <= len(service.encode("utf-8")) <= 63:
        return None
    if type(port) is not int or not 1 <= port <= 65535:
        return None
    if not isinstance(host, str) or len(host.encode("utf-8")) > 254:
        return None
    host = host[:-1] if host.endswith(".") else host
    host = host.lower()
    if not host.isascii() or not host or len(host) > 253:
        return None
    if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", x) for x in host.split(".")):
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
