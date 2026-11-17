#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate the G-1 provenance contract and its shared vectors.

This is the independent reference implementation for spec/bot/v2/provenance.md:
source identity (observation envelope source+origin), source revision (native
basis or content digest, explicit unknown), `derivation` assertions, the
read-time `source_statuses` view and the derivation view (worst-of + upstream +
cycle). It validates schema shape, closed enums and reason/state consistency,
recomputes every golden case, and runs mutation checks. It never reads the Swift
implementation.

Usage:
    python3 spec/bot/v2/tools/validate_provenance.py            # check
    python3 spec/bot/v2/tools/validate_provenance.py --print    # recomputed cases
    python3 spec/bot/v2/tools/validate_provenance.py --write    # regenerate golden

Exit 0 on success, 1 on mismatch, 2 on usage/IO error.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))

from spec.v1.tools.spec_golden import SpecError, validate_json  # noqa: E402

BOT = ROOT / "spec" / "bot" / "v2"
GOLDEN = BOT / "golden" / "provenance.json"
STATES = ("current", "changed", "unavailable", "revoked", "erased", "unknown")
STATE_ORDER = {name: index for index, name in enumerate(STATES)}
# worst-of precedence: erased > revoked > changed > unavailable > unknown > current
WORST = ("erased", "revoked", "changed", "unavailable", "unknown", "current")
STATUS_REASONS = {
    "current": set(),
    "changed": {"source-changed"},
    "revoked": {"grant-revoked"},
    "erased": {"record-erased"},
    "unavailable": {"record-unresolved", "cycle-detected", "upstream-invalidated",
                    "scan-limit-exceeded"},
    "unknown": {
        "newer-observation-unversioned",
        "revision-basis-mismatch",
        "no-baseline",
        "source-version-unknown",
        "scan-limit-exceeded",
        "no-resource-identity",
        "resource-scope-mismatch",
        "refresh-not-performed",
        "refresh-unavailable",
        "refresh-denied",
        "cross-bot-unresolved",
    },
}
VIEW_REASONS = set().union(*STATUS_REASONS.values()) | {
    "upstream-invalidated",
    "no-derivation",
    "no-skill-write-event",
}
KNOWN_BASES = ("content-sha256", "etag", "last-modified", "provider-version")
RECORD_RE = r"^record://(session/(?!\.{1,2}#)[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$"


def load(name: str) -> dict:
    return json.loads((BOT / name).read_text())


def check(instance, schema_name: str, where: str) -> None:
    validate_json(instance, load(schema_name), where)


def rejects(instance, schema_name: str, where: str) -> None:
    try:
        check(instance, schema_name, where)
    except SpecError:
        return
    raise AssertionError(f"{where}: negative fixture unexpectedly validates")


def assert_equal(left, right, where: str) -> None:
    if left != right:
        raise AssertionError(
            f"{where}: mismatch\n  actual  = {json.dumps(left, ensure_ascii=False, sort_keys=True)}"
            f"\n  expected= {json.dumps(right, ensure_ascii=False, sort_keys=True)}"
        )


def sha256_text(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def observation_identity(record: dict) -> tuple[str, str] | None:
    observation = record.get("observation")
    if not isinstance(observation, dict):
        return None
    return (observation["source"], observation["origin"])


def record_trust(record: dict) -> str | None:
    if record.get("observation"):
        return "observation"
    if record.get("type") == "user/message":
        rpc = record.get("rpcId", "")
        if rpc.startswith(("bot-", "user-action:", "card-answer:")) or not rpc:
            return "user"
        return "assistant"
    if record.get("type") == "tool/result":
        return "assistant"
    return None


def record_revision(record: dict, ref: str) -> dict | None:
    """The source revision captured by one observation record, if derivable."""
    if not record.get("observation"):
        return record.get("version")
    explicit = record.get("version")
    if isinstance(explicit, dict):
        revision = copy.deepcopy(explicit)
        revision.setdefault("basis_ref", ref)
        return revision
    text = record.get("text")
    if isinstance(text, str):
        return {
            "basis": "content-sha256",
            "value": sha256_text(text),
            "observed_at_ms": record.get("at_ms"),
            "basis_ref": ref,
        }
    return {"reason": "record-without-content", "basis_ref": ref}


def sort_key(ref: str) -> tuple:
    if ref.startswith("record://event/"):
        return (1, 0, int(ref.rsplit("/", 1)[1]))
    session, seq = ref[len("record://session/"):].split("#", 1)
    return (0, int(seq), session)


def canonical_url(origin: str) -> str:
    from urllib.parse import urlsplit, urlunsplit
    parts = urlsplit(origin)
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()
    port = parts.port
    netloc = host
    if port and not ((scheme == "http" and port == 80) or (scheme == "https" and port == 443)):
        netloc = f"{host}:{port}"
    return urlunsplit((scheme, netloc, parts.path or "/", parts.query, ""))


def record_resource(record: dict) -> dict | None:
    explicit = record.get("resource")
    if isinstance(explicit, dict):
        return explicit
    observation = record.get("observation")
    if not isinstance(observation, dict):
        return None
    origin = observation.get("origin", "")
    owner = observation.get("owner") or record.get("botId")
    if observation.get("source") == "web" and origin.startswith(("http://", "https://")):
        return {"kind": "web-url", "key": canonical_url(origin), "owner": owner}
    if observation.get("source") == "attachment":
        return {"kind": "file", "key": origin, "owner": owner}
    return None


def resource_tuple(resource: dict | None) -> tuple | None:
    if resource is None:
        return None
    return (resource["kind"], resource["key"], resource.get("owner"), resource.get("scope"))


def observation_index(records: dict) -> dict[tuple, list[tuple[int, tuple, str]]]:
    index: dict[tuple, list[tuple[int, tuple, str]]] = {}
    for ref, record in records.items():
        if observation_identity(record) is None:
            continue
        identity = resource_tuple(record_resource(record))
        if identity is None:
            continue
        at = record.get("at_ms") or 0
        index.setdefault(identity, []).append((at, sort_key(ref), ref))
    for entries in index.values():
        entries.sort()
    return index


def erasure_of(records: dict, erasures: list, ref: str) -> bool:
    if records.get(ref, {}).get("erased") is True:
        return True
    return any(ref in item.get("records", []) for item in erasures)


def grant_revoked_seq(grants: list, grant_id: str) -> int | None:
    for grant in grants:
        if grant.get("id") == grant_id:
            seq = grant.get("revoked_at_seq")
            return seq if isinstance(seq, int) else None
    return None


def carrier_seq(carrier: str) -> int | None:
    if carrier.startswith("record://event/"):
        return int(carrier.rsplit("/", 1)[1])
    return None


def resource_identity(record: dict, explicit: dict | None) -> dict | None:
    if explicit is not None:
        return explicit
    return record_resource(record)


def source_status(ref: str, role: list[str], baseline: dict | None, context: dict) -> dict:
    records = context["records"]
    record = records.get(ref)
    status = {
        "ref": ref,
        "roles": sorted(set(role)),
        "resolved": False,
        "erased": False,
        "state": "current",
        "reasons": [],
        "observed_at_ms": None,
        "record_type": None,
        "trust": None,
    }
    if baseline is not None:
        status["source_version"] = baseline
        status["baseline"] = copy.deepcopy(baseline)
    if record is None:
        status.update(state="unavailable", reasons=["record-unresolved"])
        return status
    status["resolved"] = True
    status["observed_at_ms"] = record.get("at_ms")
    status["record_type"] = record.get("type")
    status["trust"] = record_trust(record)
    if erasure_of(records, context["erasures"], ref):
        status.update(erased=True, state="erased", reasons=["record-erased"])
        return status
    if context.get("scan_exceeded") and observation_identity(record) is not None \
            and baseline is not None:
        status.update(state="unknown", reasons=["scan-limit-exceeded"])
        return status
    grant_id = context["grant_by_ref"].get(ref)
    carrier = context.get("carrier")
    if grant_id:
        # A revoked grant is terminal: a later carrier cannot revive it by
        # citing the same grant. Re-authorization needs a new grant id or a
        # new generation, which is a different grant entry.
        revoked = grant_revoked_seq(context["grants"], grant_id)
        if revoked is not None:
            status.update(state="revoked", reasons=["grant-revoked"])
            return status
    identity = observation_identity(record)
    is_observation = identity is not None
    baseline = status.get("source_version")
    current = record_revision(record, ref)
    if current is not None and baseline is None and is_observation:
        status["source_version"] = current
    if current is not None and baseline is not None \
            and "basis" in current and "basis" in baseline \
            and (current.get("basis") != baseline.get("basis")
                 or current.get("value") != baseline.get("value")):
        raise AssertionError(
            f"{ref}: recorded baseline does not match the record's own revision")
    if current is not None and baseline is not None and "reason" in current \
            and "basis" in baseline:
        # The record itself no longer exposes a version; the baseline stays the
        # only recorded version, but the current state cannot be re-proven.
        status.update(state="unknown", reasons=["source-version-unknown"])
        return status
    if is_observation and baseline is None:
        status.update(state="unknown", reasons=["no-baseline"])
        return status
    if baseline is not None and "reason" in baseline:
        reason = baseline.get("reason")
        if reason in ("record-unresolved", "invalid-reference"):
            status.update(state="unavailable", reasons=["record-unresolved"])
        elif reason == "record-erased":
            status.update(erased=True, state="erased", reasons=["record-erased"])
        else:
            status.update(state="unknown", reasons=["source-version-unknown"])
        return status
    if is_observation:
        resource = resource_identity(record, status.get("resource"))
        if resource is not None:
            status["resource"] = resource
        if resource is None:
            status.update(state="unknown", reasons=["no-resource-identity"])
            return status
        key = resource_tuple(resource)
        entries = context["observations"].get(key, [])
        same_key = [ref2 for ref2, rec in records.items()
                    if observation_identity(rec) is not None
                    and (record_resource(rec) or {}).get("kind") == resource["kind"]
                    and (record_resource(rec) or {}).get("key") == resource["key"]
                    and resource_tuple(record_resource(rec)) != key
                    and (records[ref2].get("at_ms") or 0) >= (record.get("at_ms") or 0)]
        latest = entries[-1] if entries else None
        if latest is not None:
            latest_ref = latest[2]
            latest_record = records[latest_ref]
            newer = latest_ref != ref and (
                (latest[0], sort_key(latest_ref)) > (record.get("at_ms") or 0, sort_key(ref))
            )
            if newer:
                status["latest_ref"] = latest_ref
                latest_revision = record_revision(latest_record, latest_ref)
                if baseline is not None and latest_revision is not None:
                    if "basis" in baseline and "basis" in latest_revision:
                        if baseline.get("basis") != latest_revision.get("basis"):
                            status.update(state="unknown", reasons=["revision-basis-mismatch"])
                        elif baseline.get("value") != latest_revision.get("value"):
                            status.update(state="changed", reasons=["source-changed"])
                        return status
                    status.update(state="unknown", reasons=["newer-observation-unversioned"])
                    return status
                status.update(state="unknown", reasons=["newer-observation-unversioned"])
                return status
        if same_key:
            status.update(state="unknown", reasons=["resource-scope-mismatch"])
            return status
        recheck = context.get("recheck") or (baseline or {}).get("recheck")
        if recheck == "ok":
            status["rechecked_at_ms"] = context.get("checked_at_ms") or record.get("at_ms")
            status.update(state="current", reasons=[])
            return status
        if recheck == "denied":
            status.update(state="unknown", reasons=["refresh-denied"])
            return status
        if recheck == "unavailable":
            status.update(state="unknown", reasons=["refresh-unavailable"])
            return status
        status.update(state="unknown", reasons=["refresh-not-performed"])
        return status
    if baseline is not None and "basis" in baseline:
        status.update(state="current", reasons=[])
        return status
    status.update(state="current", reasons=[])
    return status


def worst_state(states: list[str]) -> str:
    for candidate in WORST:
        if candidate in states:
            return candidate
    return "current"


def cycle_members(artifacts: list, artifacts_by_carrier: dict[str, int], subject: int) -> set[int]:
    edges = {}
    for index, item in enumerate(artifacts):
        edges[index] = [
            artifacts_by_carrier[source["record"]]
            for source in item.get("derivation", {}).get("sources", [])
            if source.get("role", "basis") in ("evidence", "basis", "creator")
            and source.get("record") in artifacts_by_carrier
        ]
    done: set[int] = set()
    path: set[int] = set()
    cycle: set[int] = set()

    def visit(node: int) -> bool:
        if node in path:
            cycle.add(node)
            return True
        if node in done:
            return node in cycle
        path.add(node)
        found = False
        for nxt in edges.get(node, []):
            if visit(nxt):
                cycle.add(node)
                found = True
        path.discard(node)
        done.add(node)
        return found

    visit(subject)
    return cycle


def resolve_case(case: dict) -> dict:
    records = copy.deepcopy(case.get("records", {}))
    records.update(copy.deepcopy(case.get("global_records", {})))
    erasures = case.get("erasures", [])
    grants = case.get("grants", [])
    artifacts = case.get("artifacts", [])
    subject = case.get("subject", 0)
    artifacts_by_carrier: dict[str, int] = {}
    for index, item in enumerate(artifacts):
        carrier = item.get("carrier")
        if carrier:
            artifacts_by_carrier[carrier] = index
    grant_by_ref: dict[str, str] = {}
    for artifact in artifacts:
        for source in artifact.get("derivation", {}).get("sources", []):
            if source.get("grantId"):
                grant_by_ref[source["record"]] = source["grantId"]
    context = {
        "records": records,
        "erasures": erasures,
        "grants": grants,
        "observations": observation_index(records),
        "grant_by_ref": grant_by_ref,
        "carrier": artifacts[subject].get("carrier") if artifacts else None,
        "scan_exceeded": case.get("scan_exceeded", False),
        "recheck": case.get("recheck"),
        "checked_at_ms": case.get("checked_at_ms"),
    }

    def artifact_state(index: int, stack: tuple[int, ...], memo: dict[int, dict]) -> dict:
        if index in memo:
            return memo[index]
        if index in stack:
            result = {
                "artifact": artifacts[index]["derivation"]["artifact"],
                "state": "unavailable",
                "reasons": ["cycle-detected"],
                "sources": [],
                "review_effective": {"state": "unknown", "reasons": ["cycle-detected"]},
                "upstream": [],
            }
            return result
        artifact = artifacts[index]
        derivation = artifact.get("derivation", {})
        sources = []
        upstream = []
        for source in derivation.get("sources", []):
            status = source_status(source["record"], [source.get("role", "basis")],
                                   source.get("sourceVersion"), context)
            sources.append({
                "record": source["record"],
                "role": source.get("role", "basis"),
                "status": status,
            })
            upstream_index = artifacts_by_carrier.get(source["record"])
            if upstream_index is not None:
                nested = artifact_state(upstream_index, stack + (index,), memo)
                upstream.append({"artifact": nested["artifact"], "state": nested["state"]})
        sources.sort(key=lambda item: (item["record"], item["role"]))
        content_roles = ("evidence", "basis", "creator")
        content_sources = [item for item in sources if item["role"] in content_roles]
        member_states = [item["status"]["state"] for item in content_sources]
        member_states += [item["state"] for item in upstream]
        if member_states:
            state = worst_state(member_states)
        else:
            state = "unknown"
        reasons = sorted({
            reason
            for item in content_sources
            for reason in item["status"]["reasons"]
        } | {
            "upstream-invalidated" for item in upstream if item["state"] != "current"
        })
        artifact_kind = derivation.get("artifact", {}).get("kind")
        if artifact_kind == "skill":
            state, reasons = "unknown", ["no-skill-write-event"]
        if not derivation.get("sources"):
            state = "unknown"
            if artifact_kind != "skill":
                reasons = ["no-derivation"]
        elif not content_sources and artifact_kind != "skill":
            state, reasons = "unknown", ["no-derivation"]
        review = artifact.get("review")
        all_current = all(item["status"]["state"] == "current" for item in sources)
        review_reasons = sorted({
            reason for item in sources if item["role"] == "review"
            for reason in item["status"]["reasons"]})
        if review is None:
            review_effective = {"state": "unknown", "reasons": []}
        elif review.get("state") == "disputed":
            review_effective = {"state": "disputed", "reasons": review_reasons}
        elif review.get("state") == "unverified":
            review_effective = {"state": "unverified", "reasons": ["review-model-basis"]
                                if review.get("basis") == "model-inference" else []}
        elif review.get("state") == "verified":
            if all_current:
                review_effective = {"state": "verified", "reasons": []}
            else:
                review_effective = {"state": "unverified", "reasons": review_reasons or reasons}
        else:
            review_effective = {"state": "unknown", "reasons": []}
        upstream.sort(key=lambda item: (item["artifact"]["kind"], item["artifact"]["id"],
                                        item["artifact"].get("version", 0)))
        result = {
            "artifact": derivation.get("artifact"),
            "state": state,
            "reasons": reasons,
            "sources": [{"record": item["record"], "role": item["role"],
                         "status": item["status"]} for item in sources],
            "review_effective": review_effective,
            "upstream": upstream,
        }
        memo[index] = result
        return result

    view = artifact_state(subject, (), {})
    cycle = cycle_members(artifacts, artifacts_by_carrier, subject)
    if cycle:
        view["state"] = "unavailable"
        view["reasons"] = ["cycle-detected"]
        view["review_effective"] = {"state": "unknown", "reasons": ["cycle-detected"]}
        view["upstream"] = [
            {"artifact": artifacts[index]["derivation"]["artifact"], "state": "unavailable"}
            for index in sorted(cycle) if index != subject
        ]
    view["generation"] = {
        "head_commit_seq": max([0] + [int(ref.rsplit("/", 1)[1]) for ref in records
                                      if ref.startswith("record://event/")]),
        "last_erasure_seq": max([0] + [item.get("seq", 0) for item in erasures]),
        "last_grant_seq": max([0] + [grant.get("revoked_at_seq", 0) for grant in grants]),
    }
    if case.get("truncated"):
        view["truncated"] = True
    return view


def statuses_for_assertions(view: dict) -> list[dict]:
    return [
        {key: value for key, value in item["status"].items() if key != "roles"}
        for item in view["sources"]
    ]


def check_semantics(status: dict, where: str) -> None:
    reasons = set(status.get("reasons", []))
    state = status["state"]
    if state == "current":
        if reasons:
            raise AssertionError(f"{where}: current must not carry reasons {sorted(reasons)}")
        return
    if not reasons:
        raise AssertionError(f"{where}: {state} requires at least one reason")
    allowed = STATUS_REASONS[state]
    unknown = reasons - allowed
    if unknown:
        raise AssertionError(f"{where}: reasons {sorted(unknown)} not allowed for {state}")


def check_revision(revision: dict, where: str) -> None:
    if "reason" in revision:
        if revision["reason"] not in (
                "record-unresolved", "record-erased", "record-without-content",
                "source-unversioned", "invalid-reference"):
            raise AssertionError(f"{where}: unknown version reason {revision['reason']!r}")
        return
    basis = revision.get("basis")
    value = revision.get("value", "")
    if "subject" in revision:
        if basis != "content-sha256":
            raise AssertionError(f"{where}: subject is only valid with content-sha256")
        if revision["subject"] not in ("file-bytes", "record-text"):
            raise AssertionError(f"{where}: invalid subject")
    if basis == "content-sha256":
        if not (value.startswith("sha256:") and len(value) == 71
                and all(char in "0123456789abcdef" for char in value[7:])):
            raise AssertionError(f"{where}: content-sha256 value must be sha256:<64 lowercase hex>")
    elif basis == "provider-version":
        if not value.startswith("rev:") or len(value) <= 4:
            raise AssertionError(f"{where}: provider-version value must be rev:<opaque>")
    elif basis == "etag":
        if not value.startswith("etag:") or len(value) <= 5:
            raise AssertionError(f"{where}: etag value must be etag:<opaque>")
    elif basis == "last-modified":
        if not value.startswith("last-modified:") or len(value) <= 14:
            raise AssertionError(f"{where}: last-modified value must be last-modified:<date>")
    else:
        raise AssertionError(f"{where}: unknown basis {basis!r}")


def check_derivation_semantics(derivation: dict, where: str) -> None:
    seen = set()
    for source in derivation.get("sources", []):
        key = (source["record"], source.get("role", "basis"))
        if key in seen:
            raise AssertionError(f"{where}: duplicate (record,role) {key}")
        seen.add(key)


def check_gate() -> None:
    gate = json.loads((BOT / "maintenance-quality-gate.json").read_text())
    if gate.get("schema") != "bot-maintenance-quality-gate/v1":
        raise AssertionError("quality gate: schema id")
    if gate.get("default_state") != "off":
        raise AssertionError("quality gate: maintainer must default off")
    thresholds = gate.get("thresholds", {})
    if thresholds.get("correction_rate_min") != 0.75:
        raise AssertionError("quality gate: correction_rate_min")
    if thresholds.get("stale_detection_rate_min") != 0.75:
        raise AssertionError("quality gate: stale_detection_rate_min")
    if thresholds.get("mechanical_violations_max") != 0:
        raise AssertionError("quality gate: mechanical_violations_max")
    if thresholds.get("false_verified_max") != 0:
        raise AssertionError("quality gate: false_verified_max")
    if thresholds.get("memory_suite_regressions_max") != 0:
        raise AssertionError("quality gate: memory_suite_regressions_max")
    if thresholds.get("min_real_batches") != 2:
        raise AssertionError("quality gate: min_real_batches")
    samples = gate.get("samples", {})
    if samples.get("contradiction") != 2 or samples.get("stale_external") != 2:
        raise AssertionError("quality gate: frozen sample counts")


def load_golden_file(name: str) -> dict:
    return json.loads((BOT / "golden" / name).read_text())


def structural(value):
    if isinstance(value, dict):
        return {key: structural(item) for key, item in value.items()
                if key not in ("$schema", "title", "description")}
    if isinstance(value, list):
        return [structural(item) for item in value]
    return value


def check_inline_copies() -> None:
    status_schema = load("source-status.schema.json")
    revision_schema = load("source-revision.schema.json")
    for name, key in (("memory-read-result.schema.json", "document"),
                      ("memory-recall.schema.json", "hit")):
        schema = load(name)
        if key == "document":
            inline = schema["oneOf"][0]["properties"]["source_statuses"]["items"]
        else:
            inline = schema["properties"]["source_statuses"]["items"]
        assert_equal(structural(inline), structural(status_schema),
                     f"{name}: inline source_statuses item drift")
    view = load("derivation-view.schema.json")
    assert_equal(structural(view["properties"]["sources"]["items"]["properties"]["status"]),
                 structural(status_schema), "derivation-view: inline status drift")
    derivation = load("derivation.schema.json")
    assert_equal(structural(derivation["properties"]["sources"]["items"]["properties"]["sourceVersion"]),
                 structural(revision_schema), "derivation: inline sourceVersion drift")


def check_vectors(golden: dict) -> dict:
    for schema_name, schema in (("derivation.schema.json", "derivation"),
                                ("source-revision.schema.json", "source_revision"),
                                ("source-status.schema.json", "status"),
                                ("derivation-view.schema.json", "view")):
        for index, instance in enumerate(golden.get("valid", {}).get(schema, [])):
            check(instance, schema_name, f"valid.{schema}[{index}]")
            if schema == "derivation":
                check_derivation_semantics(instance, f"valid.{schema}[{index}]")
        for index, instance in enumerate(golden.get("invalid", {}).get(schema, [])):
            rejected = False
            try:
                check(instance, schema_name, f"invalid.{schema}[{index}]")
            except SpecError:
                rejected = True
            if not rejected and schema == "derivation":
                try:
                    check_derivation_semantics(instance, f"invalid.{schema}[{index}]")
                except AssertionError:
                    rejected = True
            if not rejected and schema == "status":
                try:
                    check_semantics(instance, f"invalid.{schema}[{index}]")
                except AssertionError:
                    rejected = True
            if not rejected and schema == "source_revision":
                try:
                    check_revision(instance, f"invalid.{schema}[{index}]")
                except AssertionError:
                    rejected = True
            if not rejected:
                raise AssertionError(f"invalid.{schema}[{index}]: unexpectedly validates")
        for index, revision in enumerate(golden.get("valid", {}).get("known_revisions", [])):
            check_revision(revision, f"valid.known_revisions[{index}]")
        for index, status in enumerate(golden.get("valid", {}).get("status", [])):
            check_semantics(status, f"valid.status[{index}]")
    for key in ("known_revisions", "status"):
        for index, instance in enumerate(golden.get("invalid", {}).get(key, [])):
            try:
                if key == "known_revisions":
                    check_revision(instance, f"invalid.{key}[{index}]")
                else:
                    check_semantics(instance, f"invalid.{key}[{index}]")
            except AssertionError:
                continue
            raise AssertionError(f"invalid.{key}[{index}]: unexpectedly accepted")
    for index, revision in enumerate(golden.get("invalid_known_revisions", [])):
        try:
            check_revision(revision, f"invalid_known_revisions[{index}]")
        except AssertionError:
            continue
        raise AssertionError(f"invalid_known_revisions[{index}]: unexpectedly accepted")
    for index, item in enumerate(golden.get("read_results", [])):
        check(item["result"], "memory-read-result.schema.json", f"read_results[{index}]")
    cases = golden.get("cases", [])
    results = {}
    for case in cases:
        for key in ("erasures", "grants"):
            if key not in case:
                raise AssertionError(f"case {case['name']}: missing {key} (decoder requires it)")
        view = resolve_case(case)
        check(view, "derivation-view.schema.json", f"case {case['name']}: view")
        for source in view["sources"]:
            status = source["status"]
            check_semantics(status, f"case {case['name']}: {status['ref']}")
            check(status, "source-status.schema.json", f"case {case['name']}: status")
        results[case["name"]] = view
        if "expected" in case:
            assert_equal({key: view[key] for key in ("artifact", "state", "reasons",
                                                    "review_effective", "upstream")},
                         {key: case["expected"][key] for key in ("artifact", "state", "reasons",
                                                                 "review_effective", "upstream")},
                         f"case {case['name']}")
            assert_equal(statuses_for_assertions(view), case["expected"]["sources"],
                         f"case {case['name']}: sources")
    return results


def mutation_count(golden: dict) -> int:
    count = 0
    for case in golden.get("cases", []):
        if "expected" not in case:
            continue
        expected = case["expected"]
        for field_name in ("state", "reasons"):
            mutated = copy.deepcopy(expected)
            if field_name == "state":
                mutated["state"] = "erased" if mutated["state"] != "erased" else "current"
            else:
                mutated["reasons"] = mutated["reasons"] + ["source-changed"] \
                    if "source-changed" not in mutated["reasons"] else ["no-baseline"]
            try:
                view = resolve_case(case)
                assert_equal({key: view[key] for key in ("state", "reasons")},
                             {key: mutated[key] for key in ("state", "reasons")},
                             f"mutation {case['name']}.{field_name}")
            except AssertionError:
                count += 1
                continue
            raise AssertionError(f"mutation {case['name']}.{field_name} was not detected")
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if not GOLDEN.exists():
        raise SystemExit(f"missing {GOLDEN}")
    golden = json.loads(GOLDEN.read_text())
    check_inline_copies()
    check_gate()
    if args.print:
        print(json.dumps({case["name"]: resolve_case(case) for case in golden.get("cases", [])},
                         ensure_ascii=False, indent=2))
        return 0
    if args.write:
        for case in golden.get("cases", []):
            view = resolve_case(case)
            case["expected"] = {
                "artifact": view["artifact"],
                "state": view["state"],
                "reasons": view["reasons"],
                "review_effective": view["review_effective"],
                "upstream": view["upstream"],
                "sources": statuses_for_assertions(view),
            }
        GOLDEN.write_text(json.dumps(golden, ensure_ascii=False, indent=2) + "\n")
        print(f"wrote {GOLDEN}")
        return 0
    results = check_vectors(golden)
    mutations = mutation_count(golden)
    print(f"provenance vectors: PASS (cases {len(results)}, mutations {mutations}, "
          f"schemas 4, inline copies 3)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SpecError as error:
        print(f"provenance vectors: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
    except AssertionError as error:
        print(f"provenance vectors: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
