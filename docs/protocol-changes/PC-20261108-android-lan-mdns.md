# Android LAN MCP discovery provider

```yaml
change: PC-20261108-android-lan-mdns
contracts: [P07]
status: implemented
breaking: false
version_decision: No wire change. The fixed service type `_pdsh-mcp._tcp` and the `profile=pdsh-mcp-1` marker are consumed exactly as specified; Android gains a consumer that supplies the raw TXT bytes and SRV hostname the profile requires.
base: 0e9ad261
contract_revision: spec/device/v1/lan-mcp.md (normative clauses unchanged since PC-20261107-lan-hostname-security revision 2; only the Android status sentence is updated by this record)
```

## 1. Trigger, roles and scope

- Trigger → current → expected: `lan-mcp.md` kept Android `partial` "until its actual DNS-SD provider supplies the raw TXT bytes and SRV hostname without lossy conversion". Android had only the decoder (`LanDiscoveryDecoder`) and a disabled 扫描局域网设备 control. Expected: a real, user-started discovery path on Android that hands the decoder the exact TXT RDATA and the SRV target labels, with the page listing unverified candidates.
- Roles: this task is the Android implementer. It does not change any normative clause of `lan-mcp.md`, the shared vectors, schemas or the registry. The contract owner keeps `spec/**`; the only `spec/` edit is the Android status sentence the task assigned.
- Owning contract and fixtures: `spec/device/v1/lan-mcp.md`, `golden/lan-discovery.jsonl`, `golden/lan-discovery-raw.jsonl` (unchanged).
- Ends: Swift phone (`Sources/PhoneDSHLAN`, unchanged), Python reference device (`examples/lan-mcp-device`, unchanged), Android consumer (this change).

## 2. Why not NsdManager

`NsdManager` resolves a service to an `InetAddress` and exposes TXT through `NsdServiceInfo.getAttributes()`, a `Map<String, byte[]>`. Both conversions are lossy for this profile: a repeated `profile` key (in any case) collapses before the decoder can refuse it, and the SRV target hostname that the HTTPS URL and TLS validation use is replaced by an address. Android therefore uses its own minimal, read-only mDNS querier.

## 3. Implementation (no contract delta)

| Item | Implementation |
| --- | --- |
| Query | IPv4 mDNS (224.0.0.251:5353) PTR browse for `_pdsh-mcp._tcp.local.` at 0/1/3/7 s (RFC 6762 §5.2), SRV+TXT follow-up for browsed instances still missing either (≤ 64 per scan, ≤ 1 per instance per second). QM questions; shares UDP 5353 with `SO_REUSEADDR` and joins the group on the Wi-Fi interface, otherwise falls back to an ephemeral port and legacy-unicast answers (RFC 6762 §6.7, ID must match). |
| Interface and permissions | Only the network with `TRANSPORT_WIFI`; socket bound to that `Network` and its interface. `CHANGE_WIFI_MULTICAST_STATE` (normal) for a `MulticastLock` held only during the scan; `ACCESS_NETWORK_STATE` (normal, already merged from `:platform-android`). No location permission. |
| Datagram admission | Source UDP port 5353 and an IPv4 source on one of the Wi-Fi interface's subnets (RFC 6762 §11); > 9000 bytes refused before parsing; ≤ 4096 datagrams read per scan. |
| DNS parsing (`:domain` `DnsMessageParser`) | Whole-datagram refusal on any violation: 12–9000 bytes; QR=1, opcode 0, rcode 0 (TC ignored per RFC 6762 §18.5); ≤ 16 questions, ≤ 128 records; labels 1–63 bytes, ≤ 255 wire bytes per expanded name, label types 0x40/0x80 refused; each compression pointer must point strictly backwards and past the header, ≤ 16 pointers per name (no loops, no forward references); PTR/SRV RDATA must be exactly the name (+6 bytes for SRV); TXT RDATA ≤ 1300 bytes (RFC 6763 §6.2) and kept byte-for-byte; no trailing bytes. |
| Folding (`:domain` `LanMdnsBrowser`) | Class IN only; owners must be exactly `<label>._pdsh-mcp._tcp.local.` (ASCII case-insensitive); instances are created only by a PTR (≤ 100 per scan) so unsolicited SRV/TXT cannot fill the budget; PTRs apply before SRV/TXT of the same datagram; two different SRV or two different TXT for one instance in one datagram drop that value (fail closed); TTL capped at 4500 s, TTL 0 is a goodbye. |
| Decoder input | Instance label decoded as strict UTF-8 (display only); SRV target passed as DNS labels joined with `.` only when no label contains a `.` byte, bytes mapped 1:1 so non-ASCII reaches the existing hostname validator unchanged; TXT RDATA unchanged. The resolved address is never used. |
| UI (`MCPSettingsPage`, existing `mcp-settings.json` contract) | 扫描局域网设备／停止扫描, a page-owned status line, candidate rows (service name, HTTPS URL, 未验证) and the iOS note 发现结果尚未验证。请核对设备地址并输入设备提供的授权凭证。. A scan stops after 15 s, on 停止扫描 or when the page is left; results clear 120 s after the start (iOS `LANDeviceDiscovery` values). |
| Selection | Opens the existing MCP editor pre-filled like iOS `MCPEditorPage(candidate:)`: `device_<12 hex>` name, the candidate URL, 60000 ms timeout, an empty `Authorization` header row. The Android editor still cannot persist (no `phone/mcpUpsert` host tool, `writable = NO`); no registry write, grant or credential storage was added. |

Self-check (spec/README.md §5.1): no second representation, no new wire field, no new error code, no schema or vector change, no relaxed validation. `LanDeviceCandidate` became `public` inside `:domain` so `:app` can read it; the decoder itself is unchanged.

## 4. Compatibility

| Pair | Decision |
| --- | --- |
| reference device → Android | Accepted when the advertisement satisfies `lan-mcp.md`; otherwise no candidate. |
| Android → device | Android only sends standard mDNS queries; nothing connects to a device. |
| Android ↔ Swift | Both consume the same shared vectors through their real decoders; Android additionally carries every wire-representable vector through DNS bytes, parser and browser. |
| persisted data / rollback | Candidates are transient; nothing is persisted. Rolling back restores the disabled control. |

## 5. Evidence and remaining work

Runtime/test evidence (2026-11-08, galic Linux x86_64, JDK 17, Gradle 8.13):

- `./gradlew --no-daemon :domain:testDebugUnitTest :lib:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug` → PASS (domain 172, lib 1013, app 301 tests; 0 failures, 0 skipped). `DnsMessageParserTest` (10) covers compression loops, forward/header pointers, the pointer-hop bound, every truncation prefix, RDATA under/overrun, TXT/message/count limits, label types, name length, trailing bytes and 20 000 seeded mutations; `LanMdnsBrowserTest` (10) carries every wire-representable shared vector (35 of 40; the 5 others — empty or > 63-byte labels, port 65536 — cannot be encoded in DNS and are asserted to be expected errors) through DNS bytes, parser, browser and decoder, plus duplicate/ambiguous records, goodbye/TTL expiry, unsolicited records, hostile names and the instance budget.
- `aapt dump permissions` on the debug APK lists `CHANGE_WIFI_MULTICAST_STATE` and `ACCESS_NETWORK_STATE`; no new location permission.
- Live LAN run (not committed): the reference device `examples/lan-mcp-device/server.py --publish-name "PDSH Lamp 界"` on a Mac (macOS `dns-sd -R`, mDNSResponder) and a JVM harness on galic (same /24, `enp6s0`) that mirrors `AndroidLanDiscovery`'s socket steps with `java.net` and calls the committed `DnsMessageParser`/`LanMdnsBrowser`. Result: 10 datagrams, 0 off-link, 5 responses parsed, 5 queries refused as `NOT_RESPONSE`, 4 profile datagrams (compressed names, AAAA/A/NSEC additionals, TXT `1270726f66696c653d706473682d6d63702d31`, SRV target `liguanghaos-Mac-Studio.local.` port 18443) → exactly one candidate `PDSH Lamp 界` `https://liguanghaos-mac-studio.local:18443/mcp`. A goodbye run was attempted but the advertiser could not be stopped mid-run from the harness session; goodbye is covered by unit tests only.

Not verified: discovery on a physical Android phone's Wi-Fi (multicast filtering, `MulticastLock`, sharing UDP 5353 with the system responder, VPN routing), IPv6 (not implemented), and the MCP authorization flow (credential entry persisted, exact-URL grant, TLS hostname validation, `tools/list`) which Android still lacks. Android therefore stays `partial` in `lan-mcp.md`.

Owner follow-up (not done here because it is outside the implementer's paths): the P07 row of `spec/README.md` §3 still says "Android Link 与 LAN decoder 仍 `target`" and the §4 P07 trigger list does not name `android/app/src/main/kotlin/com/phonedsh/probe/AndroidLanDiscovery.kt`; the contract owner should register that file as a P07 consumer. Likewise `spec/platform/android-module-map.json` still records `PhoneDSHLAN` as `target`; `android/README.md` keeps that status cell (the `readme-map` gate compares it) and only updates the description.

## 6. Revision record

| revision | by | reason | ends notified |
| --- | --- | --- | --- |
| 1 | Android implementer (ws/android-lan-mdns) | Android DNS-SD provider; status sentence only | Swift, Python reference (no action required), contract owner (registry follow-up) |
