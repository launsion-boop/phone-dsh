# Contract change request: bind BLE task traffic to authenticated identity

```yaml
change: PC-20261107-ble-session-binding-ccr
contracts: [P07]
status: draft
breaking: true
version_decision: pending — no new session format is approved by this request
base: 1a1313ac9562ab2ca5cfa1e7580bacfe2a7a140d
contract_revision: pending
```

## Trigger and evidence

The un-frozen identity proposal authenticates a challenge signature made by a P-256 private key, but does not authenticate or encrypt the following Link task requests, responses, or receipts as part of the same cryptographic session. The iOS adapter cannot independently establish that the BLE link is bonded and encrypted (GAP-16). A live intermediary can forward a valid challenge and proof and then tamper with later task traffic; merely pinning the signing key or verifying another proof does not protect those bytes. First-use relay and later live relay also remain possible. This is not evidence that the existing ordinary Link profile provides a secure task channel.

The current task profile is `target`, and BLE task grants must remain refused. The main probe's task entry points remain disabled. This request is not a frozen contract, implementation permission, or GAP closure.

## Required contract decision

The contract owner must specify and review authenticated session establishment and integrity protection for every task command, result and receipt, including the relationship to the proven device key and the current connection. The decision must define encoding, bounds, transcript and key separation, replay and reordering protection, reconnection, timeouts, lost replies, idempotency, authentication failures, key storage and lifecycle, version and capability negotiation, and old/new interoperability. It must include shared valid and invalid fixtures and a compatibility matrix for old phone/new firmware, new phone/old firmware, new/new, and persisted data/rollback; both Swift and firmware must implement the same frozen revision. Cryptographic choices require independent security review and must not be inferred from successful simulated or radio tests.

The separate identity binding decision must also resolve key replacement and forgetting: the current UserDefaults list contains only public-key fingerprints and cannot prove which Link UUID belongs to a key. Such old entries cannot safely become bound identities automatically. UUID-based task records and intents cannot be converted to fingerprint identities or blindly replayed. A changed untrusted device label can evade a per-label legacy-record check; orphan, corrupt or unreadable intents require an explicit fail-closed recovery decision. A reference device also needs a credible independent fingerprint comparison channel before a user confirmation can detect a first-use substitution.

Proof and trust UI results must be bound to the current connection generation. Disconnect, revocation, asynchronous completion, storage errors, concurrent forget, and reconnect need defined ordering; no stale completion may restore a task grant. Proof failure must not deliberately disconnect an otherwise healthy ordinary Link, while genuine transport failure still follows the Link recovery rules.

## Acceptance before enabling BLE task grants

- Contract, schemas and shared positive/negative vectors are frozen before implementation; all registered ends run them through real encoders, decoders and state machines. Explicitly test modified, replayed, reordered and cross-session task/receipt data, wrong and changed keys, storage failures and cancellation races.
- Verify first use with an independent comparison, reconnect, changed-key refusal, restart persistence and an actual ESP32 task/receipt round trip on physical devices. Verify negative active-peer cases and record exactly what they prove. A simulator, host stub, local TLS fixture or passed static checker is not this evidence.
- Complete the separate UI, MCP lifecycle, production TLS and repository gate requirements. Do not mark the target profile implemented or close GAP-16 merely because the contract is written.

## Candidate for investigation, not a contract

One candidate is a mutually authenticated TLS 1.3 session over an explicitly negotiated, bounded BLE byte-stream transport. Both endpoints would authenticate a previously confirmed peer key; all task requests, responses, identifiers and receipts would be inside the session, and 0-RTT and unauthenticated fallback would be disabled. See RFC 8446. This is not yet a selected design: the phone-key provisioning and mutual-confirmation model, iOS and ESP-IDF API feasibility, memory and framing bounds, stream fragmentation and flow control, reconnection, failure behavior and physical-device interoperability still need proof. TLS records cannot be assumed to fit one existing Link envelope or RPC. A transport timeout or failed session still does not authorize replay of a possibly applied task; the durable task and query-only recovery rules remain necessary.

A feasibility spike must establish whether the Apple host can attach a TLS implementation to a custom GATT stream and whether the pinned ESP-IDF supports the required server authentication, pinning, and no-clock certificate policy. The reference board's lack of an independent display also leaves phone-key provisioning unresolved. Stream design must bound memory, handshake size, queues and deadlines on real hardware, respect existing Link and ATT frame limits, and distinguish a byte-identical retransmitted fragment from conflicting or out-of-order data without delivering it twice. Downgraded negotiation must never enable old plaintext tasks; the device must reject plaintext task access when the secure profile is required. None of these feasibility claims has been verified by this record.

Local SDK feasibility observation (2026-11-07): the iOS SDK exposes custom I/O callbacks in the deprecated SecureTransport API, but its documented protocol-version API does not establish TLS 1.3 support for that path. Network.framework's application framer is layered above a transport; no public API for making an arbitrary CoreBluetooth stream its TLS transport was established by this check. This does not prove such integration is impossible. Neither option is an approved implementation without a tested design and security review.

Pinned ESP-IDF source observation (2026-11-07): tag v6.1 (`fff9895c82d744c7237be8847347bdd1b07c6643`, Mbed TLS `a2b32072ea898afc1ed5b6caf6931e36028c91d6`) contains TLS 1.3 server, client-certificate authentication and custom I/O paths. TLS 1.3 and certificate date checks are disabled by default in its Kconfig; raw-public-key certificate types are not supported by the cited TLS 1.3 implementation. X.509 key pinning and a no-clock trust policy require design and validation. These are source observations, not a handshake, resource or device test.
