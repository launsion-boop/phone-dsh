# LAN MCP device discovery and skill connection

```yaml
change: PC-20261106-device-lan
contracts: [P05, P07, P09, P12, P18]
status: frozen
breaking: false
version_decision: DNS-SD profile pdsh-mcp-1; reuse existing MCP version negotiation and P07 host contract 1.
base: c4ac7b5a0849d694449c91d6efbf878655b525dc
contract_revision: spec/device/v1/lan-mcp.md@0c207dc742f337b9a7e301bb34acca0af1a0b03a
```

## Trigger and ownership

LAN MCP is presently added by manually entering an endpoint and credential. A device needs a discoverable, authenticated way to offer a tool catalog to the same phoneDSH agent. The coordinator is contract owner, implementer and integrator. Protocol impact: P07; P09; P05: none — existing MCP Streamable HTTP and gateway are reused unchanged; P12: none — Swift package wiring only, no native ABI change; P18: none — existing MCP registry and Keychain grant format are unchanged.

`spec/device/v1/lan-mcp.md` owns the DNS-SD advertisement and connection profile. `schema/lan-discovery.schema.json` describes the decoded candidate, with semantic rules in the normative text, and `golden/lan-discovery.jsonl` contains valid and invalid cases. Existing MCP and P07 host contracts retain ownership of their formats. Producers/consumers: reference LAN device advertisement and authenticated MCP server ↔ Swift phone discovery and existing Worker MCP client. Kotlin/Rust/Harmony do not implement this discovery profile in this change; no existing endpoint is changed and manually configured MCP remains available on all existing platforms. No MCP wire version is invented.

## Delta

A DNS-SD `_pdsh-mcp._tcp` service with a mandatory profile marker discovers an HTTPS `/mcp` endpoint. Raw TXT framing is bounded and duplicate markers are invalid; unknown TXT entries are ignored. Selection alone grants nothing. The user confirms the exact URL and supplies a per-device bearer credential; TLS hostname and certificate must validate normally. The existing host-managed header mechanism stores the secret. The device denies unauthenticated initialize, tool listing and calls. `tools/list` supplies names, descriptions and schemas; tool dispatch and cancellation use existing MCP semantics. The device owns replay recovery for side effects. An absent response is an unknown outcome, not `failed` or `applied` on P07, and calls are not blindly replayed. mDNS neither proves identity nor guarantees delivery or cross-VLAN discovery. Payload and JSON-RPC limits follow the existing MCP client and gateway; the discovered service cannot expand them. The new discovery marker and candidate are not persisted; existing MCP settings, tokens and grants remain authoritative.

## Compatibility

| Pair | Behavior |
| --- | --- |
| Old device → new phone | Existing manually configured MCP endpoints remain usable; endpoints without the new service and marker are not auto-discovered. |
| New device → old phone | The old phone ignores the advertisement and may connect through its existing manual MCP settings if the endpoint, TLS trust and credentials are configured. |
| New → new | Explicit discovery, selection, TLS/credential confirmation, normal MCP initialization and tool listing. Unknown profile markers are rejected. |
| Old persisted data → new / rollback | Existing MCP settings and Keychain grants retain their format. Discovery candidates are transient. Rollback leaves new MCP rows readable by the existing manager; any in-flight effect must be reconciled at the device. |

The profile is `target` until Swift discovery, reference device, shared valid/invalid vectors, the real MCP client/server, authentication failures and disconnect cases pass. Existing BLE Link remains a separate wire adapter and does not claim LAN MCP support.

## Paths and acceptance

- Coordinator/contract owner: `spec/device/v1/lan-mcp.md`, `spec/device/v1/schema/lan-discovery.schema.json`, `spec/device/v1/golden/lan-discovery.jsonl`, registry and this change record.
- Swift host implementer: `Sources/PhoneDSHLAN/**`, `Tests/PhoneDSHLANTests/**`, package and minimal MCP settings discovery UI.
- Reference device implementer: `examples/lan-mcp-device/**` with authenticated TLS MCP endpoint and DNS-SD announcement; the reference and Swift parser consume the same valid/invalid discovery vectors.
- Acceptance: `swift test --filter PhoneDSHLANTests`; reference fixture test for every shared vector; real MCP initialize/list/call over TLS including missing/incorrect token; cancellation and transport-loss behavior; `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`; iOS app build; physical phone and device discovery/connect/call where available.
- All acceptance commands → NOT_RUN at contract freeze. Physical device, pairing and network isolation → NOT_VERIFIED. Do not claim deployment or exactly-once execution from unit tests.

## Revisions

| Revision | Owner | Reason | Affected ends |
| --- | --- | --- | --- |
| `spec/device/v1/lan-mcp.md@0c207dc742f337b9a7e301bb34acca0af1a0b03a` | Coordinator | Freeze discoverable TLS MCP profile and existing-host mapping before implementation. | Swift phone, reference device, Worker MCP client |
