#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Public-repository hygiene scan for the phone-DSH roots.

The scan is deliberately conservative about false positives: absolute home
paths are only reported at a path boundary (so ``/dsh/home/**`` and a
``materialized/home/`` directory name are not findings), and reserved domains
used by tests (``.example``, ``.example.com``, ``.example.org``, ``.invalid``,
``.internal``, ``.test``, ``.localhost``) are accepted hostnames.  Every
remaining finding can be suppressed by one regular expression per line in
``scripts/ci/hygiene-allow.txt``.

The ``hostname`` rule asks one question: does this token name infrastructure a
reader could reach, and therefore attribute to a person or a private network?
Tokens that merely *look* like a hostname are not findings, and each such
exemption below is a rule about a class of token, never about a file:

* an XML namespace identifier -- ``xmlns`` values are opaque strings the parser
  never dereferences, and ``schemas.android.com`` in an ``AndroidManifest.xml``
  is a required declaration, not an endpoint;
* a prefix of a longer dotted identifier -- ``com.sun.net`` in
  ``import com.sun.net.httpserver.HttpServer`` is a Java package, not a host;
* a macOS/iOS application-bundle name -- ``.app`` is both a real gTLD and the
  bundle suffix, and a CamelCase label before it (``Google Chrome.app``,
  ``PhoneDSHProbe.app``) is a file name;
* an unroutable IPv4 literal -- loopback, link-local, RFC 1918 and RFC 5737
  addresses name nothing a reader can reach, and a placeholder octet
  (``192.168.x.x``) is not even a number.  A *public* IPv4 is still a finding;
* an elided placeholder -- ``/Users/...`` and ``https://…`` are redaction
  markers, and ``<root>/home/a`` is a path fragment appended to a symbolic
  root, not an absolute path.

The analogues for the ``email`` rule are a scale suffix on an image asset
(``running-whale@2x.png``) and a language-labelled receiver
(``this@drawWithContent``).
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
    # RFC 2606 reserves example.com (and its subdomains) for documentation, so
    # it names no real service. The CSP conformance checklist in
    # spec/v1/render-media-v1.md fetches it on purpose, and the subdomain form
    # is already covered by RESERVED_HOST_SUFFIXES below.
    "example.com",
    # The Gradle wrapper's own `distributionUrl`. Like nodejs.org and npmjs.com
    # above, it names the public distribution host a toolchain fetch needs; the
    # wrapper regenerates that line, so it cannot be rewritten by hand.
    "services.gradle.org",
}

# A dotted Java/Kotlin/Android package name is not a hostname, even though its
# last component may look like a TLD (`java.io`, `androidx.test.platform.app`).
# Matching them was a false positive on ordinary Kotlin KDoc and imports.
PACKAGE_PATH_PREFIXES = (
    "java.",
    "javax.",
    "kotlin.",
    "kotlinx.",
    "android.",
    "androidx.",
    "dalvik.",
    "com.android.",
    "org.jetbrains.",
    "org.jetbrains.kotlin.",
    "org.junit.",
    "org.w3c.",
    "org.xml.",
    "org.xmlpull.",
    "sun.",
    "jdk.",
    # The app's own install id (`com.phonedsh.app`) is an Android package name,
    # not infrastructure. The rule matched it the moment the applicationId moved
    # off `com.phonedsh.probe`, which is the same false positive the list above
    # was created for -- a dotted identifier whose last segment looks like a TLD.
    "com.phonedsh.",
)


def looks_like_package_path(candidate):
    lowered = candidate.lower()
    if any(lowered.startswith(prefix) for prefix in PACKAGE_PATH_PREFIXES):
        return True
    # `Dispatchers.IO`, `Locale.US`: an all-caps right-hand side is an object or an
    # enum constant, never a top-level domain. Every real TLD is at least partially
    # lower case in source.
    tail = candidate.rsplit(".", 1)[-1]
    return tail.isalpha() and tail.isupper() and len(tail) <= 5


# Third-party hosts the project deliberately cites or samples.  These are real
# public services, not infrastructure anyone can attribute to a contributor, so
# they are the same kind of entry as github.com/nodejs.org above -- and, like
# those, they are scoped to the *value*: a different host on the same line of
# the same file is still a finding.
CITED_PUBLIC_HOSTS = {
    # `SettingsParitySamples.kt` renders the egress allow-list page for the UI
    # screenshot diff, so it needs a page of plausible sample entries.
    "api.open-meteo.com",
    "geocoding-api.open-meteo.com",
    "api.github.com",
    "pypi.org",
    "files.pythonhosted.org",
    "registry.npmjs.org",
    "cdn.jsdelivr.net",
    "unpkg.com",
    "en.wikipedia.org",
    "api.duckduckgo.com",
    "html.duckduckgo.com",
    "lite.duckduckgo.com",
    # Public specifications the JSC compatibility notes quote by section.
    "webidl.spec.whatwg.org",
    "streams.spec.whatwg.org",
    # Licence and product pages cited by the office-conversion research note.
    "getlocalcode.app",
    "www.libreoffice.org",
    "www.collaboraonline.com",
    "www.gnu.org",
    "cloudconvert.com",
    "developers.google.com",
    "purchase.aspose.com",
    "learn.microsoft.com",
}

RESERVED_HOST_SUFFIXES = (
    ".example",
    ".example.com",
    ".example.org",
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

# The attribute value of an XML namespace declaration.  The parser hands the
# string to an XML resolver as an opaque identifier and never opens a socket, so
# `xmlns:android="http://schemas.android.com/apk/res/android"` -- required
# boilerplate in every AndroidManifest.xml and vector drawable -- is not an
# upstream.  Matching the attribute (rather than the one host) also covers
# `xmlns:tools`, SVG's `www.w3.org` namespace and any future declaration.
XMLNS_RE = re.compile(
    r"""\bxmlns(?::[A-Za-z_][\w.-]*)?\s*=\s*("[^"]*"|'[^']*')""",
)

# A hostname that is only the ASCII ellipsis or the Unicode one: `https://...`
# and `https://…` are how the receipts elide a URL they do not want to publish.
ELLIPSIS_HOST_RE = re.compile(r"^[.…]+$")
# A path whose "root" is a symbolic placeholder: `<root>/home/a`, `${REPO}/Users/x`.
# The slash does not start an absolute path there, it continues a relative join.
PLACEHOLDER_ROOT_RE = re.compile(
    r"(?:<[^<>\s]{1,40}>|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)$"
)

# A dotted identifier that keeps going: `com.sun.net.httpserver.HttpServer` and
# `io.ktor.utils.io.readAvailable` are Java/Kotlin package and member paths.  The
# matched prefix is a hostname only if nothing identifier-like follows the dot.
DOTTED_CONTINUATION_RE = re.compile(r"\.[A-Za-z_]")

# `running-whale@2x.png` is a retina asset name, not a mailbox: `@2x`/`@3x` in
# front of an image extension is the Apple scale-suffix convention.
EMAIL_SCALE_SUFFIX_RE = re.compile(
    r"@\d+x?\.(?:png|jpe?g|gif|webp|avif|heic|heif|tiff?|bmp|svg|pdf|ico)$",
    re.IGNORECASE,
)
# `this@drawWithContent.drawContent()` labels the receiver in Kotlin; the local
# part of a real address is never a reserved receiver keyword.
EMAIL_KEYWORD_LOCALS = {"this", "it", "super", "self"}

IPV4_RE = re.compile(r"(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})")
PLACEHOLDER_IPV4_RE = re.compile(r"^[0-9xX*n]{1,3}(?:\.[0-9xX*n]{1,3}){3}$")


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
    # The fixed native tool name is an API identifier, not a private hostname.
    if host == "notify.local":
        return True
    if host in ALLOWED_HOSTS or host in CITED_PUBLIC_HOSTS:
        return True
    if host.rsplit(":", 1)[-1].isdigit() and host.count(":") == 1:
        host = host.rsplit(":", 1)[0]
    if host in ALLOWED_HOSTS or host in CITED_PUBLIC_HOSTS:
        return True
    if unroutable_ipv4(host):
        return True
    return any(host.endswith(suffix) for suffix in RESERVED_HOST_SUFFIXES)


def unroutable_ipv4(host):
    """True for an IPv4 literal that cannot name an attributable endpoint.

    Loopback, link-local, RFC 1918 private space, the 100.64/10 carrier-grade
    NAT block and the RFC 5737 documentation ranges are not addresses a reader
    can reach, so naming one attributes nothing.  A placeholder octet
    (``192.168.x.x``) is not even a number.  A *public* IPv4 literal is still a
    finding: that one does point at infrastructure.
    """
    if PLACEHOLDER_IPV4_RE.match(host) and not IPV4_RE.fullmatch(host):
        return True
    match = IPV4_RE.fullmatch(host)
    if match is None:
        return False
    if any(int(part) > 255 for part in match.groups()):
        return False
    first, second, third = (int(part) for part in match.groups()[:3])
    if first in (0, 10, 127):
        return True
    if first == 169 and second == 254:
        return True
    if first == 172 and 16 <= second <= 31:
        return True
    if first == 192 and second == 168:
        return True
    if first == 100 and 64 <= second <= 127:
        return True
    return (first, second, third) in {(192, 0, 2), (198, 51, 100), (203, 0, 113)}


def looks_like_bundle_name(host):
    """True for a macOS/iOS application bundle, e.g. ``Google Chrome.app``.

    ``.app`` is a real gTLD, so the suffix alone decides nothing.  A bundle name
    carries the product name in CamelCase (``Chrome``, ``PhoneDSHProbe``,
    ``Probe``) while a hostname in source is written in lower case -- the same
    case-as-evidence rule ``looks_like_package_path`` already relies on.
    """
    if not host.lower().endswith(".app"):
        return False
    label = host.rsplit(".", 2)[-2]
    return any(char.isupper() for char in label)


def looks_like_email_asset(line, match):
    """True for ``running-whale@2x.png``: an asset name with a scale suffix."""
    return EMAIL_SCALE_SUFFIX_RE.search(line[match.start() : match.end()]) is not None


def looks_like_labelled_receiver(text):
    """True for ``this@drawWithContent``: a Kotlin/Java labelled receiver."""
    local = text.split("@", 1)[0]
    return local in EMAIL_KEYWORD_LOCALS


def home_path_is_placeholder(line, match):
    """True when a home-path match is an elided or symbolic fragment.

    ``/Users/...`` is a redaction marker and ``<root>/home/a`` appends a
    relative component to a symbolic root; neither names a real home directory.
    """
    matched = match.group(0)
    # The marker must be the segment that would name the person. Checking the
    # LAST segment let `/Users/<real name>/...` through — the ellipsis was in the
    # tail while the user name sat in the clear, which is the one thing this rule
    # exists to catch.
    segments = [seg for seg in matched.split("/") if seg]
    if segments and ELLIPSIS_HOST_RE.match(segments[1] if len(segments) > 1 else segments[0]):
        return True
    return PLACEHOLDER_ROOT_RE.search(line[: match.start()].rstrip()) is not None


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
        if home_path_is_placeholder(line, match):
            continue
        add_finding(findings, patterns, rel, number, line, "home-path", match.group(0))
    for match in EMAIL_RE.finditer(line):
        if looks_like_email_asset(line, match) or looks_like_labelled_receiver(
            match.group(0)
        ):
            continue
        add_finding(findings, patterns, rel, number, line, "email", match.group(0))
    # The official attribution is allowed verbatim; everything else that looks
    # like an internal codename is still a finding.
    line_without_attribution = ATTRIBUTION_PHRASE_RE.sub("", line)
    for match in BANNED_WORD_RE.finditer(line_without_attribution):
        add_finding(findings, patterns, rel, number, line, "banned-word", match.group(0))
    for pattern in CREDENTIAL_RES:
        for match in pattern.finditer(line):
            add_finding(findings, patterns, rel, number, line, "credential", match.group(0))

    namespace_spans = [(m.start(1), m.end(1)) for m in XMLNS_RE.finditer(line)]
    url_spans = url_hosts(line)
    seen_hosts = set()
    for start, _end, host in url_spans:
        if host.lower() in seen_hosts:
            continue
        # A string template, not a host: "http://$LOOPBACK_HOST:$port/",
        # "https://${host}/". There is no literal host to judge.
        if "$" in host or "{" in host or "}" in host or "%" in host:
            continue
        # `https://:443/...` (a URL with no host at all) and `https://…` (an
        # elided one) both have nothing to judge.
        if not host or ELLIPSIS_HOST_RE.match(host):
            continue
        if any(ns_start <= start < ns_end for ns_start, ns_end in namespace_spans):
            continue
        seen_hosts.add(host.lower())
        report_host(findings, patterns, rel, number, line, host)
    for match in DOMAIN_RE.finditer(line):
        if any(start <= match.start(1) < end for start, end, _host in url_spans):
            continue
        host = match.group(1)
        if host.lower() in seen_hosts:
            continue
        if looks_like_package_path(host) or looks_like_bundle_name(host):
            continue
        # `com.sun.net.httpserver` continues past the match, so the match is a
        # package prefix, not a host.
        if DOTTED_CONTINUATION_RE.match(line, match.end(1)):
            continue
        seen_hosts.add(host.lower())
        report_host(findings, patterns, rel, number, line, host)


def report_host(findings, patterns, rel, number, line, host):
    """Report a bare host unless it is allowed.

    Hostnames are case-insensitive, so the allow-list is consulted with the
    lower-cased spelling: the shipped provider contract writes
    ``API.deepseek.com``, which names the same host as ``api.deepseek.com``.
    """
    if host_allowed(host):
        return
    add_finding(findings, patterns, rel, number, line, "hostname", host.lower())


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
