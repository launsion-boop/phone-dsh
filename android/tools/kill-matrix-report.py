#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Reader for one P6 kill-matrix cell produced by android/tools/kill-matrix.sh.
#
# It re-parses the pulled workspace offline instead of trusting the app's logs:
#   wal/*.xlwal        spec/v1/wal.md section 2/3 framing, CRC32C verified
#   journal/*.xljournal  the journal store's own framing, CRC32C verified
#   materialized session.v4.jsonl  one JSON object per line
#   materialized tool-journal/*.ndjson
# and prints the three-step evidence plus the fail-loud lines from logcat.
#
#   python3 android/tools/kill-matrix-report.py <evidence-root>/<cell>
#
# A `torn=[]` verdict means: every record frame in the file parsed and every CRC
# matched. It is a measurement, not an assumption about the platform.
"""One compact per-cell report for the P6 kill matrix.

Args: <cell-dir>
Reads timeline.txt, the three snapshot tar extractions, the logcats and the UI
dump, and prints the three-step evidence with a verified verdict.
"""
import glob
import json
import os
import re
import struct
import subprocess
import sys

CRC_TABLE = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    CRC_TABLE.append(c)


def crc32c(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc = (crc >> 8) ^ CRC_TABLE[(crc ^ b) & 0xFF]
    return crc ^ 0xFFFFFFFF


def wal(path):
    d = open(path, "rb").read()
    if len(d) < 40 or d[:8] != b"XLWAL1\x00\x00":
        return dict(size=len(d), records=0, torn="bad-header")
    off, recs, torn, last = 40, 0, None, 0
    while off < len(d):
        if off + 8 > len(d):
            torn = f"partial-frame@{off}({len(d)-off}B)"; break
        (ln,) = struct.unpack_from(">I", d, off)
        (crc,) = struct.unpack_from(">I", d, off + 4)
        if ln < 8 or off + 8 + ln > len(d):
            torn = f"incomplete-record@{off}({len(d)-off}B)"; break
        payload = d[off + 8: off + 8 + ln]
        if crc32c(payload) != crc:
            torn = f"crc-mismatch@{off}"; break
        last = struct.unpack_from(">Q", payload, 0)[0]
        recs += 1
        off += 8 + ln
    return dict(size=len(d), records=recs, last_mseq=last, torn=torn,
                complete=(off == len(d)))


def journal(path):
    d = open(path, "rb").read()
    if len(d) < 16:
        return dict(size=len(d), records=0, torn="short-header")
    magic, ver, flags, sidlen = struct.unpack_from(">IBBH", d, 0)
    off, recs, torn, last = 8 + sidlen + 8, 0, None, 0
    while off < len(d):
        if off + 16 > len(d):
            torn = f"partial-frame@{off}({len(d)-off}B)"; break
        ln, crc = struct.unpack_from(">II", d, off)
        (jseq,) = struct.unpack_from(">Q", d, off + 8)
        if ln <= 0 or off + 16 + ln > len(d):
            torn = f"incomplete-record@{off}({len(d)-off}B)"; break
        rec = d[off + 16: off + 16 + ln]
        if crc32c(struct.pack(">Q", jseq) + rec) != crc:
            torn = f"crc-mismatch@{off}"; break
        last = jseq
        recs += 1
        off += 16 + ln
    return dict(size=len(d), records=recs, last_jseq=last, torn=torn)


def session(path):
    raw = open(path, "rb").read()
    rows, bad = [], 0
    for line in raw.split(b"\n"):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            bad += 1
    kinds = [r.get("type") for r in rows]
    return dict(lines=len(rows), unparsable_lines=bad,
                trailing_partial=(bool(raw) and not raw.endswith(b"\n")),
                has_turn_start="turn/start" in kinds,
                has_turn_end="turn/end" in kinds,
                last=kinds[-1] if kinds else None, kinds=kinds)


def snap(root, sid):
    xl = os.path.join(root, "files", "xl")
    out = {}
    wals = sorted(glob.glob(os.path.join(xl, "wal", "*.xlwal")))
    info = [wal(w) for w in wals]
    out["wal"] = dict(files=len(info), records=sum(i["records"] for i in info),
                      torn=[i["torn"] for i in info if i.get("torn")],
                      last_mseq=max([i["last_mseq"] for i in info], default=0))
    jrs = sorted(glob.glob(os.path.join(xl, "journal", "*.xljournal")))
    jinfo = [journal(j) for j in jrs]
    out["journal"] = dict(files=len(jinfo), records=sum(i["records"] for i in jinfo),
                          torn=[i["torn"] for i in jinfo if i.get("torn")], size=sum(i["size"] for i in jinfo))
    target = None
    if sid:
        cand = sorted(glob.glob(os.path.join(
            xl, "materialized", "home", "sessions", "*", f"session-{sid}", "session.v4.jsonl")))
        if cand:
            target = session(cand[0])
    out["session"] = target
    prefs = os.path.join(root, "..", "prefs.xml")
    return out


def log_evidence(path, label):
    if not os.path.isfile(path):
        return []
    lines = open(path, "r", errors="replace").read().splitlines()
    pats = [
        ("journal-open", r"journal: open"),
        ("journal-off", r"journal: off"),
        ("wal-torn", r"WAL_TORN_TAIL_TRUNCATED"),
        ("resync", r"WAL_RESYNC_REQUIRED"),
        ("turn-interrupted", r"TURN_INTERRUPTED_PREVIOUS"),
        ("turn-ok", r"APP_TURN_OK"),
        ("turn-failed", r"APP_TURN_FAILED"),
        ("turn-marker", r"TURN_MARKER_WRITTEN|TURN_MARKER_CLEARED"),
        ("hello-caps", r"host HELLO sent"),
        ("recovery-failed", r"wal: .*(fail|off)|recovery failed"),
        ("engine-failed", r"EngineHostState.Failed"),
    ]
    out = []
    for name, pat in pats:
        hits = [l for l in lines if re.search(pat, l)]
        if hits:
            out.append((label, name, hits[-1].strip()))
    return out


def main():
    cell = sys.argv[1]
    name = os.path.basename(cell.rstrip("/"))
    print(f"===== CELL {name}")
    tl = os.path.join(cell, "timeline.txt")
    if os.path.isfile(tl):
        for line in open(tl):
            print("   ", line.rstrip())
    sid = None
    before_log = os.path.join(cell, "before.logcat")
    if os.path.isfile(before_log):
        hits = re.findall(r"session/create -> session-([0-9a-f-]+)", open(before_log, errors="replace").read())
        if hits:
            sid = hits[-1]
    print("    target session:", sid or "(none created)")
    for tag in ("before", "after", "after-trim", "after-kill", "after-reboot", "recovered"):
        root = os.path.join(cell, f"{tag}.x")
        if not os.path.isdir(root):
            continue
        s = snap(root, sid)
        print(f"  [{tag}] wal files={s['wal']['files']} records={s['wal']['records']} "
              f"last_mseq={s['wal']['last_mseq']} torn={s['wal']['torn']}")
        print(f"           journal files={s['journal']['files']} records={s['journal']['records']} "
              f"bytes={s['journal']['size']} torn={s['journal']['torn']}")
        t = s["session"]
        if t:
            print(f"           session lines={t['lines']} bad={t['unparsable_lines']} "
                  f"partial_tail={t['trailing_partial']} turn_start={t['has_turn_start']} "
                  f"turn_end={t['has_turn_end']} last={t['last']} kinds_tail={t['kinds'][-3:]}")
        else:
            print("           session (target not present)")
    print("  log evidence")
    for tag in ("before", "after", "recovered", "after-reboot"):
        for row in log_evidence(os.path.join(cell, f"{tag}.logcat"), tag):
            print("    ", row[0], "|", row[1], "|", row[2][:190])
    ui = os.path.join(cell, "recovered.ui.xml")
    if os.path.isfile(ui):
        txt = open(ui, errors="replace").read()
        for probe in ("上次回合被中断", "WAL 尾部被截断", "回收凭据失效", "回合"):
            if probe in txt:
                print(f"    ui | contains: {probe}")


if __name__ == "__main__":
    main()
