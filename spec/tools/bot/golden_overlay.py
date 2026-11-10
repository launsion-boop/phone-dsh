#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Merge semantics for `spec/bot/v1/golden/*.phone.json` overlays.

The upstream file is the untouched exporter batch. A same-name
``<name>.phone.json`` overlay can only add cases or replace a case with the
same identity (``name``, ``id``, ``nonce`` or ``action.nonce``); it can never
remove an upstream case. Object-valued containers merge by key, array-valued
containers append/replace by identity, and overlay metadata is documentation
only. The Swift and TypeScript fixture loaders implement the same rules.
"""
from __future__ import annotations

import json
from pathlib import Path

METADATA_KEYS = frozenset({"schemaVersion", "vector", "source", "upstream", "delta"})
IDENTITY_KEYS = ("name", "id", "nonce")


def load_json(path: Path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def canonical(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def identity(value):
    """Return the merge identity of one case, or None when it has no stable id."""
    if not isinstance(value, dict):
        return None
    for key in IDENTITY_KEYS:
        item = value.get(key)
        if isinstance(item, str):
            return f"{key}:{item}"
    action = value.get("action")
    if isinstance(action, dict) and isinstance(action.get("nonce"), str):
        return f"action.nonce:{action['nonce']}"
    return None


def merge_value(upstream, overlay):
    if isinstance(upstream, dict) and isinstance(overlay, dict):
        return merge_object(upstream, overlay)
    if isinstance(upstream, list) and isinstance(overlay, list):
        return merge_array(upstream, overlay)
    return overlay


def merge_object(upstream: dict, overlay: dict) -> dict:
    merged = dict(upstream)
    for key, value in overlay.items():
        if key in METADATA_KEYS:
            continue
        if key in merged:
            merged[key] = merge_value(merged[key], value)
        else:
            merged[key] = value
    return merged


def merge_array(upstream: list, overlay: list) -> list:
    merged = list(upstream)
    positions = {}
    for index, item in enumerate(merged):
        key = identity(item)
        if key is not None:
            positions[key] = index
    seen = {canonical(item) for item in merged}
    for item in overlay:
        key = identity(item)
        if key is not None and key in positions:
            merged[positions[key]] = item
            continue
        text = canonical(item)
        if key is None and text in seen:
            continue
        if key is not None:
            positions[key] = len(merged)
        seen.add(text)
        merged.append(item)
    return merged


def merged_fixture(upstream: dict, overlay: dict) -> dict:
    """Return the complete fixture a consumer must see."""
    return merge_object(upstream, overlay)


def assert_append_only(upstream: dict, overlay: dict, where: str) -> list[str]:
    """Verify an overlay never drops an upstream case.

    Returns the identities the overlay replaces. The current frozen overlays
    add new cases only, so a non-empty result is a deliberate review item, not
    an error by itself.
    """
    replaced: list[str] = []
    merged = merged_fixture(upstream, overlay)
    for key, overlay_value in overlay.items():
        if key in METADATA_KEYS:
            continue
        upstream_value = upstream.get(key)
        if upstream_value is None:
            continue
        if isinstance(upstream_value, dict) and isinstance(overlay_value, dict):
            missing = set(upstream_value) - set(merged.get(key, {}))
            if missing:
                raise AssertionError(f"{where}.{key}: overlay removed upstream keys {sorted(missing)}")
            continue
        if isinstance(upstream_value, list) and isinstance(overlay_value, list):
            merged_items = merged.get(key, [])
            merged_identities = {identity(item) for item in merged_items if identity(item) is not None}
            merged_canonical = {canonical(item) for item in merged_items}
            for item in upstream_value:
                item_identity = identity(item)
                if item_identity is not None:
                    if item_identity not in merged_identities:
                        raise AssertionError(
                            f"{where}.{key}: overlay removed upstream case {item_identity}")
                elif canonical(item) not in merged_canonical:
                    raise AssertionError(
                        f"{where}.{key}: overlay removed an upstream case without an identity")
            upstream_identities = {identity(item) for item in upstream_value if identity(item) is not None}
            for item in overlay_value:
                item_identity = identity(item)
                if item_identity is not None and item_identity in upstream_identities:
                    replaced.append(f"{where}.{key}:{item_identity}")
            if len(merged_items) < len(upstream_value):
                raise AssertionError(
                    f"{where}.{key}: merged case count {len(merged_items)} < upstream {len(upstream_value)}")
            continue
        # A scalar override would replace the upstream value outright; the
        # frozen overlays only extend case containers, so refuse that here.
        if upstream_value != overlay_value:
            raise AssertionError(f"{where}.{key}: scalar metadata change is not an append")
    return replaced


def overlay_name(upstream_name: str) -> str:
    return upstream_name[:-5] + ".phone.json"
