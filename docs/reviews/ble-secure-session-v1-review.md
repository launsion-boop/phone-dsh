# Independent security review: `secure-session-v1`

```text
Reviewed:           spec/device/v1/ble-secure-session.md@secure-session-v1
Change record:      docs/protocol-changes/PC-20261108-ble-secure-session.md
Base / head:        082aff5f / 082aff5f (ws/secure-session; review branch ws/ss-review)
Protocol impact:    none — review document only; no spec, schema, golden or code changed
Reviewer role:      §3.4 reviewer (independent of the contract owner and both implementers)
Method:             static reading of spec, change record, CCR, superseded candidate,
                    schemas, fixtures, spec checker, ble-identity/ble-link/task-delegation/
                    legacy-identity-preferences, current Swift and ESP32 reference code
Commands → result:  python3 -B -m unittest test_ble_secure_session_golden (spec/v1/tools)
                      → PASS (15 tests)
                    independent X.509 re-check of golden/ble-secure-certificates.jsonl
                      with Python cryptography 48.0.0 (scratch script, not committed)
                      → all 19 vectors decide as labelled, first-failing reason matches
Not run:            any TLS handshake, Mbed TLS/ESP-IDF source inspection (pinned source
                    not available locally), Swift/C build, radio, device, Keychain,
                    power-loss or hardware experiment
```

## Verdict

**Approve with required changes.**

The cryptographic core is sound for its stated attacker: mutually pinned TLS
1.3 (one suite, one group, one signature scheme, full handshake only, no PSK,
tickets or 0-RTT, ALPN-versioned, no plaintext fallback) with a readiness
exchange inside the same connection gives confidentiality, integrity, replay
and reorder protection, and a correct key-pair binding against a radio attacker
who holds neither enrolled key. The task idempotency and lost-reply rules are
conservative and correct. Legacy `ble:<UUID>` data cannot become authority.

It must not be implemented as-is, because:

1. the physical authorization step can be satisfied by an ordinary, routine
   button press and the console is always live (H1);
2. the threat model understates what *any* USB host can do to this board, so
   the button is presented as a security boundary it is not (H2);
3. the pre-authentication CoC/TLS surface carries a known NimBLE memory-safety
   hazard that the contract mandates away but never tests (H3);
4. the phone end's post-readiness behaviour (response correlation, request-level
   errors, which device it is talking to) is largely unspecified and
   unfixtured (M1, M2).

None of these require changing the TLS profile, the message set, or the
storage formats; all are clause-level fixes (smallest change listed per
finding).

## Findings

Severity: **critical** = breaks the stated cryptographic claim against the
in-scope attacker; **high** = in-scope attacker gains authority or pre-auth
code-execution/crash surface, or a sign-off assumption is materially
misstated; **medium** = semantics gap that lets two conforming ends disagree,
or a MUST with no test; **low** = clarity / robustness.

No critical findings.

### H1 (high) — Enrollment authority via a routine button press on an always-live console

**Clause:** §3.1, §3.3 (step 5, 7, 9, 10; "Button"); §15.4.

**Scenario.** The enrollment console is served permanently on the primary
console; there is no enrollment mode. The enrollment button is
`PDSH_BUTTON_GPIO`, default GPIO0 (the devkit BOOT button,
`firmware/esp32-reference/README.md:23`), which the operator already presses
for ordinary reasons: it reopens the Just Works pairing window and emits a Link
`button.pressed` event (`main.c:313-331`). Any process that can write the
console line (a serial monitor, a remote serial bridge, a charging host, a
shared lab machine) runs, on a board in state `none` or `revoked`:

```text
pdsh-enroll begin                         → begun eid=E device=D
pdsh-enroll phone eid=E phone=<attacker>  → staged …
pdsh-enroll commit eid=E device=D phone=<attacker> → press … timeout_s=30
```

and waits. The next press within 30 s for *any* reason commits the attacker's
phone key. §3.3 then requires that press to be swallowed ("MUST NOT also open
the pairing window"), so the operator sees nothing happen and presses again.
On a `committed` board the same host reads `status` (which prints eid, device
and phone), issues `revoke …` and waits for one press, then repeats the
enrollment for a second press. The attacker phone then passes every TLS pin
and readiness check: it reads queued task bodies via `next`, accepts tasks
(denying them to the legitimate phone) and writes arbitrary `complete` outputs
that the board's local producer reads through `tools_task_result`.

The superseded candidate required "a dedicated, explicit local enrollment
mode … entered by the physical operator" (candidate §2 step 1); the frozen
contract dropped it without a recorded deviation.

**Smallest fix.** (a) Make the authorizing gesture unambiguous and distinct
from every other button meaning — e.g. a continuous hold of ≥ 3 s that starts
after the `press` line, with release required before the next gesture — and
state that a short press never authorizes. (b) Require a visible board
indication (LED pattern, if `PDSH_LED_GPIO` is configured) while `ctx = press`,
and make the absence of an indicator an explicit operator-trust assumption
otherwise. (c) Specify that a press consumed by enrollment emits no Link
`button.pressed` event either. (d) Add enrollment-state fixtures: short press
does not commit; hold that began before the `press` line does not commit; hold
shorter than the threshold does not commit. (Optional, stronger: accept
`begin`/`revoke`/`identity-reset` only within N seconds after a physical
"enter enrollment" gesture.)

### H2 (high) — Any USB host, at any time, holds full board authority; the contract implies otherwise

**Clause:** §1 "Assumed trusted", §1 non-goal 3–4, §3.1, §3.3 "Button", §4.2,
§15.3/§15.4.

**Scenario.** §1 limits host trust to "the USB/serial host … used during
enrollment", and §3.1 says a button press "authorizes every
authority-changing board action". On the reference ESP32-S3 with
USB-Serial-JTAG, no secure boot, no flash encryption and download mode
enabled, any host that is ever attached can reset the chip into ROM download
mode without touching a button, read `pdsh_id/priv`, and write
`pdsh_enr/rec_v1 = committed(<attacker phone>)` or reflash older firmware
directly. The button therefore defends only against a *console-limited*
host (H1), not against a malicious USB host, and a stolen device key gives
permanent device impersonation toward the enrolled phone (no rotation without
a new ceremony that the phone has no reason to start).

**Smallest fix.** Rewrite §1 to say: every USB host the board is ever
attached to is trusted with the device private key, the enrollment record and
the firmware image; the button authorizes console commands only and is not a
defence against a malicious USB host. Add the corresponding UI/README
obligation ("connecting this board to a computer gives that computer full
control of its task pairing"). Keep eFuse/secure boot out of scope as stated,
but list "disable USB download mode / USB-JTAG after provisioning" as the
production-hardening item that would change this assumption.

### H3 (high) — Pre-authentication CoC/TLS memory-safety requirement has no acceptance test

**Clause:** §5 "Credit safety", §8.1, §13, §14.

**Scenario.** The CoC and the TLS ClientHello parser are reachable by any
radio peer before any authentication; §5 lets the board serve the PSM and CoC
without LE encryption ("MAY require"). The CCR records that the pinned NimBLE
grants two initial credits for one receive slot at MTU 512/MPS 504 and
dereferences its receive slot before checking credits — a peer that sends
beyond its credits triggers a NULL/stale-slot dereference on the board. §5
correctly says MUST NOT, but that code lives inside NimBLE; the contract does
not say whether the fix is a library change, a configuration (MTU = MPS so
initial credits = 1) or a wrapper, and neither §13 nor §14 lists an
adversarial-peer test. A conforming firmware can therefore ship with a
remotely triggerable crash (or worse) reachable by an unauthenticated
attacker.

**Smallest fix.** Add to §13 (firmware host tests with a fake L2CAP below the
real receive path) and §14 (physical, using a Mac/Linux test central):
send beyond credits; zero-length SDU; SDU > MTU; K-frame > MPS; interleaved
disconnect during queued send (`BLE_HS_ESTALLED`); ClientHello flood with
reconnect. Record which mechanism satisfies "MUST NOT dereference before
checking credits" (upstream NimBLE commit or a documented build-time
constraint), and make "board survives every case and still serves the
enrolled phone afterwards" a §14 gate. Consider making LE encryption on the
PSM read *and* the CoC a SHOULD for the board once a bonded phone exists, as
attack-surface reduction (never as authentication).

### M1 (medium) — Phone pins "any committed device", not the device the user chose

**Clause:** §8.2 step 2 and 5; §4.4 "Many boards per phone".

**Scenario.** With two enrolled boards A and B, the phone accepts whichever
committed device certificate arrives on the CoC it opened. An attacker who
relays or spoofs the CoreBluetooth peripheral the user selected as "A"
(advertisements and names are untrusted per §5) can connect the phone to B.
Every check passes and the journal correctly records B's `device_id`, but if
the foreground grant was given for the peripheral the user *selected*, B's
tasks execute under a grant the user intended for A. §8.2.5 says the grant is
for "this generation and device ID" but does not say whether that device ID
is chosen before connecting or learned from the certificate, nor when the
grant UI is shown relative to readiness.

**Smallest fix.** In §8.2: the phone selects exactly one committed record
before opening the CoC (the user's choice), and the server pin is that single
record's device (not the set); mismatch → `pin_mismatch`. Alternatively,
require that the grant is issued only after readiness and that the grant UI
names the authenticated device ID/label from the enrollment record, never the
peripheral name. Add a phone-side sequence fixture.

### M2 (medium) — Phone-side post-readiness state machine is unspecified and unfixtured

**Clause:** §7.3, §8.2, §9.2, §9.3, §13 (`side=phone` covers readiness only).

**Gaps.** The contract never states, for the phone:

- that a response's `re` MUST equal the single outstanding `seq`, and what
  happens otherwise (an unsolicited `next_r`/`r`/`status_r`, a duplicated
  response, `re` of an earlier request);
- that the response type MUST match the request (`r` only for
  accept/complete/fail, `status_r` only for status, `next_r` only for next)
  and that `r.phase` MUST be `accepted` after accept, `completed`/`failed`
  matching the sent outcome otherwise; a mismatch is fatal `malformed`;
- what a request-level error (`unknown_task`, `invalid_transition`,
  `conflict`, `wrong_owner`) to a first-time `accept`/`complete`/`fail` does to
  the intent and the parent record (§9.3 only covers answers to `status`);
- what `next_r` with a task that fails task-delegation validation, or a task
  whose `id`/key conflicts with an existing parent, does to the session.

Because the phone records `accepted` from an `r`, a buggy or malicious-but-
enrolled board (in the threat model) that answers with the wrong type or phase
can make the phone start a DSH turn the board never accepted, and two
conforming implementations can diverge.

**Smallest fix.** Add a §8.2 table: request → only acceptable response
type, `re`, `r.result`/`phase`; everything else fatal `malformed` with the
intent kept and treated as "no authoritative answer" (§9.3 retry_query). Add
a §9.3 table for request-level errors to first sends (proposal: all
unresolved, never resend, user-visible). Add `side=phone` session-sequence
fixtures for each row.

### M3 (medium) — Session timers and grant lifetime cannot complete a normal task

**Clause:** §8.1 (board idle 60 s, lifetime 600 s), §8.2.5 (grant ends on
session close), task-delegation.md (five-minute execution bound, terminal
result "retried to the device until acknowledged").

**Scenario.** After `accept`, the phone runs a DSH turn that may take up to
five minutes and has nothing to send (one outstanding request, no keepalive
message). The board closes the idle session at 60 s; that closes the session
generation and so ends the grant. The phone cannot send `complete` until the
user grants again in the foreground. The 600 s hard lifetime likewise ends
every grant every ten minutes. Not a confidentiality issue, but it forces
either UI churn or implementers inventing a keepalive or a grant that survives
session closure (rule 7 of AGENTS.md §2).

**Smallest fix.** Either (a) state that `status` (or `next`) MAY be sent as a
keepalive and that the board's idle timer counts it, or (b) tie the grant to
the CoreBluetooth connection generation and enrollment rev rather than to the
TLS session, so a reconnect within the same connection generation needs a new
handshake and readiness but not a new grant. Record the choice in §8.1/§8.2.

### M4 (medium) — Device key doubles as an unauthenticated signing oracle; entropy at key generation

**Clause:** §2 (device ID = experimental identity key), §11.3
(`pdsh.identity.prove` unchanged), §3.3 identity-reset, §4.2 first-install
generation; §15.3.

**Observations.**

- The TLS server key is the same key that `pdsh.identity.prove` uses to sign
  `SHA-256("phoneDSH BLE identity v1" ‖ 0 ‖ nonce ‖ 0 ‖ pub)` for *any*
  ordinary-Link peer with an attacker-chosen 32-byte nonce
  (`pdsh_identity.c:101-133`). Domain separation from TLS 1.3
  CertificateVerify (which starts with 64 × 0x20) holds by prefix, so I found
  no forgery; but it gives an unauthenticated attacker unlimited ECDSA
  signatures under the session key, which turns any nonce bias into key
  recovery.
- Signing uses randomized `PSA_ALG_ECDSA`. First-boot key generation runs in
  `tools_init()` before `nimble_port_init()` and before Wi-Fi
  (`main.c:352` vs `main.c:377`). Whether the ESP32-S3 RNG is a true RNG at that point in
  ESP-IDF v6.1 (RF off, bootloader entropy already disabled) needs
  confirmation; the contract simply says "PSA RNG".

**Smallest fix.** (a) Retire `pdsh.identity.prove` in firmware that carries
the secure service, or give the session its own key (changing the device ID
definition), or at minimum require deterministic ECDSA (RFC 6979,
`PSA_ALG_DETERMINISTIC_ECDSA`) for both the prove tool and TLS
CertificateVerify on the board. (b) Require device-key, `eid`, `sc` and TLS
randomness to be drawn only when a documented true-entropy source is active,
and say how first-boot generation satisfies it. Both belong to the human
review below.

### M5 (medium) — MUSTs without negative fixtures; oracle weaker than the text

**Clause:** §13 and the listed fixture sections.

| Normative rule | Gap |
| --- | --- |
| §8.3.3 board re-checks the full captured `(state, eid, phone, rev)` | Oracle `DeviceSession.recv` checks only `record["state"]`; no vector replaces the record mid-session with a still-`committed` one (revoke + re-commit with a new eid). |
| §9.3 `phone_id` ≠ current key → unresolved | `ble-secure-recovery-vector.schema.json` has no phone-key dimension; no vector. |
| §9.1 storage failure is fatal `storage` | Only `storage-failure-on-accept`; none for `complete`/`fail`. |
| §8.1 seq exhaustion, 600 s lifetime | No vectors. |
| §6.2 "not yet valid" cleared | Board has no clock, so in a library with time checks every certificate is FUTURE or EXPIRED depending on epoch; only an expired (2020–2021) vector exists. Add notBefore far in the future, basicConstraints absent (accept), X.509 v1 (`malformed`), compressed and off-curve SPKI point (`curve`). |
| §6.2 decision itself | `CertificateTests` never parses DER; it trusts the labels. (I re-derived all 19 decisions independently with `cryptography` 48.0.0 and they match, but a future edit is unchecked.) |
| §3.3 identity-reset success from `none`/`revoked`, and its storage failure | Only reset from `key_lost`/`record_corrupt` and the `occupied` refusal. |
| §3.3 consumed press does not open pairing window | No vector (and see H1). |
| §13 loopback negatives | List lacks: record > 4352 (`record_overflow`), server NewSessionTicket, server 0.5-RTT application data before client Finished, KeyUpdate (see L1). |

**Smallest fix.** Add the vectors and extend the oracle to the full tuple
check and a real X.509 decision (the checker already runs in an environment
where `cryptography` can be optional with a SKIP that counts as INCOMPLETE).

### M6 (medium) — Compatibility matrix rows missing or unproven

**Clause:** §12.

- **Firmware roll-forward after a rollback.** The old firmware mutates only
  `tasks_v1` (local submissions); on roll-forward `tasks_v2` wins and those
  tasks silently disappear from both views. Needs a row and a decision
  (refuse to start the store if `tasks_v1` changed since migration — e.g.
  store its SHA-256 in `tasks_v2` — and disable rather than diverge).
- **Phone rollback to an app older than the 2026-11-07 containment.** The row
  covers only an old app that "refuses every BLE grant". Rollback must be
  declared supported only to builds that refuse BLE grants, mirroring the
  firmware row.
- **"Ignored by the old app"** is a claim about existing code: the current
  executor marks `accepted`/`running` parents as `unknown_outcome` on
  redelivery (`DeviceTaskExecutor.swift:60-63`). It is not reached without a
  BLE grant, so the claim is probably true, but it should be stated as "not
  dispatched" with the code reference, not "ignored", and covered by a test.

### L1 (low) — KeyUpdate "permitted"

§6.1 permits KeyUpdate. With a 600 s lifetime and ≤ 65535 requests there is
no AES-GCM usage-limit need, and I could not confirm KeyUpdate support in the
Mbed TLS TLS 1.3 stack both ends are expected to use. A conforming peer that
sends it may kill the session on the other. **Fix:** "MUST NOT send KeyUpdate;
a received KeyUpdate is processed per RFC 9846 or fails the session with
`unexpected_message`", plus a loopback case.

### L2 (low) — PSK/early-data "fails the handshake" vs server behaviour

§6.1 says the client sends no PSK/early-data extensions and "any deviation
fails the handshake", and §13 requires negatives for "PSK/early data offered".
A TLS 1.3 server with no PSK configured normally *ignores* those extensions
and completes a full handshake. **Fix:** say explicitly whether the server
must abort (custom ClientHello inspection) or may ignore; security is the
same, conformance tests are not.

### L3 (low) — Revoke storage failure silently re-activates after reboot

§3.3: after a failed revoke write the RAM flag clears on reboot and the old
pairing is authoritative again. Fail-open is documented and the operator was
told `storage`, but an unattended reboot (brown-out) re-enables a pairing the
operator believes revoked. **Fix:** after a revoke `storage` error, refuse to
serve sessions until the next successful console command (persist nothing;
just require `status`), or make the board's next boot classify a record whose
last revoke attempt failed as `record_corrupt` if a second NVS key can carry
that marker.

### L4 (low) — Small consistency items

- §3.2 response table says `cmd` is `-` "for unsolicited timeouts", but the
  press timeout (also unsolicited) uses `cmd=<action>`; the fixtures follow the
  latter. Reword.
- §3.3 identity-reset: the oracle resets `rev` to 0; the text is silent.
  State it, and state the erase order (`rec_v1` before `priv`, each committed).
- §7.2/§7.3: client `err` with `re ≠ 0` is rejected by the oracle but the
  schema allows it; fine as a semantic rule, but say "client `err` `re` MUST
  be 0" in §7.3 (currently implied by "`re:0`").
- §11.5's justification covers transition receipts only. Add that
  `pdsh.task.next` results were held only in RAM (`readonly_result`,
  `link_tools.c:389-412`, cleared at `tools_init`/HELLO), so no pre-upgrade
  task body survives in any Link receipt.
- Orphaned slots: `accepted` slots owned by a revoked phone or an old phone
  key can never be completed or failed, and the reference store holds four
  lifetime tasks. Not a security issue; record it as a known liveness limit.

## The eight assumptions (§15)

| # | Assumption | Decision | Reasoning / conditions |
| --- | --- | --- | --- |
| 1 | Pinned self-signed certificates, dates ignored, "clear exactly not-trusted / expired / not-yet-valid" | **Accept with conditions** | With enrollment as the only trust decision and revocation by record, dates add nothing and the board has no clock; the profile and reason order are coherent and the fixtures decide correctly (independently re-checked). Conditions: (a) the decision MUST be the application's own §6.2 evaluation of the leaf DER, and the TLS stack MUST abort the handshake on a negative decision — never `VERIFY_OPTIONAL` with a later, forgettable result check; (b) "clear exactly three flags" is library-specific and in some stacks the verify callback is not invoked without a configured CA chain, or a locally trusted end-entity skips the self-signature check — the spec should state the required *outcome* (rules 1–5 decide; nothing else may accept) and leave the mechanism to each end, with the loopback negatives proving it; (c) add the missing certificate vectors from M5. |
| 2 | No TLS exporter / channel binding; readiness relies on one pin-checked connection plus echoed challenges | **Accept with conditions** | Both peers are authenticated by the same TLS handshake; every application byte is protected by keys bound to that transcript; an attacker without a key can neither inject nor move messages between connections, so an exporter would add no security against the stated attacker. Echoed `cc` gives the phone liveness; `sc` makes stale requests fail closed. Conditions: (a) state that the board MUST NOT send any application data (0.5-RTT) before it has verified the client Certificate, CertificateVerify and Finished, and the phone MUST NOT act on any application data delivered before its own handshake returns; (b) fix M1, which is the real binding gap (which device, not which connection). |
| 3 | Software Keychain phone key permitted (Secure Enclave recommended); plain-NVS board key | **Accept with conditions** | Acceptable for a reference profile whose UI labels it honestly. Conditions: (a) the CCR evidence shows the only working integration so far *exported* the Keychain key into Mbed TLS memory, which contradicts §4.1 "non-exportable"; the contract must require signing through `SecKeyCreateSignature` (an opaque-key / external-sign hook) and `kSecAttrIsExtractable = false`, or file a CCR if that is not achievable — implementers must not quietly make the key exportable; (b) the board side must be restated per H2 (any USB host can read it at any time) and M4 (signing oracle, RNG). |
| 4 | Single board button press + trusted host as physical authorization | **Reject as written; accept after H1 and H2** | Attack in H1: a console-capable host stages an attacker phone and the operator's routine short press (pairing window / BOOT button) commits it; for a committed board, `status` reveals the values needed to `revoke`. Per H2 a malicious USB host does not need the button at all. With a distinct long-press gesture, an indicator, and an honest threat model statement, the residual assumption ("the operator and every attached USB host are trusted") is acceptable. |
| 5 | Resend after an authoritative `status` | **Accept with conditions** | Board transitions are deterministic, owner-checked, single-session (board allows one session, one phone), and the board has no transition back to `queued`; a `queued` / `accepted, mine` answer therefore proves the earlier send was not applied and the precondition still holds. No double execution of the DSH turn is possible because execution is gated by the phone journal, not by the board. Conditions: (a) the resend MUST be the very next request after that `status_r` in the same session (say so in §9.3); (b) add the `phone_id` ≠ current key vector (M5); (c) define first-send request-level errors (M2). |
| 6 | No anti-rollback anchor; rollback to pre-containment firmware unsupported | **Accept with conditions** | Without secure boot any USB host can flash any image (H2), so an anti-rollback counter would be decorative; declaring it a non-goal is honest. The new phone never falls back to plaintext, so a rolled-back board loses only its own queued task confidentiality, which a USB-holding attacker already has. Conditions: add the roll-forward row and the phone-rollback floor (M6). |
| 7 | Ordinary Link RESULT unchanged for pre-upgrade task transitions (no receipt quarantine) | **Accept** | Verified in `link_tools.c`: `accept`/`complete`/`fail` receipts persist only `{request_id,status,result:{}}` (or `failure_reason`), and `pdsh.task.next` results are RAM-only and cleared at boot/HELLO, so no task body or outcome is recoverable via RESULT. The residual leak (that a UUID existed and whether it completed or failed) is minor and pre-dates this change. Add the `next` justification to §11.5 (L4). |
| 8 | 4352-byte record plaintext cap without `record_size_limit` | **Accept with conditions** | Both ends are under the project's control and ALPN fixes the profile, so out-of-band agreement is enough; one 4098-byte frame fits in one record. Conditions: make the sender side a configured MUST on both ends (e.g. maximum outgoing plaintext ≤ 4352), make "receiver MUST reject > 4352" rather than MAY so the board's buffer bound is a contract fact, confirm that the largest handshake message (client Certificate + CertificateVerify ≈ 1.2 KB) fits the configured input buffer without handshake-message reassembly, and add the `record_overflow` loopback case. |

## Internal consistency summary

- **Spec ↔ schema ↔ fixtures.** Shapes agree; semantic rules the schema cannot
  express (UTF-8 byte limits, `next_r` task/phase pairing, `status_r`
  outcome presence and `mine`, client `err` `re = 0`, direction) are enforced
  by the checker and covered by negative message vectors. Gaps are listed in
  M5. The certificate fixtures are correct (independent re-derivation).
- **State machines.** Board enrollment (§3.3) is complete for the listed
  verbs and fail-closed on every error path I traced (press abort on any
  addressed line, no durable effect before the press, readback before
  `committed`, no regeneration while a record exists). Board session (§8.3)
  is fail-closed. Phone session after readiness is the main hole (M2), plus
  timer/grant liveness (M3).
- **Fail-closed.** Every failure path I examined is fail-closed except the
  documented revoke-storage-failure reboot case (L3) and the
  pre-authentication availability/memory-safety surface (H3).
- **Compatibility (§12).** Safe in every listed direction; incomplete for
  firmware roll-forward and the phone rollback floor (M6). No downgrade path
  to plaintext tasks exists on either new end.

## Needs a human cryptographer / security engineer

An automated read cannot settle these; each needs someone with the pinned
library sources and the hardware:

1. **Certificate verification wiring in the pinned Mbed TLS (ESP-IDF v6.1
   fork and upstream 4.1.1)**: how a pinned self-signed leaf is verified with
   `VERIFY_REQUIRED` and no trusted clock; whether the verify callback is
   reached without a CA chain; whether a locally trusted end-entity skips the
   self-signature check; that no path leaves `VERIFY_OPTIONAL` semantics.
2. **iOS signing path**: whether a non-extractable Keychain or Secure Enclave
   key can drive TLS 1.3 CertificateVerify through an Mbed TLS / PSA opaque
   driver, and what process-memory exposure remains.
3. **ESP32-S3 entropy** at first-boot key generation and at every TLS
   handshake (RF state, bootloader entropy), and whether ECDSA should be
   deterministic (M4).
4. **Key reuse** between `pdsh.identity.prove` and TLS server authentication:
   confirm domain separation and decide whether to retire the prove tool or
   split keys (M4).
5. **NimBLE CoC robustness** against an adversarial pre-auth peer, including
   the over-credit dereference and every send return path (H3).
6. **Physical enrollment ergonomics**: whether the chosen gesture and
   indicator actually prevent the confused-deputy press (H1), tested with
   operators.
7. **KeyUpdate, ticket and 0.5-RTT behaviour** of both stacks as configured
   (L1, L2, assumption 2a), confirmed by the §13 loopback negatives on real
   configurations rather than by reading.

```text
Status per end:     Swift not started; firmware not started (contract only)
Not verified:       every runtime, radio, device, Keychain, TLS and power-loss claim
Remaining risks:    H1–H3, M1–M6 above; tracked under GAP-16 until the contract owner
                    issues a revised revision per AGENTS.md §3.3
```
