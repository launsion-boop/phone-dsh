#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The scripted model upstream for `android/tools/acceptance/run-product-flow.sh`.

This is a FIXTURE, not a model: it answers from a script and never calls an
inference service. It exists so the seven product steps can be asserted without
a real credential — the acceptance run types a key generated at run time into
the App's settings page, the App's host model edge attaches it to the request it
sends here, and this process records only a SHA-256 of that header. No key is
written to any file of this repository, and this script cannot supply one.

Two lanes, chosen from the request body:

  stream lane (the default)
      A long answer delivered as ~12 SSE chunks with `--chunk-delay` between
      them, each one appending to the previous. Every chunk carries the marker
      `流式验收` and the last one carries `[STREAM-END]`. The driver samples
      `uiautomator dump` while this runs: the marker text on screen growing
      across samples is the evidence that the App streamed, not that it painted
      a finished string.

  csv lane (when the conversation mentions `--csv-name`)
      Round 1 answers with one `bash` tool call that cats the workspace CSV;
      round 2 is only reached when the App really executed that call, and the
      totals it reports are computed from the tool RESULT text — never from a
      constant in this file. If the result carries no parsable rows, the answer
      says so and the driver's step 5 must fail: there is no canned number to
      fall back on. Round 3 writes one summary artifact into the workspace and
      answers with the same numbers.

`ACCEPT_AUDIT` lines on stdout are the machine-readable receipt: lane, round,
rows, total, and SHA-256 of the request's credential headers and of the tool
result the numbers came from.
"""

from __future__ import annotations

import argparse
import decimal
import hashlib
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STREAM_MARKER = "流式验收"
STREAM_END = "[STREAM-END]"
CSV_END = "[CSV-END]"
TITLE_TEXT = "验收会话"
TOOL_NAME = "bash"

STREAM_SEGMENTS = (
    # Every segment carries the marker the driver looks for (STREAM_MARKER), so
    # the node it measures is the one this fixture is filling — even if the App
    # renders the answer as several text nodes.
    "流式验收 01/11：这是第 1 段，我在把一句话分成若干段写出来。",
    " 流式验收 02/11：第 2 段，屏幕上应该能看到句子在变长。",
    " 流式验收 03/11：第 3 段是在上一段之后才出现的。",
    " 流式验收 04/11：如果界面一次画完，采样就只会看到同一个长度。",
    " 流式验收 05/11：所以验收脚本边跑边 dump，比较两次长度。",
    " 流式验收 06/11：这一段继续加长，长度继续增加。",
    " 流式验收 07/11：流式的证据是中间态，不是结束态。",
    " 流式验收 08/11：到这里正文已经比第一次采样长很多。",
    " 流式验收 09/11：最后再补两句就可以收尾了。",
    " 流式验收 10/11：收尾前的倒数第二段。",
    " 流式验收 11/11：收尾前的最后一段正文。[STREAM-END]",
)

AMOUNT_HEADER = "amount"
SUMMARY_NAME = "orders-summary.md"


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def audit(line: str) -> None:
    print(f"ACCEPT_AUDIT {line}", flush=True)


def is_title_request(body: str) -> bool:
    lowered = body.lower()
    return "generate the session title" in lowered or "dsh-session-title-llm" in lowered


def parse_body(body: str) -> dict:
    try:
        value = json.loads(body)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def block_text(value) -> str:
    """The text of one `tool_result`/`tool` payload, however it is shaped."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                if isinstance(item.get("text"), str):
                    parts.append(item["text"])
                elif isinstance(item.get("content"), (str, list)):
                    parts.append(block_text(item["content"]))
        return "\n".join(parts)
    if isinstance(value, dict):
        return block_text(value.get("content"))
    return ""


def tool_results(payload: dict) -> list[str]:
    """Every tool result the transcript carries, in order."""
    found: list[str] = []
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return found
    for message in messages:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    found.append(block_text(block.get("content")))
        elif message.get("role") == "tool":
            found.append(block_text(content))
    return found


def user_text(payload: dict) -> str:
    """The last user message's text, for lane selection."""
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return ""
    for message in reversed(messages):
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = [
                item.get("text", "")
                for item in content
                if isinstance(item, dict) and item.get("type") in (None, "text")
            ]
            return "\n".join(parts)
    return ""


def parse_amounts(text: str) -> tuple[int, decimal.Decimal, str, str]:
    """Rows, amount sum, first parsed row and a digest of the parsed rows.

    The sum is computed from the text the App's host returned, so a fixture
    constant cannot answer for a file the device never read. The digest is over
    the normalized rows (`a,b,c` per line, trimmed, trailing newline) and the
    driver computes the same digest from `fixtures/orders.csv`: equal digests
    mean the numbers came from exactly those rows, not from a similar-looking
    string this file could have carried.
    """
    rows = 0
    total = decimal.Decimal("0")
    first = ""
    normalized: list[str] = []
    index = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        cells = [cell.strip() for cell in line.split(",")]
        if index is None:
            lowered = [cell.lower() for cell in cells]
            if AMOUNT_HEADER in lowered:
                index = lowered.index(AMOUNT_HEADER)
            continue
        if index >= len(cells):
            continue
        try:
            amount = decimal.Decimal(cells[index])
        except decimal.InvalidOperation:
            continue
        rows += 1
        total += amount
        normalized.append(",".join(cells))
        if not first:
            first = ",".join(cells)
    return rows, total, first, sha256("\n".join(normalized) + "\n") if normalized else "-"


def money(value: decimal.Decimal) -> str:
    return str(value.quantize(decimal.Decimal("0.01"), rounding=decimal.ROUND_HALF_UP))


def tool_arguments(command: str, description: str) -> str:
    return json.dumps(
        {"command": command, "description": description},
        ensure_ascii=False,
        separators=(",", ":"),
    )


class Plan:
    """One answer: either a text stream or one tool call."""

    def __init__(self, segments, stop_reason="end_turn", tool_call=None):
        self.segments = segments
        self.stop_reason = stop_reason
        self.tool_call = tool_call


RECALL_MARK = "recall:"
"""The chat-context driver's recall question marker (`run-chat-context-flow.sh`)."""

CONTEXT_ANSWER = "CONTEXT-OK 323"
"""What the fixture answers when the request transcript still carries the secret."""

SECRET = "PR14CHATOK"
"""The fact the driver asked the model to remember at the start of the chat."""


def earlier_user_texts(payload: dict) -> str:
    """Every user-authored text the request transcript carries, joined."""
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return ""
    parts: list[str] = []
    for message in messages:
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") in (None, "text"):
                    text = block.get("text")
                    if isinstance(text, str):
                        parts.append(text)
    return "\n".join(parts)


def plan_for(payload: dict, body: str, args) -> Plan:
    if is_title_request(body):
        return Plan([TITLE_TEXT])

    results = tool_results(payload)
    said = user_text(payload)

    # The chat-context lane (step 8) runs FIRST: once a CSV is in the
    # transcript, every later request would otherwise take the CSV lane. The
    # answer is decided from the *request transcript* only, so it is evidence
    # that the Worker resumed the same Session with its durable history: the App
    # re-sends no history of its own.
    if RECALL_MARK in said.lower():
        carried = SECRET in earlier_user_texts(payload)
        audit("lane=recall carried={} messages={}".format(carried, len(payload.get("messages") or [])))
        return Plan([CONTEXT_ANSWER if carried else "UNKNOWN"])

    # The fact the conversation must remember (the flow's first prompt). The answer
    # carries it, so the later recall question has something the model itself
    # said as well as the user's own message.
    if SECRET in said:
        audit("lane=secret messages={}".format(len(payload.get("messages") or [])))
        return Plan([SECRET + " 323"])

    wants_csv = args.csv_name.lower() in said.lower() or args.csv_name.lower() in body.lower()
    if not wants_csv:
        audit(f"lane=stream chunks={len(STREAM_SEGMENTS)} round=0")
        return Plan(list(STREAM_SEGMENTS))

    if not results:
        audit("lane=csv round=1 tool_results=0 rows=0 total=-")
        command = f"cat /dsh/workspace/{args.csv_name}"
        return Plan(
            ["我先读一下工作区里的这份 CSV。"],
            stop_reason="tool_use",
            tool_call=(command, f"read /dsh/workspace/{args.csv_name}"),
        )

    rows, total, first, rows_digest = parse_amounts(results[0])
    if rows == 0:
        audit(f"lane=csv round=2 tool_results={len(results)} rows=0 total=- rows_digest=-")
        return Plan(
            ["工具输出里没有可解析的 CSV 行，因此没有给出合计。", "[NO-CSV-DATA]"],
        )

    formatted = money(total)
    audit(
        "lane=csv round=2 tool_results={} rows={} total={} rows_digest={} tool_digest={}".format(
            len(results), rows, formatted, rows_digest, sha256(results[0])
        )
    )
    summary = (
        f"#{args.csv_name} 汇总\n"
        f"rows: {rows}\n"
        f"amount total: {formatted}\n"
        f"first row: {first}\n"
    )
    # The artifact write is asked for once. If the App's transcript still has no
    # second tool result on the next request (a dropped write, not an error the
    # fixture can see), the answer must not loop: it reports the numbers it did
    # parse and leaves the missing artifact to step 6, which asserts it directly.
    asked = SUMMARY_NAME in body
    if len(results) < 2 and not asked:
        command = (
            "printf '%s' "
            + shell_quote(summary)
            + f" > /dsh/workspace/{SUMMARY_NAME}"
        )
        return Plan(
            [f"读到了 {rows} 行，合计 {formatted}。现在把汇总写进工作区。"],
            stop_reason="tool_use",
            tool_call=(command, f"write /dsh/workspace/{SUMMARY_NAME}"),
        )

    if asked and len(results) < 2:
        audit("lane=csv artifact_write_result_missing rows={} total={}".format(rows, formatted))
    return Plan(
        [
            f"已处理 {args.csv_name}：共 {rows} 行，金额合计 {formatted}。",
            f"首行是 {first}，写入的产物是 {SUMMARY_NAME}。",
            CSV_END,
        ]
    )


def shell_quote(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


def sse(event: str, payload: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}\n\n"


def messages_frames(plan: Plan) -> list[str]:
    """The Messages-wire SSE frames, in order, one frame per delta."""
    frames = [
        sse(
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_acceptance",
                    "type": "message",
                    "role": "assistant",
                    "model": "deepseek-flash",
                    "content": [],
                    "usage": {"input_tokens": 64, "output_tokens": 0},
                },
            },
        ),
        sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
    ]
    for segment in plan.segments:
        frames.append(
            sse(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": segment},
                },
            )
        )
    frames.append(sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
    if plan.tool_call is not None:
        command, description = plan.tool_call
        frames.append(
            sse(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 1,
                    "content_block": {"type": "tool_use", "id": "toolu_acceptance", "name": TOOL_NAME, "input": {}},
                },
            )
        )
        frames.append(
            sse(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 1,
                    "delta": {"type": "input_json_delta", "partial_json": tool_arguments(command, description)},
                },
            )
        )
        frames.append(sse("content_block_stop", {"type": "content_block_stop", "index": 1}))
    frames.append(
        sse(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": plan.stop_reason},
                "usage": {"output_tokens": 24},
            },
        )
    )
    frames.append(sse("message_stop", {"type": "message_stop"}))
    return frames


def openai_frames(plan: Plan) -> list[str]:
    """The OpenAI-wire SSE frames: one `delta` per segment, tools in round two."""
    frames = []
    for segment in plan.segments:
        frames.append(
            "data: "
            + json.dumps(
                {
                    "id": "chatcmpl-acceptance",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "deepseek-flash",
                    "choices": [{"index": 0, "delta": {"content": segment}, "finish_reason": None}],
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
            + "\n\n"
        )
    if plan.tool_call is not None:
        command, description = plan.tool_call
        frames.append(
            "data: "
            + json.dumps(
                {
                    "id": "chatcmpl-acceptance",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "deepseek-flash",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_acceptance",
                                        "type": "function",
                                        "function": {
                                            "name": TOOL_NAME,
                                            "arguments": tool_arguments(command, description),
                                        },
                                    }
                                ]
                            },
                            "finish_reason": None,
                        }
                    ],
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
            + "\n\n"
        )
    frames.append(
        "data: "
        + json.dumps(
            {
                "id": "chatcmpl-acceptance",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": "deepseek-flash",
                "choices": [{"index": 0, "delta": {}, "finish_reason": plan.stop_reason}],
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n\n"
    )
    frames.append("data: [DONE]\n\n")
    return frames


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pdsh-acceptance-fixture"
    chunk_delay = 0.55

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - stdlib signature
        sys.stderr.write("upstream: " + (fmt % args) + "\n")
        sys.stderr.flush()

    def cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "*")

    def do_OPTIONS(self) -> None:  # noqa: N802 - stdlib signature
        self.send_response(204)
        self.cors()
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, POST, OPTIONS")
        requested = self.headers.get("Access-Control-Request-Headers")
        self.send_header("Access-Control-Allow-Headers", requested or "*")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802 - stdlib signature
        if self.path.split("?")[0] in ("/", "/health"):
            self.reply_json(200, {"status": "ok"})
            return
        self.reply_json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        path = self.path.split("?")[0]
        payload = parse_body(body)
        plan = plan_for(payload, body, self.server.args)
        print(
            "MODEL_REQ path={} title={} tool_results={} bytes={}".format(
                path,
                str(is_title_request(body)).lower(),
                len(tool_results(payload)),
                len(body),
            ),
            flush=True,
        )
        self.record_credentials(path)
        if path == "/v1/messages":
            self.stream(messages_frames(plan), "text/event-stream")
        elif path == "/v1/chat/completions":
            stream = bool(payload.get("stream"))
            if stream:
                self.stream(openai_frames(plan), "text/event-stream")
            else:
                self.reply_json(200, self.openai_complete(plan))
        else:
            self.reply_json(404, {"error": "not_found", "path": path})

    def record_credentials(self, path: str) -> None:
        """Hash the credential headers; the value itself is never logged."""
        authorization = self.headers.get("Authorization") or ""
        api_key = self.headers.get("x-api-key") or ""
        audit(
            "credentials path={} authorization_len={} authorization_sha256={} "
            "x_api_key_len={} x_api_key_sha256={}".format(
                path,
                len(authorization),
                sha256(authorization) if authorization else "-",
                len(api_key),
                sha256(api_key) if api_key else "-",
            )
        )

    def openai_complete(self, plan: Plan) -> dict:
        content = "".join(plan.segments)
        message = {"role": "assistant", "content": content}
        if plan.tool_call is not None:
            command, description = plan.tool_call
            message["tool_calls"] = [
                {
                    "id": "call_acceptance",
                    "type": "function",
                    "function": {
                        "name": TOOL_NAME,
                        "arguments": tool_arguments(command, description),
                    },
                }
            ]
        return {
            "id": "chatcmpl-acceptance",
            "object": "chat.completion",
            "created": 0,
            "model": "deepseek-flash",
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": "tool_calls" if plan.tool_call else "stop",
                }
            ],
            "usage": {"prompt_tokens": 64, "completion_tokens": 24, "total_tokens": 88},
        }

    def stream(self, frames: list[str], content_type: str) -> None:
        """Write each frame with a flush and a delay: that is the stream."""
        self.send_response(200)
        self.cors()
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(sum(len(frame.encode()) for frame in frames)))
        self.end_headers()
        for index, frame in enumerate(frames):
            try:
                self.wfile.write(frame.encode("utf-8"))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            if index < len(frames) - 2:
                time.sleep(self.server.args.chunk_delay)

    def reply_json(self, status: int, value: object) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description="scripted acceptance upstream")
    parser.add_argument("--port", type=int, default=0, help="0 asks the OS for a free port")
    parser.add_argument("--csv-name", default="orders.csv", help="the file name that selects the csv lane")
    parser.add_argument("--chunk-delay", type=float, default=0.55, help="seconds between SSE frames")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.args = args
    Handler.chunk_delay = args.chunk_delay
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
