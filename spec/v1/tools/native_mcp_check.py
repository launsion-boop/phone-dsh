#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Validate native Android MCP and ADB transfer golden vectors."""

from __future__ import annotations

import argparse
import base64
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

from spec_golden import SpecError, load_json  # noqa: E402

VECTOR_DIR = Path("golden/native-mcp")


def require(condition, message):
    if not condition:
        raise SpecError(message)


def mapping(value, name):
    require(type(value) is dict, f"{name}: expected object")
    return value


def fields(value, allowed, required, name):
    required = set(required)
    require(required <= set(value), f"{name}: missing {sorted(required - set(value))}")
    require(set(value) <= set(allowed), f"{name}: unknown member {sorted(set(value) - set(allowed))}")


def absolute(path, name):
    require(type(path) is str and path.startswith("/") and ".." not in path.split("/"), f"{name}: invalid absolute path")


def response(value, expected_id):
    mapping(value, "response")
    fields(value, {"jsonrpc", "id", "result"}, {"jsonrpc", "id", "result"}, "response")
    require(value["jsonrpc"] == "2.0" and value["id"] == expected_id, "response: correlation mismatch")
    result = mapping(value["result"], "response.result")
    fields(result, {"content", "isError"}, {"content", "isError"}, "response.result")
    require(result["isError"] is False, "response.result: expected success")
    content = result["content"]
    require(type(content) is list and content, "response.result.content: expected non-empty array")
    first = mapping(content[0], "response.result.content[0]")
    fields(first, {"type", "text"}, {"type", "text"}, "response.result.content[0]")
    require(first["type"] == "text" and type(first["text"]) is str, "response.result.content[0]: expected text")


def request(value):
    mapping(value, "request")
    fields(value, {"jsonrpc", "id", "method", "params"}, {"jsonrpc", "id", "method", "params"}, "request")
    require(value["jsonrpc"] == "2.0" and value["method"] == "tools/call", "request: expected tools/call")
    params = mapping(value["params"], "request.params")
    fields(params, {"name", "arguments"}, {"name", "arguments"}, "request.params")
    require(type(params["name"]) is str and params["name"].startswith("android_"), "request.params.name: expected android tool")
    require(type(params["arguments"]) is dict, "request.params.arguments: expected object")
    return value["id"]


def http_vector(data):
    fields(data, {"path", "method", "request", "android_command", "response"},
           {"path", "method", "request", "android_command", "response"}, "native HTTP vector")
    require(data["path"] == "/mcp/native" and data["method"] == "POST", "native HTTP vector: expected POST /mcp/native")
    require(type(data["android_command"]) is str and data["android_command"], "android_command: expected non-empty string")
    response(data["response"], request(data["request"]))


def package_vector(data):
    require(type(data) is list and data, "package-management: expected non-empty array")
    for item in data:
        mapping(item, "package-management item")
        fields(item, {"request", "android_command", "stdout", "response"},
               {"request", "android_command", "stdout", "response"}, "package-management item")
        require(type(item["android_command"]) is str and item["android_command"], "package-management: missing command")
        require(type(item["stdout"]) is str, "package-management.stdout: expected string")
        response(item["response"], request(item["request"]))


def transfer_vector(data):
    fields(data, {"argv", "stdout_records", "exitCode", "native_disk_transfer", "saved_status"},
           {"argv", "stdout_records", "exitCode", "native_disk_transfer", "saved_status"}, "file-transfer")
    argv = data["argv"]
    require(type(argv) is list and len(argv) == 5, "file-transfer.argv: expected five elements")
    require(argv[:3] == ["adb", "--pdsh-v1", "pull"], "file-transfer.argv: expected adb pull")
    absolute(argv[3], "file-transfer local")
    absolute(argv[4], "file-transfer remote")
    require(argv[3].startswith("/dsh/workspace/"), "file-transfer: workspace source required")
    records = data["stdout_records"]
    require(type(records) is list and len(records) >= 3, "stdout_records: expected file/data/end")
    require(data["exitCode"] == 0, "file-transfer: expected zero exit")
    kinds = []
    for record in records:
        mapping(record, "stdout_records item")
        kind = record.get("type")
        kinds.append(kind)
        if kind == "file":
            fields(record, {"type", "path", "name", "size"}, {"type", "path", "name", "size"}, "file record")
            require(type(record["name"]) is str and record["name"], "file record: missing name")
            require(type(record["size"]) is int and record["size"] >= 0, "file record: invalid size")
        elif kind == "data":
            fields(record, {"type", "data"}, {"type", "data"}, "data record")
            require(type(record["data"]) is str, "data record: expected base64 string")
            try:
                base64.b64decode(record["data"], validate=True)
            except ValueError as error:
                raise SpecError(f"data record: invalid base64: {error}") from error
        elif kind == "end":
            fields(record, {"type", "path"}, {"type", "path"}, "end record")
        else:
            raise SpecError(f"stdout_records: unknown type {kind!r}")
    require(kinds[0] == "file" and kinds[-1] == "end" and "data" in kinds, "stdout_records: invalid order")

    native = mapping(data["native_disk_transfer"], "native_disk_transfer")
    fields(native, {"argv", "max_bytes", "deadline_ms", "stdout_kind", "worker_vfs_write"},
           {"argv", "max_bytes", "deadline_ms", "stdout_kind", "worker_vfs_write"}, "native_disk_transfer")
    native_argv = native["argv"]
    require(type(native_argv) is list and len(native_argv) == 5, "native_disk_transfer.argv: expected five elements")
    require(native_argv[:3] == ["adb", "--pdsh-v1", "pull"], "native_disk_transfer.argv: expected adb pull")
    require(native_argv[3].startswith("/dsh/transfers/"), "native_disk_transfer: native store source required")
    absolute(native_argv[4], "native_disk_transfer remote")
    require(native["max_bytes"] == 1_073_741_824 and native["deadline_ms"] == 3_600_000,
            "native_disk_transfer: wrong byte or deadline bound")
    require(native["stdout_kind"] == "completion_text" and native["worker_vfs_write"] is False,
            "native_disk_transfer: expected completion text without worker VFS write")

    saved = mapping(data["saved_status"], "saved_status")
    fields(saved, {"argv", "stdout"}, {"argv", "stdout"}, "saved_status")
    saved_argv = saved["argv"]
    require(type(saved_argv) is list and len(saved_argv) == 4, "saved_status.argv: expected four elements")
    require(saved_argv[:3] == ["adb", "--pdsh-v1", "stat"], "saved_status.argv: expected adb stat")
    absolute(saved_argv[3], "saved_status path")
    require(saved_argv[3].startswith("/dsh/transfers/"), "saved_status: native store path required")
    stdout = mapping(saved["stdout"], "saved_status.stdout")
    fields(stdout, {"status", "path", "size"}, {"status", "path", "size"}, "saved_status.stdout")
    require(stdout["status"] == "saved", "saved_status.stdout: expected saved")
    require(type(stdout["size"]) is int and stdout["size"] > 0, "saved_status.stdout: invalid size")
    absolute(stdout["path"], "saved_status.stdout.path")


def validate(root: Path) -> int:
    directory = root / "spec/v1" / VECTOR_DIR
    files = sorted(directory.glob("*.json"))
    require(files, f"{directory}: no native MCP vectors")
    for path in files:
        data = load_json(path)
        if path.name == "package-management.json":
            package_vector(data)
        elif path.name == "file-transfer.json":
            transfer_vector(data)
        else:
            http_vector(data)
    return len(files)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    args = parser.parse_args(argv)
    try:
        count = validate(Path(args.root).resolve())
        print(f"native-mcp: {count} files checked, 0 error(s)")
        return 0
    except (SpecError, OSError, ValueError) as error:
        print(f"native-mcp: FAIL: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
