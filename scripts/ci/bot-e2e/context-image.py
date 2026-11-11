#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply an eval-only context profile to a derived copy of the packed Worker image.

The production Worker image is packed from ``plugins/profile/phone.worker.cordis.patch.yml``
and carries the default compaction/pruner rows. BOT-E01 needs a context threshold
it can actually cross inside its budget; changing the production profile would
change every Bot. This helper keeps the production artifact untouched and writes
a derived ``image.tar.gz`` whose ``home/cordis.patch.yml`` has the same rows with
eval-only values substituted.

Only the four context rows are touched (top-level rows and the copies nested in
the agent presets). Every other image entry is copied byte-for-byte. The helper
fails closed when the expected rows cannot be found, so a profile change can
never silently produce an image that still runs the production threshold.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path

ROW_IDS = ("compaction-basic", "tool-result-pruner", "spill-policy", "spill-local")
HOME_PATCH = "home/cordis.patch.yml"


class ContextImageError(Exception):
    """The profile or the source image cannot produce the derived image."""


def _require(condition, message):
    if not condition:
        raise ContextImageError(message)


def load_profile(path: Path, name: str):
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContextImageError(f"cannot read eval context profiles {path}: {exc}") from exc
    profiles = document.get("profiles")
    _require(isinstance(profiles, dict), f"{path} has no profiles object")
    profile = profiles.get(name)
    _require(isinstance(profile, dict), f"{path} has no profile {name!r}")
    for key in ("compaction", "pruner", "spillPolicy", "spillLocal"):
        _require(isinstance(profile.get(key), dict), f"profile {name!r} lacks {key}")
    return profile


def _yaml_scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        if value == "":
            return "''"
        # These values are simple profile scalars; quote defensively so a
        # future display name cannot turn into YAML syntax.
        escaped = value.replace("'", "''")
        return f"'{escaped}'"
    if isinstance(value, list):
        _require(not value, "the eval profile does not use list-valued context settings")
        return "[]"
    raise ContextImageError(f"unsupported YAML scalar {value!r}")


def _config_lines(row_id: str, profile) -> list[str]:
    if row_id == "compaction-basic":
        values = profile["compaction"]
        order = [
            "auto", "thresholdRatio", "headroomTokens", "retainRatio", "maxTokens",
            "summarizationProvider", "summarizationModel", "compactionRetries",
            "maxOverflowRetries", "modelPolicies",
        ]
        return [f"{key}: {_yaml_scalar(values[key])}" for key in order]
    if row_id == "tool-result-pruner":
        values = profile["pruner"]
        return [f"{key}: {_yaml_scalar(values[key])}"
                for key in ("thresholdChars", "headChars", "tailChars")]
    if row_id == "spill-policy":
        values = profile["spillPolicy"]
        return [f"maxInlineTokens: {_yaml_scalar(values['maxInlineTokens'])}"]
    if row_id == "spill-local":
        values = profile["spillLocal"]
        return [f"cleanupPeriodDays: {_yaml_scalar(values['cleanupPeriodDays'])}"]
    raise ContextImageError(f"unknown context row {row_id!r}")


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def rewrite_home_patch(text: str, profile) -> tuple[str, dict]:
    lines = text.splitlines()
    trailing_newline = text.endswith("\n")
    counts = {row_id: 0 for row_id in ROW_IDS}
    nested = {row_id: 0 for row_id in ROW_IDS}
    top = {row_id: 0 for row_id in ROW_IDS}

    # Work from the end so removing/adding lines never invalidates an earlier
    # start index.
    for row_id in ROW_IDS:
        starts = [index for index, line in enumerate(lines)
                  if line.startswith("- id: ") or line.lstrip(" ").startswith("- id: ")]
        # Process this row id only; later row ids are handled in their own pass.
        positions = [index for index in starts if lines[index].strip() == f"- id: {row_id}"]
        for start in reversed(positions):
            row_indent = _indent(lines[start])
            end = start + 1
            while end < len(lines):
                line = lines[end]
                if line.strip() and _indent(line) <= row_indent:
                    break
                end += 1
            block = lines[start:end]
            config_at = None
            name_at = None
            for offset, line in enumerate(block):
                if not line.strip():
                    continue
                if _indent(line) == row_indent + 2 and line.strip() == "config:":
                    config_at = start + offset
                if _indent(line) == row_indent + 2 and line.strip().startswith("name:"):
                    name_at = start + offset
            config_lines = _config_lines(row_id, profile)
            rendered = [" " * (row_indent + 2) + "config:"]
            rendered.extend(" " * (row_indent + 4) + line for line in config_lines)
            if config_at is not None:
                # Drop the existing config mapping. Every line under it is more
                # indented than the mapping key; a new key at the same key
                # indent or the next row ends the mapping.
                remove_end = config_at + 1
                while remove_end < len(lines):
                    candidate = lines[remove_end]
                    if candidate.strip() and _indent(candidate) <= row_indent + 2:
                        break
                    remove_end += 1
                lines[config_at:remove_end] = rendered
            else:
                insert_at = (name_at + 1) if name_at is not None else (start + 1)
                lines[insert_at:insert_at] = rendered
            counts[row_id] += 1
            if row_indent == 0:
                top[row_id] += 1
            else:
                nested[row_id] += 1

    # A row that is absent from the image is fine only for the rows that do not
    # implement compaction's threshold. A missing compaction or pruner row
    # means the derived image would still use the production behavior.
    _require(counts["compaction-basic"] >= 1,
             f"{HOME_PATCH} has no compaction-basic row to rewrite")
    _require(counts["tool-result-pruner"] >= 1,
             f"{HOME_PATCH} has no tool-result-pruner row to rewrite")
    _require(top["compaction-basic"] >= 1,
             f"{HOME_PATCH} has no top-level compaction-basic row")
    _require(nested["compaction-basic"] >= 1,
             f"{HOME_PATCH} has no preset-nested compaction-basic row; the eval "
             "profile would only change the host-level tree")

    banner = [
        "# SPDX-License-Identifier: MIT",
        "# Derived by scripts/ci/bot-e2e/context-image.py for the Bot eval runner.",
        "# The production image and the production profile are unchanged.",
        f"# Eval context profile: {profile.get('name', '<unnamed>')}",
    ]
    # Keep an existing SPDX/comment header stable; only prepend when the source
    # does not already carry the eval banner.
    if not any("Derived by scripts/ci/bot-e2e/context-image.py" in line for line in lines[:5]):
        lines = banner + lines
    output = "\n".join(lines)
    if trailing_newline and not output.endswith("\n"):
        output += "\n"
    return output, {"counts": counts, "top_level": top, "nested": nested}


def derive_image(source: Path, out: Path, profile, evidence_path: Path):
    if not source.is_file():
        raise ContextImageError(f"source image not found: {source}")
    out.parent.mkdir(parents=True, exist_ok=True)
    counts = None
    source_hash = hashlib.sha256()
    with open(source, "rb") as raw:
        for chunk in iter(lambda: raw.read(1 << 20), b""):
            source_hash.update(chunk)
    with tarfile.open(source, "r:gz") as source_tar:
        # The phone VFS tar reader supports plain ustar records only; PAX
        # extended headers (`@PaxHeader`) are rejected at boot. The source
        # image is ustar, so keep that format for the derived copy.
        with tarfile.open(out, "w:gz", compresslevel=6,
                          format=tarfile.USTAR_FORMAT) as target_tar:
            found = False
            for member in source_tar.getmembers():
                if member.name == HOME_PATCH:
                    found = True
                    fileobj = source_tar.extractfile(member)
                    if fileobj is None:
                        raise ContextImageError(f"{HOME_PATCH} is not a regular file")
                    text = fileobj.read().decode("utf-8")
                    rewritten, counts = rewrite_home_patch(text, profile)
                    payload = rewritten.encode("utf-8")
                    info = tarfile.TarInfo(member.name)
                    info.size = len(payload)
                    info.mode = member.mode
                    info.mtime = member.mtime
                    info.uid = member.uid
                    info.gid = member.gid
                    info.uname = member.uname
                    info.gname = member.gname
                    target_tar.addfile(info, io.BytesIO(payload))
                    continue
                if member.isdir() or member.issym() or member.islnk():
                    target_tar.addfile(member)
                    continue
                fileobj = source_tar.extractfile(member)
                if fileobj is None:
                    target_tar.addfile(member)
                    continue
                target_tar.addfile(member, fileobj)
    _require(found, f"source image has no {HOME_PATCH}")
    with tarfile.open(out, "r:gz") as verify_tar:
        unsupported = [member.name for member in verify_tar.getmembers()
                       if member.type not in (tarfile.REGTYPE, tarfile.DIRTYPE,
                                              tarfile.SYMTYPE, tarfile.LNKTYPE)]
    _require(not unsupported,
             f"derived image has unsupported tar entry types: {unsupported[:5]}")
    output_hash = hashlib.sha256()
    with open(out, "rb") as raw:
        for chunk in iter(lambda: raw.read(1 << 20), b""):
            output_hash.update(chunk)
    evidence = {
        "version": 1,
        "profile": profile.get("name"),
        "source_image": str(source),
        "source_sha256": source_hash.hexdigest(),
        "output_image": str(out),
        "output_sha256": output_hash.hexdigest(),
        "home_patch": HOME_PATCH,
        "rewritten_rows": counts,
        "profile_values": {key: profile[key] for key in
                           ("compaction", "pruner", "spillPolicy", "spillLocal")},
    }
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n",
                             encoding="utf-8")
    return evidence


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", type=Path, required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--source-image", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        profile = load_profile(args.profiles, args.profile)
        profile = {**profile, "name": args.profile}
        evidence = derive_image(args.source_image, args.out, profile, args.evidence)
    except ContextImageError as exc:
        print(f"context-image: {exc}", file=sys.stderr)
        return 1
    print(f"context-image: {evidence['profile']} -> {evidence['output_image']}")
    print(f"context-image: rows {evidence['rewritten_rows']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
