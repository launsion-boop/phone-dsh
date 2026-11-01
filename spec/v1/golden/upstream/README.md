# Mock-upstream fixtures — script model

Status: normative fixtures. Each file scripts a mock model upstream: the request it answers, the
ordered responses it writes on the wire and what the caller must observe. A runner that has never
read the Swift tree can implement a compatible mock and the assertions from one file.

The transport semantics are the host gateway's, not the mock's: a 429/5xx head is retried before any
byte is forwarded, a transport failure is retried only before the response head, a body cut after the
head ends the caller's stream with an error that is not retried, and a stalling upstream is ended by
the delivery layer's inactivity deadline. Those rules are implemented in `Sources/PhoneDSHGateway`
and fixed by the tests named in each fixture's `source`.

The fixtures were lifted from two places: `Tests/PhoneDSHGatewayTests/MockUpstreamServer.swift` (the
HTTP/1.1 test upstream, including its `full`, `chunked` and `abort` response shapes) and
`Sources/PhoneDSHScenario/ScenarioMockUpstream.swift` (the scripted scenario upstream and the SSE
body shape). Nothing here claims a measurement; members the Swift tests do not fix are `unmeasured`.

## 1. File shape

Every `*.json` in this directory validates against
[schema/upstream-script.schema.json](../../schema/upstream-script.schema.json):

```json
{
  "id": "retry-500-then-200",
  "model": "deepseek-flash",
  "request_match": {"method": "POST", "path_suffix": "/v1/messages"},
  "script": [
    {"status": 500, "headers": {"content-type": "application/json"},
     "frames": "content_length", "declared_content_length": 52,
     "body_chunks": ["{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"], "closes": true},
    {"status": 200, "headers": {"content-type": "text/event-stream"},
     "frames": "chunked", "body_chunks": ["event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"],
     "closes": true}
  ],
  "expected": {
    "caller_visible": "final_status_and_body",
    "retry": {"retried": true, "attempts": 2, "trigger": "upstream_status",
              "delays_ms": [1000], "jitter_disabled": true},
    "provider_error": "none",
    "client_outcome": "ok",
    "field_evidence": {"caller_visible": "swift-test", "retry": "swift-test",
                       "provider_error": "swift-test", "client_outcome": "swift-test"}
  },
  "evidence_level": "swift-test",
  "source": "Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:880-898"
}
```

* `id` — unique across both fixture families and equal to the file name.
* `model` — the `model` member of the request body the mock answers; `any` when the script is
  model-agnostic.
* `request_match.path_suffix` — must name a replay-safe model endpoint (`/v1/messages`, `/messages`,
  `/v1/chat/completions`, `/chat/completions`), because the retry rules only apply there.

The example is abridged for the second script entry; every asserted member needs a `field_evidence`
entry and the checker rejects a fixture that omits one.

## 2. Script event model

`script[]` is ordered: entry *n* answers the *n*-th upstream connection. When the caller makes more
attempts than the script has entries, **the last entry repeats**. That is how one entry models five
identical 500s.

| Member | Required | Meaning |
|---|---|---|
| `status` | yes | `0` = the connection is reset before any response byte; otherwise `200..599`, the status of the response head |
| `headers` | no | response headers, lower-case names |
| `body_chunks` | yes | body payloads written in order; strings, possibly empty |
| `delay_ms` | no | logical delay between two body chunks (default 0) |
| `closes` | yes | `true` writes the terminating chunk (or the declared length) and closes; `false` holds the connection open with no terminating chunk |
| `frames` | no | `chunked` (default) writes each body chunk as one transfer-encoding chunk and ends with the zero-length chunk; `content_length` writes the head with `declared_content_length` and then the body bytes |
| `declared_content_length` | with `content_length` | the `Content-Length` value; may exceed the bytes actually written, which is how a truncated body is expressed |
| `truncated` | no | the server closes before the declared length, so the caller observes a short body |
| `stall_after_bytes` | with `closes: false` | how many body bytes are written before the connection goes silent |
| `malformed` | no | the bytes are deliberately not valid SSE and the mock must not normalize them |

The three shapes map 1:1 to the Swift mock: `status` + body + `closes: true` is `MockUpstreamServer`
`.full`; `frames: chunked` is `.chunked`; `status: 0` is `.abort(partial: Data())`; a short body with
a larger declared length is `.abort(partial:)` with a complete head; `closes: false` plus
`stall_after_bytes` is `ScenarioMockUpstream`'s stall, which never writes the zero-length chunk.

## 3. Expected members

| Member | Values | Meaning |
|---|---|---|
| `caller_visible` | see below | what the caller of the gateway stream observes |
| `retry` | object | `retried`, `attempts` (upstream connections), `trigger`, `delays_ms`, `jitter_disabled` |
| `provider_error` | `none` or a stable cause code | the gateway's structured error code (`host_not_allowed`, `invalid_request`, `credential_unavailable`, `upstream_failed`, `shutting_down`, `transport_failure`, `upstream_status`), or `none` when the response is forwarded |
| `delivery_error` | `PDSH_DELIVERY_TIMEOUT`, `none` | the typed failure of the Worker's host-route delivery layer |
| `response_log` | `committed`, `aborted`, `not_written` | the disposition of the replay recording for this request |
| `client_outcome` | `ok`, `error` | the gateway stream's outcome: `ok` completes with a final chunk (any status), `error` throws |

`caller_visible`:

| Value | The caller observes |
|---|---|
| `sse_stream_passthrough` | the head before the last chunk, then every body byte in order, unchanged |
| `status_and_body` | one non-retried response status and body, forwarded as received |
| `final_status_and_body` | exactly the last attempt's response; the superseded attempts are invisible |
| `bytes_passed_through_unchanged` | bytes the gateway does not parse; they arrive unchanged even if they are not valid SSE |
| `truncated_stream_then_error` | the head and part of the body, then a stream error |
| `error_without_body` | no body at all, only the failure |
| `delivery_timeout` | the head and part of the body, then the delivery layer's typed timeout |

`retry.trigger` — `none`, `upstream_status` (429/5xx head), `transport_before_head` (the connection
failed before a head), `budget_exhausted` (the budget ended on a still-retryable failure).

`delays_ms` is the backoff schedule, one entry per retry, and is only deterministic when
`jitter_disabled` is true. The production default jitters each delay into the lower 20 % of its
nominal value, so a runner must compare the attempt count unless it also disables jitter.

`unmeasured` on any member means the Swift tests do not fix it; it must have no `field_evidence`
entry and the runner must not assert it.

## 4. What a runner must do

1. Start the mock, bind it on a loopback port and point the Worker's base URL at it.
2. Answer a request whose method matches and whose path ends with `path_suffix` with script entry 1;
   answer the *n*-th connection with entry *n* (or the last entry when the script is exhausted).
3. Write the head first, then the body chunks in order with the configured delay, then:
   * `frames: chunked` and `closes: true` — the zero-length chunk and a close;
   * `frames: content_length` and `closes: true` — the declared number of bytes, then a close;
   * `closes: false` — exactly `stall_after_bytes` bytes, then silence with the socket open;
   * `status: 0` — reset the connection before writing anything.
4. Assert the caller-visible behaviour of the Worker / gateway under test against `expected`:
   * `retry.attempts` — count the connections the mock accepted; `delays_ms` only when jitter is
     disabled;
   * `provider_error` — the structured cause code the gateway reports (for a forwarded response it is
     `none`, because a plain egress forwards the upstream status instead of raising);
   * `delivery_error` — the typed error the delivery layer reports, not a generic timeout;
   * `response_log` — whether the request has a committed replay recording (`aborted` means no
     replay may be served later).
5. Treat any member the runner cannot observe as a runner failure, never as a pass.

## 5. Evidence

The same four classes as the perturbation family are used — `swift-test`, `swift-source`,
`spec-only`, `NEW` — and `evidence_level` is again the **weakest** value in `expected.field_evidence`.
`NEW` requires a `new_reason`; `source: NEW` is only legal with `evidence_level: NEW`.

## 6. Validation

```sh
python3 spec/v1/tools/fixture_check.py --root .
python3 -m unittest discover -s spec/v1/tools -p 'test_fixture_check.py' -v
```

The checker validates the script against the schema and the framing laws (declared length versus
written bytes, `truncated`, `stall_after_bytes`, `closes`, retry budget and delays, and the
`caller_visible`/`provider_error` pairing).

## 7. Known gaps

* `client_outcome` is `unmeasured` for the malformed body: the Worker's model-client parser is not
  covered by any Swift test, so the fixture fixes only the byte-transparent forwarding of the
  gateway.
* The credential, header-stripping and redirect-scope fixtures the port plan calls "gateway security
  golden vectors" are a separate work item; this directory scripts responses, not credential
  injection.
* The sensitive-SSE path (a host-managed credential row that may rewrite a malformed event) has no
  fixture here: the model provider path uses a bearer credential and is not sensitive, so a fixture
  for it would need a different `request_match` contract.
* `status: 0` is the only spelling for "no response head". A malformed HTTP *framing* (an invalid
  chunk-size line) cannot be expressed: the real mock always frames correctly, and inventing a
  raw-byte escape would document behaviour no Swift test asserts.
