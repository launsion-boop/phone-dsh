#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reproducible G2 batch planning, execution and receipt aggregation.

The scenario runner (``scripts/ci/scenarios.sh``) deliberately executes one
catalog selection per process and writes the per-scenario evidence under
``--results``.  It does not own the *batch* around that invocation: which
scenarios a lane runs, which directories each lane owns, whether an earlier
PASS may be reused, or whether the collected reports really belong to the
source/catalog/model/engine that is being receipted.

This module is that thin, stdlib-only batch layer:

* ``plan`` reads the catalog, validates that every catalog id appears exactly
  once across the configured lanes, and prints a plan with an independent
  ``results``, ``sim`` and ``work`` directory per lane.
* ``run`` executes one ``scenarios.sh`` process per lane, streams redacted
  output to the lane work directory, then records a receipt per scenario.
* ``run --resume`` (or ``resume``) reuses only a prior PASS from a previous
  batch state that finished with every executed lane returning 0 and no
  timeout, whose source, catalog, model and engine identity (including the
  simulator assignment) is byte-identical **and** whose complete evidence hash
  set still matches.  A FAIL/NOT_RUN/BLOCKED/PENDING_HOST or a runner failure
  is always executed again; it is never turned into a PASS.
* ``summary`` aggregates the current reports into explicit
  ``PASS``/``FAIL``/``NOT_RUN``/``BLOCKED``/``PENDING_HOST`` states.  A missing
  or structurally incomplete run state (not finished, missing lane records, or
  no per-scenario results), a missing report, a report/attempt/source-id
  mismatch, a missing receipt or changed evidence is a failure, never an
  implicit pass.

Nothing here parses credentials or copies the environment.  A real run only
requires the same ``PDSH_MODEL_BASE_URL``/``PDSH_MODEL_NAME``/
``PDSH_MODEL_API_KEY`` variables that ``scripts/ci/scenarios.sh`` already
requires; the API key is never read into metadata, printed, or written.  The
model identity stores the provider name, the endpoint host and a SHA-256 of the
sanitized base URL; it never stores the key or a key digest.  Before hashing,
known API-key values are removed from the hostname, the path and from every
retained query value (including raw, case-varied and percent-encoded forms), so
neither a non-credential query name such as ``?code=<key>`` nor a key embedded
in the host can become plaintext metadata or a key-derived digest.  Because the
credential tenant/deployment cannot be derived from a key, a real batch records
an optional non-secret ``PDSH_MODEL_CONFIG_ID``.  Without it the credential
context is explicitly ``unknown``: a normal run still works, but an explicit
resume will not reuse a prior real PASS because a rotated key could point at a
different tenant on the same endpoint/model.

The fixture identity is truthful as well: the resolved ``--scenarios-script``
computes its repository root from its own location and always seeds
``<script-repo>/scripts/ci/scenarios/fixtures``; it has no fixture-root flag.
The batch derives that root from the resolved script, not from ``--repo-root``,
so a script in another checkout can never make the receipt describe the source
checkout's fixture bytes.  A non-default ``--fixtures-root`` is therefore
accepted only by ``plan`` (marked plan-only there); ``run``/``resume`` refuse it
instead of hashing bytes the runner would never consume.

The engine identity is execution-bound as well.  ``scenarios.sh`` computes
``$ROOT`` from its own location and ``cd``s there before ``swift test`` or
``xcodebuild``, so ``run``/``resume`` require that resolved source checkout to
equal ``--repo-root``.  They also hash the actual Worker bundle tree, image and
``plugins/dsh-pin.json`` the child will consume, and fail before starting any
lane if an asset is missing or empty.  The Python/JQ pairs are required and
hashed only on the build-cache branch; with a prebuilt
``PDSH_DSH_WWW``/``PDSH_DSH_IMAGE`` pair they are recorded as not consumed
because ``scenarios.sh`` never reads those directories.  After every lane exits
and before any receipt is written, ``run``/``resume`` recompute the source,
catalog, fixture and engine identity; a child that rewrote a tracked source
file, the catalog, a fixture or a stale default build cache therefore makes
every receipt ``BLOCKED`` instead of recording a PASS for pre-run bytes.
``plan`` may describe a different runner checkout or absent assets, but it is
marked ``execution_ready = false`` and cannot produce receipts; ``summary``
re-reads the catalog/fixture and recorded asset paths and blocks if their bytes
changed.

All captured log bytes pass through a streaming credential redactor.  The
redactor reads the recognized credential/base-URL env values in-process only,
retains a bounded suffix across read boundaries, holds an incomplete ``sk-``
token, exact-secret prefix or unfinished ``Authorization`` header until its
terminator/EOF, and streams large newline-free output instead of buffering it,
so an opaque exact value, a split ``sk-`` token and a value split inside or
after an ``Authorization`` scheme cannot leak through a chunk cut.  Provider-key
punctuation such as ``/``, ``+``, ``=``, ``,`` and ``;`` is part of the token,
not a terminator.
"""

from __future__ import annotations

import argparse
import codecs
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit, urlunsplit

HERE = Path(__file__).resolve().parent
DEFAULT_REPO_ROOT = HERE.parent.parent
DEFAULT_CATALOG = HERE / "scenarios" / "catalog.json"
DEFAULT_SCENARIOS = HERE / "scenarios.sh"
DEFAULT_FIXTURES = HERE / "scenarios" / "fixtures"

BATCH_SCHEMA = "phone-dsh-scenario-batch"
BATCH_VERSION = 1
BATCH_MANIFEST = "batch.json"
RUN_STATE = "state.json"
SUMMARY_JSON = "summary.json"
SUMMARY_MD = "summary.md"
RECEIPTS_DIR = "receipts"

SCENARIO_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
LANE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

REPORT_STATUSES = frozenset(
    {"PASS", "FAIL", "TIMEOUT", "BUDGET", "ERROR", "SKIP", "INFRA", "PENDING_HOST"}
)
REPORT_REQUIRED_FIELDS = (
    "id",
    "status",
    "assertions",
    "turns",
    "perturbations",
    "usage",
    "console_errors",
    "host_states",
)
REPORT_LIST_FIELDS = (
    "assertions",
    "turns",
    "perturbations",
    "console_errors",
    "host_states",
)
REPORT_OBJECT_FIELDS = ("usage",)

SUMMARY_STATUSES = ("PASS", "FAIL", "NOT_RUN", "BLOCKED", "PENDING_HOST")

TERMINAL_EVIDENCE = (
    "report.json",
    "transcript.jsonl",
    "workspace.tar",
    "host/materialized/workspace",
    "host/wal",
    "host/journal.xljournal",
    "host/response-log",
    "host/fence.json",
    "host/overlay-*.tar",
)
DEFERRED_EVIDENCE = ("report.json", "transcript.jsonl", "scenario.json")
HOST_DIRECTORIES = {
    "host/materialized/workspace",
    "host/wal",
    "host/response-log",
}

MODEL_ENV = ("PDSH_MODEL_BASE_URL", "PDSH_MODEL_NAME", "PDSH_MODEL_API_KEY")
# Files ``scenarios.sh``/``verify-bundle.mjs`` require in a bundle before
# either the prebuilt or build-cache branch may hand it to the runner.
BUNDLE_REQUIRED_FILES = (
    "worker-entry.js",
    "tool-worker-python.js",
    "tool-worker.js",
    "index.html",
    "boot.js",
    "phone-dsh-provenance.json",
)

SECRET_PATTERNS = (
    (
        # ``scenarios.sh`` exports both TEST_RUNNER_/SIMCTL_CHILD_ variants,
        # so the credential name may carry one or more underscore prefixes.
        re.compile(
            r"(?i)\b((?:[A-Za-z0-9]+_)*(?:PDSH_MODEL_API_KEY|DEEPSEEK_API_KEY|"
            r"OPENAI_API_KEY|ANTHROPIC_API_KEY|API[_-]?KEY))\s*=\s*"
            r"(?:'[^']*'|\"[^\"]*\"|[^\s,;]+)"
        ),
        r"\1=<redacted>",
    ),
    (
        # Authorization may use any scheme (Basic/Token/Digest/...); redact
        # the scheme and the value, not just the scheme token.
        re.compile(
            r"(?i)\b(Authorization|Proxy[_-]?Authorization)\b"
            r"(\s*[:=]\s*)"
            r"(?:[A-Za-z][A-Za-z0-9._~+/-]*\s+)?"
            r"(?:'[^']*'|\"[^\"]*\"|[^\s,;]+)"
        ),
        r"\1\2<redacted>",
    ),
    (
        re.compile(r"(?i)\bBearer\s+(?:'[^']*'|\"[^\"]*\"|[^\s,;]+)"),
        "Bearer <redacted>",
    ),
    (
        re.compile(
            r"(?i)\b((?:[A-Za-z0-9]+_)*(?:api[_-]?key|x-api-key|authorization|"
            r"access[_-]?token|refresh[_-]?token|secret|password))"
            r"(\s*[:=]\s*)([^\s,;]+)"
        ),
        r"\1\2<redacted>",
    ),
    (
        # URL userinfo and sensitive query values are credential-shaped even
        # when the value is not present in this process's model environment.
        re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)([^/\s@]+)@"),
        r"\1<redacted>@",
    ),
    (
        re.compile(
            r"(?i)([?&](?:api[_-]?key|key|token|secret|password|passwd|"
            r"credential|auth|signature|sig)=)([^&\s,;]+)"
        ),
        r"\1<redacted>",
    ),
    (
        # A provider key can contain ``/``, ``+``, ``=``, ``,``, ``;`` and
        # similar punctuation.  Only whitespace and quotes end a log token;
        # treating punctuation as a token terminator would let a split key
        # leave its suffix behind after the prefix was redacted.
        re.compile(r"sk-[^\s'\"`]{8,}"),
        "<redacted>",
    ),
)

CREDENTIAL_ENV_NAMES = (
    "PDSH_MODEL_API_KEY",
    "TEST_RUNNER_PDSH_MODEL_API_KEY",
    "SIMCTL_CHILD_PDSH_MODEL_API_KEY",
    "DEEPSEEK_API_KEY",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
)
BASE_URL_ENV_NAMES = (
    "PDSH_MODEL_BASE_URL",
    "TEST_RUNNER_PDSH_MODEL_BASE_URL",
    "SIMCTL_CHILD_PDSH_MODEL_BASE_URL",
)
MODEL_CONFIG_ID_ENV = "PDSH_MODEL_CONFIG_ID"
MODEL_CONFIG_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$")
SENSITIVE_QUERY_KEY_RE = re.compile(
    r"(?i)(?:api[_-]?key|key|token|secret|password|passwd|credential|auth|signature|sig)"
)

# A bounded suffix is retained between reads so a credential split across a
# pipe read can still be replaced.  It is at least one byte longer than the
# longest exact credential value; the fixed floor also covers short generic
# tokens (``Bearer ...``/URL userinfo) that straddle a read boundary.
MAX_REDACTION_TAIL = 8192

# A trailing ``sk-`` token may be incomplete between reads.  Keep it raw until
# a terminator (or EOF) arrives; applying the generic rule to a prefix would
# replace only the prefix and leave the suffix behind.  Provider keys commonly
# contain ``-``/``_``/``.`` (``sk-proj-...``, ``sk-ant-api03-...``) but also
# ``/``, ``+``, ``=``, ``,`` and ``;``; only whitespace or quotes are true log
# token separators.  Exact in-process credential values are additionally
# protected by their own prefix rule below, which covers keys containing a
# space or another character that cannot be recognized generically.
SK_TOKEN_CHAR_CLASS = r"[^\s'\"`]"
TRAILING_SK_TOKEN_RE = re.compile(r"sk-" + SK_TOKEN_CHAR_CLASS + r"*$")
SEALED_SK_TERMINATOR_RE = re.compile(r"[\s'\"`]")
# An unfinished Authorization header is held raw until its line terminator.
# The header value begins with a scheme (``Basic``/``Bearer``/...) and the
# generic rule replaces that scheme together with the value; if the header is
# cut after (or inside) the scheme, generic-redacting the first chunk would
# leave the next chunk's value without its label.
AUTHORIZATION_HEADER_LABEL_RE = re.compile(
    r"(?i)\b(?:Proxy[_-]?Authorization|Authorization)\b"
)
AUTHORIZATION_HEADER_TERMINATOR_RE = re.compile(r"[\r\n]")


def _add_url_secret_values(values, raw_url):
    """Add the userinfo, path and sensitive query values of a base URL."""

    raw_url = str(raw_url)
    if not raw_url:
        return
    values.add(raw_url)
    values.add(raw_url.rstrip("/"))
    try:
        parts = urlsplit(raw_url)
        query_pairs = parse_qsl(parts.query, keep_blank_values=True)
    except ValueError:
        return
    if parts.username is not None:
        userinfo = [parts.username]
        if parts.password is not None:
            userinfo.append(parts.password)
            userinfo.append("{}:{}".format(parts.username, parts.password))
        for item in userinfo:
            if item:
                values.add(item)
                values.add(unquote(item))
    if parts.path and parts.path != "/":
        values.add(parts.path)
        values.add(unquote(parts.path))
    sensitive_query = False
    for key, value in query_pairs:
        if SENSITIVE_QUERY_KEY_RE.search(key):
            sensitive_query = True
            if value:
                values.add(value)
                values.add(unquote(value))
    if sensitive_query and parts.query:
        values.add(parts.query)


def _credential_env_values(env=None):
    """The API-key values that must never become an endpoint digest."""

    env = os.environ if env is None else env
    return {
        value
        for value in (env.get(name) for name in CREDENTIAL_ENV_NAMES)
        if isinstance(value, str) and value
    }


def _exact_secret_values(env=None):
    """Credential/base-URL values known only in-process, never persisted."""

    env = os.environ if env is None else env
    values = set(_credential_env_values(env))
    for name in BASE_URL_ENV_NAMES:
        value = env.get(name)
        if isinstance(value, str) and value:
            _add_url_secret_values(values, value)
    return {value for value in values if value}


class BatchError(RuntimeError):
    """A fail-loud batch error with an operator-facing message."""

    def __init__(self, message, exit_code=2):
        super().__init__(message)
        self.exit_code = exit_code


# --------------------------------------------------------------------- basics


def utcnow():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def redact_text(value):
    """Return ``value`` with credential-shaped substrings removed.

    Known environment values (the API key and the userinfo/path/sensitive
    query of a model base URL) are removed by exact value before the generic
    patterns run.  They are read in-process for this call only and are never
    written to the manifest, receipt, summary or log.
    """

    text = str(value)
    for secret in sorted(_exact_secret_values(), key=len, reverse=True):
        text = text.replace(secret, "<redacted>")
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def safe_url(value, env=None):
    """The scheme://host[:port] of a URL, never userinfo/path/query.

    A hostname is case-insensitive (and ``urlsplit`` lowercases it), so a
    known credential embedded in the host is replaced case-insensitively as
    well; the host must not become a plaintext copy of the API key in
    ``batch.json``.
    """

    raw_url = _sanitized_raw_endpoint_url(value, env)
    try:
        parts = urlsplit(raw_url)
    except ValueError:
        return "<invalid-url>"
    if not parts.scheme or not parts.hostname:
        return "<invalid-url>"
    try:
        port_number = parts.port
    except ValueError:
        return "<invalid-url>"
    port = ":{}".format(port_number) if port_number else ""
    host = _sanitized_endpoint_host(parts.hostname, env)
    url = "{}://{}{}".format(parts.scheme, host, port)
    if _contains_known_credential(url, env):
        return "<invalid-url>"
    return url


def _sanitized_endpoint_component(text, env=None):
    """Replace known credential values in a URL component before hashing.

    The raw value and common percent-encoded spellings are both replaced so a
    key embedded in a path or in a query value cannot become an offline
    guessable digest.  Query values are decoded before this runs as well, which
    also covers lower-case percent escapes.
    """

    values = _credential_env_values(env)
    if not values or not text:
        return text
    variants = set(values)
    for secret in values:
        variants.add(quote(secret, safe=""))
        variants.add(quote(secret, safe="/"))
    for secret in sorted((item for item in variants if item), key=len, reverse=True):
        text = text.replace(secret, "<redacted>")
    return text


def _sanitized_raw_endpoint_url(value, env=None):
    """Replace known credential values in the complete raw URL before parsing.

    ``urlsplit`` treats ``/``, ``?`` and ``#`` as delimiters even when they
    appear inside URL userinfo.  A credential containing one of those
    characters therefore spills out of ``parts.username`` into the
    host/path/query components, where per-component sanitizing can no longer
    recognize the whole value.  Replace the raw value (and its common
    percent-encoded spellings) in the raw string first, so every derived
    component is already secret-free before it is parsed or hashed.
    """

    text = str(value)
    values = _credential_env_values(env)
    if not values or not text:
        return text
    variants = set(values)
    for secret in values:
        variants.add(quote(secret, safe=""))
        variants.add(quote(secret, safe="/"))
    for secret in sorted((item for item in variants if item), key=len, reverse=True):
        text = text.replace(secret, "<redacted>")
    return text


def _contains_known_credential(text, env=None):
    """Whether an endpoint identity still contains a known credential.

    Components are sanitized individually after parsing, but a malformed URL
    can still leave a credential in an unexpected spelling.  Treat any
    residual (case-insensitive, raw or percent-encoded) occurrence as a
    fail-closed condition rather than writing it to metadata or hashing it.
    """

    if not text:
        return False
    values = _credential_env_values(env)
    if not values:
        return False
    candidates = [
        candidate.replace("<redacted>", "")
        for candidate in (text, unquote(text))
    ]
    for secret in values:
        folded = secret.casefold()
        for candidate in candidates:
            if secret in candidate or folded in candidate.casefold():
                return True
    return False


def _sanitized_endpoint_host(host, env=None):
    """Replace known credential values in a URL host before identity/hashing.

    Hosts are case-insensitive and ``urlsplit`` presents the hostname in lower
    case, so the raw, lower/upper and percent-encoded spellings are all
    replaced case-insensitively.  A key in the host can therefore neither be
    written to ``batch.json`` nor become part of ``base_url_sha256``.
    """

    if not host:
        return host
    values = _credential_env_values(env)
    if not values:
        return host
    variants = set()
    for secret in values:
        variants.add(secret)
        variants.add(secret.lower())
        variants.add(secret.upper())
        for quoted in (quote(secret, safe=""), quote(secret, safe="/")):
            variants.add(quoted)
            variants.add(quoted.lower())
            variants.add(quoted.upper())
    for secret in sorted((item for item in variants if item), key=len, reverse=True):
        host = re.sub(
            re.escape(secret), lambda _match: "<redacted>", host, flags=re.IGNORECASE
        )
    return host


def _sanitized_endpoint_path(path, env=None):
    """Remove known credential values from an endpoint path before hashing."""

    if not path:
        return path
    sanitized = _sanitized_endpoint_component(path, env)
    if sanitized != path:
        return sanitized
    decoded = unquote(path)
    sanitized_decoded = _sanitized_endpoint_component(decoded, env)
    # A credential may also be percent-encoded in the URL.  Only fall back to
    # the decoded form when that replacement actually found it; otherwise keep
    # the original path spelling so normal endpoint identities do not change.
    if sanitized_decoded != decoded:
        return sanitized_decoded
    return path


def _safe_endpoint_url(value, env=None):
    """A non-secret endpoint identity: no userinfo, no sensitive query value.

    The path is retained because it changes the endpoint; userinfo, values
    whose query key looks credential-shaped, and known API-key values embedded
    in the host, path or a retained query value are removed before the URL is
    hashed.  This keeps the model identity from becoming an offline-guessable
    digest of an embedded credential.
    """

    raw_url = _sanitized_raw_endpoint_url(value, env)
    try:
        parts = urlsplit(raw_url)
    except ValueError:
        return "<invalid-url>"
    if not parts.scheme or not parts.hostname:
        return "<invalid-url>"
    try:
        port_number = parts.port
    except ValueError:
        return "<invalid-url>"
    host = _sanitized_endpoint_host(parts.hostname, env)
    if ":" in host:
        host = "[{}]".format(host)
    netloc = host + (":{}".format(port_number) if port_number else "")
    # Sanitize the raw query before parsing as well: a provider key may contain
    # characters that parse_qsl would reinterpret (for example ``+``), and the
    # raw spelling is what the operator actually passed as the base URL.
    raw_query = _sanitized_endpoint_component(parts.query, env)
    kept_query = []
    try:
        pairs = parse_qsl(raw_query, keep_blank_values=True)
    except ValueError:
        pairs = []
    for key, item in pairs:
        if SENSITIVE_QUERY_KEY_RE.search(key):
            continue
        # Values whose key is not credential-shaped (for example ``?code=...``)
        # may still carry the key itself.  Replace known values again after
        # decoding, which covers percent-encoded and re-spelled forms.
        kept_query.append(
            (
                _sanitized_endpoint_component(key, env),
                _sanitized_endpoint_component(item, env),
            )
        )
    result = urlunsplit(
        (
            parts.scheme.lower(),
            netloc,
            _sanitized_endpoint_path(parts.path, env),
            urlencode(kept_query, doseq=True),
            "",
        )
    )
    if _contains_known_credential(result, env):
        return "<invalid-url>"
    return result


def redaction_tail_length():
    """How many trailing characters a streaming read must retain."""

    longest = max((len(value) for value in _exact_secret_values()), default=0)
    return max(MAX_REDACTION_TAIL, longest + 1)


def _trailing_incomplete_sk_start(text):
    """Start of an ``sk-`` token that still reaches the end of ``text``.

    Returns ``None`` when the buffer does not end inside such a token.  The
    token is kept raw by the streaming redactor so a later read cannot append
    an unlabelled suffix after a prematurely generic-redacted prefix.
    """

    match = TRAILING_SK_TOKEN_RE.search(text)
    return match.start() if match is not None else None


def _trailing_exact_secret_start(text, secrets=None):
    """Start of a suffix of ``text`` that is a prefix of an exact secret.

    The bounded tail normally catches a secret straddling a read boundary,
    but generic rules run before the next exact-value pass.  If an exact key
    starts with ``sk-`` (or a URL secret starts with a generic pattern), a
    cut inside the key could let the generic rule replace the prefix, after
    which exact replacement can no longer match the whole value.  Holding the
    longest matching suffix raw until it is complete prevents that.

    Exact values can contain any character (including ``/``, ``+``, ``=``,
    ``,``, ``;`` or a space), so this check is character-agnostic.  An exact
    value is always shorter than ``redaction_tail_length()``, which bounds the
    hold.
    """

    if not text:
        return None
    values = _exact_secret_values() if secrets is None else secrets
    best = None
    for secret in values:
        limit = min(len(text), len(secret))
        for length in range(limit, 0, -1):
            if text.endswith(secret[:length]):
                start = len(text) - length
                if best is None or start < best:
                    best = start
                break
    return best


def _trailing_authorization_header_start(text):
    """Start of an Authorization header whose line is still open.

    The generic Authorization rule consumes the scheme together with the
    value (``Authorization: Basic <secret>``).  If a read boundary falls
    inside the scheme or just before the value, applying that rule to the
    first chunk would replace only the scheme prefix; the next chunk's token
    would then arrive without a label and leak verbatim.  Keep the whole
    unfinished header line raw until its terminator (or EOF), exactly as an
    incomplete ``sk-`` token is held.  A newline always ends a header line, so
    only the text after the last newline can be unfinished.
    """

    if not text:
        return None
    line_start = max(text.rfind("\n"), text.rfind("\r")) + 1
    match = AUTHORIZATION_HEADER_LABEL_RE.search(text, line_start)
    return match.start() if match is not None else None


def _trailing_sensitive_start(text, secrets=None):
    """Earliest start that must stay raw across the next read."""

    starts = []
    exact = _trailing_exact_secret_start(text, secrets=secrets)
    if exact is not None:
        starts.append(exact)
    sk_token = _trailing_incomplete_sk_start(text)
    if sk_token is not None:
        starts.append(sk_token)
    authorization = _trailing_authorization_header_start(text)
    if authorization is not None:
        starts.append(authorization)
    return min(starts) if starts else None


def redact_chunks(chunks):
    """Yield redacted text from decoded chunks without unbounded buffering.

    The final ``redaction_tail_length()`` characters stay pending between
    chunks, so a credential that is split at a pipe read boundary is still
    replaced before any part of it is written.  A trailing incomplete
    ``sk-`` token, exact-secret prefix or ``Authorization`` header is held raw
    until its terminator/EOF instead of being partly replaced by a generic
    rule.  An overlong such token/header is emitted once as ``<redacted>`` and
    its remaining token characters (or the rest of the header line) are
    dropped, so a hostile newline-free token cannot grow the pending buffer
    without bound.
    """

    guard = redaction_tail_length()
    secrets = _exact_secret_values()
    pending = ""
    sealed_sk_token = False
    sealed_header = False
    for chunk in chunks:
        if not chunk:
            continue
        if sealed_header:
            terminator = AUTHORIZATION_HEADER_TERMINATOR_RE.search(chunk)
            if terminator is None:
                continue
            # Preserve the line terminator so later log lines keep their
            # boundary, then treat the remainder as a fresh read.
            chunk = chunk[terminator.start():]
            sealed_header = False
            if not chunk:
                continue
        if sealed_sk_token:
            terminator = SEALED_SK_TERMINATOR_RE.search(chunk)
            if terminator is None:
                continue
            chunk = chunk[terminator.start():]
            sealed_sk_token = False
            if not chunk:
                continue
        raw = pending + chunk
        protect = _trailing_sensitive_start(raw, secrets=secrets)
        if protect is not None and len(raw) - protect > guard:
            clean = redact_text(raw[:protect])
            if clean:
                yield clean
            yield "<redacted>"
            pending = ""
            # An unfinished Authorization line may contain spaces (scheme and
            # value), so seal to the next newline rather than to the next
            # whitespace; a generic token can seal at either.
            if _trailing_authorization_header_start(raw) is not None:
                sealed_header = True
            else:
                sealed_sk_token = True
            continue
        if protect is None:
            head, tail = raw, ""
        else:
            head, tail = raw[:protect], raw[protect:]
        clean = redact_text(head)
        if len(clean) > guard:
            yield clean[:-guard]
            clean = clean[-guard:]
        pending = clean + tail
    if pending:
        yield redact_text(pending)


class _LinePrefixer:
    """Add the lane prefix at each line start without buffering a whole line."""

    def __init__(self, prefix):
        self.prefix = prefix + " "
        self.at_line_start = True

    def feed(self, piece):
        output = []
        for line in piece.splitlines(keepends=True):
            if self.at_line_start:
                output.append(self.prefix)
            output.append(line)
            self.at_line_start = line.endswith(("\n", "\r"))
        return "".join(output)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _hash_tree_entry(root, path, digest):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        digest.update(b"L\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(os.readlink(path).encode("utf-8"))
        return
    if path.is_dir():
        digest.update(b"D\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        for child in sorted(path.iterdir(), key=lambda item: item.name):
            _hash_tree_entry(root, child, digest)
        return
    if path.is_file():
        digest.update(b"F\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        return
    digest.update(b"O\0")
    digest.update(relative.encode("utf-8"))


def hash_tree(path):
    """A deterministic hash of a directory tree (paths and file bytes)."""

    path = Path(path)
    digest = hashlib.sha256()
    _hash_tree_entry(path, path, digest)
    return digest.hexdigest()


def hash_file_tree(path):
    """A deterministic file-content hash, ignoring empty directories.

    The runner creates ``$PDSH_DSH_WWW/lazy`` after the batch has already
    fingerprinted the bundle.  A directory entry would make an otherwise
    unchanged bundle look different, so bundle identity covers every regular
    file and symlink (with its target) but not an empty directory node.
    """

    path = Path(path)
    digest = hashlib.sha256()
    count = [0]

    def walk(item):
        relative = item.relative_to(path).as_posix()
        if item.is_symlink():
            digest.update(b"L\0")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(os.readlink(item).encode("utf-8"))
            digest.update(b"\0")
            count[0] += 1
            return
        if item.is_dir():
            for child in sorted(item.iterdir(), key=lambda entry: entry.name):
                walk(child)
            return
        if item.is_file():
            digest.update(b"F\0")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            with open(item, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
            digest.update(b"\0")
            count[0] += 1
            return
        digest.update(b"O\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        count[0] += 1

    walk(path)
    return digest.hexdigest(), count[0]


def canonical_sha256(document):
    payload = json.dumps(
        document, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return sha256_bytes(payload)


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_json_atomic(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=str(path.parent),
        prefix=path.name + ".",
        delete=False,
    )
    temporary = Path(handle.name)
    try:
        with handle:
            json.dump(document, handle, indent=2, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def write_text_atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=str(path.parent),
        prefix=path.name + ".",
        delete=False,
    )
    temporary = Path(handle.name)
    try:
        with handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


# ------------------------------------------------------------------- catalog


def load_catalog(path):
    """Load and validate the parts the batch layer relies on."""

    path = Path(path)
    try:
        document = read_json(path)
    except (OSError, ValueError) as exc:
        raise BatchError("cannot read catalog {}: {}".format(path, exc)) from exc
    if not isinstance(document, dict):
        raise BatchError("catalog is not a JSON object: {}".format(path))
    scenarios = document.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        raise BatchError("catalog has no scenarios list: {}".format(path))
    seen = set()
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            raise BatchError("catalog scenario {} is not an object".format(index))
        scenario_id = scenario.get("id")
        if (
            not isinstance(scenario_id, str)
            or not SCENARIO_ID_RE.fullmatch(scenario_id)
            or scenario_id in (".", "..")
        ):
            raise BatchError(
                "catalog scenario {} has an invalid id: {!r}".format(
                    index, scenario_id
                )
            )
        if scenario_id in seen:
            raise BatchError(
                "catalog contains duplicate scenario id: {}".format(scenario_id)
            )
        seen.add(scenario_id)
        budget = scenario.get("budget")
        if not isinstance(budget, dict):
            raise BatchError(
                "catalog scenario {} has no budget object".format(scenario_id)
            )
        for key in ("max_minutes", "max_model_requests"):
            value = budget.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise BatchError(
                    "catalog scenario {} budget.{} must be a positive integer".format(
                        scenario_id, key
                    )
                )
    return document


def catalog_ids(document):
    return [scenario["id"] for scenario in document["scenarios"]]


def scenario_by_id(document):
    return {scenario["id"]: scenario for scenario in document["scenarios"]}


def _referenced_fixtures(document):
    names = set()
    for fixture in document.get("fixtures") or []:
        if isinstance(fixture, dict) and isinstance(fixture.get("name"), str):
            names.add(fixture["name"])
    for scenario in document.get("scenarios") or []:
        workspace = scenario.get("workspace")
        if isinstance(workspace, dict) and isinstance(workspace.get("fixture"), str):
            names.add(workspace["fixture"])
    return names


def default_fixtures_root(repo_root):
    """The fixture root under a checkout with the canonical runner layout."""

    return Path(repo_root).resolve() / "scripts" / "ci" / "scenarios" / "fixtures"


def runner_source_root(scenarios_script=None):
    """The source checkout the resolved runner builds and runs.

    ``scenarios.sh`` computes ``$ROOT="$(cd "$HERE/../.." && pwd)"`` and then
    ``cd "$ROOT"`` before ``swift test``/``xcodebuild``.  The batch therefore
    cannot execute a script from one checkout while receipting another
    checkout's source and pin.
    """

    script = Path(scenarios_script or DEFAULT_SCENARIOS).resolve()
    return script.parent.parent.parent.resolve()


def runner_source_provenance(repo_root, scenarios_script=None):
    """Whether the runner's source checkout is the receipted ``--repo-root``."""

    repo_root = Path(repo_root).resolve()
    script = Path(scenarios_script or DEFAULT_SCENARIOS).resolve()
    source_root = runner_source_root(script)
    return {
        "repo_root": str(repo_root),
        "scenario_repo": str(source_root),
        "scenario_script": str(script),
        "same_repo": source_root == repo_root,
    }


def _require_same_runner_source(repo_root, scenarios_script=None):
    provenance = runner_source_provenance(repo_root, scenarios_script)
    if provenance["same_repo"]:
        return provenance
    raise BatchError(
        "--scenarios-script {!r} resolves its runner source repo to {!r}, but "
        "--repo-root is {!r}; the child builds and runs the script's checkout, "
        "so source/pin receipts would describe a different tree.  Use the "
        "same checkout for both, or use `plan` for a plan-only view (which is "
        "explicitly not executable)".format(
            provenance["scenario_script"],
            provenance["scenario_repo"],
            provenance["repo_root"],
        )
    )


def runner_fixtures_root(scenarios_script=None):
    """The fixture root the resolved runner actually consumes.

    ``scenarios.sh`` computes its repository root from its own location
    (``HERE/../..``) and always seeds
    ``<script-repo>/scripts/ci/scenarios/fixtures``.  Deriving that path from
    ``--repo-root`` is wrong when ``--scenarios-script`` points at a checkout
    in another directory, so derive it from the resolved script instead.  The
    formula mirrors the runner exactly for any script path, not only the
    canonical ``scripts/ci/scenarios.sh`` layout: a script at
    ``<root>/tools/runner/scenarios.sh`` has ``$ROOT=<root>`` and therefore
    reads ``<root>/scripts/ci/scenarios/fixtures``, not
    ``<root>/tools/runner/scenarios/fixtures``.
    """

    script = Path(scenarios_script or DEFAULT_SCENARIOS).resolve()
    return (
        script.parent.parent.parent
        / "scripts"
        / "ci"
        / "scenarios"
        / "fixtures"
    )


def fixture_root_provenance(
    fixtures_root=None, repo_root=None, scenarios_script=None
):
    """Describe whether a fixture root is the runner's or planning-only."""

    if scenarios_script is not None or repo_root is None:
        runner_root = runner_fixtures_root(scenarios_script)
    else:
        # Backwards-compatible fallback for callers that only know a checkout.
        runner_root = default_fixtures_root(repo_root)
    runner_root = Path(runner_root).resolve()
    if fixtures_root is None:
        return {
            "root": str(runner_root),
            "source": "runner-default",
            "runner_consumes": True,
            "explicit": False,
            "runner_root": str(runner_root),
        }
    selected = Path(fixtures_root).resolve()
    consumes = selected == runner_root
    return {
        "root": str(selected),
        "source": "runner-default" if consumes else "plan-only",
        "runner_consumes": consumes,
        "explicit": True,
        "runner_root": str(runner_root),
    }


def _require_executable_fixture_root(
    repo_root, fixtures_root, scenarios_script=None
):
    """Refuse a fixture root the real runner would not consume."""

    provenance = fixture_root_provenance(
        fixtures_root, repo_root=repo_root, scenarios_script=scenarios_script
    )
    if provenance["runner_consumes"]:
        return provenance
    raise BatchError(
        "--fixtures-root {!r} is plan-only: scripts/ci/scenarios.sh always "
        "seeds {!r} for the resolved --scenarios-script and has no "
        "fixture-root argument, so run/resume refuse to hash bytes the runner "
        "would not use; omit --fixtures-root or use `plan` to inspect a "
        "candidate root".format(
            provenance["root"], provenance.get("runner_root")
        )
    )


def catalog_identity(
    path, document, fixtures_root=None, repo_root=None, scenarios_script=None
):
    """Identity of the catalog and the fixture payloads it references.

    ``fixtures_root`` is only an execution identity when it is the runner's
    fixed root.  A custom root is a plan-only input; receipts are never built
    from it because ``run``/``resume`` reject it before any child starts.
    """

    path = Path(path).resolve()
    raw_sha256 = sha256_file(path)
    semantic = {
        key: document.get(key)
        for key in ("version", "scenarios", "fixtures")
        if key in document
    }
    semantic_sha256 = canonical_sha256(semantic)
    provenance = fixture_root_provenance(
        fixtures_root, repo_root=repo_root, scenarios_script=scenarios_script
    )
    fixtures_root = Path(provenance["root"])
    fixtures = {}
    for name in sorted(_referenced_fixtures(document)):
        directory = fixtures_root / name
        if not directory.is_dir():
            raise BatchError(
                "catalog references fixture {!r} but {} is not a directory".format(
                    name, directory
                )
            )
        fixtures[name] = hash_tree(directory)
    return {
        "sha256": raw_sha256,
        "semantic_sha256": semantic_sha256,
        "fixture_root": str(fixtures_root),
        "fixture_root_source": provenance["source"],
        "fixture_root_runner_consumes": provenance["runner_consumes"],
        "fixtures_sha256": fixtures,
        "fixture_count": len(fixtures),
    }


# ------------------------------------------------------------------ identity


def _git(repo_root, arguments, text=True):
    command = ["git", "-C", str(repo_root)] + list(arguments)
    try:
        result = subprocess.run(command, capture_output=True, text=text)
    except OSError as exc:
        raise BatchError("cannot run git: {}".format(exc)) from exc
    if result.returncode != 0:
        stderr = result.stderr
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", "replace")
        raise BatchError(
            "git {} failed: {}".format(" ".join(arguments), redact_text(stderr.strip()))
        )
    return result.stdout


def source_identity(repo_root):
    """The commit plus a content fingerprint of its tracked working tree.

    The commit SHA alone is not enough for an explicit resume: a dirty tree at
    the same commit is different source.  ``fingerprint`` covers the binary
    diff, so the same dirty content fingerprints identically while any edit is
    a mismatch.  Untracked files are deliberately outside the source identity;
    the scenarios, fixtures and runner scripts are tracked.
    """

    repo_root = Path(repo_root).resolve()
    commit = str(_git(repo_root, ["rev-parse", "HEAD"])).strip()
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise BatchError("git rev-parse HEAD returned an unusable source SHA")
    status = str(
        _git(repo_root, ["status", "--porcelain", "--untracked-files=no"])
    ).strip()
    diff = _git(repo_root, ["diff", "--binary", "HEAD"], text=False)
    tree_sha256 = sha256_bytes(diff if isinstance(diff, bytes) else diff.encode())
    dirty = bool(status) or bool(diff)
    fingerprint = canonical_sha256(
        {"commit": commit, "dirty": dirty, "tree_sha256": tree_sha256}
    )
    return {
        "sha": commit,
        "dirty": dirty,
        "tree_sha256": tree_sha256,
        "fingerprint": fingerprint,
    }


def _credential_context(env):
    """Non-secret tenant/deployment identity, or an explicit ``unknown``.

    A key itself cannot tell whether a rotated key still addresses the same
    tenant.  An operator may pin a non-secret configuration identity for that
    boundary; without it a real run is still valid, but an explicit resume must
    not reuse an earlier PASS.
    """

    raw = env.get(MODEL_CONFIG_ID_ENV)
    if raw is None or raw == "":
        return {
            "source": "unknown",
            "resume_reusable": False,
            "detail": "set {} to a non-secret tenant/deployment id to allow "
            "PASS reuse".format(MODEL_CONFIG_ID_ENV),
        }
    value = str(raw)
    if not MODEL_CONFIG_ID_RE.fullmatch(value):
        raise BatchError(
            "{} must be a non-secret id of 1-128 characters "
            "[A-Za-z0-9._:/@+-], starting with an alphanumeric character".format(
                MODEL_CONFIG_ID_ENV
            )
        )
    for name in CREDENTIAL_ENV_NAMES:
        secret = env.get(name)
        if isinstance(secret, str) and secret and secret in value:
            raise BatchError(
                "{} appears to contain a credential value; it must be a "
                "non-secret tenant/deployment id".format(MODEL_CONFIG_ID_ENV)
            )
    return {
        "source": "explicit",
        "config_id": value,
        "resume_reusable": True,
    }


def model_identity(upstream, env=None):
    """Provider identity without the credential value or a key digest."""

    env = os.environ if env is None else env
    if upstream == "mock":
        return {"upstream": "mock", "fingerprint": canonical_sha256({"upstream": "mock"})}
    if upstream != "real":
        raise BatchError("upstream must be mock or real")
    # The identity only checks presence; the credential value is not stored in
    # metadata.  (The log redactor reads recognized env values separately and
    # keeps them in memory only.)  The runner performs the non-empty check.
    missing = []
    for name in MODEL_ENV:
        if name == "PDSH_MODEL_API_KEY":
            if name not in env:
                missing.append(name)
        elif not env.get(name):
            missing.append(name)
    if missing:
        raise BatchError(
            "--upstream real requires {}; run: eval \"$(node "
            "scripts/ci/model-env.mjs)\"".format(", ".join(missing))
        )
    base_url = str(env["PDSH_MODEL_BASE_URL"])
    identity = {
        "upstream": "real",
        "name": str(env["PDSH_MODEL_NAME"]),
        "base_url": safe_url(base_url, env=env),
        "base_url_sha256": sha256_bytes(
            _safe_endpoint_url(base_url, env=env).encode("utf-8")
        ),
        "credential_context": _credential_context(env),
    }
    identity["fingerprint"] = canonical_sha256(identity)
    return identity


def _normalized_simulators(simulators):
    return [
        str(item).strip()
        for item in (simulators or [])
        if str(item).strip()
    ]


def _child_path(value, repo_root):
    """Resolve a child-visible path the way ``scenarios.sh`` does from cwd."""

    path = Path(str(value))
    if not path.is_absolute():
        path = Path(repo_root) / path
    return path.resolve()


def runner_asset_paths(repo_root, env=None):
    """The exact bundle/image/Python/JQ paths the child will consume.

    This mirrors ``scenarios.sh``'s own resolution: relative environment paths
    are relative to the directory the batch starts the child in (the repo
    root), ``PDSH_SCENARIO_BUILD_DIR`` wins over its ``$TMPDIR`` default, and
    the image defaults to ``$WWW/image.tar.gz``.
    """

    env = os.environ if env is None else env
    repo_root = Path(repo_root).resolve()
    base = str(env.get("TMPDIR") or "/tmp")
    base = base.rstrip("/") or "/"
    build_value = env.get("PDSH_SCENARIO_BUILD_DIR")
    if build_value:
        build_dir = _child_path(build_value, repo_root)
    else:
        build_dir = _child_path(Path(base) / "pdsh-scenarios-build", repo_root)
    www_value = env.get("PDSH_DSH_WWW")
    if www_value:
        www = _child_path(www_value, repo_root)
    else:
        www = build_dir / "www"
    image_value = env.get("PDSH_DSH_IMAGE")
    if image_value:
        image = _child_path(image_value, repo_root)
    else:
        image = www / "image.tar.gz"
    python_value = env.get("PDSH_PYTHON_ARTIFACTS")
    if python_value:
        python_dir = _child_path(python_value, repo_root)
    else:
        python_dir = _child_path(Path(base) / "pdsh-python-wasi", repo_root)
    jq_value = env.get("PDSH_JQ_ARTIFACTS")
    if jq_value:
        jq_dir = _child_path(jq_value, repo_root)
    else:
        jq_dir = _child_path(Path(base) / "pdsh-jq-wasi", repo_root)
    return {
        "build_dir": build_dir,
        "bundle": www,
        "image": image,
        "python": python_dir,
        "jq": jq_dir,
    }


def _bundle_identity(path):
    path = Path(path)
    if not path.is_dir():
        return {
            "path": str(path),
            "sha256": None,
            "file_count": 0,
            "present": False,
            "missing": ["bundle directory {}".format(path)],
        }
    digest, count = hash_file_tree(path)
    missing = []
    if count == 0:
        missing.append("bundle files under {}".format(path))
    for name in BUNDLE_REQUIRED_FILES:
        item = path / name
        if not item.is_file():
            missing.append("bundle file {}".format(item))
        elif item.stat().st_size <= 0:
            missing.append("empty bundle file {}".format(item))
    return {
        "path": str(path),
        "sha256": digest,
        "file_count": count,
        "present": not missing,
        "missing": missing,
    }


def _file_identity(path, label):
    path = Path(path)
    if not path.is_file():
        return {
            "path": str(path),
            "sha256": None,
            "present": False,
            "missing": ["{} {}".format(label, path)],
        }
    if path.stat().st_size <= 0:
        return {
            "path": str(path),
            "sha256": None,
            "present": False,
            "missing": ["empty {} {}".format(label, path)],
        }
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "present": True,
        "missing": [],
    }


def _artifact_identity(directory, names, label):
    directory = Path(directory)
    files = {}
    missing = []
    for name in names:
        item = directory / name
        if not item.is_file():
            missing.append("{} {}".format(label, item))
        elif item.stat().st_size <= 0:
            missing.append("empty {} {}".format(label, item))
        else:
            files[name] = {"path": str(item), "sha256": sha256_file(item)}
    combined = None
    if not missing:
        digest = hashlib.sha256()
        for name in names:
            with open(directory / name, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
        combined = digest.hexdigest()
    return {
        "path": str(directory),
        "files": files,
        "sha256": combined,
        "present": not missing,
        "missing": missing,
    }


def _not_consumed_artifact_identity(directory):
    """Python/JQ bytes are irrelevant on the prebuilt bundle/image branch."""

    return {
        "path": str(directory),
        "files": {},
        "sha256": None,
        "present": False,
        "consumed": False,
        "missing": [],
        "reason": "scripts/ci/scenarios.sh uses the supplied "
        "PDSH_DSH_WWW/PDSH_DSH_IMAGE prebuilt pair and does not read "
        "PDSH_PYTHON_ARTIFACTS/PDSH_JQ_ARTIFACTS",
    }


def engine_asset_identity(repo_root, env=None):
    """Content identity of every build artifact the real child consumes.

    ``scenarios.sh`` takes the prebuilt pair branch when both
    ``PDSH_DSH_WWW`` and ``PDSH_DSH_IMAGE`` are supplied: it validates those
    bytes and never reads the external Python/JQ directories.  Otherwise it
    uses the build cache, whose freshness check and rebuild both read the
    Python/JQ pairs, so those are required there.  A real batch is not allowed
    to hash an empty/absent asset tree and then run a different one:
    ``run``/``resume`` require this identity to be complete before the first
    child starts.  ``plan`` records the same structure (with
    ``present=false``/``missing``) so a plan-only view can explain why it is
    not executable.
    """

    env = os.environ if env is None else env
    paths = runner_asset_paths(repo_root, env)
    www_supplied = bool(env.get("PDSH_DSH_WWW"))
    image_supplied = bool(env.get("PDSH_DSH_IMAGE"))
    prebuilt = www_supplied and image_supplied
    bundle = _bundle_identity(paths["bundle"])
    image = _file_identity(paths["image"], "image")
    if prebuilt:
        python = _not_consumed_artifact_identity(paths["python"])
        jq = _not_consumed_artifact_identity(paths["jq"])
    else:
        python = _artifact_identity(
            paths["python"], ("python.wasm", "python313.zip"), "python artifact"
        )
        jq = _artifact_identity(
            paths["jq"], ("jq.wasm", "engine.json"), "jq artifact"
        )
    missing = []
    if www_supplied != image_supplied:
        missing.append(
            "PDSH_DSH_WWW and PDSH_DSH_IMAGE must be supplied together"
        )
    for component in (bundle, image, python, jq):
        missing.extend(component.get("missing") or [])
    return {
        "mode": "prebuilt" if prebuilt else "build-cache",
        "build_dir": str(paths["build_dir"]),
        "bundle": bundle,
        "image": image,
        "python": python,
        "jq": jq,
        "missing": missing,
        "complete": not missing,
    }


def _engine_execution_errors(engine):
    """Why this engine identity cannot be executed/reused truthfully."""

    if not isinstance(engine, dict):
        return ["engine identity is missing"]
    errors = []
    if not engine.get("same_source_repo"):
        errors.append(
            "runner source repo {!r} differs from --repo-root {!r}".format(
                engine.get("scenario_repo"), engine.get("source_repo")
            )
        )
    assets = engine.get("assets")
    if not isinstance(assets, dict):
        return errors + ["engine identity has no bundle/image/artifact digests"]
    if not assets.get("complete"):
        missing = assets.get("missing") or ["unknown artifact"]
        errors.append(
            "engine assets are missing or empty: {}".format(", ".join(missing))
        )
    for key in ("bundle", "image"):
        component = assets.get(key)
        if not isinstance(component, dict) or not component.get("present"):
            errors.append("engine {} identity is incomplete".format(key))
    for key in ("python", "jq"):
        component = assets.get(key)
        if isinstance(component, dict) and component.get("consumed") is False:
            continue
        if not isinstance(component, dict) or not component.get("present"):
            errors.append("engine {} identity is incomplete".format(key))
    if not engine.get("dsh_pin_sha256"):
        errors.append("plugins/dsh-pin.json is missing")
    return errors


def _require_executable_engine(engine):
    errors = _engine_execution_errors(engine)
    if errors:
        raise BatchError(
            "execution provenance is not complete: {}.  Build/verify the "
            "assets first and pass PDSH_DSH_WWW/PDSH_DSH_IMAGE (plus "
            "PDSH_PYTHON_ARTIFACTS/PDSH_JQ_ARTIFACTS when they are not in "
            "their default dirs); `plan` remains a non-executable view".format(
                "; ".join(errors)
            )
        )


def _engine_current_errors(engine):
    """Recompute recorded engine paths and report any current mismatch."""

    errors = _engine_execution_errors(engine)
    if errors:
        return errors
    script = engine.get("scenario_script")
    if not script or not Path(script).is_file():
        errors.append("scenario runner is missing: {}".format(script))
    elif sha256_file(Path(script)) != engine.get("scenario_script_sha256"):
        errors.append("scenario runner changed since the batch was planned")
    pin = (engine.get("assets") or {}).get("pin") or {}
    pin_path = pin.get("path")
    if not pin_path or not Path(pin_path).is_file():
        errors.append("plugins/dsh-pin.json is missing")
    elif sha256_file(Path(pin_path)) != engine.get("dsh_pin_sha256"):
        errors.append("plugins/dsh-pin.json changed since the batch was planned")
    assets = engine.get("assets") or {}
    bundle = assets.get("bundle") or {}
    bundle_path = bundle.get("path")
    if not bundle_path or not Path(bundle_path).is_dir():
        errors.append("Worker bundle is missing: {}".format(bundle_path))
    else:
        current_bundle, _count = hash_file_tree(Path(bundle_path))
        if current_bundle != bundle.get("sha256"):
            errors.append("Worker bundle changed since the batch was planned")
    image = assets.get("image") or {}
    image_path = image.get("path")
    if (
        not image_path
        or not Path(image_path).is_file()
        or Path(image_path).stat().st_size <= 0
        or sha256_file(Path(image_path)) != image.get("sha256")
    ):
        errors.append("Worker image changed since the batch was planned")
    for key, names in (
        ("python", ("python.wasm", "python313.zip")),
        ("jq", ("jq.wasm", "engine.json")),
    ):
        recorded = assets.get(key) or {}
        if recorded.get("consumed") is False:
            continue
        recorded_path = recorded.get("path")
        if not recorded_path or not Path(recorded_path).is_dir():
            errors.append(
                "{} artifacts are missing: {}".format(key, recorded_path)
            )
            continue
        current = _artifact_identity(
            Path(recorded_path), names, "{} artifact".format(key)
        )
        if not current.get("present") or current.get("sha256") != recorded.get("sha256"):
            errors.append("{} artifacts changed since the batch was planned".format(key))
    return errors


def _runtime_provenance_errors(
    identity, repo_root, catalog_path, fixtures_root=None, scenarios_script=None
):
    """Recompute source/catalog/fixture/engine identity after lanes exit.

    A child may rewrite a tracked source file, the catalog, or a fixture while
    it runs.  Rebuilding the identity only after the fact would let the receipt
    describe bytes the run did not consume, so any change must block every
    receipt for this invocation.
    """

    errors = []
    source = identity.get("source") or {}
    try:
        current_source = source_identity(repo_root)
    except BatchError as exc:
        errors.append(
            "source identity cannot be recomputed after the run: {}".format(exc)
        )
    else:
        if current_source.get("fingerprint") != source.get("fingerprint"):
            errors.append("source changed while the batch was running")

    catalog = identity.get("catalog") or {}
    try:
        document = load_catalog(catalog_path)
        current_catalog = catalog_identity(
            catalog_path,
            document,
            fixtures_root=fixtures_root,
            repo_root=repo_root,
            scenarios_script=scenarios_script,
        )
    except (BatchError, OSError) as exc:
        errors.append(
            "catalog identity cannot be recomputed after the run: {}".format(exc)
        )
    else:
        if current_catalog.get("sha256") != catalog.get("sha256"):
            errors.append("catalog changed while the batch was running")
        if current_catalog.get("fixtures_sha256") != catalog.get("fixtures_sha256"):
            errors.append("fixture payload changed while the batch was running")
        if (
            current_catalog.get("fixture_root") != catalog.get("fixture_root")
            or current_catalog.get("fixture_root_source")
            != catalog.get("fixture_root_source")
        ):
            errors.append("fixture root changed while the batch was running")

    errors.extend(_engine_current_errors(identity.get("engine")))
    return errors


def engine_identity(
    repo_root, run_on, scenarios_script, simulators=None, env=None
):
    repo_root = Path(repo_root).resolve()
    pin = repo_root / "plugins" / "dsh-pin.json"
    script = Path(scenarios_script).resolve()
    if not script.is_file():
        raise BatchError("scenario runner not found: {}".format(script))
    simulator_values = _normalized_simulators(simulators)
    source = runner_source_provenance(repo_root, script)
    pin_identity = _file_identity(pin, "DSH pin")
    assets = engine_asset_identity(repo_root, env)
    assets["pin"] = pin_identity
    if not pin_identity["present"]:
        assets["missing"] = list(assets.get("missing") or []) + pin_identity["missing"]
        assets["complete"] = False
    identity = {
        "run_on": run_on,
        "simulators": simulator_values,
        "source_repo": source["repo_root"],
        "scenario_repo": source["scenario_repo"],
        "scenario_script": str(script),
        "same_source_repo": source["same_repo"],
        "dsh_pin_sha256": pin_identity.get("sha256"),
        "scenario_script_sha256": sha256_file(script),
        "assets": assets,
    }
    identity["execution_provenance"] = {
        "same_source_repo": identity["same_source_repo"],
        "assets_complete": bool(assets.get("complete")),
        "ready": bool(
            identity["same_source_repo"] and assets.get("complete")
        ),
    }
    identity["fingerprint"] = canonical_sha256(
        {
            "run_on": identity["run_on"],
            "simulators": identity["simulators"],
            "source_repo": identity["source_repo"],
            "scenario_repo": identity["scenario_repo"],
            "scenario_script": identity["scenario_script"],
            "scenario_script_sha256": identity["scenario_script_sha256"],
            "dsh_pin_sha256": identity["dsh_pin_sha256"],
            "assets": {
                "mode": assets.get("mode"),
                "build_dir": assets.get("build_dir"),
                "bundle": assets["bundle"].get("sha256"),
                "image": assets["image"].get("sha256"),
                "python": assets["python"].get("sha256"),
                "jq": assets["jq"].get("sha256"),
            },
        }
    )
    return identity


def build_identity(
    repo_root,
    catalog_path,
    run_on,
    upstream,
    env=None,
    fixtures_root=None,
    scenarios_script=None,
    document=None,
    simulators=None,
):
    repo_root = Path(repo_root).resolve()
    catalog_path = Path(catalog_path).resolve()
    document = document if document is not None else load_catalog(catalog_path)
    script = scenarios_script or DEFAULT_SCENARIOS
    identity = {
        "version": BATCH_VERSION,
        "source": source_identity(repo_root),
        "catalog": catalog_identity(
            catalog_path,
            document,
            fixtures_root,
            repo_root=repo_root,
            scenarios_script=script,
        ),
        "model": model_identity(upstream, env),
        "engine": engine_identity(
            repo_root, run_on, script, simulators=simulators, env=env
        ),
    }
    identity["fingerprint"] = canonical_sha256(
        {
            "source": identity["source"]["fingerprint"],
            "catalog": identity["catalog"]["sha256"],
            "fixtures": identity["catalog"]["fixtures_sha256"],
            "fixture_root_source": identity["catalog"]["fixture_root_source"],
            "model": identity["model"]["fingerprint"],
            "engine": identity["engine"]["fingerprint"],
        }
    )
    return identity


# ----------------------------------------------------------------------- plan


def _scenario_part(scenario_id):
    if scenario_id.startswith("G2-") and len(scenario_id) > 3:
        return scenario_id[3]
    return scenario_id[:1]


def _check_declared(actual, declared, label):
    if declared is not None and declared != actual:
        raise BatchError(
            "run_plan {} is {!r} but the catalog computes {!r}".format(
                label, declared, actual
            )
        )


def validate_run_plan_metadata(document):
    """Fail when the machine-readable run_plan drifts from the catalog."""

    run_plan = document.get("run_plan")
    if not isinstance(run_plan, dict):
        return
    scenarios = document["scenarios"]
    total_minutes = sum(item["budget"]["max_minutes"] for item in scenarios)
    total_requests = sum(item["budget"]["max_model_requests"] for item in scenarios)
    normal = [item for item in scenarios if _scenario_part(item["id"]) != "D"]
    long_run = [item for item in scenarios if _scenario_part(item["id"]) == "D"]
    normal_minutes = sum(item["budget"]["max_minutes"] for item in normal)
    normal_requests = sum(item["budget"]["max_model_requests"] for item in normal)
    long_minutes = sum(item["budget"]["max_minutes"] for item in long_run)
    long_requests = sum(item["budget"]["max_model_requests"] for item in long_run)
    by_part = {}
    for item in scenarios:
        part = _scenario_part(item["id"])
        by_part[part] = by_part.get(part, 0) + 1

    inventory = run_plan.get("inventory")
    if isinstance(inventory, dict):
        _check_declared(len(scenarios), inventory.get("scenarios"), "inventory.scenarios")
        _check_declared(
            len(document.get("fixtures") or []),
            inventory.get("fixtures"),
            "inventory.fixtures",
        )
        _check_declared(by_part, inventory.get("by_part"), "inventory.by_part")
        _check_declared(
            len(normal), inventory.get("normal_scenarios"), "inventory.normal_scenarios"
        )
        _check_declared(
            len(long_run),
            inventory.get("long_run_scenarios"),
            "inventory.long_run_scenarios",
        )

    budget = run_plan.get("budget")
    if isinstance(budget, dict):
        _check_declared(total_minutes, budget.get("serial_max_minutes"), "budget.serial_max_minutes")
        _check_declared(
            total_requests,
            budget.get("serial_max_model_requests"),
            "budget.serial_max_model_requests",
        )
        _check_declared(
            normal_minutes, budget.get("normal_50_max_minutes"), "budget.normal_50_max_minutes"
        )
        _check_declared(
            normal_requests,
            budget.get("normal_50_max_model_requests"),
            "budget.normal_50_max_model_requests",
        )
        _check_declared(
            long_minutes, budget.get("long_run_6_max_minutes"), "budget.long_run_6_max_minutes"
        )
        _check_declared(
            long_requests,
            budget.get("long_run_6_max_model_requests"),
            "budget.long_run_6_max_model_requests",
        )
        largest = max(
            scenarios,
            key=lambda item: (
                item["budget"]["max_minutes"],
                item["budget"]["max_model_requests"],
            ),
        )
        declared_largest = budget.get("largest_scenario")
        if isinstance(declared_largest, dict):
            actual_largest = {
                "id": largest["id"],
                "max_minutes": largest["budget"]["max_minutes"],
                "max_model_requests": largest["budget"]["max_model_requests"],
            }
            _check_declared(actual_largest, declared_largest, "budget.largest_scenario")

    lane_plan = run_plan.get("lane_plan")
    declared_lane_budget = (run_plan.get("macos_pass") or {}).get("lane_budget")
    if isinstance(lane_plan, list) and isinstance(declared_lane_budget, dict):
        by_id = {item["id"]: item for item in scenarios}
        for lane in lane_plan:
            if not isinstance(lane, dict) or not isinstance(lane.get("id"), str):
                continue
            ids = lane.get("scenario_ids")
            if not isinstance(ids, list) or any(item not in by_id for item in ids):
                continue
            actual = {
                "max_minutes": sum(
                    by_id[item]["budget"]["max_minutes"] for item in ids
                ),
                "max_model_requests": sum(
                    by_id[item]["budget"]["max_model_requests"] for item in ids
                ),
            }
            _check_declared(
                actual,
                declared_lane_budget.get(lane["id"]),
                "macos_pass.lane_budget.{}".format(lane["id"]),
            )

    categories = run_plan.get("time_budget_by_category_minutes")
    if isinstance(categories, dict):
        category_totals = {}
        for item in scenarios:
            category = item.get("category")
            if isinstance(category, str):
                category_totals[category] = category_totals.get(category, 0) + item[
                    "budget"
                ]["max_minutes"]
        for category, declared in categories.items():
            if category in category_totals:
                _check_declared(
                    category_totals[category],
                    declared,
                    "time_budget_by_category_minutes.{}".format(category),
                )
        if "总计串行" in categories:
            _check_declared(
                total_minutes,
                categories.get("总计串行"),
                "time_budget_by_category_minutes.总计串行",
            )
    request_budget = run_plan.get("model_request_budget")
    if isinstance(request_budget, dict):
        _check_declared(
            total_requests,
            request_budget.get("catalog_total"),
            "model_request_budget.catalog_total",
        )
        _check_declared(
            normal_requests,
            request_budget.get("normal_50"),
            "model_request_budget.normal_50",
        )
        _check_declared(
            long_requests,
            request_budget.get("long_run_6"),
            "model_request_budget.long_run_6",
        )


def _scenario_budget(document, scenario_id):
    scenario = scenario_by_id(document)[scenario_id]
    return (
        scenario["budget"]["max_minutes"],
        scenario["budget"]["max_model_requests"],
    )


def _lane_budget(document, ids):
    minutes = sum(_scenario_budget(document, scenario_id)[0] for scenario_id in ids)
    requests = sum(_scenario_budget(document, scenario_id)[1] for scenario_id in ids)
    return {"max_minutes": minutes, "max_model_requests": requests}


def _balanced_partition(document, count):
    """Deterministic cost-balanced lanes; no scenario-id special cases."""

    if count < 1:
        raise BatchError("--lanes must be at least 1")
    order = list(enumerate(document["scenarios"]))
    order.sort(
        key=lambda item: (
            -item[1]["budget"]["max_minutes"],
            -item[1]["budget"]["max_model_requests"],
            item[0],
        )
    )
    bins = [{"ids": [], "minutes": 0, "requests": 0} for _ in range(count)]
    for _index, scenario in order:
        target = min(
            bins,
            key=lambda lane: (lane["minutes"], lane["requests"], len(lane["ids"])),
        )
        target["ids"].append(scenario["id"])
        target["minutes"] += scenario["budget"]["max_minutes"]
        target["requests"] += scenario["budget"]["max_model_requests"]
    catalog_order = {scenario["id"]: index for index, scenario in enumerate(document["scenarios"])}
    return [
        {
            "id": "lane-{}".format(number + 1),
            "scenario_ids": sorted(lane["ids"], key=lambda item: catalog_order[item]),
        }
        for number, lane in enumerate(bins)
    ]


def _validated_lane_sets(document, all_ids):
    """Use the catalog's machine-readable lane plan when it has one."""

    run_plan = document.get("run_plan")
    if not isinstance(run_plan, dict):
        return None
    lane_plan = run_plan.get("lane_plan")
    if lane_plan is None:
        return None
    if not isinstance(lane_plan, list) or not lane_plan:
        raise BatchError("run_plan.lane_plan must be a non-empty list")
    result = []
    seen_lanes = set()
    seen_scenarios = set()
    for index, lane in enumerate(lane_plan):
        if not isinstance(lane, dict):
            raise BatchError("run_plan.lane_plan[{}] is not an object".format(index))
        lane_id = lane.get("id")
        if (
            not isinstance(lane_id, str)
            or not LANE_ID_RE.fullmatch(lane_id)
            or lane_id in (".", "..")
        ):
            raise BatchError(
                "run_plan.lane_plan[{}] has an invalid id: {!r}".format(index, lane_id)
            )
        if lane_id in seen_lanes:
            raise BatchError("run_plan.lane_plan has duplicate lane id: {}".format(lane_id))
        seen_lanes.add(lane_id)
        ids = lane.get("scenario_ids")
        if not isinstance(ids, list) or not ids:
            raise BatchError(
                "run_plan.lane_plan[{}] has no scenario_ids list".format(index)
            )
        for scenario_id in ids:
            if not isinstance(scenario_id, str) or scenario_id not in all_ids:
                raise BatchError(
                    "run_plan.lane_plan[{}] names an unknown scenario: {!r}".format(
                        index, scenario_id
                    )
                )
            if scenario_id in seen_scenarios:
                raise BatchError(
                    "run_plan.lane_plan lists scenario {} more than once".format(
                        scenario_id
                    )
                )
            seen_scenarios.add(scenario_id)
        result.append({"id": lane_id, "scenario_ids": list(ids)})
    missing = sorted(set(all_ids) - seen_scenarios)
    if missing:
        raise BatchError(
            "run_plan.lane_plan omits {} catalog scenario(s): {}".format(
                len(missing), ", ".join(missing)
            )
        )
    return result


def build_plan(
    catalog_path,
    repo_root,
    batch_dir,
    run_on="macos",
    upstream="mock",
    lanes=None,
    simulators=None,
    env=None,
    fixtures_root=None,
    scenarios_script=None,
    identity=None,
):
    """Build the exact, duplicate-free lane plan for the current catalog."""

    repo_root = Path(repo_root).resolve()
    catalog_path = Path(catalog_path).resolve()
    batch_dir = Path(batch_dir).resolve()
    for unsafe in (Path("/"), Path.home().resolve(), repo_root):
        if batch_dir == unsafe:
            raise BatchError("refusing unsafe batch directory: {}".format(batch_dir))
    document = load_catalog(catalog_path)
    validate_run_plan_metadata(document)
    all_ids = catalog_ids(document)
    all_id_set = set(all_ids)
    lane_sets = _validated_lane_sets(document, all_id_set)
    if lanes is not None:
        lane_sets = _balanced_partition(document, lanes)
    if lane_sets is None:
        lane_sets = _balanced_partition(document, 2)

    lane_scenarios = set()
    for lane in lane_sets:
        for scenario_id in lane["scenario_ids"]:
            if scenario_id in lane_scenarios:
                raise BatchError(
                    "lane plan lists scenario {} more than once".format(scenario_id)
                )
            lane_scenarios.add(scenario_id)
    if lane_scenarios != all_id_set:
        missing = sorted(all_id_set - lane_scenarios)
        extra = sorted(lane_scenarios - all_id_set)
        raise BatchError(
            "lane plan is not the catalog: missing={} extra={}".format(missing, extra)
        )

    simulators = list(simulators or [])
    if run_on == "sim":
        if simulators:
            if len(simulators) < len(lane_sets):
                raise BatchError(
                    "{} simulator(s) were supplied for {} lane(s); every lane must "
                    "own a distinct simulator".format(len(simulators), len(lane_sets))
                )
            if len(set(simulators)) != len(simulators):
                raise BatchError("--simulators must name distinct simulators")
        elif len(lane_sets) > 1:
            raise BatchError(
                "{} simulator lanes need --simulators with one distinct simulator "
                "per lane".format(len(lane_sets))
            )
    if run_on not in ("macos", "sim"):
        raise BatchError("--run-on must be macos or sim")
    if upstream not in ("mock", "real"):
        raise BatchError("--upstream must be mock or real")

    identity = identity or build_identity(
        repo_root,
        catalog_path,
        run_on,
        upstream,
        env=env,
        fixtures_root=fixtures_root,
        scenarios_script=scenarios_script,
        document=document,
        simulators=simulators,
    )
    script = Path(
        (identity.get("engine") or {}).get("scenario_script") or scenarios_script
        or DEFAULT_SCENARIOS
    ).resolve()

    lanes_out = []
    seen_results = set()
    seen_work = set()
    seen_sim = set()
    for index, lane in enumerate(lane_sets):
        lane_id = lane["id"]
        ids = list(lane["scenario_ids"])
        lane_dir = batch_dir / lane_id
        results_dir = lane_dir / "results"
        work_dir = lane_dir / "work"
        sim_dir = lane_dir / "sim"
        for candidate, seen, label in (
            (results_dir, seen_results, "results"),
            (work_dir, seen_work, "work"),
            (sim_dir, seen_sim, "sim"),
        ):
            normalized = str(candidate.resolve())
            if normalized in seen:
                raise BatchError(
                    "lane {} reuses another lane's {} directory: {}".format(
                        lane_id, label, candidate
                    )
                )
            seen.add(normalized)
        lanes_out.append(
            {
                "id": lane_id,
                "scenario_ids": ids,
                "scenario_count": len(ids),
                "budget": _lane_budget(document, ids),
                "results_dir": str(results_dir),
                "work_dir": str(work_dir),
                "sim_dir": str(sim_dir),
                "simulator": simulators[index] if run_on == "sim" and simulators else None,
                "log": str(work_dir / "scenarios.log"),
            }
        )

    engine = identity.get("engine") or {}
    engine_errors = _engine_execution_errors(engine)
    fixture_ready = bool(
        identity["catalog"].get("fixture_root_runner_consumes")
    )
    blocked_reasons = []
    if not fixture_ready:
        blocked_reasons.append(
            "fixture root {!r} is plan-only; the resolved runner consumes "
            "{!r}".format(
                identity["catalog"].get("fixture_root"),
                str(runner_fixtures_root(script)),
            )
        )
    blocked_reasons.extend(engine_errors)
    assets = engine.get("assets") or {}
    plan = {
        "schema": BATCH_SCHEMA,
        "version": BATCH_VERSION,
        "created_at": utcnow(),
        "repo_root": str(repo_root),
        "catalog": {
            "path": str(catalog_path),
            "sha256": identity["catalog"]["sha256"],
            "semantic_sha256": identity["catalog"]["semantic_sha256"],
            "scenario_count": len(all_ids),
            "fixture_count": identity["catalog"]["fixture_count"],
        },
        "fixture_provenance": {
            "root": identity["catalog"].get("fixture_root"),
            "source": identity["catalog"].get("fixture_root_source"),
            "runner_consumes": fixture_ready,
            "note": (
                "scripts/ci/scenarios.sh always seeds "
                "scripts/ci/scenarios/fixtures; a plan-only root is never "
                "executed and run/resume refuse it"
            ),
        },
        "engine_provenance": {
            "source_repo": engine.get("source_repo"),
            "scenario_repo": engine.get("scenario_repo"),
            "same_source_repo": bool(engine.get("same_source_repo")),
            "assets_complete": bool(assets.get("complete")),
            "missing_assets": list(assets.get("missing") or []),
            "note": (
                "run/resume require the runner source repo to equal "
                "--repo-root and the bundle/image/Python/JQ bytes to be "
                "present and hashed before the first child starts"
            ),
        },
        "execution_ready": fixture_ready and not engine_errors,
        "run_on": run_on,
        "upstream": upstream,
        "scenarios_script": str(script),
        "identity": identity,
        "scenario_ids": all_ids,
        "scenario_lane": {
            scenario_id: lane["id"]
            for lane in lanes_out
            for scenario_id in lane["scenario_ids"]
        },
        "budget": {
            "max_minutes": sum(lane["budget"]["max_minutes"] for lane in lanes_out),
            "max_model_requests": sum(
                lane["budget"]["max_model_requests"] for lane in lanes_out
            ),
        },
        "lanes": lanes_out,
        "batch_dir": str(batch_dir),
    }
    if blocked_reasons:
        plan["execution_blocked_reason"] = "; ".join(blocked_reasons)
    if len(plan["scenario_lane"]) != len(all_ids) or set(plan["scenario_lane"]) != all_id_set:
        raise BatchError("internal lane plan is not an exact catalog partition")
    return plan


def lane_by_id(plan):
    return {lane["id"]: lane for lane in plan["lanes"]}


def scenario_lane(plan, scenario_id):
    lane_id = plan["scenario_lane"].get(scenario_id)
    return lane_by_id(plan).get(lane_id)


def same_lane_layout(left, right):
    if not isinstance(left, dict) or not isinstance(right, dict):
        return False
    left_lanes = {lane.get("id"): lane for lane in left.get("lanes", [])}
    right_lanes = {lane.get("id"): lane for lane in right.get("lanes", [])}
    if set(left_lanes) != set(right_lanes):
        return False
    for lane_id, lane in left_lanes.items():
        other = right_lanes[lane_id]
        if sorted(lane.get("scenario_ids") or []) != sorted(
            other.get("scenario_ids") or []
        ):
            return False
        if (lane.get("simulator") or None) != (other.get("simulator") or None):
            return False
        for key in ("results_dir", "work_dir", "sim_dir"):
            if os.path.normpath(str(lane.get(key))) != os.path.normpath(
                str(other.get(key))
            ):
                return False
    return True


# ------------------------------------------------------------------- reports


def report_schema_errors(report, expected_id=None):
    if not isinstance(report, dict):
        return ["report.json is not a JSON object"]
    errors = []
    for field in REPORT_REQUIRED_FIELDS:
        if field not in report:
            errors.append("report.json is missing required field: {}".format(field))
    identifier = report.get("id")
    if "id" in report and (
        not isinstance(identifier, str) or not identifier.strip()
    ):
        errors.append("report.json field 'id' is not a non-empty string")
    elif expected_id is not None and identifier != expected_id:
        errors.append(
            "report.json id {!r} does not match scenario {!r}".format(
                identifier, expected_id
            )
        )
    status = report.get("status")
    if "status" in report:
        if not isinstance(status, str):
            errors.append("report.json field 'status' is not a string")
        elif status not in REPORT_STATUSES:
            errors.append("report.json has unknown status: {!r}".format(status))
    for field in REPORT_LIST_FIELDS:
        if field in report and not isinstance(report[field], list):
            errors.append("report.json field '{}' is not a list".format(field))
    for field in REPORT_OBJECT_FIELDS:
        if field in report and not isinstance(report[field], dict):
            errors.append("report.json field '{}' is not an object".format(field))
    for field in ("assertions", "turns", "perturbations"):
        values = report.get(field)
        if not isinstance(values, list):
            continue
        for index, item in enumerate(values):
            if not isinstance(item, dict):
                errors.append(
                    "report.json {} item {} is not an object".format(field, index)
                )
            elif field == "assertions" and not isinstance(item.get("ok"), bool):
                errors.append(
                    "report.json assertion {} field 'ok' is not a boolean".format(index)
                )
    for field in ("console_errors", "host_states"):
        values = report.get(field)
        if not isinstance(values, list):
            continue
        for index, item in enumerate(values):
            if not isinstance(item, str):
                errors.append(
                    "report.json {} item {} is not a string".format(field, index)
                )
    return errors


def index_current(results_dir, scenario_id):
    path = Path(results_dir) / ".capability-index.json"
    if not path.is_file():
        return None, None, "missing {}".format(path.name)
    try:
        document = read_json(path)
    except (OSError, ValueError) as exc:
        return None, None, "unreadable {}: {}".format(path.name, exc)
    scenarios = document.get("scenarios") if isinstance(document, dict) else None
    entry = scenarios.get(scenario_id) if isinstance(scenarios, dict) else None
    current = entry.get("current") if isinstance(entry, dict) else None
    if not isinstance(current, dict):
        return None, None, "index has no current entry for {}".format(scenario_id)
    attempt = current.get("attempt")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt <= 0:
        return None, None, "index current.attempt is not a positive integer"
    if current.get("state") not in (None, "CURRENT"):
        return None, None, "index current.state is {!r}, not CURRENT".format(
            current.get("state")
        )
    return attempt, current.get("status"), None


def required_evidence(report_status):
    if report_status in ("SKIP", "INFRA"):
        return list(DEFERRED_EVIDENCE)
    return list(TERMINAL_EVIDENCE)


def collect_evidence(directory, required):
    directory = Path(directory)
    evidence = {}
    missing = []
    for relative in required:
        if relative == "host/overlay-*.tar":
            entries = {}
            for path in sorted((directory / "host").glob("overlay-*.tar")):
                if path.is_file():
                    entries[path.relative_to(directory).as_posix()] = sha256_file(path)
            if not entries:
                missing.append(relative)
            else:
                evidence[relative] = {"kind": "glob", "entries": entries}
            continue
        path = directory / relative
        if relative in HOST_DIRECTORIES:
            if not path.is_dir():
                missing.append(relative)
            else:
                evidence[relative] = {"kind": "tree", "sha256": hash_tree(path)}
            continue
        if not path.is_file():
            missing.append(relative)
            continue
        evidence[relative] = {"kind": "file", "sha256": sha256_file(path)}
    return evidence, missing


def _status_from_report(report_status):
    if report_status == "PASS":
        return "PASS"
    if report_status == "PENDING_HOST":
        return "PENDING_HOST"
    if report_status in ("FAIL", "TIMEOUT", "BUDGET", "ERROR"):
        return "FAIL"
    if report_status == "SKIP":
        return "NOT_RUN"
    if report_status == "INFRA":
        return "BLOCKED"
    return "FAIL"


def inspect_scenario(lane, scenario_id, not_before_ns=None):
    """Read one result and return its explicit batch state (never a fake pass)."""

    results_dir = Path(lane["results_dir"])
    directory = results_dir / scenario_id
    report_path = directory / "report.json"
    result = {
        "scenario_id": scenario_id,
        "lane": lane["id"],
        "report_path": str(report_path),
        "report_status": None,
        "status": "NOT_RUN",
        "attempt": None,
        "index_attempt": None,
        "report_sha256": None,
        "evidence": {},
        "required_evidence": [],
        "missing_evidence": [],
        "detail": "",
    }
    if not report_path.is_file():
        result["detail"] = "missing report.json"
        return result
    try:
        stat = report_path.stat()
        if not_before_ns is not None and stat.st_mtime_ns < int(not_before_ns):
            result["detail"] = "stale report.json predates this run"
            return result
    except OSError as exc:
        result["status"] = "BLOCKED"
        result["detail"] = "cannot stat report.json: {}".format(redact_text(exc))
        return result
    try:
        report = read_json(report_path)
    except (OSError, ValueError) as exc:
        result["status"] = "FAIL"
        result["detail"] = "unreadable report.json: {}".format(redact_text(exc))
        return result
    result["report_sha256"] = sha256_file(report_path)
    errors = report_schema_errors(report, expected_id=scenario_id)
    if errors:
        result["status"] = "FAIL"
        result["report_status"] = (
            report.get("status") if isinstance(report, dict) else None
        )
        result["detail"] = "; ".join(errors)
        return result
    report_status = report["status"]
    result["report_status"] = report_status
    attempt = report.get("attempt")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt <= 0:
        result["status"] = "FAIL"
        result["detail"] = "report.attempt is missing or not a positive integer"
        return result
    result["attempt"] = attempt
    index_attempt, index_status, index_error = index_current(results_dir, scenario_id)
    result["index_attempt"] = index_attempt
    if index_error:
        result["status"] = "BLOCKED"
        result["detail"] = "attempt evidence unusable: {}".format(index_error)
        return result
    if index_attempt != attempt:
        result["status"] = "FAIL"
        result["detail"] = "report attempt {} != index attempt {}".format(
            attempt, index_attempt
        )
        return result
    if index_status is not None and index_status != report_status:
        result["status"] = "FAIL"
        result["detail"] = "report status {} != index status {}".format(
            report_status, index_status
        )
        return result
    required = required_evidence(report_status)
    result["required_evidence"] = required
    evidence, missing = collect_evidence(directory, required)
    result["evidence"] = evidence
    result["missing_evidence"] = missing
    result["status"] = _status_from_report(report_status)
    if result["status"] == "PASS" and missing:
        result["status"] = "BLOCKED"
        result["detail"] = "PASS report is missing evidence: {}".format(
            ", ".join(missing)
        )
    elif missing:
        result["detail"] = "missing evidence: {}".format(", ".join(missing))
    return result


# ------------------------------------------------------------------ receipts


def _receipt_path(plan, scenario_id):
    lane = scenario_lane(plan, scenario_id)
    if lane is None:
        raise BatchError("scenario has no lane: {}".format(scenario_id))
    return Path(lane["work_dir"]) / RECEIPTS_DIR / (scenario_id + ".json")


def receipt_identity_fields(identity):
    return {
        "source_sha": identity["source"]["sha"],
        "source_fingerprint": identity["source"]["fingerprint"],
        "catalog_sha256": identity["catalog"]["sha256"],
        "fixture_root_source": identity["catalog"].get("fixture_root_source"),
        "fixtures_sha256": identity["catalog"].get("fixtures_sha256"),
        "model_fingerprint": identity["model"]["fingerprint"],
        "credential_context": identity["model"].get("credential_context"),
        "engine_fingerprint": identity["engine"]["fingerprint"],
        "identity_fingerprint": identity["fingerprint"],
    }


def build_receipt(plan, identity, result):
    return {
        "version": BATCH_VERSION,
        "scenario_id": result["scenario_id"],
        "lane": result["lane"],
        "status": result["status"],
        "report_status": result["report_status"],
        "attempt": result["attempt"],
        "index_attempt": result["index_attempt"],
        "report_sha256": result["report_sha256"],
        "required_evidence": result["required_evidence"],
        "evidence": result["evidence"],
        "missing_evidence": result["missing_evidence"],
        "detail": redact_text(result["detail"]),
        "recorded_at": utcnow(),
        **receipt_identity_fields(identity),
    }


def write_receipt(plan, identity, result):
    path = _receipt_path(plan, result["scenario_id"])
    write_json_atomic(path, build_receipt(plan, identity, result))
    return path


def load_receipt(plan, scenario_id):
    try:
        return read_json(_receipt_path(plan, scenario_id))
    except (OSError, ValueError):
        return None


def receipt_identity_errors(receipt, identity):
    errors = []
    if not isinstance(receipt, dict):
        return ["receipt is not a JSON object"]
    for key, expected in receipt_identity_fields(identity).items():
        if receipt.get(key) != expected:
            errors.append("receipt {} mismatch".format(key))
    return errors


def receipt_reuse_errors(plan, identity, scenario_id, receipt):
    """Why a prior PASS is not safe to reuse (empty list means reusable)."""

    if not isinstance(receipt, dict):
        return ["missing receipt"]
    errors = receipt_identity_errors(receipt, identity)
    if receipt.get("scenario_id") != scenario_id:
        errors.append("receipt scenario_id mismatch")
    lane = scenario_lane(plan, scenario_id)
    if lane is None:
        errors.append("scenario has no planned lane")
        return errors
    if receipt.get("lane") != lane["id"]:
        errors.append("receipt lane mismatch")
    if receipt.get("status") != "PASS" or receipt.get("report_status") != "PASS":
        errors.append("prior status is not PASS")
    report_path = Path(lane["results_dir"]) / scenario_id / "report.json"
    if not report_path.is_file():
        errors.append("report.json is missing")
        return errors
    if receipt.get("report_sha256") != sha256_file(report_path):
        errors.append("report.json hash mismatch")
    result = inspect_scenario(lane, scenario_id)
    if result["status"] != "PASS":
        errors.append("current report is {}".format(result["status"]))
    if result.get("attempt") != receipt.get("attempt"):
        errors.append("report attempt mismatch")
    if result.get("index_attempt") != receipt.get("attempt"):
        errors.append("index attempt mismatch")
    if sorted(receipt.get("required_evidence") or []) != sorted(
        result.get("required_evidence") or []
    ):
        errors.append("required evidence set mismatch")
    if receipt.get("evidence") != result.get("evidence"):
        errors.append("evidence hash mismatch")
    if receipt.get("missing_evidence"):
        errors.append("receipt records missing evidence")
    return errors


def collect_receipts(
    plan,
    identity,
    not_before_by_lane=None,
    run_scenarios=None,
    failed_lanes=None,
    blocking_error=None,
):
    """Inspect every planned scenario and write its receipt.

    ``not_before_by_lane`` applies only to scenarios this invocation actually
    executed.  A reused PASS is intentionally older than the lane start; it is
    validated by its receipt/evidence hashes, not by its mtime.  ``failed_lanes``
    maps a lane whose launch raised to its error detail; no old report from that
    lane may be presented as this invocation's result.  ``blocking_error`` is a
    batch-wide provenance failure (for example a child rebuilding the assets
    after they were fingerprinted): no scenario may keep a PASS receipt then.
    """

    not_before_by_lane = not_before_by_lane or {}
    failed_lanes = failed_lanes or {}
    run_scenarios = set(run_scenarios) if run_scenarios is not None else None
    results = {}
    for scenario_id in plan["scenario_ids"]:
        lane = scenario_lane(plan, scenario_id)
        if lane is None:
            raise BatchError("scenario has no planned lane: {}".format(scenario_id))
        not_before = None
        executed = run_scenarios is None or scenario_id in run_scenarios
        if executed:
            not_before = not_before_by_lane.get(lane["id"])
        result = inspect_scenario(lane, scenario_id, not_before_ns=not_before)
        if executed and lane["id"] in failed_lanes:
            result["status"] = "BLOCKED"
            result["detail"] = redact_text(
                "lane runner failed before producing this result: {}".format(
                    failed_lanes[lane["id"]]
                )
            )
        if blocking_error:
            result["status"] = "BLOCKED"
            result["detail"] = redact_text(blocking_error)
        write_receipt(plan, identity, result)
        results[scenario_id] = result
    return results


# --------------------------------------------------------------- command/env


def build_command(plan, lane, scenario_ids):
    if not scenario_ids:
        return []
    command = [
        "bash",
        str(plan["scenarios_script"]),
        "--catalog",
        str(plan["catalog"]["path"]),
        "--results",
        str(lane["results_dir"]),
        "--only",
        ",".join(scenario_ids),
        "--run-on",
        str(plan["run_on"]),
        "--upstream",
        str(plan["upstream"]),
    ]
    simulator = lane.get("simulator")
    if plan["run_on"] == "sim" and simulator:
        if str(simulator).startswith("platform=") or str(simulator).startswith("id="):
            command += ["--destination", str(simulator)]
    return command


def lane_phases(plan, scenario_ids):
    """Split a lane's desired order into catalog-increasing invocations.

    The Swift selector preserves catalog order, so one ``--only`` list cannot
    make a long-run D scenario run after E/F.  Contiguous increasing runs are
    executed as separate ``scenarios.sh`` invocations against the same lane
    results directory; every scenario is still selected exactly once.
    """

    order = {scenario_id: index for index, scenario_id in enumerate(plan["scenario_ids"])}
    phases = []
    current = []
    for scenario_id in scenario_ids:
        index = order[scenario_id]
        if current and index <= order[current[-1]]:
            phases.append(current)
            current = []
        current.append(scenario_id)
    if current:
        phases.append(current)
    return phases


def lane_environment(lane, plan, build_dir=None):
    """The child environment; no value is printed or persisted."""

    env = os.environ.copy()
    env["PDSH_SCENARIO_SIM_DIR"] = str(lane["sim_dir"])
    if build_dir:
        env["PDSH_SCENARIO_BUILD_DIR"] = str(build_dir)
    simulator = lane.get("simulator")
    if plan["run_on"] == "sim" and simulator and not (
        str(simulator).startswith("platform=") or str(simulator).startswith("id=")
    ):
        env["PDSH_SIM_DEVICE"] = str(simulator)
    return env


def _decoded_chunks(stream, size=65536):
    """Decode a binary child stream incrementally, never buffering a line."""

    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    read1 = getattr(stream, "read1", None)
    while True:
        chunk = read1(size) if read1 is not None else stream.read(size)
        if not chunk:
            break
        text = decoder.decode(chunk)
        if text:
            yield text
    tail = decoder.decode(b"", final=True)
    if tail:
        yield tail


def _pump_output(process, log_handle, prefix):
    prefixer = _LinePrefixer(prefix)
    try:
        for clean in redact_chunks(_decoded_chunks(process.stdout)):
            log_handle.write(clean)
            log_handle.flush()
            print(prefixer.feed(clean), end="", flush=True)
    finally:
        try:
            process.stdout.close()
        except Exception:  # noqa: BLE001 - best-effort close
            pass


def _run_one_lane(plan, lane, scenario_ids, build_dir, timeout=None):
    phases = lane_phases(plan, scenario_ids)
    log_path = Path(lane["log"])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "lane": lane["id"],
        "scenario_ids": list(scenario_ids),
        "phases": [],
        "commands": [],
        "log": str(log_path),
        "started_ns": time.time_ns(),
        "started_at": utcnow(),
        "returncode": 0,
        "timed_out": False,
    }
    if not scenario_ids:
        return record
    with open(log_path, "w", encoding="utf-8") as log_handle:
        for phase in phases:
            command = build_command(plan, lane, phase)
            record["commands"].append(command)
            record["phases"].append(list(phase))
            env = lane_environment(lane, plan, build_dir=build_dir)
            print(
                "scenario_batch: {}: running {} scenario(s): {}".format(
                    lane["id"], len(phase), ", ".join(phase)
                ),
                flush=True,
            )
            process = subprocess.Popen(
                command,
                cwd=str(plan["repo_root"]),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0,
                start_new_session=True,
            )
            pump = threading.Thread(
                target=_pump_output,
                args=(process, log_handle, "[{}]".format(lane["id"])),
                daemon=True,
            )
            pump.start()
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record["timed_out"] = True
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                except (OSError, ProcessLookupError):
                    pass
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                    except (OSError, ProcessLookupError):
                        pass
                    process.wait()
            finally:
                pump.join(timeout=30)
            if process.returncode not in (0, None):
                record["returncode"] = process.returncode
                # A product FAIL/TIMEOUT in one phase must not hide the later
                # phases in the same lane. A hung/timed-out phase is different:
                # keep the lane bounded instead of retrying the next phase.
                if record["timed_out"]:
                    break
    record["finished_at"] = utcnow()
    return record


# --------------------------------------------------------------------- state


def write_manifest(plan):
    path = Path(plan["batch_dir"]) / BATCH_MANIFEST
    write_json_atomic(path, plan)
    return path


def load_manifest(batch_dir):
    path = Path(batch_dir) / BATCH_MANIFEST
    if not path.is_file():
        return None
    try:
        document = read_json(path)
    except (OSError, ValueError) as exc:
        raise BatchError("cannot read {}: {}".format(path, exc)) from exc
    if not isinstance(document, dict) or document.get("schema") != BATCH_SCHEMA:
        raise BatchError("{} is not a scenario batch manifest".format(path))
    return document


def _write_state(batch_dir, state):
    write_json_atomic(Path(batch_dir) / RUN_STATE, state)


def load_state(batch_dir):
    path = Path(batch_dir) / RUN_STATE
    if not path.is_file():
        return None
    try:
        document = read_json(path)
    except (OSError, ValueError) as exc:
        raise BatchError("cannot read {}: {}".format(path, exc)) from exc
    return document if isinstance(document, dict) else None


# ----------------------------------------------------------------------- run


def _state_reuse_errors(plan, identity, state):
    """Why a previous state cannot authorise reuse (empty means it can)."""

    if not isinstance(state, dict):
        return ["previous run state is missing"]
    errors = []
    if state.get("status") != "finished":
        errors.append(
            "previous batch state is {!r}, not finished".format(state.get("status"))
        )
    if state.get("identity_fingerprint") != identity["fingerprint"]:
        errors.append("previous run state identity mismatch")
    lanes = state.get("lanes")
    if not isinstance(lanes, dict) or not lanes:
        errors.append("previous run state has no lane records")
        return errors
    expected_lanes = {lane["id"] for lane in plan.get("lanes", [])}
    if set(lanes) != expected_lanes:
        errors.append("previous run state lane set does not match the plan")
    for lane_id, lane_state in sorted(lanes.items()):
        if not isinstance(lane_state, dict):
            errors.append("lane {} state is not an object".format(lane_id))
            continue
        returncode = lane_state.get("returncode")
        status = lane_state.get("status")
        if lane_state.get("timed_out"):
            errors.append("lane {} timed out".format(lane_id))
        elif status == "reused":
            if returncode not in (None, 0):
                errors.append(
                    "lane {} reused record has returncode {!r}".format(
                        lane_id, returncode
                    )
                )
        elif not isinstance(returncode, int) or isinstance(returncode, bool):
            errors.append("lane {} has no integer returncode".format(lane_id))
        elif returncode != 0:
            errors.append(
                "lane {} runner failed (returncode={!r}, status={!r})".format(
                    lane_id, returncode, status
                )
            )
    return errors


def _load_reusable(plan, identity, existing, state=None):
    if not isinstance(existing, dict):
        return {}
    if existing.get("identity", {}).get("fingerprint") != identity["fingerprint"]:
        print(
            "scenario_batch: resume identity changed; no prior PASS is reused",
            file=sys.stderr,
        )
        return {}
    if not same_lane_layout(existing, plan):
        print(
            "scenario_batch: lane layout changed; no prior PASS is reused",
            file=sys.stderr,
        )
        return {}
    existing_catalog = (existing.get("identity") or {}).get("catalog") or {}
    if existing_catalog.get("fixture_root_source") != "runner-default":
        print(
            "scenario_batch: prior fixture provenance is {!r}, not the "
            "runner's default; no prior PASS is reused".format(
                existing_catalog.get("fixture_root_source")
            ),
            file=sys.stderr,
        )
        return {}
    if identity.get("model", {}).get("upstream") == "real":
        context = identity["model"].get("credential_context") or {}
        if context.get("source") != "explicit" or not context.get(
            "resume_reusable"
        ):
            print(
                "scenario_batch: real credential context is unknown (set {} to "
                "a non-secret tenant/deployment id); no prior real PASS is "
                "reused".format(MODEL_CONFIG_ID_ENV),
                file=sys.stderr,
            )
            return {}
    state_errors = _state_reuse_errors(plan, identity, state)
    if state_errors:
        print(
            "scenario_batch: previous run is not reusable: {}".format(
                redact_text("; ".join(state_errors))
            ),
            file=sys.stderr,
        )
        return {}
    reusable = {}
    for scenario_id in plan["scenario_ids"]:
        receipt = load_receipt(plan, scenario_id)
        errors = receipt_reuse_errors(plan, identity, scenario_id, receipt)
        if errors:
            print(
                "scenario_batch: {} not reused: {}".format(
                    scenario_id, redact_text("; ".join(errors))
                ),
                file=sys.stderr,
            )
            continue
        reusable[scenario_id] = receipt
    return reusable


def run_batch(args, resume=False):
    repo_root = Path(args.repo_root).resolve()
    catalog_path = Path(args.catalog).resolve()
    batch_dir = Path(args.batch_dir).resolve()
    scenarios_script = Path(
        args.scenarios_script or DEFAULT_SCENARIOS
    ).resolve()
    build_dir = Path(args.build_dir).resolve() if args.build_dir else None
    simulators = [
        item.strip() for item in (args.simulators or "").split(",") if item.strip()
    ]
    _require_executable_fixture_root(
        repo_root, args.fixtures_root, scenarios_script=scenarios_script
    )
    _require_same_runner_source(repo_root, scenarios_script)

    identity_env = dict(os.environ)
    if build_dir is not None:
        identity_env["PDSH_SCENARIO_BUILD_DIR"] = str(build_dir)
    document = load_catalog(catalog_path)
    identity = build_identity(
        repo_root,
        catalog_path,
        args.run_on,
        args.upstream,
        env=identity_env,
        fixtures_root=args.fixtures_root,
        scenarios_script=scenarios_script,
        document=document,
        simulators=simulators,
    )
    _require_executable_engine(identity.get("engine"))
    existing = load_manifest(batch_dir) if (batch_dir / BATCH_MANIFEST).is_file() else None
    if existing is not None and not resume and not args.force:
        raise BatchError(
            "{} already contains a batch; pass --resume or choose a new --batch-dir".format(
                batch_dir
            )
        )
    plan = build_plan(
        catalog_path,
        repo_root,
        batch_dir,
        run_on=args.run_on,
        upstream=args.upstream,
        lanes=args.lanes,
        simulators=simulators,
        fixtures_root=args.fixtures_root,
        scenarios_script=scenarios_script,
        identity=identity,
    )
    previous_state = None
    if resume:
        try:
            previous_state = load_state(batch_dir)
        except BatchError as exc:
            print(
                "scenario_batch: previous run state is unreadable; no prior "
                "PASS is reused: {}".format(redact_text(str(exc))),
                file=sys.stderr,
            )
    reusable = (
        _load_reusable(plan, identity, existing, state=previous_state)
        if resume
        else {}
    )
    if existing is not None and not resume and args.force:
        reusable = {}
    batch_dir.mkdir(parents=True, exist_ok=True)
    write_manifest(plan)

    to_run = {
        lane["id"]: [
            scenario_id
            for scenario_id in lane["scenario_ids"]
            if scenario_id not in reusable
        ]
        for lane in plan["lanes"]
    }
    batch_started_ns = time.time_ns()
    state = {
        "version": BATCH_VERSION,
        "status": "running",
        "started_at": utcnow(),
        "started_ns": batch_started_ns,
        "identity_fingerprint": identity["fingerprint"],
        "reused": sorted(reusable),
        "lanes": {
            lane["id"]: {
                "status": "pending" if to_run[lane["id"]] else "reused",
                "scenario_ids": to_run[lane["id"]],
                "started_ns": None,
                "log": lane["log"],
            }
            for lane in plan["lanes"]
        },
    }
    commands = []
    for lane in plan["lanes"]:
        ids = to_run[lane["id"]]
        for phase in lane_phases(plan, ids):
            command = build_command(plan, lane, phase)
            if command:
                commands.append(
                    {"lane": lane["id"], "scenario_ids": phase, "command": command}
                )
    if args.dry_run:
        for entry in commands:
            print(
                "scenario_batch: {}: {}".format(
                    entry["lane"], " ".join(entry["command"])
                )
            )
        if not commands:
            print("scenario_batch: nothing to run; every scenario is a reusable PASS")
        return 0

    _write_state(batch_dir, state)
    lane_records = {}
    threads = []
    for lane in plan["lanes"]:
        ids = to_run[lane["id"]]
        if not ids:
            continue
        print(
            "scenario_batch: {}: {} scenario(s) in {} phase(s), log {}".format(
                lane["id"], len(ids), len(lane_phases(plan, ids)), lane["log"]
            ),
            flush=True,
        )

        def launch(lane=lane, ids=list(ids)):
            try:
                lane_records[lane["id"]] = _run_one_lane(
                    plan, lane, ids, build_dir=build_dir, timeout=args.timeout
                )
            except Exception as exc:  # noqa: BLE001 - must become a lane failure
                detail = redact_text(
                    "{}: {}".format(type(exc).__name__, exc)
                )
                print(
                    "scenario_batch: {}: lane launch failed: {}".format(
                        lane["id"], detail
                    ),
                    file=sys.stderr,
                    flush=True,
                )
                lane_records[lane["id"]] = {
                    "lane": lane["id"],
                    "scenario_ids": list(ids),
                    "phases": [],
                    "commands": [],
                    "log": lane["log"],
                    "started_ns": batch_started_ns,
                    "started_at": utcnow(),
                    "finished_at": utcnow(),
                    "returncode": -1,
                    "timed_out": False,
                    "status": "error",
                    "error": detail,
                }

        thread = threading.Thread(target=launch, name="lane-" + lane["id"], daemon=True)
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()

    # A child may rewrite a fixture, the catalog, a tracked source file, or a
    # default build cache after the preflight hash was taken.  Re-read every
    # provenance input after all lanes have exited; if any of them no longer
    # match the planned bytes, no scenario may receive a PASS receipt even when
    # its report says PASS.
    runtime_errors = _runtime_provenance_errors(
        identity,
        repo_root,
        catalog_path,
        fixtures_root=args.fixtures_root,
        scenarios_script=scenarios_script,
    )
    runtime_blocking_error = None
    if runtime_errors:
        runtime_blocking_error = (
            "provenance changed while the batch was running: "
            + "; ".join(runtime_errors)
        )
        print(
            "scenario_batch: " + redact_text(runtime_blocking_error),
            file=sys.stderr,
            flush=True,
        )

    # Every lane that has work in this invocation is anchored to the batch
    # start, not to an individual thread record.  A lane whose launch failed
    # therefore cannot inherit an older PASS report just because no record was
    # published for it.  Filesystems may round mtimes; one second of tolerance
    # keeps a report written immediately after Popen unambiguous.
    not_before = {
        lane["id"]: batch_started_ns - 1_000_000_000
        for lane in plan["lanes"]
        if to_run[lane["id"]]
    }
    failed_lanes = {
        lane["id"]: (
            (lane_records.get(lane["id"]) or {}).get("error")
            or "lane runner did not start"
        )
        for lane in plan["lanes"]
        if to_run[lane["id"]]
        and (
            lane_records.get(lane["id"]) is None
            or (lane_records.get(lane["id"]) or {}).get("status") == "error"
        )
    }
    results = collect_receipts(
        plan,
        identity,
        not_before_by_lane=not_before,
        run_scenarios={scenario_id for ids in to_run.values() for scenario_id in ids},
        failed_lanes=failed_lanes,
        blocking_error=runtime_blocking_error,
    )
    state["status"] = "finished"
    state["finished_at"] = utcnow()
    lane_status = {}
    for lane in plan["lanes"]:
        record = lane_records.get(lane["id"])
        if not to_run[lane["id"]]:
            # A lane with no work in this invocation is the only lane that may
            # be described as reused.  A missing failure record is an error,
            # never an implicit reuse.
            status = "reused"
        elif record is None:
            status = "error"
        elif record.get("timed_out"):
            status = "timed_out"
        elif record.get("status") == "error":
            status = "error"
        elif record.get("returncode") not in (0, None):
            status = "failed"
        else:
            status = "finished"
        lane_status[lane["id"]] = {
            "status": status,
            "scenario_ids": to_run[lane["id"]],
            "phases": record.get("phases") if record else [],
            "returncode": record.get("returncode") if record else None,
            "log": lane["log"],
        }
        if record and record.get("error"):
            lane_status[lane["id"]]["error"] = record["error"]
    state["lanes"] = lane_status
    state["scenarios"] = {
        scenario_id: {
            "status": result["status"],
            "report_status": result["report_status"],
            "attempt": result["attempt"],
            "detail": redact_text(result["detail"]),
        }
        for scenario_id, result in results.items()
    }
    _write_state(batch_dir, state)

    summary_code = summarize(batch_dir, plan=plan, identity=identity, state=state)
    return 0 if summary_code == 0 else 1


# ------------------------------------------------------------------- summary


def _summary_scenario_status(plan, identity, state, scenario_id):
    """Return ``(status, detail, result)`` for one planned scenario."""

    lane = scenario_lane(plan, scenario_id)
    if lane is None:
        return "BLOCKED", "scenario has no planned lane", None
    reused = set((state or {}).get("reused") or [])
    if (state or {}).get("status") == "running" and scenario_id not in reused:
        return "BLOCKED", "batch run did not finish", None
    result = inspect_scenario(lane, scenario_id)
    if result["status"] != "PASS":
        receipt = load_receipt(plan, scenario_id)
        if isinstance(receipt, dict):
            errors = receipt_identity_errors(receipt, identity)
            if errors:
                return (
                    "BLOCKED",
                    "receipt mismatch: " + "; ".join(errors),
                    result,
                )
        return result["status"], result["detail"], result
    receipt = load_receipt(plan, scenario_id)
    if not isinstance(receipt, dict):
        return "BLOCKED", "PASS report has no batch receipt", result
    errors = receipt_reuse_errors(plan, identity, scenario_id, receipt)
    if errors:
        return "BLOCKED", "receipt mismatch: " + "; ".join(errors), result
    return "PASS", "", result


def _state_structure_errors(plan, identity, state):
    """Structural problems that make a summary untrustworthy.

    A missing, interrupted or malformed state is not evidence that the batch
    passed.  Runner failures (a nonzero/timed-out lane) are reported separately
    so the individual report verdicts remain visible, but the batch still fails.
    """

    if not isinstance(state, dict):
        return ["run state is missing; refusing to trust reports without it"]
    errors = []
    if state.get("status") != "finished":
        errors.append(
            "run state is {!r}, not finished".format(state.get("status"))
        )
    if state.get("identity_fingerprint") != identity["fingerprint"]:
        errors.append("run state identity does not match the batch manifest")
    lanes = state.get("lanes")
    expected_lanes = {lane["id"] for lane in plan.get("lanes", [])}
    if not isinstance(lanes, dict) or not lanes:
        errors.append("run state has no lane records")
    else:
        if set(lanes) != expected_lanes:
            errors.append("run state lane set does not match the batch manifest")
        for lane_id, lane_state in sorted(lanes.items()):
            if not isinstance(lane_state, dict):
                errors.append("run state lane {} is not an object".format(lane_id))
                continue
            status = lane_state.get("status")
            if status not in ("reused", "finished", "failed", "timed_out", "error"):
                errors.append(
                    "run state lane {} has unknown status {!r}".format(
                        lane_id, status
                    )
                )
            returncode = lane_state.get("returncode")
            if status == "reused":
                if returncode not in (None, 0):
                    errors.append(
                        "run state lane {} reused record has returncode {!r}".format(
                            lane_id, returncode
                        )
                    )
            elif not isinstance(returncode, int) or isinstance(returncode, bool):
                errors.append(
                    "run state lane {} has no integer returncode".format(lane_id)
                )
    scenarios = state.get("scenarios")
    if not isinstance(scenarios, dict):
        errors.append("run state has no per-scenario results")
    else:
        expected_scenarios = set(plan.get("scenario_ids") or [])
        if set(scenarios) != expected_scenarios:
            errors.append(
                "run state scenario set does not match the batch manifest"
            )
    return errors


def summarize(
    batch_dir,
    plan=None,
    identity=None,
    state=None,
    expected_source_sha=None,
    expected_catalog_sha=None,
    require_current_source=False,
    write=True,
):
    batch_dir = Path(batch_dir).resolve()
    if plan is None:
        plan = load_manifest(batch_dir)
    if plan is None:
        raise BatchError("no batch manifest in {}".format(batch_dir))
    if identity is None:
        identity = plan.get("identity")
    if not isinstance(identity, dict) or not isinstance(plan.get("identity"), dict):
        raise BatchError("batch manifest has no identity")
    if identity.get("fingerprint") != plan["identity"].get("fingerprint"):
        raise BatchError("summary identity does not match the batch manifest")
    state_error = None
    if state is None:
        try:
            state = load_state(batch_dir)
        except BatchError as exc:
            state_error = redact_text(str(exc))
            state = None

    planned = list(plan.get("scenario_ids") or [])
    lane_ids = [scenario_id for lane in plan.get("lanes", []) for scenario_id in lane.get("scenario_ids", [])]
    issues = []
    if len(planned) != len(set(planned)):
        issues.append("batch manifest has duplicate scenario ids")
    if set(planned) != set(lane_ids) or len(lane_ids) != len(set(lane_ids)):
        issues.append("batch manifest lane selection is not the catalog")
    if state_error:
        issues.append("run state is unreadable: {}".format(state_error))
    issues.extend(_state_structure_errors(plan, plan["identity"], state))

    catalog_path = Path(plan["catalog"]["path"])
    plan_engine = plan.get("identity", {}).get("engine") or {}
    plan_script = plan.get("scenarios_script") or plan_engine.get("scenario_script")
    try:
        document = load_catalog(catalog_path)
        current_catalog = catalog_identity(
            catalog_path,
            document,
            fixtures_root=plan["identity"]["catalog"].get("fixture_root"),
            repo_root=plan.get("repo_root"),
            scenarios_script=plan_script,
        )
    except BatchError as exc:
        current_catalog = None
        issues.append(str(exc))
    fixture_source = (plan["identity"].get("catalog") or {}).get(
        "fixture_root_source"
    )
    if fixture_source != "runner-default":
        issues.append(
            "batch fixture provenance is {!r}, not 'runner-default'; the "
            "receipt would not describe the bytes scenarios.sh consumes".format(
                fixture_source
            )
        )
    if current_catalog is not None:
        if current_catalog["sha256"] != plan["identity"]["catalog"]["sha256"]:
            issues.append("catalog sha256 changed since the batch was planned")
        if current_catalog["fixtures_sha256"] != plan["identity"]["catalog"].get("fixtures_sha256"):
            issues.append("fixture payload changed since the batch was planned")
    issues.extend(_engine_current_errors(plan_engine))
    if expected_source_sha is not None and plan["identity"]["source"]["sha"] != expected_source_sha:
        issues.append(
            "batch source SHA {} != expected {}".format(
                plan["identity"]["source"]["sha"], expected_source_sha
            )
        )
    if expected_catalog_sha is not None and plan["identity"]["catalog"]["sha256"] != expected_catalog_sha:
        issues.append(
            "batch catalog SHA {} != expected {}".format(
                plan["identity"]["catalog"]["sha256"], expected_catalog_sha
            )
        )
    if require_current_source:
        try:
            current_source = source_identity(plan["repo_root"])
        except BatchError as exc:
            issues.append(str(exc))
        else:
            if current_source["fingerprint"] != plan["identity"]["source"]["fingerprint"]:
                issues.append("working tree source changed since the batch was planned")

    runner_failures = []
    if isinstance(state, dict):
        for lane_id, lane_state in sorted((state.get("lanes") or {}).items()):
            if not isinstance(lane_state, dict):
                continue
            returncode = lane_state.get("returncode")
            if lane_state.get("status") == "timed_out" or (
                isinstance(returncode, int) and returncode != 0
            ):
                runner_failures.append(
                    "{} runner failed (returncode={!r}, status={!r}); see {}".format(
                        lane_id,
                        returncode,
                        lane_state.get("status"),
                        lane_state.get("log"),
                    )
                )
        if state.get("status") == "running":
            runner_failures.append("batch run did not finish")

    scenarios = {}
    counts = {name: 0 for name in SUMMARY_STATUSES}
    if issues:
        reason = "batch identity is not reproducible: " + "; ".join(issues)
        for scenario_id in planned:
            scenarios[scenario_id] = {
                "status": "BLOCKED",
                "report_status": None,
                "attempt": None,
                "lane": plan.get("scenario_lane", {}).get(scenario_id),
                "detail": reason,
            }
            counts["BLOCKED"] += 1
    else:
        for scenario_id in planned:
            status, detail, result = _summary_scenario_status(
                plan, identity, state, scenario_id
            )
            scenarios[scenario_id] = {
                "status": status,
                "report_status": result["report_status"] if result else None,
                "attempt": result["attempt"] if result else None,
                "lane": plan.get("scenario_lane", {}).get(scenario_id),
                "detail": redact_text(detail),
            }
            counts[status] += 1

    expected_total = len(planned)
    if sum(counts.values()) != expected_total:
        issues.append("summary did not classify every planned scenario")
        counts["BLOCKED"] = max(0, expected_total - sum(counts.values()))
    ok = (
        not issues
        and not runner_failures
        and expected_total > 0
        and counts["PASS"] == expected_total
    )

    summary = {
        "version": BATCH_VERSION,
        "schema": BATCH_SCHEMA + "-summary",
        "generated_at": utcnow(),
        "batch_dir": str(batch_dir),
        "run_on": plan.get("run_on"),
        "upstream": plan.get("upstream"),
        "source_sha": plan["identity"]["source"]["sha"],
        "catalog_sha256": plan["identity"]["catalog"]["sha256"],
        "identity_fingerprint": plan["identity"]["fingerprint"],
        "fixture_provenance": plan.get("fixture_provenance")
        or {
            "root": plan["identity"]["catalog"].get("fixture_root"),
            "source": fixture_source,
            "runner_consumes": fixture_source == "runner-default",
        },
        "credential_context": (plan["identity"].get("model") or {}).get(
            "credential_context"
        ),
        "expected": {
            "scenarios": expected_total,
            "fixtures": plan["catalog"].get("fixture_count"),
            "max_minutes": plan.get("budget", {}).get("max_minutes"),
            "max_model_requests": plan.get("budget", {}).get("max_model_requests"),
        },
        "ok": ok,
        "issues": [redact_text(item) for item in issues],
        "runner_failures": [redact_text(item) for item in runner_failures],
        "counts": counts,
        "scenarios": scenarios,
    }
    if write:
        write_json_atomic(batch_dir / SUMMARY_JSON, summary)
        write_text_atomic(batch_dir / SUMMARY_MD, _summary_markdown(summary))
    _print_summary(summary)
    return 0 if ok else 1


def _summary_markdown(summary):
    lines = [
        "# G2 batch summary",
        "",
        "- Generated: `{}`".format(summary["generated_at"]),
        "- Source SHA: `{}`".format(summary["source_sha"]),
        "- Catalog SHA-256: `{}`".format(summary["catalog_sha256"]),
        "- Run on: `{}` with `{}` upstream".format(
            summary["run_on"], summary["upstream"]
        ),
        "- Fixture provenance: `{}` ({})".format(
            (summary.get("fixture_provenance") or {}).get("source"),
            (summary.get("fixture_provenance") or {}).get("root"),
        ),
        "- Result: **{}**".format("PASS" if summary["ok"] else "FAIL"),
        "- Counts: " + ", ".join(
            "{} {}".format(name, summary["counts"][name])
            for name in SUMMARY_STATUSES
        ),
        "",
    ]
    context = summary.get("credential_context") or {}
    if summary.get("upstream") == "real" and context.get("source") != "explicit":
        lines.append(
            "> Credential context is **unknown**: these reports describe the "
            "run that produced them, but an explicit resume will not reuse "
            "their PASS. Set `PDSH_MODEL_CONFIG_ID` to a non-secret "
            "tenant/deployment id for reuse."
        )
        lines.append("")
    if summary["issues"]:
        lines.append("## Blocking issues")
        lines.append("")
        for issue in summary["issues"]:
            lines.append("- {}".format(issue))
        lines.append("")
    if summary.get("runner_failures"):
        lines.append("## Runner failures")
        lines.append("")
        for failure in summary["runner_failures"]:
            lines.append("- {}".format(failure))
        lines.append("")
    lines.append("## Scenarios")
    lines.append("")
    lines.append("| scenario | lane | status | report | attempt | detail |")
    lines.append("|---|---|---|---|---|---|")
    for scenario_id in sorted(summary["scenarios"]):
        item = summary["scenarios"][scenario_id]
        detail = str(item.get("detail") or "").replace("|", "\\|")
        lines.append(
            "| {} | {} | {} | {} | {} | {} |".format(
                scenario_id,
                item.get("lane") or "",
                item.get("status") or "",
                item.get("report_status") or "",
                item.get("attempt") or "",
                detail,
            )
        )
    lines.append("")
    return "\n".join(lines)


def _print_summary(summary):
    print(
        "scenario_batch: {} scenario(s): {}".format(
            summary["expected"]["scenarios"],
            ", ".join(
                "{} {}".format(name, summary["counts"][name])
                for name in SUMMARY_STATUSES
            ),
        )
    )
    for issue in summary["issues"]:
        print("scenario_batch: BLOCKED: {}".format(issue))
    for failure in summary.get("runner_failures", []):
        print("scenario_batch: RUNNER FAILED: {}".format(failure))
    for scenario_id in sorted(summary["scenarios"]):
        item = summary["scenarios"][scenario_id]
        if item["status"] == "PASS":
            continue
        detail = " {}".format(item["detail"]) if item.get("detail") else ""
        print(
            "scenario_batch: {} {} report={} attempt={}{}".format(
                scenario_id,
                item["status"],
                item.get("report_status") or "-",
                item.get("attempt") or "-",
                detail,
            )
        )
    print(
        "scenario_batch: {}".format(
            "PASS" if summary["ok"] else "NOT PASS (a batch is complete only when every scenario is PASS)"
        )
    )


# ---------------------------------------------------------------- cli parser


def _split_list(value):
    return [item.strip() for item in (value or "").split(",") if item.strip()]


def _add_common_arguments(parser):
    parser.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    parser.add_argument("--repo-root", default=str(DEFAULT_REPO_ROOT))
    parser.add_argument("--batch-dir", default=None)
    parser.add_argument("--run-on", choices=("macos", "sim"), default="macos")
    parser.add_argument("--upstream", choices=("mock", "real"), default="mock")
    parser.add_argument("--lanes", type=int, default=None)
    parser.add_argument("--simulators", default="")
    parser.add_argument("--fixtures-root", default=None)
    parser.add_argument("--scenarios-script", default=None)


def _add_run_arguments(parser):
    _add_common_arguments(parser)
    parser.add_argument("--build-dir", default=None)
    parser.add_argument("--timeout", type=float, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true")


def _default_batch_dir():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return str(Path(tempfile.gettempdir()) / "pdsh-g2-batch" / "{}-{}".format(
        stamp, os.getpid()
    ))


def _cmd_plan(args):
    batch_dir = Path(args.batch_dir or _default_batch_dir()).resolve()
    plan = build_plan(
        Path(args.catalog),
        Path(args.repo_root),
        batch_dir,
        run_on=args.run_on,
        upstream=args.upstream,
        lanes=args.lanes,
        simulators=_split_list(args.simulators),
        fixtures_root=args.fixtures_root,
        scenarios_script=args.scenarios_script,
    )
    if not plan.get("execution_ready", True):
        print(
            "scenario_batch: PLAN ONLY: {}".format(
                plan.get("execution_blocked_reason")
            ),
            file=sys.stderr,
        )
    text = json.dumps(plan, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    if args.out:
        write_text_atomic(Path(args.out), text)
    print(text, end="")
    return 0


def _cmd_run(args, resume=False):
    if args.batch_dir is None:
        args.batch_dir = _default_batch_dir()
    print("scenario_batch: batch dir {}".format(Path(args.batch_dir).resolve()))
    return run_batch(args, resume=resume)


def _cmd_summary(args):
    return summarize(
        args.batch_dir,
        expected_source_sha=args.expect_source_sha,
        expected_catalog_sha=args.expect_catalog_sha,
        require_current_source=args.require_current_source,
    )


def _build_parser():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan = subparsers.add_parser(
        "plan", help="validate the catalog/lanes and print the exact batch plan"
    )
    _add_common_arguments(plan)
    plan.add_argument("--out", default=None)
    plan.set_defaults(func=_cmd_plan)

    run = subparsers.add_parser("run", help="execute one scenarios.sh process per lane")
    _add_run_arguments(run)
    run.add_argument("--resume", action="store_true")
    run.set_defaults(func=lambda args: _cmd_run(args, resume=args.resume))

    resume = subparsers.add_parser(
        "resume", help="run again, reusing only identity-matching PASS receipts"
    )
    _add_run_arguments(resume)
    resume.set_defaults(func=lambda args: _cmd_run(args, resume=True))

    summary = subparsers.add_parser(
        "summary", help="aggregate reports/receipts into explicit batch states"
    )
    summary.add_argument("--batch-dir", required=True)
    summary.add_argument("--expect-source-sha", default=None)
    summary.add_argument("--expect-catalog-sha", default=None)
    summary.add_argument("--require-current-source", action="store_true")
    summary.set_defaults(func=_cmd_summary)
    return parser


def main(argv=None):
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except BatchError as exc:
        print("scenario_batch: {}".format(redact_text(exc)), file=sys.stderr)
        return exc.exit_code
    except OSError as exc:
        print(
            "scenario_batch: I/O error: {}".format(redact_text(exc)),
            file=sys.stderr,
        )
        return 2
    except KeyboardInterrupt:
        print("scenario_batch: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
