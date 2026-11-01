#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The scripted model upstream for android/tools/run-app-turn.sh.

The model is a SCRIPT, not a model: request 1 answers with one tool call
(bash -> `phone info`), the request carrying the tool result answers with the
final text. DSH's DeepSeek adapter speaks the Messages wire format
(`POST /v1/messages`, SSE), so that is the route the App's turn uses; the
OpenAI route is kept for a direct egress probe.

The process binds 127.0.0.1 on an ephemeral port (or --port) and prints
`LISTENING <port>` so the shell can start `adb reverse` for exactly that port.
It never sees a real credential and never calls a model.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FINAL_TEXT = "The host executed `phone info`; done."
PENDING_TEXT = "I will ask the host for the phone facts."
TITLE_TEXT = "Phone info"
TOOL_COMMAND = "phone info"
TOOL_DESCRIPTION = "Ask the host for the phone's facts (exec/1 accelerator)"


def is_title_request(body: str) -> bool:
    lowered = body.lower()
    return "generate the session title" in lowered or "dsh-session-title-llm" in lowered


def carries_tool_result(body: str) -> bool:
    return '"type":"tool_result"' in body or '"type": "tool_result"' in body


def quote(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


def tool_arguments() -> str:
    return json.dumps(
        {"command": TOOL_COMMAND, "description": TOOL_DESCRIPTION},
        ensure_ascii=False,
        separators=(",", ":"),
    )


def messages_events(body: str) -> str:
    title = is_title_request(body)
    respond_with_tool = not title and not carries_tool_result(body)
    text = TITLE_TEXT if title else (PENDING_TEXT if respond_with_tool else FINAL_TEXT)
    model = "deepseek-flash"
    blocks: list[str] = []

    def emit(event: str, payload: dict) -> None:
        blocks.append(f"event: {event}\ndata: {json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}\n\n")

    emit(
        "message_start",
        {
            "type": "message_start",
            "message": {
                "id": "msg_scripted_app",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "usage": {"input_tokens": 64, "output_tokens": 0},
            },
        },
    )
    emit("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    emit(
        "content_block_delta",
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
    )
    emit("content_block_stop", {"type": "content_block_stop", "index": 0})
    if respond_with_tool:
        emit(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {
                    "type": "tool_use",
                    "id": "toolu_scripted_app",
                    "name": "bash",
                    "input": {},
                },
            },
        )
        emit(
            "content_block_delta",
            {
                "type": "content_block_delta",
                "index": 1,
                "delta": {"type": "input_json_delta", "partial_json": tool_arguments()},
            },
        )
        emit("content_block_stop", {"type": "content_block_stop", "index": 1})
    emit(
        "message_delta",
        {
            "type": "message_delta",
            "delta": {"stop_reason": "tool_use" if respond_with_tool else "end_turn"},
            "usage": {"output_tokens": 24},
        },
    )
    emit("message_stop", {"type": "message_stop"})
    return "".join(blocks)


def chat_completion(body: str) -> str:
    respond_with_tool = not is_title_request(body) and not carries_tool_result(body)
    message = {
        "role": "assistant",
        "content": PENDING_TEXT if respond_with_tool else FINAL_TEXT,
    }
    if respond_with_tool:
        message["tool_calls"] = [
            {
                "id": "call_scripted_app",
                "type": "function",
                "function": {"name": "bash", "arguments": tool_arguments()},
            }
        ]
    return json.dumps(
        {
            "id": "chatcmpl-scripted-app",
            "object": "chat.completion",
            "created": 0,
            "model": "deepseek-flash",
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": "tool_calls" if respond_with_tool else "stop",
                }
            ],
            "usage": {"prompt_tokens": 64, "completion_tokens": 24, "total_tokens": 88},
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pdsh-scripted-model"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - stdlib signature
        sys.stderr.write("upstream: " + (fmt % args) + "\n")
        sys.stderr.flush()

    def do_OPTIONS(self) -> None:  # noqa: N802 - stdlib signature
        # The Worker page is same-origin with the host, not with this upstream;
        # a browser fetch to <host>:<port>/v1/messages is cross-origin and sends a
        # preflight. The real provider answers it; this scripted one must too.
        self.send_response(204)
        self.cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, POST, OPTIONS")
        requested = self.headers.get("Access-Control-Request-Headers")
        self.send_header("Access-Control-Allow-Headers", requested or "*")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802 - stdlib signature
        if self.path.split("?")[0] in ("/", "/health"):
            self.respond_json(200, {"status": "ok"})
            return
        self.respond_json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        path = self.path.split("?")[0]
        title = is_title_request(body)
        print(
            f"MODEL_REQ path={path} title={str(title).lower()} "
            f"tool_result={str(carries_tool_result(body)).lower()} bytes={len(body)}",
            flush=True,
        )
        if path == "/v1/messages":
            payload = messages_events(body).encode("utf-8")
            self.respond(200, "text/event-stream", payload)
        elif path == "/v1/chat/completions":
            payload = chat_completion(body).encode("utf-8")
            self.respond(200, "application/json", payload)
        else:
            self.respond_json(404, {"error": "not_found", "path": path})

    def respond_json(self, status: int, value: object) -> None:
        self.respond(status, "application/json", json.dumps(value).encode("utf-8"))

    def cors_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "*")

    def respond(self, status: int, content_type: str, payload: bytes) -> None:
        self.send_response(status)
        self.cors_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0, help="0 asks the OS for a free port")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"LISTENING {server.server_address[1]}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
