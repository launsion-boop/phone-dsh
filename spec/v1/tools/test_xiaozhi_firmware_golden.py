#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared-fixture checker for spec/device/v1/xiaozhi-firmware.md.

A spec checker, not runtime conformance: it pins the reviewed golden file and replays every vector
through an oracle written from the normative text (§2.4 rewrite, §3 report, §4 key/name/text).
The iOS relay and Bot tools must run the same file through their real functions.
"""

from __future__ import annotations

import hashlib
import json
import re
import unittest
from pathlib import Path

GOLDEN = Path(__file__).resolve().parents[2] / "device" / "v1" / "golden" / "xiaozhi-ota.jsonl"

# Reviewed fixture revision xiaozhi-firmware-v1. Changing a vector needs a new contract revision.
FROZEN = "703e106ef4cd7e4e241298de127c32c1b23aadf9d6391546f78443af5526cc4a"

MAC = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
DESCRIPTION = "管理一台小智设备（{mac}）：可以导出和修改固件源码、在这台 iPhone 上编译，并通过 Wi-Fi 刷入新固件。刷入前会先问你。"


def ordered(text: str):
    return json.loads(text, object_pairs_hook=lambda pairs: [(k, v) for k, v in pairs])


def report(headers: dict, body):
    mac = next((v for k, v in headers.items() if k.lower() == "device-id"), None)
    mac = mac.lower() if isinstance(mac, str) else None
    if mac is not None and not MAC.match(mac):
        mac = None
    doc = {}
    if body is not None:
        doc = json.loads(body)
        if not isinstance(doc, dict):
            return "invalid_body"
    app = doc.get("application") if isinstance(doc.get("application"), dict) else {}
    board = doc.get("board") if isinstance(doc.get("board"), dict) else {}
    version = app.get("version") if isinstance(app.get("version"), str) else None
    elf = app.get("elf_sha256") if isinstance(app.get("elf_sha256"), str) and HEX64.match(app["elf_sha256"]) else None
    board_type = board.get("type") if isinstance(board.get("type"), str) else None
    return {"mac": mac, "version": version, "elfSha256": elf, "boardType": board_type}


def rewrite(status: int, body: str, rep: dict, staged, base: str):
    if staged is None or staged["mac"] != rep["mac"]:
        return "passthrough", body
    try:
        members = ordered(body)
    except ValueError:
        return "passthrough", body
    if status != 200 or not isinstance(members, list) or not json.loads(body).__class__ is dict:
        return "passthrough", body
    version = rep.get("version")
    if not isinstance(version, str) or not VERSION.match(version):
        return "passthrough", body
    if rep.get("elfSha256") == staged["elfSha256"]:
        decision, firmware = "hold", {"version": version, "url": ""}
    else:
        decision = "offer"
        firmware = {"version": version + ".1", "url": f"{base}/xiaozhi/firmware/{staged['sha256']}.bin"}
    out, replaced = [], False
    for k, v in members:
        if k == "firmware":
            out.append((k, firmware)); replaced = True
        else:
            out.append((k, v))
    if not replaced:
        out.append(("firmware", firmware))
    return decision, out


def to_pairs(value):
    if isinstance(value, list) and all(isinstance(x, tuple) for x in value):
        return [(k, to_pairs(v)) for k, v in value]
    if isinstance(value, dict):
        return [(k, to_pairs(v)) for k, v in value.items()]
    return value


class XiaozhiFirmwareGolden(unittest.TestCase):
    def setUp(self):
        raw = GOLDEN.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), FROZEN, "golden changed without a contract revision")
        self.vectors = [json.loads(line) for line in raw.decode("utf-8").splitlines() if line.strip()]

    def test_ids_unique_and_kinds_covered(self):
        ids = [v["id"] for v in self.vectors]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual({v["kind"] for v in self.vectors}, {"report", "rewrite", "key", "name", "description"})
        decisions = {v["decision"] for v in self.vectors if v["kind"] == "rewrite"}
        self.assertEqual(decisions, {"passthrough", "hold", "offer"})

    def test_vectors(self):
        for v in self.vectors:
            with self.subTest(v["id"]):
                i = v["input"]
                if v["kind"] == "report":
                    self.assertEqual(report(i["headers"], i["body"]), v["report"])
                elif v["kind"] == "rewrite":
                    decision, out = rewrite(i["status"], i["body"], i["report"], i["staged"], i["base"])
                    self.assertEqual(decision, v["decision"])
                    if decision == "passthrough":
                        self.assertEqual(out, v["body"])
                    else:
                        self.assertEqual(to_pairs(out), to_pairs(ordered(v["body"])))
                elif v["kind"] == "key":
                    m = i["mac"]
                    self.assertEqual("xiaozhi:" + m if MAC.match(m) else None, v["key"])
                elif v["kind"] == "name":
                    self.assertEqual("小智 " + "".join(i["mac"].split(":")[-2:]).upper(), v["raw"])
                elif v["kind"] == "description":
                    self.assertEqual(DESCRIPTION.format(mac=i["mac"]), v["description"])


if __name__ == "__main__":
    unittest.main()
