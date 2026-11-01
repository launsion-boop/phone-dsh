# Gateway security vectors (proto 1)

Status: P0 conformance contract, MIT. Normative, language-independent description of the
security-critical gateway semantics the Kotlin `:gateway` port must reproduce. The executable
oracle is [`golden/gateway/`](golden/gateway), checked by
[`tools/gateway_check.py`](tools/gateway_check.py) against
[`schema/gateway-vector.schema.json`](schema/gateway-vector.schema.json). Swift is the reference
implementation; where this document and a vector disagree the vector is the defect. Six rule
classes: `credential-injection`, `header-strip`, `redirect-scope`, `egress-classification`,
`response-redaction`, `failure-surface`.

## 1. Judging one vector

`{id, rule, kind, input, expect, source}` is one exchange; `source` is the implementing line and
`references` name the Swift assertions that pin it.

- `input.method`, `input.url`, `input.headers` are the Worker `/v1/http` request as the gateway
  sees it. Fixture header names are always lowercase.
- `input.allowlist` holds `allowedUpstreamHosts` entries verbatim: `host`, `host:port`,
  `scheme://host[:port]`, `*`, `scheme://*`, `*.suffix`.
- `input.credential` is what the host `CredentialProvider` returns for the URL scope: `none` =
  `Credential.none` (anonymous), `unavailable` = the provider throws, `bearer` =
  `Authorization: Bearer <value>`, `api-key` = `<header>: <value>`, `headers` = a host-managed map.
- `input.mcp: true` marks a call admitted by the host's exact-URL MCP egress grant; it takes the
  sensitive response path whatever the credential kind is.
- `input.redirects` are the ordered `{status, location}` hops the origin answers; `Location` is
  already absolute. `input.response` is the upstream `status`/`headers`/`body` (or synthetic
  `body_bytes`); `input.quota_bytes` is `responseLogQuotaBytes`.
- `expect.dispatch`: `allow` means every request the exchange implies was sent; `deny` means at
  least one hop was refused. A pre-flight deny sends nothing; a refused redirect sends the hops
  before it and hands the original 3xx back.
- `expect.outbound_headers` are the gateway's request header map for `request`/`redirect-chain`
  (transport-added `Host`, `Content-Length`, `Connection`, `Accept-Encoding` are out of scope) and
  the response headers handed to the Worker for `response` (lowercased, filtered). `expect.stripped`
  lists caller header names removed by name; a value-level drop (the Worker placeholder) or a
  same-name override is not `stripped`.
- `expect.outbound_url` is the last URL actually contacted (`""` for a pre-flight deny).
  `expect.redirects_followed` is the hops re-issued: an `allow` chain follows every hop with
  `final_url == outbound_url`; a `deny` chain stops earlier with
  `final_url == redirects[redirects_followed].location`.
- `expect.body` is exact text; `expect.body_json` is structural equality (member order and
  whitespace in the *input* are insignificant, because the sanitizer re-encodes). Re-encoding
  sorts keys, so the output bytes are reproducible; `expect.body_sha256` pins those bytes.
  `expect.log.recorded` says whether the response log committed; `expect.failure` is the
  `/v1/http` envelope. Every `deny` carries `deny_reason`. `expect.status` is the status handed
  back, `expect.response_headers` a header subset, `expect.upstream_contacts` the calls made.

## 2. Credential injection — `credential-injection`

- **Scope.** The provider is queried with the lowercased host (`service`), the normalized path
  (`audience`), the scheme and the explicit port; query and fragment never participate
  (`Sources/PhoneDSHGateway/ModelGatewayCredentialRouting.swift:26`, `:54`). Input: request URL →
  expect: one provider call for that scope.
- **Injection.** After caller headers are copied, `Credential.apply` sets
  `Authorization: Bearer <value>`, `<header>: <value>`, or every member of a `headers` map
  (`Sources/PhoneDSHAgentCore/Credentials.swift:64`, `Sources/PhoneDSHGateway/ModelGateway.swift:1018`).
  Input: provider value → expect: exactly those outbound headers.
- **Authority.** A caller `Authorization`, `Proxy-Authorization` or
  `X-PDSH-Upstream-Authorization` is dropped before injection; the host value is applied last, so
  it also overrides a caller header of the same name (for example `x-api-key`). The drop is
  counted in `workerCredentialsDropped`, never silent (`ModelGateway.swift:1031`, `:1043`, `:384`).
- **Placeholder.** The value `phone-host-injects-mcp-key` is dropped per value; the header name
  stays and the host map supplies the real value (`ModelGateway.swift:1010`, `:1028`).
- **The Worker never holds the key.** Injection happens inside `makeURLRequest` in the host
  process; no vector may put a host value into the Worker request. Vectors: `gw-cred-001` (key
  injected), `gw-cred-002` (forged caller value overridden and counted), `gw-cred-003` (MCP map).

## 3. Header stripping — `header-strip`

- **Request denylist** (removed by name): `authorization`, `proxy-authorization`, `host`,
  `connection`, `content-length`, `transfer-encoding`, `accept-encoding`, `expect`, `upgrade`,
  `te`, `trailer`, `proxy-connection`, `cookie`, `cookie2`, `referer`, `referrer`, plus every
  `x-pdsh-*` internal header (`ModelGateway.swift:1007`, `:1031`). Input: those headers → expect:
  absent from `outbound_headers` and listed in `stripped`.
- **Cookie and Referer.** The Worker's same-origin XHR carries the loopback launch cookie and a
  loopback Referer; they authenticate the local origin, not the upstream, so both are always
  dropped (`ModelGateway.swift:1035`). A host cookie credential is applied later by §2 and is the
  only cookie the upstream sees.
- **`Idempotency-Key`.** Caller-owned: forwarded verbatim, never synthesized, rewritten or
  deduplicated by the gateway; exec dedup is D10's job (`ModelGateway.swift:1031`). No Swift test
  asserts the forwarded value, so `gw-hop-003` is the only oracle for this rule.
- **Default is passthrough.** Only the denylist is removed; an unknown caller header (including an
  authentication-shaped one) is forwarded unchanged. See §9.
- Vectors: `gw-hop-001` (hop-by-hop, `Host`, `X-PDSH-*`), `gw-hop-002` (cookie/cookie2/Referer),
  `gw-hop-003` (`Idempotency-Key` survives).

## 4. Redirect scope — `redirect-scope`

- **Re-authorize every hop.** Before following, the target is checked against the same allowlist
  (rules plus `egressAuthorizer`); a miss returns the 3xx instead of following it
  (`Sources/PhoneDSHGateway/GatewaySession.swift:368`, `:303`). A refused hop is never re-issued and
  receives no credential; the Worker gets the original 3xx (`GatewaySession.swift:362`).
- **Credential scope.** When the request carries a host credential, a hop is followed only if
  scheme, lowercased host, effective port and normalized path all match the origin the credential
  was resolved for; query/fragment are excluded and trailing separators are normalized
  (`GatewaySession.swift:185`, `:373`, `:394`). Same host + different path, port or scheme is
  refused even on the allowlist. Input: hop target → expect: `allow` in the same scope, or `deny`
  + `redirect_scope_mismatch`.
- **Re-apply the credential.** On an in-scope hop the host credential is applied again, because
  URLSession may drop `Authorization` on redirect (`GatewaySession.swift:383`).
- **Anonymous is not pinned.** A request with no secret credential may cross origins when both are
  allow-listed (`GatewaySession.swift:372`, `:388`).
- **Wildcards.** `*` admits any http(s) host on any port; `scheme://*` admits any host under that
  scheme only; `*.suffix` admits the apex and everything below it; an explicit port compares the
  effective port; non-http(s) schemes never match (`GatewaySession.swift:59`, `:63`, `:66`, `:78`).
  `https://*` therefore does not permit an http downgrade: the target is not allow-listed and the
  hop is refused.
- Vectors: `gw-redir-001` (off-list host), `gw-redir-002` (same scope followed), `gw-redir-003`
  (same host, other path), `gw-redir-004` (cross-host mid-chain), `gw-redir-005` (`https://*` +
  http downgrade), `gw-redir-006` (anonymous cross-host allowed), `gw-redir-007` (308, cross-host
  mid-chain, the key stays on the first host), `gw-redir-008` (301, off-list host, one contact).

## 5. Egress classification — `egress-classification`

- **Scheme gate.** Only `http`/`https` with a non-empty host is a request; a non-http(s) URL is
  `invalid_request` before any allow-list work (`ModelGateway.swift:573`).
- **One effective list.** `allowedUpstreamHosts` = model hosts ∪ the scenario's `network.allow`
  entries, blanks dropped; an empty list denies every host (`ModelGateway.swift:141`, `:148`). An
  MCP grant is a second, exact scheme/host/effective-port/normalized-path authorizer layered on
  top (`Sources/PhoneDSH/PhoneMCPAccessSettings.swift:210`, `:250`).
- **Classes.** The gateway does not classify by IP literal. Loopback/local, private and public
  hosts are all admitted only by a matching entry: there is no implicit localhost or RFC1918
  exemption (`GatewaySession.swift:59`). A wildcard admits every literal host, including private
  ones (§9).
- **Default deny.** Input: a host with no matching entry → expect: `deny` + `host_not_allowed`,
  before credential resolution and before any connection (`ModelGateway.swift:580`, `:648`).
- Vectors: `gw-egress-001` (exact `127.0.0.1:7861` hit), `gw-egress-002` (unlisted public host),
  `gw-egress-003` (unlisted loopback/private address), `gw-egress-004` (`https://*` hit),
  `gw-egress-005` (port mismatch).

## 6. Response side — `response-redaction`

- **MCP calls are always sensitive.** Sensitivity is a property of the call, not of the credential
  kind: the exact-URL egress grant and the Worker placeholder mark an MCP call, and every such
  response is body-redacted and excluded from the response log even when the credential is a
  scalar `bearer`/`api-key` (`ModelGateway.swift:647`, `:1206`, `:1240`). A non-empty `.headers`
  map remains only a defensive fallback; credential kind never decides sensitivity.
- **Non-2xx.** The status is the diagnostic; the body is replaced by one controlled JSON-RPC error
  and the head is `application/json; charset=utf-8`. `HEAD` and 204/205/304 keep no body
  (`SensitiveResponseBody.swift:68`, `:110`).
- **2xx JSON/text.** Buffered up to 4 MiB; every exact injected value, plus the credential part
  after `Bearer`/`Basic`/`Token`, is replaced with `[redacted]`; JSON is rewritten structurally so
  the JSON-RPC `id` survives; invalid UTF-8 falls back to byte-level replacement; exceeding the
  bound fails closed (`SensitiveResponseBody.swift:58`, `:143`, `:321`). Re-encoding uses
  `.sortedKeys`, so the same input always produces the same UTF-8 bytes and `body_sha256` can
  pin them (`SensitiveResponseBody.swift:152`). Input: body echoing a secret → expect: no secret
  in `body`/`body_json` and the exact bytes in `body_sha256`.
- **Headers.** The response denylist is dropped; non-structural values are redacted; `content-type`
  is sanitized; `mcp-session-id` and `mcp-protocol-version` are withheld if they contain a secret;
  `cache-control` becomes `no-store` (`ModelGateway.swift:1065`, `:1084`).
- **Log.** MCP responses never enter the disk log, whatever the credential kind (`ModelGateway.swift:735`). Ordinary
  responses are recorded only by `finish`; a transport-truncated stream is aborted, and a body
  larger than the whole quota is dropped whole, never truncated (`ResponseLog.swift:130`, `:349`,
  `:467`). Eviction is LRU under `quotaBytes` (`ResponseLog.swift:177`, `:542`). The receipt carries
  only `key`, `status`, `bodyBytes`, `disposition` (`GatewayResponseReceipt.swift:24`).
- Vectors: `gw-resp-001` (non-2xx withheld, header redacted, not logged), `gw-resp-002` (JSON-RPC
  redaction keeps `id`), `gw-resp-003` (over-quota body dropped, caller still served), `gw-resp-004`
  (scalar bearer MCP call redacted and not logged), `gw-resp-005` (sorted-key bytes pinned by
  SHA-256).

## 7. Failure surface — `failure-surface`

- **Fail loud and structured.** A denial carries a stable lower-snake cause in body and
  `X-PDSH-Proxy-Error`, mapped `host_not_allowed` → 403/`forbidden`, `invalid_request` →
  400/`bad_request`, `credential_unavailable` → 502/`credential_unavailable`
  (`ModelGateway.swift:256`, `:276`, `:289`).
- **Nothing secret in the diagnostic.** Messages carry a host or short reason; credential, request
  headers and body never appear, and the provider error text is not forwarded
  (`ModelGateway.swift:229`, `:651`, `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1242`).
- **No contact.** Input: a pre-flight denial → expect: no socket opened; a redirect denial sends
  only the hops before the refused one (`ModelGateway.swift:580`, `GatewaySession.swift:366`).
- **Bounded reason.** A transport reason is capped at 256 characters and made newline-free before
  it reaches a response body or the run log (`ModelGateway.swift:1307`).
- **Log hygiene.** The response log never contains the host credential, the Worker `Authorization`
  or upstream cookies; volatile auth headers do not even participate in the content key
  (`Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1205`, `ResponseLog.swift:542`).
- Vectors: `gw-fail-001` (denied host), `gw-fail-002` (no credential).

## 8. Swift assertion → vector

| Swift assertion | Vector |
|---|---|
| `Tests/PhoneDSHGatewayTests/ModelGatewayCredentialRoutingTests.swift:92` | `gw-cred-001` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:126` | `gw-cred-002` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:130` | `gw-cred-002` |
| `Tests/PhoneDSHGatewayTests/MCPEgressPolicyTests.swift:106` | `gw-cred-003` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:128` | `gw-hop-001` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:153` | `gw-hop-002` |
| `Tests/PhoneDSHGatewayTests/GatewayHostRuleWildcardTests.swift:24` | `gw-egress-004` |
| `Tests/PhoneDSHGatewayTests/GatewayHostRuleWildcardTests.swift:25` | `gw-redir-005` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1269` | `gw-redir-001` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1289` | `gw-redir-003` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1314` | `gw-redir-004` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1364` | `gw-redir-002` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:1107` | `gw-redir-006` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayEgressClassificationTests.swift:161` | `gw-egress-001` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayEgressClassificationTests.swift:140` | `gw-egress-002`, `gw-egress-003`, `gw-fail-001` |
| `Tests/PhoneDSHGatewayTests/GatewayHostRuleWildcardTests.swift:28` | `gw-egress-005` |
| `Tests/PhoneDSHGatewayTests/MCPEgressPolicyTests.swift:201` | `gw-resp-001` |
| `Tests/PhoneDSHGatewayTests/MCPEgressPolicyTests.swift:254` | `gw-resp-002` |
| `Tests/PhoneDSHGatewayTests/ResponseLogTests.swift:294` | `gw-resp-003` |
| `Tests/PhoneDSHGatewayTests/MCPEgressPolicyTests.swift:242` | `gw-resp-004` |
| `Tests/PhoneDSHGatewayTests/MCPEgressPolicyTests.swift:333` | `gw-resp-005` |
| `Tests/PhoneDSHGatewayTests/ModelGatewayTests.swift:261` | `gw-fail-002` |

## 9. Known weak spots and fixed items (do not silently "fix" in Kotlin)

- **Fixed 2026-10-31.** Scalar MCP credentials now take the sensitive path, and redacted JSON is re-encoded with sorted keys so its bytes are reproducible (§6, `gw-resp-004`, `gw-resp-005`).
- **No IP-class classification.** Private and loopback literals are ordinary hosts and `*` admits them all; only default-deny is pinned, so an IP block is an open decision.
- **Stripping is a denylist.** Caller headers outside it pass through; a custom auth header can ride an anonymous cross-origin redirect.
- **Same-scope redirect is stricter than origin.** A different path or port is refused even when allow-listed; that is intended.
- **`Idempotency-Key` is only forwarded.** The gateway does not derive or dedup it; exec.md D10 owns that.

## 10. Oracle rules pinned after the Kotlin port (2026-10-31)

- **Redirects keep method and body.** Every hop re-issues the original method and body; a
  301/302/303 is never rewritten to `GET` and a body is never dropped (`gw-redir-002`,
  `gw-redir-006`).
- **A refused redirect keeps its original surface.** The caller receives the original 3xx with no
  `failure` envelope; `deny_reason` (`redirect_target_not_allowed`, `redirect_scope_mismatch`) is
  internal/run-log only, and the surface is pinned by `expect.status` (the refused hop's own 3xx),
  not by a missing envelope (`gw-redir-001`, `gw-redir-003`, `gw-redir-004`, `gw-redir-005`,
  `gw-redir-007`, `gw-redir-008`).
- **Canonical JSON numbers.** `body_sha256` canonicalises sorted keys with no insignificant
  whitespace and assumes integer-only bodies, as `channel.md` §5 requires; there is no float path
  to implement (`gw-resp-005`).
- **Duplicate member names in an upstream body.** The canonical form never contains them, but an
  upstream may send them. The rule is last-wins on parse — the same answer Python's `json.loads`
  and Foundation's `JSONSerialization` give — and the re-encoded body then has one member. This is
  stated because it is not vector-covered: `expect.body_json` cannot express a duplicate, so the
  oracle cannot distinguish last-wins from a rejection. An implementation that rejects them is not
  wrong, but it must not be *assumed* to.
- **`stripped` is ASCII-sorted.** Caller header names removed by name are emitted in ascending byte
  order, not set or hash order (`gw-hop-001`, `gw-hop-002`).
- **The positive response log is pinned.** `gw-log-001` requires `log.recorded: true` with
  `reason: recorded_ok`; a gateway that never records a response fails the oracle instead of
  passing every `recorded: false` vector by omission.
- **Empty bodies are not failures.** A `HEAD` response and any 1xx/204/205/304 response carry no
  body (`body_bytes: 0`, `body_withheld: false`) and still record; `gw-resp-006` pins the class.

