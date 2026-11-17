#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared-fixture checker for spec/device/v1/device-app.md.

A spec checker, not runtime conformance: it pins the reviewed golden file, validates each vector
against the schema, and replays it through an oracle written from the normative text. The phone's
validator, the device's installer and guard must each run the same file through their real code.
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import tokenize
import unicodedata
import unittest
from pathlib import Path

import spec_golden

DEVICE = Path(__file__).resolve().parents[2] / "device" / "v1"
GOLDEN = DEVICE / "golden" / "device-app.jsonl"
SCHEMA = json.loads((DEVICE / "schema" / "device-app-vector.schema.json").read_text(encoding="utf-8"))

# Reviewed fixture revision device-app-v1. Changing a vector needs a new contract revision.
FROZEN = "963187a6224e0721e5442d238ca6b1a92e4194a7a89fad4989d059f293d03f7d"

NAME = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
PATH = re.compile(r"^([A-Za-z0-9_-]+/){0,2}[A-Za-z0-9_-]+\.(py|json)$")
PERMS = {"audio", "mic", "battery"}
FILE_MAX = 12288
BASE_MODULES = {"time", "math", "random", "json", "gc", "struct", "array", "micropython", "lcd", "keys", "ui", "kit", "audio", "battery"}
FORBIDDEN_NAMES = {"exec", "eval", "compile", "execfile", "open", "__import__", "getattr", "setattr", "delattr", "globals",
                   "locals", "vars", "dir", "breakpoint", "input", "__builtins__", "machine", "os", "sys", "socket",
                   "network", "bluetooth", "_thread", "esp32", "_passport", "apprt", "settings"}
MIC_NAMES = {"record_wav", "readinto", "mic_gain"}
RULE = {"lex": 1, "fstring": 2, "import": 3, "name": 4, "underscore": 5, "perm": 6, "except": 7}


def rows():
    return [json.loads(line) for line in GOLDEN.read_text(encoding="utf-8").splitlines()]


def digest_of(values):
    data = "\n".join(json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False) for v in values)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


# --- oracle (device-app.md §2-§9) --------------------------------------------


def valid_name(v):
    return bool(NAME.fullmatch(v))


def valid_path(v):
    return len(v) <= 64 and bool(PATH.fullmatch(v))


def valid_title(v):
    if not 1 <= len(v) <= 20:
        return False
    return not any(unicodedata.category(c) in ("Cc", "Cf") for c in v)


def valid_manifest(app_name, text):
    def hook(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise ValueError("duplicate key")
        return dict(pairs)
    try:
        m = json.loads(text, object_pairs_hook=hook)
    except ValueError:
        return False
    if not isinstance(m, dict) or set(m) != {"name", "title", "version", "perms"}:
        return False
    if m["name"] != app_name or not valid_name(m["name"]) or not isinstance(m["title"], str) or not valid_title(m["title"]):
        return False
    if isinstance(m["version"], bool) or not isinstance(m["version"], int) or m["version"] < 1:
        return False
    p = m["perms"]
    return (isinstance(p, list) and all(isinstance(x, str) for x in p) and len(p) == len(set(p)) and set(p) <= PERMS)


def manifest_digest(files):
    text = "".join("%s\t%d\t%s\n" % (f["path"], f["size"], f["sha256"])
                   for f in sorted(files, key=lambda f: f["path"].encode("utf-8")))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def static_check(files, perms):
    """Return (code, path, line) of the first violation, or None."""
    for path in sorted(files):
        if len(files[path].encode("utf-8")) > FILE_MAX or "\x00" in files[path]:
            return ("size", path, 0)
    siblings = {p[:-3] for p in files if p.endswith(".py") and "/" not in p}
    allowed = BASE_MODULES | siblings
    found = []
    exit_path = False
    for path in sorted(files):
        if not path.endswith(".py"):
            continue
        toks = []
        try:
            for t in tokenize.generate_tokens(io.StringIO(files[path]).readline):
                if t.type in (tokenize.COMMENT, tokenize.NL, tokenize.ENDMARKER):
                    continue
                if t.type == tokenize.ERRORTOKEN and not t.string.strip():
                    continue
                if t.type == tokenize.ERRORTOKEN:
                    found.append((path, t.start[0], RULE["lex"], "lex"))
                    continue
                toks.append(t)
        except (tokenize.TokenError, IndentationError, SyntaxError) as e:
            line = e.lineno if isinstance(e, SyntaxError) else e.args[1][0]
            found.append((path, line, RULE["lex"], "lex"))
        sep = {tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT}
        n = len(toks)
        i = 0
        prev_start = True
        while i < n:
            t = toks[i]
            ty, s, line = t.type, t.string, t.start[0]
            fs = getattr(tokenize, "FSTRING_START", None)
            if (ty == tokenize.STRING and re.match(r"^[A-Za-z]*", s).group(0).lower().find("f") >= 0) or (fs is not None and ty == fs):
                found.append((path, line, RULE["fstring"], "fstring"))
            if ty == tokenize.NAME:
                if prev_start and s in ("import", "from"):
                    j = i + 1
                    if s == "from":
                        if j < n and toks[j].type == tokenize.OP and toks[j].string in (".", "..."):
                            found.append((path, line, RULE["import"], "import"))
                        elif j < n and toks[j].type == tokenize.NAME and toks[j].string not in allowed:
                            found.append((path, line, RULE["import"], "import"))
                        while j < n and not (toks[j].type == tokenize.NAME and toks[j].string == "import") and toks[j].type not in sep:
                            j += 1
                        if j + 1 < n and toks[j + 1].type == tokenize.OP and toks[j + 1].string == "*":
                            found.append((path, line, RULE["import"], "import"))
                    else:
                        while j < n:
                            if toks[j].type == tokenize.NAME:
                                if toks[j].string not in allowed:
                                    found.append((path, toks[j].start[0], RULE["import"], "import"))
                                j += 1
                                while j + 1 < n and toks[j].type == tokenize.OP and toks[j].string == "." and toks[j + 1].type == tokenize.NAME:
                                    j += 2
                                if j + 1 < n and toks[j].type == tokenize.NAME and toks[j].string == "as":
                                    j += 2
                                if j < n and toks[j].type == tokenize.OP and toks[j].string == ",":
                                    j += 1
                                    continue
                            break
                if s in FORBIDDEN_NAMES:
                    found.append((path, line, RULE["name"], "name"))
                if (s.startswith("__") and s.endswith("__") and len(s) > 4 and s not in ("__name__", "__init__")):
                    found.append((path, line, RULE["underscore"], "underscore"))
                if i and toks[i - 1].type == tokenize.OP and toks[i - 1].string == "." and s.startswith("_"):
                    found.append((path, line, RULE["underscore"], "underscore"))
                if s == "audio" and "audio" not in perms:
                    found.append((path, line, RULE["perm"], "perm"))
                if s == "battery" and "battery" not in perms:
                    found.append((path, line, RULE["perm"], "perm"))
                if s in MIC_NAMES and "mic" not in perms:
                    found.append((path, line, RULE["perm"], "perm"))
                if s == "except":
                    j, depth, bad = i + 1, 0, False
                    if j < n and toks[j].type == tokenize.OP and toks[j].string == ":":
                        bad = True
                    while j < n and toks[j].type not in sep:
                        tj = toks[j]
                        if tj.type == tokenize.OP and tj.string in "([{":
                            depth += 1
                        elif tj.type == tokenize.OP and tj.string in ")]}":
                            depth -= 1
                        elif tj.type == tokenize.OP and tj.string == ":" and depth == 0:
                            break
                        elif tj.type == tokenize.NAME and tj.string in ("BaseException", "KeyboardInterrupt"):
                            bad = True
                        j += 1
                    if bad:
                        found.append((path, line, RULE["except"], "except"))
                if s == "keys" and i + 2 < n and toks[i + 1].string == "." and toks[i + 2].string in ("get", "pressed"):
                    exit_path = True
            prev_start = ty in sep or (ty == tokenize.OP and s in (";", ":"))
            i += 1
    if found:
        found.sort(key=lambda f: (f[0], f[1], f[2]))
        p, line, _, code = found[0]
        return (code, p, line)
    if not exit_path:
        return ("exit_path", "main.py", 0)
    return None


def put_rule(declared, nxt, offset, length, same):
    if offset + length > declared:
        return (False, "too_large", None)
    if offset == nxt:
        return (True, None, nxt + length)
    if offset < nxt and offset + length <= nxt and same:
        return (True, None, nxt)
    return (False, "offset_mismatch", None)


class DeviceAppGoldenTest(unittest.TestCase):
    def test_pinned_and_schema_valid(self):
        data = rows()
        self.assertEqual(digest_of(data), FROZEN)
        self.assertEqual(len(data), len({r["id"] for r in data}))
        for r in data:
            spec_golden.validate_json(r, SCHEMA, r["id"])

    def test_every_vector_replays(self):
        for r in rows():
            with self.subTest(r["id"]):
                k = r["kind"]
                if k == "name":
                    self.assertEqual(valid_name(r["value"]), r["valid"])
                elif k == "path":
                    self.assertEqual(valid_path(r["value"]), r["valid"])
                elif k == "title":
                    self.assertEqual(valid_title(r["value"]), r["valid"])
                elif k == "manifest":
                    self.assertEqual(valid_manifest(r["app_name"], r["json"]), r["valid"])
                elif k == "digest":
                    self.assertEqual(manifest_digest(r["files"]), r["digest"])
                elif k == "check":
                    got = static_check(r["files"], r["perms"])
                    if r["ok"]:
                        self.assertIsNone(got)
                    else:
                        self.assertEqual(got, (r["code"], r["path"], r["line"]))
                elif k == "put":
                    ok, code, nxt = put_rule(r["declared"], r["next_offset"], r["offset"], r["length"], r["same_bytes"])
                    self.assertEqual(ok, r["ok"])
                    if ok:
                        self.assertEqual(nxt, r["result_next"])
                    else:
                        self.assertEqual(code, r["code"])

    def test_every_rejection_code_is_exercised(self):
        codes = {r["code"] for r in rows() if r["kind"] == "check" and not r["ok"]}
        self.assertEqual(codes, {"size", "lex", "fstring", "import", "name", "underscore", "perm", "except", "exit_path"})


if __name__ == "__main__":
    unittest.main()
