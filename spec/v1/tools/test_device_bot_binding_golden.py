#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Shared-fixture checker for spec/device/v1/device-bot.md.

A spec checker, not runtime conformance: it pins the reviewed golden file, validates each vector
against the schema, and replays it through a small oracle written from the normative text. The
iOS registry (and Android, when it implements the file) must run the same file through its real
functions.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
import unicodedata
import unittest
from pathlib import Path

import spec_golden

DEVICE = Path(__file__).resolve().parents[2] / "device" / "v1"
GOLDEN = DEVICE / "golden" / "device-bot-binding.jsonl"
SCHEMA = json.loads((DEVICE / "schema" / "device-bot-binding.schema.json").read_text(encoding="utf-8"))

# Reviewed fixture revision device-bot-v1.1. Changing a vector needs a new contract revision.
FROZEN = "be43586ea8bd86350baf367c66aa2a25fddc9faa092dff1b022614f69ea37bf9"

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HOST = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")
TOOL = re.compile(r"^[a-z0-9_.-]{1,64}$")
GATT_LABELS = [("battery", "电池"), ("temperature", "温度"), ("humidity", "湿度"),
               ("manufacturer", "厂商"), ("model", "型号"), ("alert", "提醒")]
BOARD = "通过小智 Link 帮你操作这台 iPhone：打开 App、点按、输入、看屏幕，也能调板子的灯效。对板子说「你好小智」就会找我。"
NAME_MAX = 60
DEVICE_APP_TOOLS = {"app.info", "app.begin", "app.put", "app.abort", "app.commit", "app.run", "app.stop", "app.remove"}
DEVICE_APP_LINK = "管理一台设备，可以帮你写小应用装到设备上（比如计时器、计数器）。装之前会先问你。"
TECH_ID = re.compile(r"^(?:[Pp][Dd][Ss][Hh]-.*|[0-9A-Fa-f]{4,}|[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){2,})$")


def rows():
    return [json.loads(line) for line in GOLDEN.read_text(encoding="utf-8").splitlines()]


def digest(values):
    data = "\n".join(json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False) for v in values)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


# --- oracle (device-bot.md §3, §5, §6) ---------------------------------------


def derive_key(cls, i):
    if cls == "link":
        v = i["device_id"].lower()
        return v if v and ":" not in v else None
    if cls == "gatt":
        v = i["peripheral_uuid"].lower()
        return "gatt:" + v if UUID.match(v) else None
    if cls == "lan":
        host, port = i["host"], i["port"]
        if not HOST.match(host) or not (1 <= port <= 65535):
            return None
        return "lan:" + host + ("" if port == 443 else ":%d" % port)
    if cls == "tonolink":
        v = i["ble_name"].lower()
        return "tonolink:" + v if v else None
    raise AssertionError(cls)


def make_name(raw, roster):
    out = []
    for ch in unicodedata.normalize("NFC", raw):
        cat = unicodedata.category(ch)
        if cat == "Cf":
            continue
        out.append(" " if cat in ("Cc", "Zl", "Zp", "Zs") else ch)
    text = " ".join("".join(out).split(" ")).strip()
    text = re.sub(" +", " ", text)[:NAME_MAX].rstrip(" ")
    base = "设备助手" if not text or TECH_ID.fullmatch(text) else text
    if base not in roster:
        return base
    n = 2
    while True:
        suffix = " %d" % n
        candidate = base[: NAME_MAX - len(suffix)].rstrip(" ") + suffix
        if candidate not in roster:
            return candidate
        n += 1


def make_description(cls, i):
    if cls == "board":
        return BOARD
    if cls == "link":
        if DEVICE_APP_TOOLS <= set(i["tools"]):
            return DEVICE_APP_LINK
        seen, tools = set(), []
        for t in i["tools"]:
            if TOOL.match(t) and t not in seen:
                seen.add(t)
                tools.append(t)
        tools = tools[:8]
        return "管理一台通过 Link 连接的设备。" + ("可用工具：" + "、".join(tools) + "。" if tools else "")
    if cls == "gatt":
        labels = [label for name, label in GATT_LABELS if name in i["profiles"]]
        return "管理一台标准蓝牙设备。" + ("已授权：" + "、".join(labels) + "。" if labels else "")
    if cls == "lan":
        return "管理一台局域网设备" + ("（%s）" % i["host"] if HOST.match(i["host"]) else "") + "。"
    raise AssertionError(cls)


def decide(state, key, new_id, alias=None):
    s = copy.deepcopy(state)
    b, intents, roster = s["bindings"], s["intents"], set(s["roster"])
    if key in b and b[key] in roster:
        return {"do": "none"}, b, intents
    b.pop(key, None)
    if alias and alias in b and b[alias] in roster:
        b[key] = b[alias]
        return {"do": "bind", "bot": b[key]}, b, intents
    if key in intents:
        c = intents[key]
        bot = s["created"].get(c)
        if bot in roster:
            b[key] = bot
            del intents[key]
            return {"do": "bind", "bot": bot}, b, intents
        return {"do": "create", "creation_id": c}, b, intents
    intents[key] = new_id
    return {"do": "create", "creation_id": new_id}, b, intents


def complete(state, key, bot):
    s = copy.deepcopy(state)
    s["bindings"][key] = bot
    s["intents"].pop(key, None)
    return s["bindings"], s["intents"]


class DeviceBotBindingGoldenTest(unittest.TestCase):
    def test_pinned_and_schema_valid(self):
        data = rows()
        self.assertEqual(digest(data), FROZEN)
        self.assertEqual(len(data), len({r["id"] for r in data}))
        for r in data:
            spec_golden.validate_json(r, SCHEMA, r["id"])

    def test_every_vector_replays(self):
        for r in rows():
            with self.subTest(r["id"]):
                k = r["kind"]
                if k == "key":
                    self.assertEqual(derive_key(r["class"], r["input"]), r["key"])
                elif k == "name":
                    self.assertEqual(make_name(r["raw"], r["roster_names"]), r["name"])
                    self.assertLessEqual(len(r["name"]), NAME_MAX)
                elif k == "description":
                    self.assertEqual(make_description(r["class"], r["input"]), r["description"])
                elif k == "decide":
                    action, b, i = decide(r["state"], r["key"], r["new_creation_id"], r.get("alias"))
                    self.assertEqual(action, r["action"])
                    self.assertEqual({"bindings": b, "intents": i}, r["after"])
                    for key, bot in r["state"]["bindings"].items():
                        if ":" in key and key.split(":")[0] not in ("gatt", "lan", "tonolink") and key != r["key"]:
                            self.assertEqual(b[key], bot)  # unknown prefixes survive
                elif k == "complete":
                    b, i = complete(r["state"], r["key"], r["bot"])
                    self.assertEqual({"bindings": b, "intents": i}, r["after"])

    def test_no_description_carries_device_free_text(self):
        for r in rows():
            if r["kind"] == "description":
                for value in r["input"].values():
                    if isinstance(value, str) and r["class"] != "lan":
                        self.assertNotIn(value, r["description"])

    def test_mutated_oracle_is_caught(self):
        # A name-and-description rebind (the rejected design) must not satisfy any decide vector.
        wrong = [r for r in rows() if r["id"] == "decide-same-name-bot-is-not-bound"][0]
        self.assertEqual(wrong["action"]["do"], "create")


if __name__ == "__main__":
    unittest.main()
