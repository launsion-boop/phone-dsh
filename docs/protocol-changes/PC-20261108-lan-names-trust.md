# LAN hostname canonical form, name consistency and TLS trust decision

```yaml
change: PC-20261108-lan-names-trust
contracts: [P07, P13]
status: implemented
breaking: true
version_decision: Retain DNS-SD profile marker pdsh-mcp-1 (revision lan-names-v2). Discovery deliberately refuses SRV targets containing any label that begins with xn-- (A-labels), as the 2026-11-07 numeric-final-label correction refused ambiguous numeric targets; internationalized device names use an LDH name or manual MCP configuration. Name consistency adds producer obligations only (no wire field). The per-device pin trust model is frozen as target; existing grants keep OS trust.
base: 0e9ad261
contract_revision: spec/device/v1/lan-mcp.md@sha256:b2928a066781364341fea86c52f703c03a32ce890bfdb3c28abba75abd724131
```

Supersedes the open question in [PC-20261107-lan-idna-ccr](PC-20261107-lan-idna-ccr.md) (GAP-18) and the producer gap recorded in revision 2 of [PC-20261107-lan-hostname-security](PC-20261107-lan-hostname-security.md) (GAP-17). Protocol impact: P07; P13 — the Worker MCP input path is a consumer of the shared discovery URLs; P05: none — the gateway and egress policy are unchanged until the pin target is implemented; P18: none — no grant format change in this revision (the pin target names a future P18 change); P12: none — no native ABI or dependency is added.

## 1. Trigger, roles and ends

- **GAP-18** (trigger → current → expected): Swift, Python and Android accepted any LDH-shaped `xn--` label; Node 22, Node 24, WebKit and Python IDNA2008 disagree on which such labels are valid, so a phone could list a candidate the Worker cannot save, or save it with a different host. Expected: one deterministic rule every end evaluates identically without Unicode data.
- **GAP-17**: the reference device's `dns-sd -R` lets the OS choose the SRV target and nothing checked it against `--hostname`, the certificate or SNI. Expected: one value `H` at SRV target, URL host, `Host`, SNI and certificate name, with the producer verifying what it actually published.
- **TLS trust**: production trust for LAN devices was never decided; device tests pinned an ephemeral certificate only inside test `URLSession` delegates. Expected: a normative decision with lifecycle and failure behavior, and honest status.
- Coordinator / contract owner / implementer / integrator: this task (single agent). Owning contract: `spec/device/v1/lan-mcp.md` §Hostname canonical form, §Name consistency, §TLS trust model.
- Ends: Swift phone decoder `Sources/PhoneDSHLAN`; Python reference decoder and publisher `examples/lan-mcp-device`; Android decoder `android/domain/.../connector/lan` (target-only, no DNS-SD provider); Worker MCP input path `plugins/phone-mcp/src/schema.ts` `validateServerInput` (unchanged code, consumer test only).

## 2. Contract delta

| Item | Before → After |
| --- | --- |
| SRV target labels | LDH-shaped `xn--` labels accepted → any label beginning `xn--` (ASCII case-insensitive) rejected as `invalid_advertisement`, whether or not its Punycode is valid. Non-ASCII input remains rejected before case mapping. Other `??--` LDH labels stay valid. |
| Canonical form | Prose rules spread across sections → one ordered algorithm `canon` (ASCII check, one root dot, ASCII lowercase, LDH, no `xn--`, numeric final label). Steps other than 4 are unchanged in meaning. |
| Name consistency | Implicit → normative table: SRV target, URL host, `Host`, SNI and certificate dNSName are all `H`. Producers must reject wrong SNI, carry `H` as a non-wildcard dNSName, and verify the actually published record within a bounded time, withdrawing on failure. |
| Diagnostics | none → reference-only names `hostname_invalid`, `certificate_name_missing`, `srv_target_invalid`, `srv_target_mismatch`, `srv_port_mismatch`, `publication_unverified`. Not a wire field. |
| TLS trust | "OS trust store; private CA via provisioning" → decision: per-device SPKI pin enrolled out of band with the bearer credential (`target`). OS trust remains the implemented behavior and the behavior for unpinned grants. Local-CA advice removed from the profile. |
| Fixtures | + `golden/lan-discovery-alabel.jsonl` (raw-vector shape, 21 invalid / 8 valid); + `golden/lan-publication.jsonl` with `schema/lan-publication-vector.schema.json` (23 rows). Existing vector files unchanged. |

Self-check (§5.1): no second expression of an existing field; no new wire field, TXT key, capability or version marker; the profile marker is unchanged because the advertised wire shape is unchanged and the refusal tightens validation consumers already must perform; no name or code reused.

## 3. Compatibility

| Pair | Decision |
| --- | --- |
| Old producer → new consumer | LDH targets without `xn--` are accepted exactly as before. A device advertising an `xn--` target is no longer listed; it must advertise an LDH name or be added manually. A producer whose OS-chosen SRV target differs from its certificate name already failed TLS on every phone; it is now caught by the producer instead. |
| New producer → old consumer | A conforming producer advertises only names old consumers accept; SNI enforcement affects only clients that send a different or no server name, which no conforming phone does. |
| New → new | All four ends produce identical accept/reject results and identical URLs for all shared vectors; the Worker keeps every accepted URL byte-identical. |
| Persisted data / rollback | Candidates are transient and saved MCP grants are not migrated or deleted, including any manually saved `xn--` URL. Rolling back a decoder re-admits `xn--` targets with runtime-dependent Worker results; rolling back the reference publisher loses the published-value check. Neither rollback weakens TLS. |

The pin trust model's compatibility (old grants keep OS trust, old phones ignore pins, rollback fails closed) is normative in `lan-mcp.md` §TLS trust model item 7 and takes effect only when implemented.

## 4. Ownership and acceptance

- Contract owner: `spec/device/v1/lan-mcp.md`, the two new golden files and schema, `spec/README.md`, `spec/registry.json`, this record.
- Swift: `Sources/PhoneDSHLAN/LANAdvertisement.swift`, `Tests/PhoneDSHLANTests/**` — `swift test --filter PhoneDSHLANTests`.
- Python reference: `examples/lan-mcp-device/**` — `python3 examples/lan-mcp-device/test_discovery.py`, `python3 examples/lan-mcp-device/test_server.py`, `python3 examples/lan-mcp-device/test_publication.py` (the last publishes through the real macOS mDNSResponder).
- Android: `android/domain/src/{main,test}/kotlin/com/phonedsh/domain/connector/lan/**` — `cd android && ./gradlew --no-daemon :domain:testDebugUnitTest`.
- Worker path: `plugins/tests/lan-discovery-mcp-input.test.ts` — `cd plugins && node scripts/run-tests.mjs tests/lan-discovery-mcp-input.test.ts`.
- Contract: `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.

## 5. Revisions

| Revision | Owner | Reason | Ends notified |
| --- | --- | --- | --- |
| `lan-names-v2` (this freeze) | Coordinator | Resolve GAP-18 CCR by excluding A-labels; specify GAP-17 consistency and producer verification; decide TLS trust (target). | Swift, Python reference, Android decoder (and the parallel Android raw-mDNS branch: rebase onto the new vector files), Worker test |
| `lan-mcp.md@sha256:b2928a066781364341fea86c52f703c03a32ce890bfdb3c28abba75abd724131` (`lan-names-v2`, editorial) | Coordinator | Name the exact files the Worker MCP input path consumes; no rule changed. Freeze hash was `b1a46dbb…` in `fc08d697`. | Worker test |

## 6. Implementation evidence (2026-11-08, macOS 27.0.1 host and galic Linux)

Base / head: `0e9ad261` / the commit carrying this section (implementation `87718907`, `97da4fc6`).

| End | Change | Command → result |
| --- | --- | --- |
| Swift | `LANDeviceCandidate.hostname` rejects `xn--` labels; tests consume the A-label and publication files | `swift test --scratch-path /Volumes/dream/ws-scratch-lan/spm --filter PhoneDSHLANTests` → PASS, 7 tests (includes the existing real Bonjour publish/discover test) |
| Python reference decoder | `canonical_hostname`, `publication_check` | `python3 examples/lan-mcp-device/test_discovery.py` → PASS, 5 tests |
| Python reference publisher | `publication.py`; `server.py` identity/SNI checks, verified `dns-sd -R`/`-P`, periodic recheck, SIGTERM withdrawal, IP endpoints manual-only | `python3 examples/lan-mcp-device/test_publication.py` → PASS, 10 tests, including real mDNSResponder publication with `-P` (target, port and TXT re-resolved; wrong port → `srv_port_mismatch`), `-R` with the Mac's system hostname (consistent) and with a different configured name (`srv_target_mismatch`, withdrawn), an unpublished instance (`publication_unverified` within 2 s), the server refusing to keep a mismatching advertisement (exit 2, no listener, instance no longer resolves), and the full chain published SRV → `canon` → URL → mDNS address → TLS SNI and certificate check → authenticated MCP `initialize`, followed by withdrawal on SIGTERM. `python3 examples/lan-mcp-device/test_server.py` → PASS, 9 tests on three consecutive runs (SNI mismatch/absent rejected, startup refused for `certificate_name_missing` / `hostname_invalid`, IP endpoint manual-only); two earlier runs while the host was saturated by parallel builds reported 2 ERRORs in Node-subprocess tests whose tracebacks were not captured. `python3 examples/lan-mcp-device/test_tasks.py` → PASS, 7 tests |
| Android | `LanDiscoveryDecoder.hostname` rejects `xn--` labels; tests consume both new files | galic: `cd android && bash tools/with-android-toolchain.sh ./gradlew --no-daemon :domain:testDebugUnitTest` → PASS (BUILD SUCCESSFUL; 154 tests, 0 failures; `LanDiscoveryDecoderTest` 6 tests) |
| Worker MCP input path | no code change; test consumes every accepted URL of the three discovery files and the `consistent` publication rows | `cd plugins && node scripts/run-tests.mjs tests/lan-discovery-mcp-input.test.ts` → PASS, 4 tests, Node 22.23.1 |
| Contract | spec, vectors, schema, registry | `bash scripts/ci/check.sh --only phone-spec,phone-cross-tree` → PASS. `--only phone-p0-conformance` → FAIL solely from `page_structure_check.py` ("24 new divergence(s) outside the baseline", UI page contracts); the same checker reports the identical failure on base `0e9ad261`, and this change touches no `spec/ui` or app page source. Its other sub-checks passed. |

Mutation check: disabling the Python `xn--` rule makes `test_discovery.py` fail 12 subtests and the publication vectors fail 4; restored afterwards.

Supplementary (not product evidence): a standalone macOS 27.0.1 `WKWebView` evaluated `new URL()` for all 21 accepted URLs; all 21 kept their exact `href`. This is macOS WebKit, not the product iOS WKWebView Worker.

Not verified: the product iOS WKWebView Worker with these vectors (keeps GAP-18 open); iPhone or physical device discovery/connection; Android DNS-SD transport (target-only decoder); non-macOS publishers (the reference publisher uses macOS `dns-sd`); behavior when the Mac's Bonjour hostname is renamed while advertising (covered only by the injected-verify monitor unit test). The TLS pin trust model is `target` on every end.

Remaining risks: GAP-18 product Worker run; pin trust model implementation (owner P07 with P05/P18 per `lan-mcp.md` §TLS trust model implementer acceptance).
