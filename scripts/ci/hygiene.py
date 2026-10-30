#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Public-repository hygiene scan for the phone-DSH roots.

The scan is deliberately conservative about false positives: absolute home
paths are only reported at a path boundary (so ``/dsh/home/**`` and a
``materialized/home/`` directory name are not findings), and reserved domains
used by tests (``.example``, ``.example.com``, ``.invalid``, ``.internal``,
``.test``, ``.localhost``) are accepted hostnames.  Every remaining finding can
be suppressed by one regular expression per line in
``scripts/ci/hygiene-allow.txt``.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import common

ALLOWED_HOSTS = {
    "github.com",
    "developer.apple.com",
    "webkit.org",
    "nodejs.org",
    "npmjs.com",
    "deepseek.com",
    "docs.rs",
    "example.com",
    "example.org",
    "example.net",
    "crates.io",
    "python.org",
    "modelcontextprotocol.io",
    "localhost",
    "127.0.0.1",
}

RESERVED_HOST_SUFFIXES = (
    ".example",
    ".example.com",
    ".invalid",
    ".internal",
    ".test",
    ".localhost",
)

HOME_PATH_RE = re.compile(r"(?<![\w.-])/(?:Users|home)/[^\s\"'`<>),;\]]*")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
URL_RE = re.compile(r"(?i)\b(?:https?|wss?|ftp)://([^\s/?#\"'`<>]+)")
DOMAIN_RE = re.compile(
    r"(?<![\w@.-])"
    r"((?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"(?:com|net|org|io|dev|ai|app|co|cn|me|cloud|internal|invalid|test|"
    r"localhost|example|corp|lan|local|intranet|svc|uk|de|jp|fr|ru|edu|gov))"
    r"\b",
    re.IGNORECASE,
)
# Internal service/branch spellings must never leak into the public tree, but
# the project's own public attribution ("Xiaozhi & Tono AI Team") is sanctioned
# and appears in LICENSE, README and NOTICE.
BANNED_WORD_RE = re.compile(r"\b(?:tonoai|tonolive|tonofleet|xiaozhi-link)\b", re.IGNORECASE)
ATTRIBUTION_PHRASE_RE = re.compile(r"xiaozhi\s*&\s*tono\s*ai\s*team", re.IGNORECASE)
CREDENTIAL_RES = [
    re.compile(r"sk-[A-Za-z0-9]{16,}"),
    re.compile(r"Bearer\s+[A-Za-z0-9._~+/-]{32,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN"),
]


def load_allowlist(root):
    patterns = []
    errors = []
    path = Path(root) / common.ALLOW_LIST
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return patterns, errors
    for number, raw in enumerate(text.splitlines(), start=1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        try:
            patterns.append(re.compile(entry))
        except re.error as exc:
            errors.append((number, str(exc)))
    return patterns, errors


def allowed(patterns, rel, number, line, matched):
    context = f"{rel}:{number}: {line}"
    return any(
        pattern.search(context) or pattern.search(matched) for pattern in patterns
    )


def host_allowed(host):
    host = host.lower().rstrip(".")
    if host in ALLOWED_HOSTS:
        return True
    if host.rsplit(":", 1)[-1].isdigit() and host.count(":") == 1:
        host = host.rsplit(":", 1)[0]
    if host in ALLOWED_HOSTS:
        return True
    return any(host.endswith(suffix) for suffix in RESERVED_HOST_SUFFIXES)


def url_hosts(line):
    hosts = []
    for match in URL_RE.finditer(line):
        host = match.group(1)
        if "@" in host:
            host = host.rsplit("@", 1)[-1]
        if host.startswith("[") and "]" in host:
            host = host[1 : host.index("]")]
        elif ":" in host:
            host = host.rsplit(":", 1)[0]
        # Drop sentence punctuation that URL tokenizers commonly absorb.
        host = host.rstrip(".,;:!?)]}'\"")
        hosts.append((match.start(1), match.end(1), host))
    return hosts


def scan_line(rel, number, line, patterns, findings):
    for match in HOME_PATH_RE.finditer(line):
        add_finding(findings, patterns, rel, number, line, "home-path", match.group(0))
    for match in EMAIL_RE.finditer(line):
        add_finding(findings, patterns, rel, number, line, "email", match.group(0))
    # The official attribution is allowed verbatim; everything else that looks
    # like an internal codename is still a finding.
    line_without_attribution = ATTRIBUTION_PHRASE_RE.sub("", line)
    for match in BANNED_WORD_RE.finditer(line_without_attribution):
        add_finding(findings, patterns, rel, number, line, "banned-word", match.group(0))
    for pattern in CREDENTIAL_RES:
        for match in pattern.finditer(line):
            add_finding(findings, patterns, rel, number, line, "credential", match.group(0))

    url_spans = url_hosts(line)
    seen_hosts = set()
    for _start, _end, host in url_spans:
        if host.lower() in seen_hosts:
            continue
        seen_hosts.add(host.lower())
        if not host_allowed(host):
            add_finding(findings, patterns, rel, number, line, "hostname", host)
    for match in DOMAIN_RE.finditer(line):
        if any(start <= match.start(1) < end for start, end, _host in url_spans):
            continue
        host = match.group(1)
        if host.lower() in seen_hosts:
            continue
        seen_hosts.add(host.lower())
        if not host_allowed(host):
            add_finding(findings, patterns, rel, number, line, "hostname", host)


def add_finding(findings, patterns, rel, number, line, rule, matched):
    if allowed(patterns, rel, number, line, matched):
        return
    findings.append((rel, number, rule, matched))


def run(root):
    patterns, allowlist_errors = load_allowlist(root)
    findings = []
    for number, message in allowlist_errors:
        findings.append(
            (common.ALLOW_LIST, number, "allow-list", f"invalid regex: {message}")
        )
    for rel in common.scan_files(root):
        lines = common.read_lines(root, rel)
        if lines is None:
            continue
        for number, line in enumerate(lines, start=1):
            scan_line(rel, number, line, patterns, findings)
    for rel, number, rule, excerpt in sorted(findings):
        common.emit(rel, number, rule, excerpt)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(
        common.main_guard(
            __file__,
            "public-repository hygiene scan of the phone-DSH roots",
            run,
        )
    )
