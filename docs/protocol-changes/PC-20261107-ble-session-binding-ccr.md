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
