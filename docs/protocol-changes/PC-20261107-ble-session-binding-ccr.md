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

The separate identity binding decision must also resolve key replacement and forgetting: the current UserDefaults list (`pdsh.ble.trustedIdentities`, see [ble-identity.md](../../spec/device/v1/ble-identity.md) §5) contains only strings — public-key fingerprints and possibly legacy labels — and cannot prove which Link UUID belongs to a key. Such old entries cannot safely become bound identities automatically. UUID-based task records and intents cannot be converted to fingerprint identities or blindly replayed. A changed untrusted device label can evade a per-label legacy-record check; orphan, corrupt or unreadable intents require an explicit fail-closed recovery decision. A reference device also needs a credible independent fingerprint comparison channel before a user confirmation can detect a first-use substitution.

Proof and trust UI results must be bound to the current connection generation. Disconnect, revocation, asynchronous completion, storage errors, concurrent forget, and reconnect need defined ordering; no stale completion may restore a task grant. Proof failure must not deliberately disconnect an otherwise healthy ordinary Link, while genuine transport failure still follows the Link recovery rules.

## Acceptance before enabling BLE task grants

- Contract, schemas and shared positive/negative vectors are frozen before implementation; all registered ends run them through real encoders, decoders and state machines. Explicitly test modified, replayed, reordered and cross-session task/receipt data, wrong and changed keys, storage failures and cancellation races.
- Verify first use with an independent comparison, reconnect, changed-key refusal, restart persistence and an actual ESP32 task/receipt round trip on physical devices. Verify negative active-peer cases and record exactly what they prove. A simulator, host stub, local TLS fixture or passed static checker is not this evidence.
- Complete the separate UI, MCP lifecycle, production TLS and repository gate requirements. Do not mark the target profile implemented or close GAP-16 merely because the contract is written.

## Candidate for investigation, not a contract

One candidate is a mutually authenticated TLS 1.3 session over an explicitly negotiated, bounded BLE byte-stream transport. Both endpoints would authenticate a previously confirmed peer key; all task requests, responses, identifiers and receipts would be inside the session, and 0-RTT and unauthenticated fallback would be disabled. See RFC 9846, which obsoletes RFC 8446. The tested libraries are not thereby proven compliant with every updated requirement. This is not yet a selected design: the phone-key provisioning and mutual-confirmation model, iOS and ESP-IDF API feasibility, memory and framing bounds, stream fragmentation and flow control, reconnection, failure behavior and physical-device interoperability still need proof. TLS records cannot be assumed to fit one existing Link envelope or RPC. A transport timeout or failed session still does not authorize replay of a possibly applied task; the durable task and query-only recovery rules remain necessary.

A feasibility spike must establish whether the Apple host can attach a TLS implementation to a custom GATT stream and whether the pinned ESP-IDF supports the required server authentication, pinning, and no-clock certificate policy. The reference board's lack of an independent display also leaves phone-key provisioning unresolved. Stream design must bound memory, handshake size, queues and deadlines on real hardware, respect existing Link and ATT frame limits, and distinguish a byte-identical retransmitted fragment from conflicting or out-of-order data without delivering it twice. Downgraded negotiation must never enable old plaintext tasks; the device must reject plaintext task access when the secure profile is required. None of these feasibility claims has been verified by this record.

Local SDK feasibility observation (2026-11-07): the iOS SDK exposes custom I/O callbacks in the deprecated SecureTransport API, but its documented protocol-version API does not establish TLS 1.3 support for that path. Network.framework's application framer is layered above a transport; no public API for making an arbitrary CoreBluetooth stream its TLS transport was established by this check. This does not prove such integration is impossible. Neither option is an approved implementation without a tested design and security review.

Pinned ESP-IDF source observation (2026-11-07): tag v6.1 (`fff9895c82d744c7237be8847347bdd1b07c6643`, Mbed TLS `a2b32072ea898afc1ed5b6caf6931e36028c91d6`) contains TLS 1.3 server, client-certificate authentication and custom I/O paths. TLS 1.3 and certificate date checks are disabled by default in its Kconfig; raw-public-key certificate types are not supported by the cited TLS 1.3 implementation. X.509 key pinning and a no-clock trust policy require design and validation. These are source observations, not a handshake, resource or device test.

Isolated iOS Simulator feasibility spike (2026-11-07): the exact ESP-IDF v6.1 Mbed TLS/TF-PSA-Crypto sources built for iOS Simulator arm64 after adding two temporary compatibility headers that include private `bignum` and `ecp` headers. A minimal simulator program linked the resulting static libraries, initialized TLS 1.3 configuration and ran `ssl_setup` with exit 0. This used no repository dependency or source patch, but the temporary headers rely on private API and are not a production integration. No handshake, certificate validation, mutual authentication, GATT transport, device resource measurement, or iPhone test was performed. Licenses and distribution obligations for every compiled component remain to be reviewed.

Further host/simulator evidence: an isolated experiment using the same pinned Mbed TLS source and temporary private-header shims completed a TLS 1.3 mutual-certificate handshake between a macOS host and an iOS Simulator, exchanged application bytes, and rejected a modified encrypted record and two mismatched leaf certificates. The test pins complete DER test certificates and uses a temporary test CA and localhost TCP; it does not validate the intended device public-key provisioning, GATT stream, hardware resources, or physical devices. TLS handshake success alone is not task authorization.

Legacy recovery evidence: the reference firmware's existing persistent Link receipt stores request UUID, a hash of the idempotency key, a hash of the complete request bytes, state and result, but no tool classification. Its existing plaintext RESULT returns a result by UUID without returning those digests. A claimed old completed result therefore cannot safely be matched to the persisted task intent using that RESULT alone, and new protected task receipts must not become readable through the plaintext path. A future authenticated recovery contract must define how the old exact request and idempotency hashes are verified, and how ambiguous, orphaned, missing, corrupted or previously untrusted records stay unresolved without replay. `pdsh_task_store_next` does not distinguish queued from accepted tasks in its response; blindly treating a legacy returned task as new can re-execute it. These observations do not select an automatic migration or claim old plaintext requests were authenticated.

Additional isolated feasibility evidence (2026-11-07): a host-to-iOS-Simulator
TLS experiment sent the pinned Mbed TLS byte stream through a simulated Link
fragmentation/reassembly proxy with a 512-byte envelope and a 19-byte fragment
budget. A handshake and ping/pong succeeded including 5 ms per-fragment delay;
a modified encrypted record with a recomputed Link CRC failed TLS MAC
verification, and a disconnect during handshake delivered no application
data. A separate post-handshake disconnect showed that a successful sender write
can coexist with no completed receiver read. This proxy is not the repository's
GATT implementation, and it does not prove physical radio behavior, bounded
queue/backpressure, loss recovery or ESP32 memory use.

A separate host/Simulator experiment verified a SHA-256 pin over a checked
65-byte uncompressed P-256 certificate public point: both peers accepted the
same key under a reissued certificate and rejected a changed key. With a test
CA it also rejected the wrong CA and wrong hostname despite a matching key. A
no-clock experiment cleared only certificate not-yet-valid/expired flags while
continuing to reject the other tested errors; this deliberately forfeits date
validity checks and is **not** an approved deployment policy. These experiments
used CA-issued test certificates, not a production provisioning, revocation or
no-clock trust design, ESP32 hardware, or a production iOS Keychain-backed TLS
signing integration. They do not freeze a session or authorize task grants.

A further Simulator-only probe imported the exported bytes of a temporary P-256
`SecKey` into PSA and used the wrapped key in the same mutual TLS 1.3 handshake;
the exchange completed, but the private key entered process memory. Attempts to
persist that key in Keychain failed with error -34018 in a command-line process
and an unentitled test app; a separately entitled temporary simulator app failed
to launch. Thus neither persistent Keychain retrieval nor a non-exportable
Secure Enclave signing callback has been established. This experiment does not
select an iOS production key-storage or certificate policy.

A cross-version Simulator experiment used the official Mbed TLS 4.1.1 release
archive (SHA-256 `3359a349e23db3d5536fcee032ae7b2ecbfc08972fab643089b5cbf2a375c98c`,
including TF-PSA-Crypto 1.2.0). AppleClang built the iOS Simulator arm64 library
without the two temporary Espressif-fork compatibility shims. Its Simulator
client completed mutual TLS 1.3 and ping/pong with the fixed ESP-IDF-fork host
server; 21 pin, CA, hostname and simulated date-policy cases passed. This is a
candidate, not an approved or vendored dependency. It used test PEM keys, host
certificate verification and localhost; ESP32 compilation, true no-clock
configuration, production licensing/integration, Keychain signing, GATT,
physical devices and memory budgets remain unverified.

Packaging feasibility (2026-11-07): the same upstream archive was built without
added compatibility shims for iphoneos arm64 (iOS 17), iphonesimulator arm64
(iOS 17) and macOS arm64 (macOS 14). A temporary combined-static-library
XCFramework and a minimal opaque C bridge linked from Swift for all three
slices; the Simulator and macOS binaries actually initialized PSA and set up
TLS 1.3. The iphoneos binary was linked only. The experiment did not establish
x86_64 support, SwiftPM binary-target resolution, deterministic outputs,
production license closure, Keychain access or security review, and no
XCFramework or upstream source is committed by this change.
A separate local SwiftPM consumer subsequently resolved and built the temporary
binary target for macOS; SwiftPM resolution for iOS and its Simulator remains
NOT_RUN.

A separate signed, App-hosted iOS 27.1 Simulator XCTest succeeded in adding,
reading and deleting a unique Keychain password item. Across separate app
processes it created and read the item, deleted it, and observed not-found on a
subsequent launch. This corrects the narrower unentitled-process observations
above, but is not evidence for permanent P-256 `SecKey` creation, signing,
export, Secure Enclave, physical iPhone or integration with the TLS library.

A later App-hosted iOS 27.1 Simulator test created a permanent P-256 Keychain
software key, then queried and used it to sign/verify in a second process. The
65-byte public point and its SHA-256 matched across launches; deletion followed
by a third query returned not-found. This Simulator key was exportable as 97
bytes and did not use a Secure Enclave token. The test key was deleted. These
results are not a claim about physical iPhone key export, Secure Enclave,
Keychain lock/reboot policy or TLS use of the persisted key.

A further temporary App-hosted Simulator test exported the unique permanent
Keychain software key only into process memory, imported it into upstream
Mbed TLS 4.1.1 and used a matching CA-issued client certificate. It completed a
TLS 1.3 mutual handshake with an OpenSSL host server, with both certificate
verifications successful. The subsequent application read returned WANT_READ;
application-data round trip and wrong-key rejection were NOT_RUN. Both test
keys were deleted and subsequent queries returned not-found. The temporary C
buffer was zeroized and Swift data was cleared on a best-effort basis, without
a guarantee that system or library copies were erased. This is not a
non-exportable key, physical iPhone, ESP32, GATT, no-clock or production
session test. The experiment stopped when available disk dropped below its
predefined safety threshold.

A later independent iOS 18.4 Simulator rerun used two permanent Keychain
software keys and a matching client certificate with upstream Mbed TLS 4.1.1.
After handling TLS 1.3 post-handshake messages, the client exchanged actual
HTTP request/response data with the local Python/OpenSSL server (HTTP 200,
`pong`, certificate verification flags 0). Supplying the other Keychain key
with the original certificate caused the server to report BAD_SIGNATURE before
receiving a request. The isolated App was built with `xcodebuild build` for
its temporary Simulator; each case ran in a separate `simctl launch` process.
Both keys were deleted and subsequent separate-process lookups returned
`errSecItemNotFound`; temporary CA/server private keys and the dedicated
Simulator were also deleted. Logs and source of the experiment are under
`/private/tmp/pdsh59-mtls-again/` on the test machine. These results do not
establish a non-exportable signing path, ESP32, GATT, no-clock behavior,
physical-device identity recovery, or a production security design.

An isolated ESP32-S3 reference-firmware copy was cross-compiled with the fixed
ESP-IDF 6.1 and a temporary probe referencing the TLS 1.3 server handshake,
own certificate and client-certificate verification APIs. The build passed;
the linked ELF contains the handshake and probe symbols. Relative to the
previous reference build, the image grew from 728,927 to 752,727 bytes and
static DIRAM from 160,343 to 160,359 bytes. This rough delta includes the
temporary probe and configuration effects. The trial enabled ephemeral KEX,
peer-certificate retention and the default PSK mode, with early data disabled;
it is not a frozen session policy. No flash, BLE transport, real certificate
handshake, handshake heap peak or production resource budget was tested.
Build and `esp_idf_size` logs are under `/private/tmp/pdsh59-esp-tls/` on the
test machine; no trial code or build artifact is included in this repository.

Physical iPhone feasibility (2026-11-07): an isolated, uniquely identified test
app on an iPhone 15 Pro Max (iOS 27.2) created a permanent P-256 Keychain
software key. A second app process retrieved the same public-key fingerprint
and signed successfully. After the user enabled Wi-Fi for that test app, an
upstream Mbed TLS 4.1.1 client using that key completed TLS 1.3 mutual
authentication and HTTP request/response with a local OpenSSL test server.
Replacing the key while retaining the client certificate made the server reject
the handshake with `BAD_SIGNATURE` before any request. The two unique test
keys were deleted and subsequent separate-process lookups returned not-found;
the test app was uninstalled and temporary CA and server private keys removed.
This used an exportable software key, not a Secure Enclave signing callback;
it did not test a phone reboot, ESP32, BLE framing, first-use provisioning or
the proposed production session. It is feasibility evidence, not a security
review or permission to enable task grants.

An alternative transport candidate is native LE L2CAP credit-based channels:
Apple's `CBL2CAPChannel` exposes input and output streams, and the pinned
ESP-IDF 6.1 NimBLE source contains native CoC server, receive and send APIs.
This native NimBLE API is distinct from the experimental BLE Audio L2CAP wrapper.
The fixed reference configuration has `CONFIG_BT_NIMBLE_L2CAP_COC_MAX_NUM=0`,
so the earlier static TLS measurement did not include CoC. Android's public
LE CoC client API starts at API 29; older supported Android releases require a
separate compatibility decision. PSM discovery, peer binding, lifecycle,
backpressure, bounds and real iPhone/ESP32 interoperability remain undecided.
Apple documents a PSM characteristic with a two-byte little-endian value;
using that existing characteristic inside a dedicated service is a candidate,
not an authorization mechanism. A PSM read must be tied to the current
connection and re-read on reconnect; a modified value can affect availability
but must never bypass the independently provisioned key pins.

The pinned NimBLE send implementation can return `BLE_HS_ESTALLED` after taking
ownership of and queueing an SDU; blindly retrying that buffer can duplicate
bytes. Other error paths and examples need explicit ownership and cancellation
tests before defining a wrapper. A CoC byte stream is not itself peer
authentication or an authorized task session. Neither this candidate nor the
physical iPhone TLS test changes the default denial of BLE task grants.

Isolated physical CoC feasibility (2026-11-07): after the user allowed Bluetooth,
an iPhone 15 Pro Max and a Mac used native CoreBluetooth LE CoC with a randomly
generated test service and the system PSM characteristic. The test reported
two 65,536-byte synthetic-data echo cycles with byte-for-byte agreement, a BLE
disconnect and reconnect with a fresh PSM read, and 44 observed output-stream
backpressure pauses followed by completion. The temporary phone and Mac apps,
source and run files were removed after the test; raw logs were not retained,
so this observation alone is not independently replayable acceptance evidence.
The channel was intentionally unencrypted and carried no TLS or private data;
there was no ESP32, production provisioning, authenticated peer, hostile relay,
or persistence test. Future acceptance must retain suitable sanitized evidence
and exercise the real two-end implementation and its failure paths.

The fixed ESP-IDF TLS 1.3 sources also indicate that small application frames or
CoC SDUs do not by themselves bound TLS record size. The prior cross-compile
used a 16 KiB input buffer and did not include CoC. Its record-size-limit option
and the candidate client's negotiation, omitted-extension behavior, handshake
peak memory and real ESP32 resource limits remain unverified. No smaller TLS
buffer or production ALPN/version policy is selected by this observation.

The draft review also requires the secure receipt namespace to remain separate
from legacy plaintext RESULT and to bind authorized device identity, request
UUID, idempotency key and request hash. Old UUID-labeled intents and receipts
cannot be upgraded solely from a later key claim; unprovable history remains
preserved and unresolved. An authenticated end-to-end session can protect
message integrity and confidentiality but cannot prove physical proximity or
prevent a transparent radio relay. Initial independent fingerprint comparison,
phone-key provisioning, certificate validation and no-clock policy, persistent
revocation, and safe handling of unresolved old records remain contract decisions.

A later isolated ESP32-S3 build enabled one native NimBLE CoC alongside the
same TLS 1.3 test configuration, with temporary probe code referencing the
actual CoC and mutual-certificate TLS APIs so the relevant symbols linked. The
fixed ESP-IDF and complete locked cJSON component were verified. The firmware
binary was 757,888 bytes: 5,040 bytes more than the earlier TLS-only probe and
28,848 bytes more than the reference build. Static DIRAM was 160,375 bytes,
versus 160,359 for TLS-only and 160,343 for the reference. These comparisons
include temporary probe code and are not a runtime memory budget. The probe was
not flashed and does not connect CoC I/O to TLS. Real handshake heap peaks,
credit exhaustion, ownership on each send error, certificates, provisioning,
ESP32/iPhone radio behavior and device power loss remain untested. The test
configuration enabled PSK support for feasibility and is not the proposed
production policy.

Physical ESP32-S3 follow-up (2026-11-07): after the user connected a board,
two isolated CoC/TLS experiment runs did not complete a handshake. The first
laboratory firmware rebooted because its NimBLE event objects were initialized
before the NPL function table. After correcting that order, the board started
and an iPhone opened a CoC, but the connection closed before the phone reported
any stream bytes; the phone's handshake returned an internal stream error and
the board stopped waiting for input. The logs did not establish the cause,
certificate verification, application delivery or a production defect.

Before using the board, two complete original flash images were independently
read and matched; each test also compared the current entire flash against the
backup before writing. Following each failed test the original image was
written back, the device-side whole-flash digest matched, and the reset command
succeeded. The original application's functioning after reset was not
independently verified. The experiment was a separate test firmware with test
credentials, not the reference task implementation or an authorized task
session; no eFuse changes were made. These failures do not close GAP-16.

Subsequent isolated physical iPhone/ESP32-S3 experiment: after retaining the
iPhone's CoreBluetooth channel and correcting the experiment's receive-credit
handling, an upstream Mbed TLS 4.1.1 iPhone client and the ESP-IDF 6.1 Mbed TLS
server completed TLS 1.3 mutual-certificate authentication over native LE
CoC. The iPhone verified the test CA, hostname and exact server leaf DER, then
read the expected `PONG` for its `PING`. A different client leaf signed by the
same test CA was rejected by the ESP's exact-leaf pin (`BADCERT_OTHER`); an
incorrect expected server leaf was rejected by the iPhone before its PING.
Neither negative case produced a PONG. All three runs used separate connections
and per-run result identifiers. The temporary phone app was uninstalled. The
original entire board image was written back, verified against the protected
backup, and a reset command succeeded; original application functionality after
reset was not independently checked.

This laboratory firmware used embedded, exportable test keys and a test CA;
the ESP ignored certificate date flags for its untrusted clock. It did not use
Keychain signing, independent provisioning, the production Link/task code,
device-task receipts, persistent trust, ESP reboot recovery or Android. It is
not a production security review or a completed authenticated task session.
The earlier ESP crash exposed a specific CoC flow-control hazard: with RX MTU
512 and MPS 504 the fixed NimBLE build initially grants two credits despite a
single application receive slot, so another SDU can arrive while the slot is
empty. A 256-byte lab MTU produced one initial credit and worked with this
cooperating iPhone. The recorded packets did not prove the precise fragment
sequence of the crash. Source inspection also found that the receive path
dereferences its slot before checking credits; resistance to an over-credit
peer remains unverified and the laboratory workaround is not a production DoS
fix. Record sizing, supported-platform compatibility, resource bounds and a
safe upstream resolution remain open.


## Independently reviewed candidate, still draft

The [security design candidate](../design/device-ble-secure-session-candidate.md)
records a possible two-way out-of-band enrollment, locally verified mutual
TLS session, explicit readiness, protected task/receipt isolation and
fail-closed recovery. Its independent review led to explicit partial-commit,
old unclassified plaintext receipt, untrusted clock and peer-verification
limitations. This is not a frozen protocol revision, a selected implementation
or permission to enable task grants; the CCR's existing acceptance remains
mandatory. No new physical or security experiment was performed for it.
