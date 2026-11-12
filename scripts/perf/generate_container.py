#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate the W0 synthetic app container for the three plan profiles.

The fixture is deliberately small in surface and large only in bytes:

* ``materialized/home/sessions/<project-key>/<session-id>/session.v4.jsonl``
  are real-format DSH v4 session journals (one JSON object per line, the
  first record is the session header).  The field names and shapes mirror the
  fixtures and readers already in this repository, not an invented schema.
* ``materialized/workspace`` is a real (if minimal) git repository with one
  commit, plus a deterministic set of large files.

Nothing else is fabricated by default.  WAL segments, the journal, steps,
response-log bodies and overlay archives are created by the host when the app
runs; the optional ``--store-stubs`` mode writes deterministic byte patterns
only so the measurement script and a dry run have something to classify.  The
stub files are *not* replayable protocol data and the manifest says so.

The whole tree is a deterministic function of ``--seed`` and the profile:
no wall-clock timestamp, inode number, random UUID or dictionary iteration
order reaches the output.  Running the same command twice therefore produces
identical bytes and identical file sizes.

Usage:
    python3 scripts/perf/generate_container.py --profile light --output /tmp/c
    python3 scripts/perf/generate_container.py --profile heavy  --output /tmp/c

The profile table is defined in ``docs/perf/README.md``; the sizes here are
synthetic fixture targets, never device measurements.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
import stat
import struct
import sys
import uuid
import zlib
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

MIB = 1024 * 1024
KIB = 1024

PROJECT_KEY = "--dsh-workspace--"
SESSION_CWD = "/dsh/workspace"
BASE_TIME_MS = 1_760_000_000_000
GIT_TIME = 1_760_000_000
GIT_AUTHOR = "phone-dsh perf fixture <perf-fixture@example.invalid>"

# One line of JSON is cheap to build; the exact-size writer only needs the
# encoded line length, which it measures directly.
_ENCODER = lambda obj: json.dumps(  # noqa: E731 - one expression, no state
    obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True
).encode("utf-8") + b"\n"


@dataclass(frozen=True)
class Profile:
    """One row of plan §1.3."""

    name: str
    sessions: int
    workspace_bytes: int
    longest_session_bytes: int
    short_session_bytes: int
    continuous_run: str
    purpose: str


PROFILES: Dict[str, Profile] = {
    "light": Profile(
        name="light",
        sessions=20,
        workspace_bytes=50 * MIB,
        longest_session_bytes=1 * MIB,
        short_session_bytes=24 * KIB,
        continuous_run="a few uses per day",
        purpose="regression floor",
    ),
    "typical": Profile(
        name="typical",
        sessions=150,
        workspace_bytes=150 * MIB,
        longest_session_bytes=7 * MIB,
        short_session_bytes=48 * KIB,
        continuous_run="1-2 hours per day",
        purpose="primary acceptance profile",
    ),
    "heavy": Profile(
        name="heavy",
        sessions=500,
        workspace_bytes=288 * MIB,
        longest_session_bytes=20 * MIB,
        short_session_bytes=64 * KIB,
        continuous_run="8 hours without a kill, 30 days without reinstall",
        purpose="stability and storage ceiling",
    ),
}

MIN_SESSION_BYTES = 4096
FINAL_RESERVE_BYTES = 2048

# ASCII only, so one character in a padded final message is one byte.
_WORDS = (
    "baseline workspace session turn step tool result request response model "
    "storage journal overlay recovery materialized durable epoch segment "
    "snapshot transcript container profile measurement latency write read "
    "queue outbox retry cancel approval identity cache buffer stream frame"
).split()


def _digest(*parts: object) -> bytes:
    return hashlib.sha256("|".join(str(part) for part in parts).encode("utf-8")).digest()


def _uuid_for(seed: int, label: str) -> str:
    # UUID version/variant bits are set by the constructor; all remaining bits
    # come from the seed, so this is stable across processes and platforms.
    return str(uuid.UUID(bytes=_digest(seed, label)[:16], version=4))


def _text(seed: int, label: str, length: int) -> str:
    """Deterministic ASCII prose of exactly ``length`` characters."""
    if length <= 0:
        return ""
    rng = random.Random(int.from_bytes(_digest(seed, label, "words")[:8], "big"))
    words: List[str] = []
    size = 0
    while size < length:
        word = rng.choice(_WORDS)
        words.append(word)
        size += len(word) + 1
    return (" ".join(words))[:length].ljust(length, "x")


def _pattern(seed: int, label: str, length: int, block_size: int = 64 * KIB) -> bytes:
    """Deterministic non-compressible-looking byte pattern of exact length."""
    if length <= 0:
        return b""
    block = bytearray()
    counter = 0
    while len(block) < block_size:
        block.extend(hashlib.sha256(_digest(seed, label, counter)).digest())
        counter += 1
    data = bytes(block[:block_size])
    whole, tail = divmod(length, len(data))
    return data * whole + data[:tail]


def _write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.write(data)
        handle.flush()


def _write_pattern(path: Path, seed: int, label: str, length: int) -> None:
    if length < 0:
        raise ValueError("negative file length")
    path.parent.mkdir(parents=True, exist_ok=True)
    block = _pattern(seed, label, min(length, 64 * KIB))
    if not block:
        _write_bytes(path, b"")
        return
    with path.open("wb") as handle:
        remaining = length
        while remaining:
            chunk = block[: min(remaining, len(block))]
            handle.write(chunk)
            remaining -= len(chunk)
        handle.flush()


# --------------------------------------------------------------------------
# DSH v4 session journals


class _SessionState:
    __slots__ = ("seq", "time")

    def __init__(self, seq: int = 0, time_ms: int = BASE_TIME_MS) -> None:
        self.seq = seq
        self.time = time_ms

    def copy(self) -> "_SessionState":
        return _SessionState(self.seq, self.time)

    def next(self, record_type: str, data: dict, surface_op: Optional[str] = None) -> dict:
        self.time += 17
        record = {
            "type": record_type,
            "seq": self.seq,
            "time": self.time,
            "data": data,
        }
        if surface_op is not None:
            record["surfaceOp"] = surface_op
        self.seq += 1
        return record


def _content(text: str) -> List[dict]:
    return [{"type": "text", "text": text}]


def _user_message(state: _SessionState, seed: int, label: str, length: int) -> dict:
    return state.next(
        "user/message",
        {
            "message": {"role": "user", "content": _content(_text(seed, label, length))},
            "source": {"kind": "user", "rpcId": _uuid_for(seed, label + ":rpc")},
        },
        surface_op="append",
    )


def _assistant_message(state: _SessionState, seed: int, label: str, length: int,
                       turn: int, step: int) -> dict:
    return state.next(
        "assistant/message",
        {
            "turn": turn,
            "step": step,
            "message": {"role": "assistant", "content": _content(_text(seed, label, length))},
        },
        surface_op="append",
    )


def _tool_call(state: _SessionState, seed: int, label: str, turn: int, step: int,
               call_id: str) -> dict:
    names = ("bash", "read_file", "write_file", "grep", "web_fetch")
    name = names[int.from_bytes(_digest(seed, label, "tool")[:1], "big") % len(names)]
    if name == "bash":
        arguments = {"command": "git status --short && ls -la"}
    elif name == "web_fetch":
        arguments = {"url": "https://example.com/fixture"}
    else:
        arguments = {"path": "src/fixture.py", "query": "fixture"}
    return state.next(
        "tool/call",
        {
            "turn": turn,
            "step": step,
            "callId": call_id,
            "name": name,
            "arguments": json.dumps(arguments, separators=(",", ":"), sort_keys=True),
        },
    )


def _tool_result(state: _SessionState, seed: int, label: str, turn: int, step: int,
                 call_id: str, length: int) -> dict:
    return state.next(
        "tool/result",
        {
            "turn": turn,
            "step": step,
            "message": {
                "role": "tool",
                "toolCallId": call_id,
                "isError": False,
                "content": _content(_text(seed, label, length)),
            },
            "source": {"kind": "tool", "callId": call_id},
        },
        surface_op="append",
    )


def _turn_records(state: _SessionState, seed: int, label: str, turn: int,
                  chunk_bytes: int) -> List[dict]:
    records = [state.next("turn/start", {"turn": turn})]
    records.append(state.next("step/start", {"turn": turn, "step": 1}))
    records.append(_user_message(state, seed, f"{label}:u{turn}", max(16, chunk_bytes // 4)))
    records.append(_assistant_message(
        state, seed, f"{label}:a{turn}", max(32, chunk_bytes // 2), turn, 1))
    if turn % 3 == 0:
        call_id = f"call-{_digest(seed, label, turn)[:8].hex()}"
        records.append(_tool_call(state, seed, label, turn, 1, call_id))
        records.append(_tool_result(
            state, seed, f"{label}:r{turn}", turn, 1, call_id,
            max(16, chunk_bytes // 4)))
    records.append(state.next("step/end", {"turn": turn, "step": 1}))
    records.append(state.next("turn/end", {"turn": turn, "reason": {"kind": "completed"}}))
    return records


def _encoded_size(records: Sequence[dict]) -> int:
    return sum(len(_ENCODER(record)) for record in records)


def _write_session(path: Path, target_bytes: int, *, seed: int, session_id: str) -> None:
    """Write one DSH v4 JSONL journal whose file size is exactly ``target_bytes``."""
    if target_bytes < MIN_SESSION_BYTES:
        raise ValueError(f"session target {target_bytes} is below {MIN_SESSION_BYTES} bytes")

    header = {
        "type": "session",
        "version": 4,
        "id": session_id,
        "createdAt": BASE_TIME_MS,
        "cwd": SESSION_CWD,
        "isSeeded": False,
        "delegationDepth": 0,
    }
    header_line = _ENCODER(header)
    if target_bytes <= len(header_line) + FINAL_RESERVE_BYTES:
        raise ValueError("session target is too small for a header and one turn")

    label = f"{seed}:{session_id}"
    path.parent.mkdir(parents=True, exist_ok=True)
    state = _SessionState(time_ms=BASE_TIME_MS)
    written = 0
    turn = 0

    with path.open("wb") as handle:
        handle.write(header_line)
        written += len(header_line)

        while True:
            turn += 1
            # Vary the chunk deterministically so the journal is not a long
            # run of identical records, but keep each turn small enough that
            # the final exact-size turn needs only a short filler message.
            chunk = 512 + ((turn * 211 + int.from_bytes(_digest(seed, label, turn)[:2], "big"))
                           % 4096)
            candidate_state = state.copy()
            records = _turn_records(candidate_state, seed, label, turn, chunk)
            encoded = [_ENCODER(record) for record in records]
            size = sum(len(line) for line in encoded)
            if written + size + FINAL_RESERVE_BYTES > target_bytes:
                break
            for line in encoded:
                handle.write(line)
            written += size
            state = candidate_state

        # Final turn: every record is fixed except the assistant text, which
        # is padded by exactly the number of bytes still missing.  The padding
        # is ASCII, so one character is one byte.
        final_turn = turn + 1
        fixed_state = state.copy()
        fixed: List[dict] = [
            fixed_state.next("turn/start", {"turn": final_turn}),
            fixed_state.next("step/start", {"turn": final_turn, "step": 1}),
            _user_message(fixed_state, seed, f"{label}:final-u", 64),
        ]
        placeholder = _assistant_message(
            fixed_state, seed, f"{label}:final-a", 0, final_turn, 1)
        fixed.extend([
            placeholder,
            fixed_state.next("step/end", {"turn": final_turn, "step": 1}),
            fixed_state.next("turn/end", {"turn": final_turn, "reason": {"kind": "completed"}}),
        ])
        fixed_bytes = _encoded_size(fixed)
        padding = target_bytes - written - fixed_bytes
        if padding < 1:
            raise ValueError(
                f"cannot pad session {session_id}: target={target_bytes} used={written} "
                f"fixed={fixed_bytes}")
        placeholder["data"]["message"]["content"] = _content(
            _text(seed, f"{label}:final-fill", padding))
        final_lines = [_ENCODER(record) for record in fixed]
        for line in final_lines:
            handle.write(line)
        written += sum(len(line) for line in final_lines)
        handle.flush()

    actual = path.stat().st_size
    if actual != target_bytes:
        raise AssertionError(
            f"session {session_id}: wrote {actual} bytes, expected {target_bytes}")


# --------------------------------------------------------------------------
# A minimal, deterministic git repository (pure stdlib)


def _git_object(kind: str, payload: bytes) -> Tuple[str, bytes]:
    body = kind.encode("ascii") + b" " + str(len(payload)).encode("ascii") + b"\0" + payload
    return hashlib.sha1(body).hexdigest(), zlib.compress(body, 9)


def _git_tree(entries: Iterable[Tuple[str, bytes, bool]]) -> Tuple[str, bytes]:
    # entries: (name, object id, is_tree), already sorted by name.
    payload = bytearray()
    for name, object_id, is_tree in entries:
        mode = b"40000" if is_tree else b"100644"
        payload.extend(mode + b" " + name.encode("utf-8") + b"\0")
        payload.extend(object_id)
    return _git_object("tree", bytes(payload))


def _write_loose_object(git_dir: Path, object_id: str, compressed: bytes) -> None:
    path = git_dir / "objects" / object_id[:2] / object_id[2:]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(compressed)


def _build_git_repo(repo: Path, seed: int, source_budget: int) -> int:
    """Create a one-commit repository and return the number of regular-file bytes."""
    git_dir = repo / ".git"
    git_dir.mkdir(parents=True, exist_ok=True)

    # A small source tree: README, a package module, a test module and docs.
    source_files: Dict[str, bytes] = {}
    names = [
        ("README.md", 1, "text"),
        ("src/fixture.py", 3, "python"),
        ("src/helpers.py", 2, "python"),
        ("tests/test_fixture.py", 2, "python"),
        ("docs/notes.md", 2, "text"),
        (".gitignore", 1, "gitignore"),
    ]
    weights = [max(1, weight) for _, weight, _ in names]
    total_weight = sum(weights)
    for (name, weight, kind), _ in zip(names, weights):
        if kind == "gitignore":
            content = b"assets/\n"
        elif kind == "python":
            body = _text(seed, f"source:{name}", max(64, source_budget * weight // total_weight))
            content = (
                "# SPDX-License-Identifier: MIT\n"
                "# Synthetic file generated by scripts/perf/generate_container.py.\n"
                f"VALUE = {body!r}\n"
            ).encode("utf-8")
        else:
            body = _text(seed, f"source:{name}", max(64, source_budget * weight // total_weight))
            content = (
                "# Synthetic workspace fixture\n\n"
                "This file is part of the phone-dsh W0 performance fixture. "
                "It is not a measurement.\n\n"
                f"{body}\n"
            ).encode("utf-8")
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        source_files[name] = content

    # Build blobs and a tree per directory.
    blob_ids: Dict[str, str] = {}
    for name, content in source_files.items():
        object_id, compressed = _git_object("blob", content)
        blob_ids[name] = object_id
        _write_loose_object(git_dir, object_id, compressed)

    tree_entries: Dict[str, List[Tuple[str, bytes, bool]]] = {}
    for name, object_id in blob_ids.items():
        parent, _, leaf = name.rpartition("/")
        tree_entries.setdefault(parent, []).append((leaf, bytes.fromhex(object_id), False))

    tree_ids: Dict[str, str] = {}
    for parent in sorted(tree_entries, key=lambda p: (p.count("/"), p), reverse=True):
        entries = sorted(tree_entries[parent], key=lambda item: item[0])
        object_id, compressed = _git_tree(entries)
        tree_ids[parent] = object_id
        _write_loose_object(git_dir, object_id, compressed)
        if parent:
            grandparent, _, leaf = parent.rpartition("/")
            tree_entries.setdefault(grandparent, []).append((leaf, bytes.fromhex(object_id), True))

    root_tree = tree_ids[""]
    commit_body = (
        f"tree {root_tree}\n"
        f"author {GIT_AUTHOR} {GIT_TIME} +0000\n"
        f"committer {GIT_AUTHOR} {GIT_TIME} +0000\n"
        "\n"
        "Synthetic W0 fixture\n"
    ).encode("utf-8")
    commit_id, commit_compressed = _git_object("commit", commit_body)
    _write_loose_object(git_dir, commit_id, commit_compressed)

    (git_dir / "HEAD").write_text("ref: refs/heads/main\n", encoding="ascii")
    (git_dir / "config").write_text(
        "[core]\n"
        "\trepositoryformatversion = 0\n"
        "\tfilemode = true\n"
        "\tbare = false\n"
        "\tlogallrefupdates = true\n",
        encoding="ascii",
    )
    ref = git_dir / "refs" / "heads" / "main"
    ref.parent.mkdir(parents=True, exist_ok=True)
    ref.write_text(commit_id + "\n", encoding="ascii")

    # Write a version-2 index with zeroed stat fields.  Zeroed fields force
    # git to compare content rather than trust a timestamp, and keep the index
    # itself byte-deterministic.
    index_entries = []
    for name in sorted(source_files):
        content = source_files[name]
        object_id = blob_ids[name]
        flags = min(len(name.encode("utf-8")), 0xFFF)
        entry = bytearray()
        # ctime (s, ns), mtime (s, ns), dev, ino, mode, uid, gid, size.
        entry.extend(struct.pack(
            ">IIIIIIIIII", 0, 0, 0, 0, 0, 0, stat.S_IFREG | 0o644, 0, 0, len(content)))
        entry.extend(bytes.fromhex(object_id))
        entry.extend(struct.pack(">H", flags))
        entry.extend(name.encode("utf-8"))
        entry.append(0)
        while len(entry) % 8:
            entry.append(0)
        index_entries.append(bytes(entry))
    index = bytearray(b"DIRC" + struct.pack(">II", 2, len(index_entries)))
    for entry in index_entries:
        index.extend(entry)
    index.extend(hashlib.sha1(index).digest())
    (git_dir / "index").write_bytes(bytes(index))

    return sum(
        path.stat().st_size
        for path in repo.rglob("*")
        if path.is_file()
    )


# --------------------------------------------------------------------------
# Workspace


def _tree_bytes(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                total += path.stat().st_size
        except OSError:
            pass
    return total


def _generate_workspace(workspace: Path, target_bytes: int, seed: int) -> int:
    if target_bytes < 64 * KIB:
        raise ValueError("workspace target must be at least 64 KiB")
    workspace.mkdir(parents=True, exist_ok=True)
    source_budget = max(16 * KIB, min(4 * MIB, target_bytes // 16))
    _build_git_repo(workspace, seed, source_budget)
    used = _tree_bytes(workspace)
    remaining = target_bytes - used
    if remaining < 3:
        raise ValueError(
            f"workspace target {target_bytes} cannot hold the git repository "
            f"({used} bytes)")
    block_count = max(1, min(16, remaining // (4 * MIB) or 1))
    block_size = remaining // block_count
    for index in range(block_count):
        size = block_size if index < block_count - 1 else remaining - block_size * (block_count - 1)
        _write_pattern(
            workspace / "assets" / f"bulk-{index:03d}.bin",
            seed,
            f"workspace:{index}",
            size,
        )
    actual = _tree_bytes(workspace)
    if actual != target_bytes:
        raise AssertionError(f"workspace: wrote {actual} bytes, expected {target_bytes}")
    return actual


# --------------------------------------------------------------------------
# Optional size-only store stubs


def _generate_store_stubs(root: Path, seed: int, workspace_bytes: int,
                          sessions_bytes: int, session_ids: Sequence[str]) -> None:
    """Deterministic byte patterns so ``measure_container.py`` can be exercised.

    These files are not valid WAL/journal/response-log data.  They are opt-in
    only and the manifest marks them as size stubs.
    """
    wal_bytes = max(4096, workspace_bytes // 12)
    segment = 16 * MIB
    index = 0
    remaining = wal_bytes
    while remaining > 0:
        size = min(segment, remaining)
        _write_pattern(root / "wal" / f"00000001.{index:06d}.xlwal", seed, f"wal:{index}", size)
        remaining -= size
        index += 1

    _write_pattern(root / "journal.xljournal", seed, "journal", max(1024, workspace_bytes // 50))

    steps_bytes = max(1024, sessions_bytes // 20)
    step_files = min(len(session_ids), max(1, steps_bytes // 512))
    per_step = steps_bytes // step_files
    for index in range(step_files):
        size = per_step if index < step_files - 1 else steps_bytes - per_step * (step_files - 1)
        _write_pattern(root / "steps" / f"{session_ids[index]}.ndjson", seed, f"steps:{index}", size)

    response_bytes = max(1024, sessions_bytes // 8)
    body_count = min(4, len(session_ids))
    per_body = response_bytes // body_count if body_count else response_bytes
    for index in range(body_count):
        size = per_body if index < body_count - 1 else response_bytes - per_body * (body_count - 1)
        key = hashlib.sha256(f"{seed}:response:{index}".encode()).hexdigest()
        entry_dir = root / "response-log" / key
        _write_pattern(entry_dir / "body", seed, f"response:{index}", size)
        _write_bytes(
            entry_dir / "entry.json",
            json.dumps({"stub": True, "bodyBytes": size}, sort_keys=True).encode() + b"\n",
        )

    _write_pattern(root / "overlay-cache.tar", seed, "overlay-cache", max(1024, workspace_bytes // 20))
    _write_bytes(
        root / "overlay-cache.json",
        json.dumps({"stub": True, "watermark": 0}, sort_keys=True).encode() + b"\n",
    )
    boot_id = _digest(seed, "boot")[:8].hex()
    _write_pattern(root / f"overlay-{boot_id}.tar", seed, "overlay-boot", max(1024, workspace_bytes // 20))

    documents = root.parent.parent.parent / "Documents"
    snapshot_bytes = max(512, sessions_bytes // 50)
    snapshot_count = min(8, len(session_ids))
    per_snapshot = snapshot_bytes // snapshot_count if snapshot_count else snapshot_bytes
    for index in range(snapshot_count):
        size = (per_snapshot if index < snapshot_count - 1
                else snapshot_bytes - per_snapshot * (snapshot_count - 1))
        payload = {
            "stub": True,
            "sessionID": session_ids[index],
            "note": "size stub, not an app transcript snapshot",
            "bytes": size,
        }
        encoded = json.dumps(payload, sort_keys=True).encode() + b"\n"
        if len(encoded) < size:
            encoded = encoded[:-1] + b" " * (size - len(encoded)) + b"\n"
        _write_bytes(documents / "transcript-snapshots" / f"{session_ids[index]}.json", encoded)


# --------------------------------------------------------------------------
# Public entry point


def resolve_profile(name: str, *, sessions: Optional[int] = None,
                    workspace_bytes: Optional[int] = None,
                    longest_session_bytes: Optional[int] = None,
                    short_session_bytes: Optional[int] = None) -> Profile:
    try:
        profile = PROFILES[name]
    except KeyError as exc:
        raise ValueError(f"unknown profile {name!r}; known: {', '.join(sorted(PROFILES))}") from exc
    if sessions is not None:
        if sessions < 1:
            raise ValueError("--sessions must be at least 1")
        profile = replace(profile, sessions=sessions)
    if workspace_bytes is not None:
        if workspace_bytes < 64 * KIB:
            raise ValueError("--workspace-bytes must be at least 64 KiB")
        profile = replace(profile, workspace_bytes=workspace_bytes)
    if longest_session_bytes is not None:
        if longest_session_bytes < MIN_SESSION_BYTES:
            raise ValueError(f"--longest-session-bytes must be at least {MIN_SESSION_BYTES}")
        profile = replace(profile, longest_session_bytes=longest_session_bytes)
    if short_session_bytes is not None:
        if short_session_bytes < MIN_SESSION_BYTES:
            raise ValueError(f"--short-session-bytes must be at least {MIN_SESSION_BYTES}")
        profile = replace(profile, short_session_bytes=short_session_bytes)
    return profile


def _prepare_root(root: Path, force: bool) -> None:
    if root.exists() or root.is_symlink():
        if not force:
            raise FileExistsError(
                f"{root} already exists; pass --force to replace it")
        resolved = root.resolve()
        if resolved == Path(resolved.anchor) or resolved == Path.home().resolve():
            raise ValueError(f"refusing to remove {resolved}")
        if root.is_symlink():
            raise ValueError(f"refusing to replace symlink {root}")
        shutil.rmtree(root)
    root.mkdir(parents=True)


def generate_container(root: Path, profile: Profile, *, seed: int = 1,
                       workspace_id: Optional[str] = None,
                       store_stubs: bool = False, force: bool = False) -> dict:
    """Generate one container under ``root`` and return its manifest."""
    root = Path(root)
    workspace_id = workspace_id or f"perf-{profile.name}-{seed}"
    if (not workspace_id or workspace_id in (".", "..")
            or "/" in workspace_id or "\\" in workspace_id):
        raise ValueError("--workspace-id must be one path component")
    _prepare_root(root, force)

    workspace_root = root / "Library" / "xl" / workspace_id
    sessions_root = (
        workspace_root / "materialized" / "home" / "sessions" / PROJECT_KEY
    )
    sessions_root.mkdir(parents=True, exist_ok=True)
    workspace_root.mkdir(parents=True, exist_ok=True)

    session_ids: List[str] = []
    session_bytes = 0
    for index in range(profile.sessions):
        session_id = f"session-{_uuid_for(seed, f'session:{index}')}"
        session_ids.append(session_id)
        target = (profile.longest_session_bytes if index == 0
                  else profile.short_session_bytes)
        path = sessions_root / session_id / "session.v4.jsonl"
        _write_session(path, target, seed=seed, session_id=session_id)
        session_bytes += target

    workspace = workspace_root / "materialized" / "workspace"
    workspace_bytes = _generate_workspace(workspace, profile.workspace_bytes, seed)

    if store_stubs:
        _generate_store_stubs(workspace_root, seed, workspace_bytes, session_bytes, session_ids)

    manifest = {
        "schemaVersion": 1,
        "fixture": "phone-dsh-w0-container",
        "profile": profile.name,
        "seed": seed,
        "workspaceID": workspace_id,
        "workspaceRoot": f"Library/xl/{workspace_id}",
        "projectKey": PROJECT_KEY,
        "sessionCwd": SESSION_CWD,
        "sessions": {
            "count": profile.sessions,
            "longestSessionID": session_ids[0],
            "longestSessionBytes": profile.longest_session_bytes,
            "shortSessionBytes": profile.short_session_bytes,
            "totalBytes": session_bytes,
        },
        "workspaceBytes": workspace_bytes,
        "storeStubs": bool(store_stubs),
        "continuousRun": profile.continuous_run,
        "purpose": profile.purpose,
    }
    _write_bytes(
        root / "perf-fixture.json",
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n",
    )
    return manifest


def _bytes_arg(parser: argparse.ArgumentParser, name: str, help_text: str) -> None:
    parser.add_argument(f"--{name}", type=float, default=None, metavar="MIB", help=help_text)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a deterministic phone-dsh W0 app-container fixture.")
    parser.add_argument("--profile", choices=sorted(PROFILES), required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="container directory to create")
    parser.add_argument("--seed", type=int, default=1,
                        help="deterministic seed (default: 1)")
    parser.add_argument("--workspace-id", default=None,
                        help="Library/xl/<workspace-id> name (default: perf-<profile>-<seed>)")
    parser.add_argument("--sessions", type=int, default=None,
                        help="override the profile's session count")
    _bytes_arg(parser, "workspace-mib", "override workspace size in MiB")
    _bytes_arg(parser, "longest-session-mib", "override longest session size in MiB")
    _bytes_arg(parser, "short-session-mib", "override the other sessions' size in MiB")
    parser.add_argument("--store-stubs", action="store_true",
                        help="also write size-only WAL/journal/steps/response-log/overlay stubs")
    parser.add_argument("--force", action="store_true",
                        help="replace an existing output directory")
    args = parser.parse_args(argv)

    try:
        profile = resolve_profile(
            args.profile,
            sessions=args.sessions,
            workspace_bytes=(round(args.workspace_mib * MIB)
                             if args.workspace_mib is not None else None),
            longest_session_bytes=(round(args.longest_session_mib * MIB)
                                   if args.longest_session_mib is not None else None),
            short_session_bytes=(round(args.short_session_mib * MIB)
                                 if args.short_session_mib is not None else None),
        )
        manifest = generate_container(
            args.output, profile, seed=args.seed,
            workspace_id=args.workspace_id, store_stubs=args.store_stubs,
            force=args.force)
    except (ValueError, FileExistsError, OSError) as exc:
        print(f"generate_container: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
