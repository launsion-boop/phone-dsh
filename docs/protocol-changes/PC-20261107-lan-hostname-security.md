# LAN discovery hostname ambiguity correction

```yaml
change: PC-20261107-lan-hostname-security
contracts: [P07]
status: frozen
breaking: true
version_decision: Retain pdsh-mcp-1 wire marker and reject ambiguous numeric-final-label targets that cannot reliably remain DNS names across existing URL/resolver stacks. This is a deliberate security refusal of previously accepted text, including DNS names with numeric final labels; devices must use a name with a nonnumeric final label, and manually configured MCP remains outside this profile. Rollback restores the unsafe parser and is not a security-preserving rollback.
base: 07d9098c
contract_revision: spec/device/v1/lan-mcp.md@sha256:fa18292665ea30307252699b4643b3eb134d59ba399cb5f73edd2dfaa6f3f929
```

## Trigger and contract delta

The current profile requires a DNS hostname, not a resolved address. Existing Swift and Python decoders accept `192.168.1.2`, `127.1`, decimal single-number and hexadecimal forms as hostnames; ordinary resolvers can interpret them directly as IPv4 literals. This allows an advertisement to be interpreted as an IP instead of the required DNS name. Python additionally lowercases Unicode before its ASCII check, allowing the Kelvin-sign hostname to become ASCII although the profile requires original ASCII input.

The owning `lan-mcp.md` now specifies an identical, deterministic pre-resolution rule: after ASCII validation and normalizing case/removing at most one final root dot, if the final DNS label consists solely of decimal digits or `0x` followed by zero or more hexadecimal digits, reject it independently of numeric value, number of labels or leading zeros. The bare `0x` prefix is included because URL parsers can interpret it as zero. This deliberately refuses some DNS names with numeric final labels previously accepted: all-numeric targets can be interpreted as IPv4, and Node and a local macOS WKWebView URL parser reject names such as `foo.123`. It does not change TXT framing, service name, URL path, credentials, TLS validation, or allow a resolved address to stand in for an SRV target. New shared valid and invalid raw vectors are in `golden/lan-discovery-raw.jsonl`; their shape is in `schema/lan-discovery-raw-vector.schema.json`. Swift, Python reference and Android decoders must all consume the same cases. The existing Worker MCP input validator, executed under Node, must accept the generated URLs for the shared valid cases without changing their host; this does not restrict generic manually configured MCP URLs. The schemas retain existing permissive shape; semantic hostname validation is mandatory.

## Compatibility and deployment

| Pair | Decision |
| --- | --- |
| Old producer → new consumer | An advertisement with an unambiguous DNS target remains accepted. Previously accepted numeric-final-label targets are refused; they must advertise a name with a nonnumeric final label. Manual MCP configuration is unaffected. |
| New producer → old consumer | Valid named target and `pdsh-mcp-1` remain understood. Old consumers remain vulnerable to ambiguous numeric target input and cannot be claimed to enforce this rule. |
| New → new | All registered decoders reject the same numeric and non-ASCII cases, and accept shared named-target vectors. Discovery remains untrusted and never grants access. |
| Old persisted data / rollback | Discovery candidates are transient; existing MCP settings are neither migrated nor deleted. Rolling back a decoder restores acceptance of ambiguous targets; disable discovery or retain the fix when rolling back. |

The marker is retained because the advertised wire shape is unchanged and the correction enforces the existing requirement to use a DNS target rather than an IP address. The marker does not identify a patched receiver; update receivers first and do not infer enforcement or safe rollback from its presence. The `breaking: true` declaration records the observable refusal of legacy accepted input; this is not a claim that all preexisting numerical DNS labels were invalid under the prior ambiguous text. This is a deliberate fail-closed compatibility break; implement all registered ends together and keep it visible to reviewers.

## Ownership and acceptance

- Contract owner: `spec/device/v1/**`, registry and this record. The Android decoder is still target-only and not connected to discovery.
- Swift/Python implementer: `Sources/PhoneDSHLAN/LANAdvertisement.swift`, `Tests/PhoneDSHLANTests/LANAdvertisementTests.swift`, `examples/lan-mcp-device/discovery.py` and `examples/lan-mcp-device/test_discovery.py`; both real decoders consume the shared raw vectors. Existing reference advertisement and existing vectors remain supported.
- Android implementer: `android/domain/src/{main,test}/kotlin/com/phonedsh/domain/connector/lan/**`; decoder consumes existing and raw shared vectors. No Map-based TXT reconstruction or address-as-SRV fallback.
- Acceptance: `swift test --filter LANAdvertisementTests`, `python3 examples/lan-mcp-device/test_discovery.py`, `cd android && ./gradlew :domain:testDebugUnitTest --tests '*LanDiscovery*'`, the existing Worker `validateServerInput` against generated valid URLs; `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`, plus review at one combined head. No physical device, TLS or Android DNS-SD runtime claim follows from these decoder tests.

## Revision 2

This resolves the LAN hostname CCR reported against `36ed605f`. The BLE reassembly clarification remains `07d9098c`. All LAN implementers must use this revision; any new ambiguity requires a further CCR before local workarounds.

The reference server currently delegates its actual SRV target to the operating system `dns-sd -R` publisher and does not verify it matches the configured TLS hostname. This change tests the reference candidate decoder but does not establish that the real publisher emits a compliant or matching target. That producer gap remains open and must be resolved and verified before claiming end-to-end LAN profile completion.

## Implementation evidence (2026-11-07)

The Swift, Python and target-only Android candidate decoders reject the shared numeric-final-label and non-ASCII cases and consume the raw valid/invalid vectors. `swift test --filter LANAdvertisementTests` → PASS (5 tests); `python3 examples/lan-mcp-device/test_discovery.py` → PASS (4 tests); Android `:domain:testDebugUnitTest` filtered to `*LanDiscovery*` → PASS (4 tests); Node 22 `--experimental-strip-types --test plugins/tests/lan-discovery-mcp-input.test.ts` → PASS (2 tests against the real Worker input validator under Node). The producer's actual DNS-SD publication remains GAP-17, and invalid IDNA A-label interoperability remains GAP-18; these tests do not establish full producer or Android discovery conformance.

## Follow-up (2026-11-08)

The producer gap of Revision 2 (GAP-17) is resolved by [PC-20261108-lan-names-trust](PC-20261108-lan-names-trust.md): the reference publisher now verifies the actually published SRV target, port and TXT against its configured hostname and certificate, and withdraws on mismatch.
