#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""phone-dsh-v1 gateway security vector checker.

Validates ``spec/v1/golden/gateway/*.json`` against
``spec/v1/schema/gateway-vector.schema.json`` with the shared JSON Schema
subset validator of ``spec_golden.py``, then enforces the language-independent
invariants the schema cannot express: deny reasons, caller-credential
leakage, strip/outbound disjointness, redirect-chain arithmetic, source
resolution and rule coverage.

Usage::

    python3 spec/v1/tools/gateway_check.py --root .

Exit status: 0 when every vector and every coverage rule passes, 1 otherwise.
Python 3.9, standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import urlsplit

RULES = (
    "credential-injection",
    "header-strip",
    "redirect-scope",
    "egress-classification",
    "response-redaction",
    "failure-surface",
)

MIN_VECTORS = 30

# The failure surface bounds a transport reason before it reaches a response
# body or the run log (gateway-security.md §7, gw-fail-004).
REASON_LIMIT = 256
TRANSPORT_REASON_PREFIX = "upstream transport failed: "

# Failures a gateway can only raise after it contacted the upstream; unlike a
# pre-flight deny they build headers and report at least one contact.
SENT_FAILURE_CODES = ("transport_failure", "upstream_status", "upstream_failed")

# A value the Worker might send as its own credential. No vector may let it
# reach the upstream or appear in an expected response.
CALLER_SENTINEL = "sk-SENTINEL-DO-NOT-USE"

# The non-secret placeholder a Worker puts into a host-managed header.
WORKER_PLACEHOLDER = "phone-host-injects-mcp-key"

RESERVED_HOSTS = ("example.invalid",)
LOOPBACK_HOSTS = {"127.0.0.1"}

HEADER_NAME_RE = None  # set lazily to avoid importing re at module import


def _header_name_ok(name):
    global HEADER_NAME_RE
    if HEADER_NAME_RE is None:
        import re

        HEADER_NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
    return isinstance(name, str) and HEADER_NAME_RE.fullmatch(name) is not None


FAILURE_SHAPES = {
    "host_not_allowed": (403, "forbidden"),
    "invalid_request": (400, "bad_request"),
    "credential_unavailable": (502, "credential_unavailable"),
    "shutting_down": (502, "shutting_down"),
    "transport_failure": (502, "upstream"),
    "upstream_status": (502, "upstream"),
    "upstream_failed": (502, "upstream"),
}

REDIRECT_DENY_REASONS = ("redirect_target_not_allowed", "redirect_scope_mismatch")


def load_validator(root):
    """Import the shared validator from the checker tree under *root*."""

    tools = str((Path(root) / "spec" / "v1" / "tools").resolve())
    if tools not in sys.path:
        sys.path.insert(0, tools)
    import spec_golden

    return spec_golden


def _strings(value):
    """Every string inside *value*, including object member names."""

    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for name, item in value.items():
            if isinstance(name, str):
                yield name
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _has(value, needle):
    lowered = needle.lower()
    return any(lowered in text.lower() for text in _strings(value))


def _url_host(value):
    """Return the lowercased host of an http(s) URL, or None."""

    if not isinstance(value, str) or not value:
        return None
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    return parts.hostname.lower()


def _check_url(value, where, errors):
    host = _url_host(value)
    if host is None:
        errors.append("{}: {!r} is not an absolute http(s) URL".format(where, value))
        return
    if host in LOOPBACK_HOSTS:
        return
    if any(host == suffix or host.endswith("." + suffix) for suffix in RESERVED_HOSTS):
        return
    errors.append("{}: host {!r} is not a reserved fixture host".format(where, host))


def _check_header_map(value, where, errors):
    if not isinstance(value, dict):
        errors.append("{}: expected an object".format(where))
        return
    for name in value:
        if not _header_name_ok(name):
            errors.append(
                "{}: header name {!r} must be lowercase [a-z0-9-]".format(where, name)
            )
    for name, item in value.items():
        if not isinstance(item, str):
            errors.append("{}: value of {!r} is not a string".format(where, name))


def _check_source(root, value, where, errors, line_cache):
    if not isinstance(value, str) or ":" not in value:
        errors.append("{}: {!r} is not path:line".format(where, value))
        return
    path_text, _, line_text = value.rpartition(":")
    if not path_text or not line_text.isdigit():
        errors.append("{}: {!r} is not path:line".format(where, value))
        return
    if ".." in Path(path_text).parts or Path(path_text).is_absolute():
        errors.append("{}: {!r} must be a repo-relative path".format(where, path_text))
        return
    path = root / path_text
    if not path.is_file():
        errors.append("{}: source file {!r} does not exist".format(where, path_text))
        return
    if path_text not in line_cache:
        try:
            line_cache[path_text] = len(path.read_text(encoding="utf-8").splitlines())
        except (OSError, UnicodeDecodeError) as exc:
            errors.append("{}: cannot read {!r}: {}".format(where, path_text, exc))
            return
    total = line_cache[path_text]
    line = int(line_text)
    if line < 1 or line > total:
        errors.append(
            "{}: {!r} points at line {} but the file has {} lines".format(
                where, path_text, line, total
            )
        )


def _check_credential(credential, errors):
    if not isinstance(credential, dict):
        errors.append("input.credential: expected an object")
        return
    kind = credential.get("kind")
    if kind in ("none", "unavailable"):
        for name in ("header", "value", "headers"):
            if name in credential:
                errors.append(
                    "input.credential: kind {!r} must not carry {!r}".format(kind, name)
                )
    elif kind == "bearer":
        if not credential.get("value"):
            errors.append("input.credential: bearer needs a non-empty value")
        for name in ("header", "headers"):
            if name in credential:
                errors.append(
                    "input.credential: bearer must not carry {!r}".format(name)
                )
    elif kind == "api-key":
        if not credential.get("header"):
            errors.append("input.credential: api-key needs a header")
        if not credential.get("value"):
            errors.append("input.credential: api-key needs a value")
        if "headers" in credential:
            errors.append("input.credential: api-key must not carry headers")
    elif kind == "headers":
        headers = credential.get("headers")
        if not isinstance(headers, dict) or not headers:
            errors.append("input.credential: headers needs a non-empty map")
        else:
            _check_header_map(headers, "input.credential.headers", errors)
        for name in ("header", "value"):
            if name in credential:
                errors.append(
                    "input.credential: headers must not carry {!r}".format(name)
                )
    else:
        errors.append("input.credential: unknown kind {!r}".format(kind))


def _credential_secrets(credential):
    """Exact values a host-managed credential injects, longest first."""

    if not isinstance(credential, dict):
        return []
    values = []
    if credential.get("kind") == "headers":
        for name, value in (credential.get("headers") or {}).items():
            if not value:
                continue
            values.append(value)
            if name.lower() in ("authorization", "proxy-authorization"):
                scheme, _, remainder = value.partition(" ")
                if scheme.lower() in ("bearer", "basic", "token") and remainder.strip():
                    values.append(remainder.strip())
    elif credential.get("kind") == "bearer":
        value = credential.get("value")
        if value:
            values.append(value)
            values.append("Bearer " + value)
    elif credential.get("kind") == "api-key":
        if credential.get("value"):
            values.append(credential["value"])
    return sorted(set(values), key=len, reverse=True)


def _bounded_reason(raw, limit=REASON_LIMIT):
    """Normalise a diagnostic the way the gateway does: CR/LF to space, trim, cap."""

    text = raw.replace("\r\n", " ").replace("\r", " ").replace("\n", " ").strip()
    return text[:limit]


def _is_redirect_status(value):
    return isinstance(value, int) and not isinstance(value, bool) and 300 <= value < 400


def _check_contacts(exp, expected, errors):
    """A refused or unanswered hop is never re-sent: contacts equal sent hops."""

    if "upstream_contacts" not in exp:
        return
    if exp["upstream_contacts"] != expected:
        errors.append(
            "expect.upstream_contacts: {} hop(s) after the initial request means "
            "{} contact(s), not {}".format(
                expected - 1, expected, exp["upstream_contacts"]
            )
        )


def _check_semantics(doc, rel, root, line_cache):
    errors = []
    kind = doc["kind"]
    rule = doc["rule"]
    inp = doc["input"]
    exp = doc["expect"]
    credential = inp["credential"]

    # Resolve provenance first so even a malformed semantic still reports a
    # broken source instead of hiding it behind an early return.
    _check_source(root, doc["source"], "source", errors, line_cache)
    for index, value in enumerate(doc.get("references", [])):
        _check_source(root, value, "references[{}]".format(index), errors, line_cache)

    if rule == "response-redaction" and kind != "response":
        errors.append("response-redaction vectors must use kind 'response'")
    if rule == "redirect-scope" and kind != "redirect-chain":
        errors.append("redirect-scope vectors must use kind 'redirect-chain'")
    if rule == "failure-surface" and kind != "request":
        errors.append("failure-surface vectors must use kind 'request'")

    _check_credential(credential, errors)
    _check_header_map(inp["headers"], "input.headers", errors)
    _check_header_map(exp["outbound_headers"], "expect.outbound_headers", errors)
    if "response_headers" in exp:
        _check_header_map(exp["response_headers"], "expect.response_headers", errors)

    for index, entry in enumerate(inp["allowlist"]):
        if not isinstance(entry, str) or not entry:
            errors.append("input.allowlist[{}]: expected a non-empty string".format(index))

    invalid_request = exp.get("deny_reason") == "invalid_request"
    if invalid_request:
        # The whole point of this vector is a URL the gateway cannot parse:
        # there is no allow-list, credential or socket step to reach.
        if _url_host(inp["url"]) is not None:
            errors.append(
                "input.url: an invalid_request vector must carry a URL that is not "
                "a valid absolute http(s) URL"
            )
    else:
        _check_url(inp["url"], "input.url", errors)
    if exp["outbound_url"]:
        _check_url(exp["outbound_url"], "expect.outbound_url", errors)
    if "final_url" in exp:
        _check_url(exp["final_url"], "expect.final_url", errors)
    if "response" in inp:
        response = inp["response"]
        for name, item in (response.get("headers") or {}).items():
            if not _header_name_ok(name):
                errors.append(
                    "input.response.headers: {!r} must be lowercase".format(name)
                )
        if "body" in response and "body_bytes" in response:
            if len(response["body"].encode("utf-8")) != response["body_bytes"]:
                errors.append(
                    "input.response: body_bytes does not match body length"
                )
    if "redirects" in inp:
        for index, hop in enumerate(inp["redirects"]):
            _check_url(hop.get("location"), "input.redirects[{}].location".format(index), errors)

    transport_failure = inp.get("transport_failure")
    if transport_failure is not None:
        if not isinstance(transport_failure, str) or not transport_failure:
            errors.append("input.transport_failure: expected a non-empty string")
        if exp["dispatch"] != "deny" or exp.get("deny_reason") != "transport_failure":
            errors.append(
                "input.transport_failure: the exchange must deny with "
                "deny_reason transport_failure"
            )

    # ---------------------------------------------------------- stripped
    stripped = exp["stripped"]
    if stripped != sorted(stripped):
        # The list is an ordered comparison surface, not a set: two ports must
        # agree on the byte order (gateway-security.md §10).
        errors.append("expect.stripped: must be ASCII-sorted")
    seen = set()
    for name in stripped:
        if name in seen:
            errors.append("expect.stripped: duplicate {!r}".format(name))
        seen.add(name)
        if name not in {header.lower() for header in inp["headers"]}:
            errors.append(
                "expect.stripped: {!r} is not a caller request header".format(name)
            )
    outbound_names = {name.lower() for name in exp["outbound_headers"]}
    for name in stripped:
        if name in outbound_names:
            errors.append(
                "expect.stripped: {!r} is both stripped and in outbound_headers".format(name)
            )

    # ------------------------------------------------- caller credential
    if _has(exp["outbound_headers"], CALLER_SENTINEL):
        errors.append(
            "expect.outbound_headers: caller credential {!r} reached the outbound "
            "request".format(CALLER_SENTINEL)
        )
    for key in ("body", "body_json"):
        if key in exp and _has(exp[key], CALLER_SENTINEL):
            errors.append("expect.{}: still contains the caller credential".format(key))
    if _has(exp["outbound_headers"], WORKER_PLACEHOLDER):
        errors.append(
            "expect.outbound_headers: the Worker placeholder reached the outbound request"
        )
    for key in ("body", "body_json"):
        if key in exp and _has(exp[key], WORKER_PLACEHOLDER):
            errors.append("expect.{}: still contains the Worker placeholder".format(key))

    # A response body handed to the Worker may never carry a host-managed
    # secret: that is the whole point of the response-redaction rule.
    if kind == "response":
        for secret in _credential_secrets(credential):
            if _has(exp["outbound_headers"], secret):
                errors.append(
                    "expect.outbound_headers: response header still contains an "
                    "injected credential value"
                )
                break
        for key in ("body", "body_json"):
            if key not in exp:
                continue
            leaked = [secret for secret in _credential_secrets(credential) if _has(exp[key], secret)]
            if leaked:
                errors.append(
                    "expect.{}: redaction is incomplete, an injected credential "
                    "value is still present".format(key)
                )

    # ------------------------------------------------------ deny / allow
    dispatch = exp["dispatch"]
    if dispatch == "deny":
        if "deny_reason" not in exp:
            errors.append("expect: a deny must carry deny_reason")
        elif "failure" in exp and exp["failure"].get("code") != exp["deny_reason"]:
            errors.append("expect.failure.code must equal expect.deny_reason")
    else:
        if "deny_reason" in exp:
            errors.append("expect: an allow must not carry deny_reason")
        if "failure" in exp:
            errors.append("expect: an allow must not carry failure")

    failure = exp.get("failure")
    if failure is not None:
        code = failure.get("code")
        shape = FAILURE_SHAPES.get(code)
        if shape is None:
            errors.append("expect.failure.code: unknown code {!r}".format(code))
        else:
            status, proxy_error = shape
            if failure.get("proxy_status") != status:
                errors.append(
                    "expect.failure: {} maps to status {}".format(code, status)
                )
            if failure.get("proxy_error") != proxy_error:
                errors.append(
                    "expect.failure: {} maps to header value {!r}".format(
                        code, proxy_error
                    )
                )

        reason = failure.get("reason")
        if reason is not None:
            if "\n" in reason or "\r" in reason:
                errors.append("expect.failure.reason: must be newline-free")
            if len(reason) > REASON_LIMIT:
                errors.append(
                    "expect.failure.reason: longer than {} characters".format(
                        REASON_LIMIT
                    )
                )
            if _has(reason, CALLER_SENTINEL):
                errors.append(
                    "expect.failure.reason: carries the caller credential"
                )
            if _has(reason, WORKER_PLACEHOLDER):
                errors.append(
                    "expect.failure.reason: carries the Worker placeholder"
                )
            if any(
                secret and secret in reason
                for secret in _credential_secrets(credential)
            ):
                errors.append(
                    "expect.failure.reason: carries an injected credential value"
                )
        if transport_failure:
            expected_reason = _bounded_reason(
                TRANSPORT_REASON_PREFIX + _bounded_reason(transport_failure)
            )
            if reason is None:
                errors.append(
                    "expect.failure.reason: a transport failure must state the "
                    "bounded reason"
                )
            elif reason != expected_reason:
                errors.append(
                    "expect.failure.reason: must be the bounded transport reason"
                )
        if "body" in exp:
            try:
                envelope = json.loads(exp["body"])
            except ValueError:
                errors.append("expect.body: a failure body must be JSON")
            else:
                error_object = (
                    envelope.get("error") if isinstance(envelope, dict) else None
                )
                if not isinstance(error_object, dict):
                    errors.append(
                        "expect.body: a failure body must be the error envelope"
                    )
                else:
                    if error_object.get("code") != code:
                        errors.append(
                            "expect.body: envelope code must equal failure.code"
                        )
                    if reason is not None and error_object.get("message") != reason:
                        errors.append(
                            "expect.body: envelope message must equal failure.reason"
                        )

    # ------------------------------------------------------- kind rules
    if kind == "request":
        if inp.get("redirects"):
            errors.append("kind 'request' must not carry redirects")
        if dispatch == "allow":
            if exp["outbound_url"] != inp["url"]:
                errors.append("expect.outbound_url must be input.url on an allow")
            if exp.get("final_url") not in (None, inp["url"]):
                errors.append("expect.final_url must stay input.url without redirects")
        else:
            contacts = 0 if failure is None else failure.get("upstream_contacts", 0)
            sent = bool(exp["outbound_url"]) or contacts > 0
            if not sent:
                if exp["outbound_headers"]:
                    errors.append(
                        "expect.outbound_headers must be empty for a pre-flight deny"
                    )
                if failure is not None and failure.get("upstream_contacts") != 0:
                    errors.append(
                        "expect.failure.upstream_contacts must be 0 for a pre-flight deny"
                    )
                if "body" in exp or "body_json" in exp or "log" in exp:
                    errors.append("a pre-flight deny carries no response body or log")
                if "status" in exp or "response_headers" in exp:
                    errors.append(
                        "a pre-flight deny carries no response status or headers"
                    )
            else:
                # A transport failure after the credential was applied is
                # still a denial, but the request was built and one contact
                # happened: it is the opposite shape from a pre-flight deny.
                if not exp["outbound_url"]:
                    errors.append("a sent failure must state the contacted URL")
                elif exp["outbound_url"] != inp["url"]:
                    errors.append(
                        "expect.outbound_url must be input.url without redirects"
                    )
                if failure is None:
                    errors.append("a sent failure must carry a failure envelope")
                elif failure.get("code") not in SENT_FAILURE_CODES:
                    errors.append(
                        "a sent failure must use one of {}".format(
                            list(SENT_FAILURE_CODES)
                        )
                    )
                if contacts < 1:
                    errors.append(
                        "a sent failure must report at least one upstream contact"
                    )
                if "log" in exp:
                    errors.append("a sent failure carries no response log")
                if "body" in exp and "body_bytes" in exp:
                    if len(exp["body"].encode("utf-8")) != exp["body_bytes"]:
                        errors.append(
                            "expect.body_bytes does not match expect.body length"
                        )

    elif kind == "response":
        if "response" not in inp:
            errors.append("kind 'response' requires input.response")
        if inp.get("redirects"):
            errors.append("kind 'response' must not carry redirects")
        if dispatch != "allow":
            errors.append("kind 'response' describes a forwarded response, use allow")
        if exp["outbound_url"] != inp["url"]:
            errors.append("expect.outbound_url must be input.url on a response vector")
        response_status = (inp.get("response") or {}).get("status")
        forbids_body = inp["method"] == "HEAD" or (
            isinstance(response_status, int)
            and (
                100 <= response_status < 200
                or response_status in (204, 205, 304)
            )
        )
        if forbids_body:
            if exp.get("body_withheld"):
                errors.append(
                    "a body-forbidden response is suppressed, not withheld"
                )
            if exp.get("body", "") != "":
                errors.append("a body-forbidden response must suppress the body")
            if "body_json" in exp:
                errors.append(
                    "a body-forbidden response must not carry body_json"
                )
            if exp.get("body_bytes", 0) != 0:
                errors.append(
                    "a body-forbidden response must state body_bytes 0"
                )
        if "body_bytes" in exp and "body" in exp:
            if len(exp["body"].encode("utf-8")) != exp["body_bytes"]:
                errors.append("expect.body_bytes does not match expect.body length")
        if "body_sha256" in exp:
            material = None
            if "body" in exp:
                material = exp["body"].encode("utf-8")
            elif "body_json" in exp:
                material = json.dumps(
                    exp["body_json"],
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=False,
                ).encode("utf-8")
            else:
                errors.append(
                    "expect.body_sha256 requires expect.body or expect.body_json"
                )
            if material is not None:
                actual = hashlib.sha256(material).hexdigest()
                if actual != exp["body_sha256"]:
                    errors.append(
                        "expect.body_sha256 does not match the canonical body bytes"
                    )
        if inp.get("mcp"):
            log = exp.get("log") or {}
            if log.get("recorded") is not False:
                errors.append("an MCP call must exclude its response from the log")
            elif log.get("reason") != "sensitive_credential":
                errors.append(
                    "an MCP call must state log.reason sensitive_credential"
                )
        if exp.get("body_withheld"):
            if "body" not in exp and "body_json" not in exp:
                errors.append("a withheld body must still state the controlled body")
            log = exp.get("log") or {}
            if log.get("recorded") is not False:
                errors.append("a withheld body must not enter the response log")
        if "log" in exp:
            log = exp["log"]
            if log["recorded"]:
                # The positive-log vector is the oracle's only guard against a
                # gateway that never writes; its success reason is part of the
                # contract, not an implementation detail.
                if log.get("reason") != "recorded_ok":
                    errors.append(
                        "a recording log must state reason recorded_ok"
                    )
                if (
                    "body_bytes" in log
                    and log.get("retained_bytes") != log["body_bytes"]
                ):
                    errors.append("a recording log retains the whole body")
                if "body_bytes" in log and "body_bytes" in exp:
                    if log["body_bytes"] != exp["body_bytes"]:
                        errors.append(
                            "log.body_bytes must equal expect.body_bytes"
                        )
            else:
                if "reason" not in log:
                    errors.append("a non-recording log must state a reason")
                elif log.get("reason") == "recorded_ok":
                    errors.append("recorded_ok requires log.recorded true")
            if "body_bytes" in log and "retained_bytes" in log:
                if log["retained_bytes"] > log["body_bytes"]:
                    errors.append(
                        "log.retained_bytes cannot exceed log.body_bytes"
                    )
            if log.get("reason") == "quota_exceeded":
                quota = inp.get("quota_bytes")
                if quota is None:
                    errors.append("quota_exceeded needs input.quota_bytes")
                elif exp.get("body_bytes", 0) <= quota:
                    errors.append(
                        "quota_exceeded needs expect.body_bytes greater than quota_bytes"
                    )
                if log.get("retained_bytes") != 0:
                    errors.append("quota_exceeded must retain 0 bytes")
            if log.get("reason") == "sensitive_credential":
                sensitive = (
                    bool(inp.get("mcp"))
                    or (
                        credential.get("kind") == "headers"
                        and bool(credential.get("headers"))
                    )
                    or any(
                        value == WORKER_PLACEHOLDER for value in inp["headers"].values()
                    )
                )
                if not sensitive:
                    errors.append(
                        "sensitive_credential requires an MCP call, a host-managed "
                        "header credential, or the Worker placeholder"
                    )

    elif kind == "redirect-chain":
        redirects = inp.get("redirects") or []
        if not redirects:
            errors.append("kind 'redirect-chain' requires input.redirects")
            return errors
        followed = exp.get("redirects_followed", 0)
        if followed > len(redirects):
            errors.append(
                "expect.redirects_followed {} exceeds the {} hop(s)".format(
                    followed, len(redirects)
                )
            )
        if dispatch == "allow":
            if followed != len(redirects):
                errors.append("an allowed redirect chain must follow every hop")
            expected = redirects[-1]["location"] if redirects else inp["url"]
            if exp["outbound_url"] != expected:
                errors.append(
                    "expect.outbound_url must be the last followed URL {!r}".format(expected)
                )
            if exp.get("final_url", expected) != expected:
                errors.append("expect.final_url must be the last followed URL")
            if "status" in exp and "response" in inp:
                if exp["status"] != inp["response"]["status"]:
                    errors.append(
                        "expect.status: an allowed chain ends on input.response "
                        "status {}".format(inp["response"]["status"])
                    )
            _check_contacts(exp, followed + 1, errors)
        else:
            if followed >= len(redirects):
                errors.append("a denied chain must refuse a hop before the end")
            last_sent = redirects[followed - 1]["location"] if followed else inp["url"]
            if exp["outbound_url"] != last_sent:
                errors.append(
                    "expect.outbound_url must be the last contacted URL {!r}".format(last_sent)
                )
            if followed < len(redirects) and exp.get("final_url") != redirects[followed]["location"]:
                errors.append(
                    "expect.final_url must be the refused target {!r}".format(
                        redirects[followed]["location"]
                    )
                )
            if exp.get("deny_reason") not in REDIRECT_DENY_REASONS:
                errors.append(
                    "a denied redirect hop must use one of {}".format(
                        list(REDIRECT_DENY_REASONS)
                    )
                )
            if "failure" in exp:
                errors.append(
                    "a refused redirect returns the original 3xx, not an error envelope"
                )
            # The class invariant: every refused redirect must name the exact
            # 3xx it hands back. Without it the oracle can only prove "no
            # failure envelope", which any non-envelope answer also satisfies.
            reason = exp.get("deny_reason")
            if isinstance(reason, str) and reason.startswith("redirect_"):
                if "status" not in exp:
                    errors.append(
                        "a refused redirect must state expect.status (the refused "
                        "hop's own 3xx)"
                    )
                elif not _is_redirect_status(exp["status"]):
                    errors.append(
                        "expect.status: a refused redirect must stay 3xx, not {}".format(
                            exp["status"]
                        )
                    )
            refused = redirects[followed] if followed < len(redirects) else None
            if refused is not None and "status" in exp:
                if exp["status"] != refused["status"]:
                    errors.append(
                        "expect.status: must be the refused hop's own status {}, "
                        "not {}".format(refused["status"], exp["status"])
                    )
            if refused is not None and "response_headers" in exp:
                if exp["response_headers"].get("location") != refused["location"]:
                    errors.append(
                        "expect.response_headers.location: must be the refused "
                        "hop's Location {!r}".format(refused["location"])
                    )
            _check_contacts(exp, followed + 1, errors)

    return errors


def check(root):
    """Validate one tree and return ``(rows, stats)``.

    ``rows`` is a list of ``(ok, text)`` pairs, one per vector file plus one
    per coverage line. ``stats`` carries counts for the caller's summary.
    """

    root = Path(root).resolve()
    rows = []
    stats = {
        "vectors": 0,
        "rules": Counter(),
        "wildcard_allow": 0,
        "wildcard_deny": 0,
        "positive_log": 0,
    }

    try:
        spec_golden = load_validator(root)
    except ImportError as exc:
        rows.append((False, "FAIL: cannot import spec_golden.py: {}".format(exc)))
        return rows, stats

    schema_path = root / "spec" / "v1" / "schema" / "gateway-vector.schema.json"
    vectors_dir = root / "spec" / "v1" / "golden" / "gateway"
    if not schema_path.is_file():
        rows.append((False, "FAIL: missing {}".format(schema_path)))
        return rows, stats
    if not vectors_dir.is_dir():
        rows.append((False, "FAIL: missing {}".format(vectors_dir)))
        return rows, stats
    try:
        schema = spec_golden.load_json(schema_path)
    except spec_golden.SpecError as exc:
        rows.append((False, "FAIL schema: {}".format(exc)))
        return rows, stats

    paths = sorted(vectors_dir.glob("*.json"))
    if not paths:
        rows.append((False, "FAIL: no vectors in spec/v1/golden/gateway"))
        return rows, stats

    line_cache = {}
    seen_ids = {}
    sentinel_seen = False
    placeholder_seen = False

    for path in paths:
        rel = str(path.relative_to(root))
        try:
            doc = spec_golden.load_json(path)
        except spec_golden.SpecError as exc:
            rows.append((False, "FAIL {}: {}".format(rel, exc)))
            continue
        try:
            spec_golden.validate_json(doc, schema, rel)
        except spec_golden.SpecError as exc:
            rows.append((False, "FAIL {}: {}".format(rel, exc)))
            continue

        stats["vectors"] += 1
        if (doc["expect"].get("log") or {}).get("recorded") is True:
            stats["positive_log"] += 1
        errors = _check_semantics(doc, rel, root, line_cache)

        vector_id = doc["id"]
        if vector_id in seen_ids:
            errors.append(
                "duplicate id {!r} (also {})".format(vector_id, seen_ids[vector_id])
            )
        else:
            seen_ids[vector_id] = rel
        if path.stem != vector_id[3:]:
            errors.append(
                "file name {!r} does not match id minus the gw- prefix".format(path.name)
            )

        stats["rules"][doc["rule"]] += 1
        has_wildcard = any("*" in entry for entry in doc["input"]["allowlist"])
        if has_wildcard and doc["expect"]["dispatch"] == "allow":
            stats["wildcard_allow"] += 1
        if has_wildcard and doc["expect"]["dispatch"] == "deny":
            stats["wildcard_deny"] += 1
        for value in doc["input"]["headers"].values():
            if CALLER_SENTINEL.lower() in value.lower():
                sentinel_seen = True
            if value == WORKER_PLACEHOLDER:
                placeholder_seen = True

        if errors:
            rows.append(
                (False, "FAIL {}: {}".format(rel, "; ".join(errors)))
            )
        else:
            rows.append(
                (
                    True,
                    "ok  {}  {}  {}".format(rel, vector_id, doc["rule"]),
                )
            )

    # ------------------------------------------------------- coverage
    if stats["vectors"] < MIN_VECTORS:
        rows.append(
            (
                False,
                "FAIL coverage: {} vectors, at least {} required".format(
                    stats["vectors"], MIN_VECTORS
                ),
            )
        )
    missing = [rule for rule in RULES if stats["rules"][rule] < 1]
    if missing:
        rows.append((False, "FAIL coverage: rules without a vector {}".format(missing)))
    else:
        rows.append(
            (
                True,
                "ok  coverage rules " + " ".join(
                    "{}={}".format(rule, stats["rules"][rule]) for rule in RULES
                ),
            )
        )
    if stats["positive_log"] < 1:
        rows.append(
            (
                False,
                "FAIL coverage: no vector records a response (log.recorded true)",
            )
        )
    else:
        rows.append(
            (
                True,
                "ok  coverage positive log={}".format(stats["positive_log"]),
            )
        )
    if stats["wildcard_allow"] < 1 or stats["wildcard_deny"] < 1:
        rows.append(
            (
                False,
                "FAIL coverage: wildcard rules need at least one allow and one deny "
                "vector (allow={}, deny={})".format(
                    stats["wildcard_allow"], stats["wildcard_deny"]
                ),
            )
        )
    else:
        rows.append(
            (
                True,
                "ok  coverage wildcard allow={} deny={}".format(
                    stats["wildcard_allow"], stats["wildcard_deny"]
                ),
            )
        )
    if not sentinel_seen:
        rows.append(
            (
                False,
                "FAIL coverage: no vector sends the caller sentinel {!r}".format(
                    CALLER_SENTINEL
                ),
            )
        )
    if not placeholder_seen:
        rows.append(
            (
                False,
                "FAIL coverage: no vector carries the Worker placeholder {!r}".format(
                    WORKER_PLACEHOLDER
                ),
            )
        )
    return rows, stats


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="phone-dsh-v1 gateway security vector checker"
    )
    parser.add_argument(
        "--root", default=".", help="repository root (default: the current directory)"
    )
    args = parser.parse_args(argv)
    rows, stats = check(args.root)
    for ok, text in rows:
        print(text)
    failed = sum(1 for ok, _ in rows if not ok)
    print(
        "{} vectors checked, {} error(s)".format(stats["vectors"], failed)
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
