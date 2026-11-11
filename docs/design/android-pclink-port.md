# Android PCLink port — module, crypto, persistence, pages and C0–C5

Status: **design / draft** (no code). Companion contract freeze draft:
[`docs/protocol-changes/PC-20261112-pclink-android.md`](../protocol-changes/PC-20261112-pclink-android.md)
(hereafter **PC-ANDROID**). Base `56e7b6ceb5e66bcce72e7e6be53c5df674b22927`; branch
`dsh/20261111-200540/01-02-pclink-android-plan`.

Read first: `AGENTS.md` §3/§5/§6, `docs/parity/lessons.md`,
`docs/parity/android-parity-roadmap.md`, `spec/pclink/v1/README.md` (2,240 lines,
revision `pclink-v1.6`), `android/README.md`, `spec/platform/android-module-map.json`.

This document is written so a wave-2 worker can take **one** checkpoint (C1–C5)
without reading the other workers' diffs. Each checkpoint names its exclusive
paths, the exact golden file(s), the acceptance command and the expected output.
It does not edit `spec/**`, `Sources/**`, `examples/probe-app/**`, `relay/**` or
`pclink/**`.

---

## 1. Decisions at a glance

| # | Decision | Why / evidence |
| --- | --- | --- |
| D1 | **No wire change.** Android is a second `role:"phone"` implementation of the same `pclink-v1.6` bytes. | Every byte is already normative; §3.1 of PC-ANDROID lists them. The existing golden vector file is the shared fixture. |
| D2 | **New Gradle module `:pclink`** (`java-library` + `kotlin-jvm`), package `com.phonedsh.pclink`, JVM only. | `:core` and `:net` are the precedent for protocol code (`android/core/build.gradle.kts`, `android/net/build.gradle.kts`). `:net` is P05 loopback/gateway; `:dsh` is the phone host. Putting P28 files in either would double-own the boundary (AGENTS.md §1.1). |
| D3 | **Crypto = Bouncy Castle lightweight API**, `org.bouncycastle:bcprov-jdk18on:1.86`, already pinned. | `android/gradle/libs.versions.toml:17`; already used by `:app` for SSH (`android/app/build.gradle.kts:666`). minSdk 26 has no platform X25519/Ed25519 and ChaCha20-Poly1305 only from API 28; using JCA would need a second code path. BC gives one path that matches the vectors. See §4. |
| D4 | **WebSocket = Ktor client CIO + WebSockets 3.2.3**, behind a 3-method seam. | No WebSocket client exists in the tree; Ktor 3.2.3 is already the server and test client (`android/net/build.gradle.kts:27-36`) and is Kotlin-2.1.0-metadata compatible. The seam keeps tests on an in-memory socket. |
| D5 | **Identity seed = software seed wrapped by AndroidKeyStore AES-GCM** through the existing `:platform` `SecureStore`. | `AndroidSecureStore` already implements exactly this shape (`android/platform-android/src/main/kotlin/com/phonedsh/platform/android/AndroidSecureStore.kt:93-180`); minSdk 26 has no Ed25519 KeyStore key type. See §5.1 and platform entry `platform.pclink-identity-seed`. |
| D6 | **Pairing record = `filesDir/pclink/pairs.json`**, atomic replace + fsync; no backup (`android:allowBackup="false"`, `android/app/src/main/AndroidManifest.xml:116`). | Spec §4.6 record shape; matches `Sources/PhoneDSHPCLink/PCLinkPairingStore.swift:184-302`. |
| D7 | **P18 preference keys go through the existing `PreferenceFile` seam** (`android/app/src/main/kotlin/com/phonedsh/probe/PreferenceStore.kt:213-243,256-296,595`); the current-session key stays in the existing `:domain` `ChatSessionStore` authority (`android/app/src/main/kotlin/com/phonedsh/probe/ChatSessionStore.kt:468`) and gains a scope there. | One authority per fact; the P18 key names/values are protocol (PC-ANDROID §2.2), and a second copy of the current session in preferences would violate AGENTS.md §1.1. |
| D8 | **Relay socket is foreground-only** (plus an active turn foreground service); background closes it, foreground calls `foregroundResumed()`. | Android Doze/background limits; the contract is already demand-driven with no queue (§10). Platform entries `platform.pclink-foreground-relay` and `platform.pclink-doze-network`. |
| D9 | **Pages live in `:lib`; camera + Keystore + protocol wiring live in `:app`.** | `:lib` is the published AAR (`android/lib/build.gradle.kts`), pages there are compared by `page_structure_check.py`; the camera/Keystore/protocol deps must not leak into the AAR. |
| D10 | **No PCLink data migration on Android** (first release); a build without PCLink ignores `filesDir/pclink/`. | PC-ANDROID §3.2; matches spec §11 "A build without PCLink ignores the directory". |

---

## 2. Module layout

### 2.1 Current tree (the boundaries to preserve)

`android/README.md:5-7` describes 13 Gradle modules: `:core` merges wire+log+agentcore,
`:net` merges loopback+gateway, `:testkit` merges scenario+harness, and the
remaining modules are platform/UI/app shells. `android/README.md:141` is the
`Swift 模块 → Kotlin 包 → Gradle 模块（16/16）` table; it has no
`PhoneDSHPCLink` row. `spec/platform/android-module-map.json` likewise has 16
entries and no `PhoneDSHPCLink`; `android/tools/structure_check.py:47-61` pins the
13-module inventory and `:362-471` checks the module-map/README/Package agreement.
This is why the first Android PCLink change is a **registration checkpoint** (C0),
not a code checkpoint.

### 2.2 Target graph

```text
                 :platform (pure JVM SPI: SecureStore, Clock, ...)
                     ▲                                   ▲
                     │                                   │
 :core (JsonValue, host events) ─────► :pclink (JVM, P28) │
                     ▲                                   │
                     │                                   │
                   :app (probe) ─────────────────────────┘
                     │  uses :pclink, :lib, :platform-android
                     ▼
                   :lib (Compose pages, AAR)  ◄── pages take plain state/callbacks
```

- `:pclink` is a **JVM library**, not an Android library. It has no `android.*`
  import; JVM tests run on the host.
- `:pclink` depends on `:core` only for `com.phonedsh.agentcore.JsonValue`
  (`android/core/src/main/kotlin/com/phonedsh/agentcore/JsonValue.kt`) and
  `kotlinx-coroutines-core:1.10.1` (already an `api` of `:core`,
  `android/core/build.gradle.kts:49`). It does **not** depend on `:net`
  (P05) or `:dsh` (P14/P06).
- `:app` depends on `:pclink` with `implementation`; the published `:lib` AAR
  does **not** expose `:pclink`, so a consumer of the AAR gets no crypto/protocol
  classes. The pages in `:lib` receive a `PcLinkUiState`/callbacks defined in
  `:lib`; `:app` maps `PclinkClientStatus` into them. This keeps the AAR's
  `api` surface unchanged (`android/lib/build.gradle.kts` dependencies block).
- If a future external composition root needs the PC client, promoting `:pclink`
  into `:lib`'s `api` is a separate P12/P28 decision. Not in this port.

### 2.3 `:pclink` build file (C0 writes it)

```kotlin
// android/pclink/build.gradle.kts
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
}
kotlin { jvmToolchain(17) }

val repoRoot: File = rootProject.projectDir.parentFile
tasks.test {
    systemProperty("pdsh.repo.root", repoRoot.absolutePath) // golden files from disk
    useJUnit()
}

dependencies {
    api(project(":core"))                       // JsonValue + coroutines
    implementation(libs.bouncycastle.bcprov)    // Ed25519/X25519/ChaCha20-Poly1305/HKDF
    implementation("io.ktor:ktor-client-core:3.2.3")
    implementation("io.ktor:ktor-client-cio:3.2.3")
    implementation("io.ktor:ktor-client-websockets:3.2.3")
    testImplementation(libs.junit)
}
```

C0 also adds `include(":pclink")` to `android/settings.gradle.kts` (next to
`include(":core")`/`include(":net")`, lines 55–56), adds `"pclink"` to
`EXPECTED_MODULES` (`android/tools/structure_check.py:47-61`), and adds the
module-map row:

```json
{"swift":"PhoneDSHPCLink","kotlin":"com.phonedsh.pclink","gradle":":pclink","status":"target"}
```

plus the `android/README.md` row (`PhoneDSHPCLink | com.phonedsh.pclink | :pclink | target`).
The README table is 16/16 today (`android/README.md:141`); after the row it is
17/17, and the module inventory is 14. The owner must update the prose numbers
(`android/README.md:5`, `:123`, `:141`) in the same change; the checker compares
data, not prose, but stale prose is a review defect.

### 2.4 Why not an existing module

| Candidate | Problem |
| --- | --- |
| `:net` | Maps `PhoneDSHLoopback` + `PhoneDSHGateway`, P05 owns `android/net/src/main/**` (`spec/README.md:108` trigger table). A P28 file there would trigger P05 on every PCLink change and put relay crypto in the gateway module. |
| `:dsh` | Maps `PhoneDSH` (host) and P14's `DshTurnClient`; PCLink is a *client* transport, not the phone host. Its `build.gradle.kts` also carries the host's Android deps. |
| `:core` | Maps wire/log/agentcore; PCLink's Ktor + BC dependencies would leak into every consumer of the AAR (via `:lib`'s `api(project(":dsh"))` graph). |
| `:app` only | No JVM test module, no reusable protocol surface, and the `:app` build already has the JNI/Worker/proot packaging complexities (`android/app/build.gradle.kts:1-200`). C1–C4 must be host-JVM testable. |

---

## 3. Swift file → Kotlin file mapping

`Sources/PhoneDSHPCLink/**` is 7,687 lines (measured with `wc -l`); tests are
3,938 lines. The Kotlin port is not a line-by-line translation; the table names
the owner of each file so the checkpoints stay disjoint. LOC are estimates for
planning, not acceptance.

| Swift file (lines) | Kotlin file(s) under `android/pclink/src/main/kotlin/com/phonedsh/pclink/` | Checkpoint | Est. LOC | Notes |
| --- | --- | --- | --- | --- |
| `PCLinkJSON.swift` (700) | `PclinkJson.kt` | C1 | 760 | strict parser + canonical encoder; no `org.json`. |
| `PCLinkEncoding.swift` (300) | `PclinkEncoding.kt` | C1 | 320 | b64url/base32/Crockford/hex; strict canonical checks. |
| `PCLinkCrypto.swift` (376) | `PclinkCrypto.kt` | C1 | 430 | BC lightweight; all transcripts/AAD/HKDF. |
| `PCLinkWireValidation.swift` (567) | `PclinkWireValidation.kt` | C1 | 600 | closed relay/inner/handshake/pairing/admin shapes. |
| `PCLinkLimits.swift` (33) | `PclinkLimits.kt` | C1 | 45 | constants from §3.5/§5.4/§6.2. |
| `PCLinkErrors.swift` (220) | `PclinkErrors.kt` | C1 | 250 | §9.1 vocabulary + DSH mapping seam. |
| `PCLinkEndpoints.swift` (115) | `PclinkEndpoints.kt` | C1 | 130 | embedded 57-row table; test re-reads `endpoints.json`. |
| `PCLinkValidation.swift` (301) | `PclinkValidation.kt` | C1 | 320 | name/NFC/Cf, origin, ids, SemVer, timestamps. |
| `PCLinkIdentity.swift` (136) | `PclinkIdentity.kt` | C1 | 90 | interface only; Android adapter is in `:app`. |
| (no Swift file) | `PclinkSeams.kt` | C1 | 80 | `PclinkRelayLink`/`PclinkRelayLinkFactory`; keeps C2/C3 parallel. |
| `PCLinkPairing.swift` (437) | `PclinkQr.kt` + `PclinkPairing.kt` | C2 | 280 + 380 | QR/manual parse; pair.hello/auth/confirm/final MACs. |
| `PCLinkPairingStore.swift` (302) | `PclinkPairingStore.kt` | C2 | 280 | phone record, stale-identity check, atomic file. |
| `PCLinkE2E.swift` (668) | `PclinkE2e.kt` | C2 | 720 | handshake, keys, AEAD, seq, rekey, reject verification. |
| `PCLinkClient.swift` (2,604) | `PclinkClient.kt` (state/lifecycle/pairing) + `PclinkHandshake.kt` | C2 | 1,300 + 350 | C4 plugs RPC through an interface; no C2→C4 compile edge. |
| `PCLinkRelayClient.swift` (730) | `PclinkWebSocket.kt` + `PclinkRelayClient.kt` | C3 | 170 + 760 | `PclinkWebSocket` is the injectable seam (Ktor in `:pclink`). |
| `PCLinkPacing.swift` (65) | `PclinkPacer.kt` | C3 | 90 | token bucket, monotonic clock, overdraw. |
| `RelayDSHTransport.swift` (133) | `PclinkRpc.kt` + `PclinkDshTransport.kt` | C4 | 700 + 200 | calls/streams/chunk/mux; DSH adapter returns `JsonValue`. |
| (no Swift file) | `PclinkPresence.kt` | C4 | 130 | three-state reachability from PC-ANDROID §2.1.5. |
| (no Swift file) | `PclinkRosterCache.kt` | C4 | 280 | P18 PC list/transcript cache; see §5.3. |
| — | **main total** | — | **≈9,100** | — |
| `Tests/PhoneDSHPCLinkTests/*.swift` (3,938) | `android/pclink/src/test/kotlin/com/phonedsh/pclink/*.kt` | C1–C4 | ≈4,000 | table in §7.2. |
| App-side Swift (≈3,000) | `android/lib/.../page/*.kt` + `android/app/.../pc/*.kt` | C5 | ≈2,300 | §6 C5. |

**Deliberate differences from the Swift shape**

1. `PclinkClient.kt` is split from `PclinkRpc.kt`; Swift keeps both in one
   2,604-line actor. The split is what makes C2 and C4 disjoint.
2. `PclinkWebSocket` is a Kotlin interface with `sendText`, `incoming`, `close`;
   Swift's `PCLinkWebSocket` has `send`/`receive`/`close`
   (`Sources/PhoneDSHPCLink/PCLinkRelayClient.swift:14-18`). The Kotlin shape allows one reader loop
   instead of a per-call `receive`.
3. `PclinkIdentityStore` is an interface in `:pclink`; the Android implementation
   is `:app` (`SecureStorePclinkIdentityStore`), not in `:pclink`. Swift puts the
   Keychain store in the library (`Sources/PhoneDSHPCLink/PCLinkIdentity.swift:71-136`); Android cannot,
   because `:pclink` must stay JVM.

---

## 4. Crypto, encoding and JSON choices

### 4.1 Provider decision (per AGENTS.md §6)

**Use Bouncy Castle 1.86 lightweight API, `org.bouncycastle.crypto.*`, no JCA
provider registration.** Justification:

- `minSdk = 26` (`android/app/build.gradle.kts:435`). Android's platform
  `KeyAgreement`/`KeyFactory` has no X25519/Ed25519 guarantee at 26; ChaCha20-
  Poly1305 `Cipher` is API 28+. A JCA path would need feature detection plus a
  fallback, i.e. two implementations of the same bytes.
- `bcprov-jdk18on:1.86` is already pinned (`android/gradle/libs.versions.toml:17,28`)
  and already compiled into `:app` for SSH (`android/app/build.gradle.kts:666`;
  `android/README.md:157` PhoneDSHSSH row). Reusing it adds **no new dependency
  family**; the change is moving the catalog edge to `:pclink`.
- The lightweight API does not touch `Security.addProvider`, so the app's global
  JCA provider list is unchanged; Android's built-in `BC`/Conscrypt provider
  cannot shadow `org.bouncycastle.crypto.*` classes.
- BC 1.86 is a Java 8+ artifact; the project compiles with JDK 17
  (`android/app/build.gradle.kts` `compileOptions`/`kotlinOptions`) and Android
  D8 desugars it. `:app` already ships it, so packaging is proven.

**Not chosen:** Tink (new dependency + key-management surface), libsodium/JNI
(new native artifact, ABI/16 KB burden), platform JCA (see above), a hand-written
Ed25519/X25519 (unacceptable side-channel/maintenance risk).

### 4.2 Primitive → BC class → golden section

| Primitive | BC lightweight class | Golden section / test |
| --- | --- | --- |
| SHA-256 | `SHA256Digest` | `identities`, `canonical_json`, `handshake.transcripts` |
| HMAC-SHA-256 | `HMac(SHA256Digest())` | `pairing.*.mac`, `handshake.confirmations` |
| HKDF-SHA-256 | `HKDFBytesGenerator(SHA256Digest())` + `HKDFParameters` | `pairing.pair_key_*`, `handshake.keys` |
| Ed25519 public from seed | `Ed25519PrivateKeyParameters(seed, 0).generatePublicKey()` | `identities.*` |
| Ed25519 sign/verify | `Ed25519Signer` | `relay_auth`, `handshake.*.sig`, `invalid` reject rows |
| X25519 keypair | `X25519PrivateKeyParameters(SecureRandom())` | `handshake.phone_eph/pc_eph` |
| X25519 shared secret | `X25519Agreement` + `X25519PublicKeyParameters` | `handshake.dh_hex`, `invalid` all-zero rows |
| ChaCha20-Poly1305 | `ChaCha20Poly1305` + `AEADParameters(KeyParameter, 128, nonce, aad)` | `frames`, `chunking`, AEAD invalid rows |
| Constant-time compare | `org.bouncycastle.util.Arrays.constantTimeAreEqual` | MAC/tag/confirm comparisons |
| CSPRNG | `java.security.SecureRandom` | nonces/sid/ephemeral seeds |

**Exact byte rules** (must be literals in code, not derived):

- Nonce: `00000000 || u64be(seq)` (`spec/pclink/v1/README.md:1273-1275`).
- AAD: `"pclink-v1/aad" || 0x00 || "1" || 0x00 || "e2e" || 0x00 || sid_b64url
  || 0x00 || decimal(seq) || 0x00 || from || 0x00 || to` (`:1294-1300`).
- Relay auth transcript: `"pclink-v1/relay-auth" || 0x00 || UTF8(relay) || 0x00
  || nonce_raw_32` (`:404-409`).
- Handshake transcripts: `T_init`, `T_resp`, `T_confirm` exactly as
  `:1192-1207`; `salt = th2`; four HKDF info strings
  `"pclink-v1/key/phone->pc"`, `"pclink-v1/key/pc->phone"`,
  `"pclink-v1/key-confirm/phone->pc"`, `"pclink-v1/key-confirm/pc->phone"`
  (`:1237-1241`).
- Pair MAC: `HMAC-SHA256(pair_key, UTF8(domain) || 0x00 || canonical_json(obj
  without mac))`; domains `pclink-v1/pair-hello|pair-auth|pair-confirm|pair-final`
  (`:799-804`).
- Rendezvous: `b64url(sha256("pclink-v1/pair" || 0x00 || UTF8(origin) || 0x00 ||
  X))[0:22]` (`:716-719`).
- `machineId`: `lower(base32_nopad(sha256(E)))[0:26]` (`:214-222`).

**All-zero DH:** BC returns 32 zero bytes for low-order points; check
`constantTimeAreEqual(dh, ByteArray(32))` and throw `auth_failed` before any key
derivation (`spec:1221-1227`). Do not rely on BC to throw.

**Key lifetime:** keep seed/eph private bytes in `ByteArray`; fill with zero in
`finally` where the JVM allows. BC key objects do not expose a portable
`destroy()`; do not log key material, and never put it in a `data class`
`toString`. This is best-effort zeroization, not a claim.

### 4.3 Encoding

Implement the decoders exactly like `Sources/PhoneDSHPCLink/PCLinkEncoding.swift:27-299`:

- `b64url`: alphabet `A-Za-z0-9-_`, **no** padding, exact expected decoded
  length, and canonical re-encode check (unused low bits of the last character
  must be zero). Reject `=`, `+`, `/`, whitespace, non-ASCII.
- `base32_nopad`: RFC 4648 `A-Z2-7`, used only for `machineId`; lowercase output.
- Crockford: uppercase, remove `-`, spaces and all whitespace, `O→0`, `I/L→1`,
  reject `U` and every other non-alphabet character; exactly 16 chars → 10 bytes;
  display as `XXXX-XXXX-XXXX-XXXX` (`spec:664-680`).
- hex: lowercase output; `*_hex` vectors are lowercase (`spec:195-196`).
- Random: 16-byte `sid`, 32-byte nonces, 16-byte S, 10-byte C, 32-byte seed.
  `ByteArray(n).also(SecureRandom()::nextBytes)`.

### 4.4 Strict JSON (the part `org.json` cannot do)

`PclinkJson.kt` must be a **custom** parser/encoder, mirroring
`Sources/PhoneDSHPCLink/PCLinkJSON.swift:237-700`:

- Root exactly one object; no BOM; no literal `0x00` byte anywhere; UTF-8 only;
  no trailing bytes.
- Duplicate member names at any depth rejected by decoded scalar sequence
  (`"a"` and `"\u0061"` are the same key) (`spec:271-274`).
- Reject `NaN`, `Infinity`, non-finite, unpaired surrogates, non-object roots.
- A legal `\u0000` escape inside a **DSH passthrough** string is accepted and
  preserved; a `U+0000` in a PCLink-owned field is rejected by that field's rule
  (`spec:275-307`). This is the `pclink-v1.3` boundary; the test table is
  `json_boundary` in the vectors.
- Canonical JSON: object keys sorted by **Unicode scalar / UTF-8 byte** order,
  not Kotlin `String.compareTo` (UTF-16 code units); `"` and `\` escaped;
  `U+0000` always lowercase `\u0000`; `U+0001`–`U+001F` short forms where
  defined; `/` literal; non-ASCII literal UTF-8 (`spec:309-333`).
- Number handling: parse integers into `Long`; reject `1.0`, leading zeros,
  exponent notation for `seq`/`part`/`port` (`spec:197-199`). The largest wire
  value is `seq` < 2^20, so `Long` is sufficient; do not use `Double`.
- Unknown members of a PCLink object/type/error code are `bad_frame`; unknown
  DSH error codes are passed through (`spec:280-285, 1899-1902`).

**Why not kotlinx.serialization/Moshi:** they do not reject duplicate keys at
parse time by default, do not preserve arbitrary JSON numbers as exact integers,
and do not produce the canonical form required by the pairing MAC. The iOS module
has the same custom parser for the same reason.

### 4.5 How the shared vectors run through the real codec (JVM)

The test source set reads the repository, never a copy:

```kotlin
// android/pclink/src/test/kotlin/com/phonedsh/pclink/TestSupport.kt
object TestSupport {
    val repoRoot: Path = System.getProperty("pdsh.repo.root")?.let(Path::of)
        ?: generateSequence(Path.of("").toAbsolutePath()) { it.parent }
            .first { it.resolve("spec/pclink/v1/golden").isDirectory }
    fun vectors(): PclinkJson = PclinkJson.parseStrict(
        Files.readAllBytes(repoRoot.resolve("spec/pclink/v1/golden/pclink-v1-vectors.json")))
    fun samples(): PclinkJson = ...
}
```

`build.gradle.kts` sets `pdsh.repo.root` (same pattern as
`android/core/build.gradle.kts:30` and `android/lib/build.gradle.kts:552`).
Tests call the **production** `PclinkCrypto`, `PclinkE2eSession`,
`PclinkPairingMessage`, `PclinkRelayClient`, `PclinkRpc`; there is no
hand-written expected ciphertext. For negative rows, assert the exact
`PclinkError.code` (`auth_failed`/`bad_frame`/`replay`/…), not just "throws".

Vector section → checkpoint/test map:

| Vector section (keys) | Checkpoint | Test class | What must be driven |
| --- | --- | --- | --- |
| `identities`, `relay_auth`, `canonical_json` | C1 | `GoldenVectorCryptoTest` | `PclinkCrypto`, `PclinkEncoding`, canonical encoder |
| `json_boundary.passthrough/accepted/rejected` | C1 | `PclinkJsonBoundaryTest` | strict parser, field rules |
| `frames` (9 AEAD frames) | C1 | `GoldenVectorCryptoTest` | nonce/AAD/seal/open |
| `handshake` (`init/resp/confirm/reject/transcripts/keys/confirmations/dh`) | C2 | `GoldenVectorHandshakeTest` | `PclinkE2eSession` |
| `pairing` (`qr`, `manual`, `rendezvous*`, `pair_key*`, `hello/auth/confirm/final`, `transcript_hash`, `records`, `approval`, `audit`) | C2 | `GoldenVectorPairingTest` | QR/manual parsers, MACs, record validator |
| `chunking` (`small`, `result_chunk`, `interleave`, `threshold`, `too_large`, `cancel`, limits) | C4 | `PclinkRpcChunkingTest` | split/reassembly via `PclinkRpc` |
| `invalid` rows by `kind` | C1–C4 | per kind | exact error code |
| `resources` (`sid_cache`, `pairing_slots`, `ipv6`, `e2e_idle`, `confirm_recheck`, `unpair_abort`, `approval`, `admin_peer`) | C2/C4 | state-machine tests | counters/refusals; not cryptographic evidence |
| `endpoints.json` (57 rows) | C1 | `PclinkEndpointsTest` | embedded table equals file, row by row |

---

## 5. Persistence and platform state

### 5.1 Phone identity

- `PclinkIdentityStore` (interface in `:pclink`):
  `loadSeed(): ByteArray?`, `saveSeed(ByteArray)`, `deleteSeed()`.
- Android adapter `SecureStorePclinkIdentityStore` in
  `android/app/src/main/kotlin/com/phonedsh/probe/pc/`:
  `SecureStore.put("pclink.identity-v1", seed)` / `get`; on
  `SecureLookup.Unreadable` return a typed `identityUnreadable` and **do not**
  treat it as absent; on `Absent` generate a new seed only when there is no
  pairing record (spec §2.2, `:252-256`).
- The SPI is `com.phonedsh.platform.SecureStore`
  (`android/platform/src/main/kotlin/com/phonedsh/platform/SecureStore.kt:55-95`);
  the Android implementation is `AndroidSecureStore` (AES-GCM + AndroidKeyStore,
  `noBackupFilesDir`, atomic envelope, 3-level `SecurityLevel`). No new crypto
  code for storage is needed.
- Test with `FakeSecureStore` (pure JVM) for the adapter; the real Keystore path
  is covered by `:platform-android`'s existing instrumented tests and must be
  re-run on a device (`NOT_VERIFIED` until then).

### 5.2 Pairing record

Path: `context.filesDir/pclink/pairs.json` (internal, per-app UID; not
`noBackupFilesDir`, because the record is user-visible state and Android backup
is already disabled). Shape exactly `spec:971-982`:

```json
{"v":1,"phoneMachineId":"<26>","records":[{...}]}
```

- Exactly zero or one record; a new pairing is blocked while one exists (spec
  §4.6, `:973-980`). A stale `phoneMachineId` makes the record unusable but
  preserves it for inspection; the UI requires re-pair.
- Android atomic write: temp file in `pclink/`, `FileOutputStream.fd.sync()`,
  `Files.move(..., ATOMIC_MOVE, REPLACE_EXISTING)`, then fsync the directory
  (`FileChannel.open(dir, READ).force(true)`). Mirror `AtomicFile` in
  `Sources/PhoneDSHPCLink/PCLinkPairingStore.swift:251-300`.
- File mode 0600 has no direct Android equivalent inside the app sandbox; use
  `File.setReadable(false, false)`/`setWritable(false, false)` then owner-only
  `setReadable(true, true)`, and document that the UID sandbox is the real
  boundary. Do not claim POSIX 0600 on all filesystems.

### 5.3 P18 keys (Android)

Use the existing `PreferenceFile` seam, not a new store. The P18 key names and
value domains are protocol; the Android paths are what the P18 owner must add.

| Key | Value | Where |
| --- | --- | --- |
| `phone-dsh.drawer.backend` | `"phone"` \| `"pc"`, default `"phone"` | `PreferenceFile` (`android/app/src/main/kotlin/com/phonedsh/probe/PreferenceStore.kt:213-243`) |
| `chat.dsh.currentSession.<scope>` | session id, scope `phone` \| `pc:<machineId>` | `:domain` `ChatSessionStore` (`CURRENT_SESSION_ID_KEY = "chat.dsh.currentSessionID"`, `ChatSessionStore.kt:468`), extended with the scope; **not** a second preference and **not** the bare key |
| `phone-dsh.pc.last-workspace.<machineId>` | DSH `workspaceId` string; absent/stale falls back to recent workspace | `PreferenceFile` |
| `phone-dsh.pc.session-snapshot.<machineId>` | `{"v":1,"capturedAtMilliseconds","backend","payload"}`; `payload` is Android's `PcRosterSnapshot` (id/title/time/running/cwd/parent/search/workspace grouping/pinned/archived; **no** pending approvals/queue/stream/tool output/key) | `PreferenceFile` (small) or a JSON file for larger snapshots |
| `Documents/transcript-snapshots/<scope>/<sessionID>.json` (Android: `filesDir/transcript-snapshots/...`) | `{"v":1,"capturedAtMilliseconds","backend","sessionID","lastSeq","items"}`, caps 400 items / 512 KiB / 4096 chars per item / title 256, keep 200 files, current file protected | file store in `:app` |
| `pclink-diag.log` (+`.1`) | 256 KiB each, status/reason class/gap seconds only; no titles/messages/keys/fingerprints | `:app` |

Rules copied from the P18 freeze: read envelope first, then legacy bare array;
unknown `v`, scope/session mismatch, bad bytes → ignore, never clear the current
list; write only after a successful `session/list`; empty snapshot not written;
unpair deletes only that `pc:<machineId>` scope (`PC-20261110-pclink-pc-roster-snapshot.md`
§2, `PC-20261110-pclink-workspace-cache.md` §2). Android has no pre-PCLink data
to migrate, so there is **no** Android bare-key migration; a new install starts
at `phone`.

### 5.4 Presence / cached list

`PclinkPresence` (C4) is a pure state machine over the client's connection
events and a monotonic clock:

- `Online` when an established E2E session exists.
- `Reconnecting` while dialing/handshaking **or** within 8 s of a drop with a
  retry in flight (value from `PC-20261110-pclink-workspace-cache.md` §2; if the
  owner keeps 8 s out of P28, it is still the P09 value).
- `Offline` after one dial failed or the grace expired.
- `longOffline` after 10 minutes of failed reconnects or when the connection
  screen is opened while offline; the exact sentence is `spec:1969-1977`.

The drawer uses `PclinkDrawerPolicy`:
`phase(selected, hasRecord, presence)`, `showsStateCard(phase, pcRowCount)`
(**pcRowCount only**), `cachedListNote(presence, capturedAt, hasRows)`,
`listState(isLoading, error, sessionCount)` and the workspace grouping rule
(membership → longest cwd prefix → 未分组). The Swift reference is
`examples/probe-app/ProbeKit/Backends/PCWorkspaceBackend.swift:656-750`; the
Android port is a pure Kotlin object in `:lib` (C5) so it is Robolectric-testable
without the client.

---

## 6. Checkpoints

The checkpoints are ordered by dependency, not by calendar. With two workers,
C2 and C3 can run in parallel after C1; C4 starts once C2's `PclinkE2eSession`
and `PclinkRpcHost` interfaces are frozen; C5 starts once C2+C4 expose the state
the pages need. C0 must land before C1 (module/registration).

### C0 — Register `:pclink` (P12/P08 owner, 0.5 day)

**Owned paths (only these):**

- `android/settings.gradle.kts`
- `android/pclink/build.gradle.kts` (new)
- `android/pclink/src/main/kotlin/com/phonedsh/pclink/PackageMarker.kt` (new, one
  package line + comment; no logic)
- `android/pclink/src/test/kotlin/com/phonedsh/pclink/PackageMarkerTest.kt`
  (new; one real assertion so the module has a test)
- `spec/platform/android-module-map.json` (P12 owns the spec file)
- `android/README.md` (mapping row + module count/prose)
- `android/tools/structure_check.py` (`EXPECTED_MODULES`; `:47-61`)
- `android/tools/test_structure_check.py` (if it pins the inventory)

**Do not touch:** `:lib`, `:app`, `spec/pclink/**`.

**Acceptance commands:**

```sh
python3 android/tools/structure_check.py --root .
python3 -m unittest discover -s android/tools -p 'test_*.py'
bash android/tools/with-android-toolchain.sh ./gradlew :pclink:test --no-daemon
```

Expected: structure checks pass except the **pre-existing** `readme-map` red
(`unregistered Sources modules: PhoneDSHBot, PhoneDSHPCLink, PhoneDSHVenus` —
this C0 fixes the PCLink one, so after C0 the message should name only
`PhoneDSHBot, PhoneDSHVenus`; the gate still exits 1 because of them. That is the
known pre-existing red from `docs/parity/lessons.md` §3, not a C0 failure).
`:pclink:test` PASS (one test).

**Goldens:** none (structural).

**Exit criteria:** `:pclink` is in the Gradle graph and module map; the package
directory matches the module map; no P28 code yet.

---

### C1 — Frames, encoding, auth, strict JSON and all shared vectors (worker A, 3 days)

**Owned paths:**

```text
android/pclink/src/main/kotlin/com/phonedsh/pclink/
  PclinkJson.kt
  PclinkEncoding.kt
  PclinkCrypto.kt
  PclinkWireValidation.kt
  PclinkLimits.kt
  PclinkErrors.kt
  PclinkEndpoints.kt
  PclinkValidation.kt
  PclinkIdentity.kt
  PclinkSeams.kt
android/pclink/src/test/kotlin/com/phonedsh/pclink/
  TestSupport.kt
  GoldenVectorCryptoTest.kt
  GoldenSchemaSampleTest.kt
  PclinkJsonBoundaryTest.kt
  PclinkEndpointsTest.kt
  PclinkEncodingTest.kt
```

**Goldens it must pass:**

- `spec/pclink/v1/golden/pclink-v1-vectors.json`:
  `identities`, `relay_auth`, `canonical_json` (3 cases), `json_boundary`
  (6 accepted / 8 rejected), `frames` (9), and every `invalid` row whose
  `kind` is `aead`, `canonical`, `encoding`, `name`, `origin`, `frame`,
  `handshake_signature`, `handshake_transcript`, `x25519`, `suite`, `caps`,
  `fingerprint` (the crypto rows; the state-machine rows are C2/C4).
- `spec/pclink/v1/golden/schema-samples.json`: the relay/inner/handshake shapes
  it validates (`valid`/`invalid` pairs for `inner-message`, `e2e-frame`,
  `e2e-handshake`, `relay-*`).
- `spec/pclink/v1/endpoints.json`: the embedded 57-row table equals the file
  row by row, including `kind`/`retry`/`phoneOnly`.

**Acceptance:**

```sh
bash android/tools/with-android-toolchain.sh ./gradlew :pclink:test \
  --tests 'com.phonedsh.pclink.GoldenVectorCryptoTest' \
  --tests 'com.phonedsh.pclink.GoldenSchemaSampleTest' \
  --tests 'com.phonedsh.pclink.PclinkJsonBoundaryTest' \
  --tests 'com.phonedsh.pclink.PclinkEndpointsTest' \
  --tests 'com.phonedsh.pclink.PclinkEncodingTest' --no-daemon
node spec/pclink/v1/tools/vectors.mjs --check
python3 spec/pclink/v1/tools/check_samples.py --root .
```

Expected: all tests PASS; `vectors.mjs` prints the 12-section/56-crypto/26-model
summary; `check_samples.py` prints 19 schemas/33 valid/33 invalid/57 endpoints.
Any mismatch in canonical JSON is a **blocker**: do not "fix" the vector.

**Size:** ≈2,680 main + ≈1,100 test LOC.

**Definition of done:** no C2/C3/C4 class referenced; all crypto functions have a
vector test; `PclinkEndpoints` has the "unknown endpoint → unsafe, still forwarded"
rule (`spec:1646-1648`).

---

### C2 — Pairing/QR + E2E handshake/AEAD/rekey/replay (worker B, 4 days)

**Owned paths:**

```text
android/pclink/src/main/kotlin/com/phonedsh/pclink/
  PclinkQr.kt
  PclinkPairing.kt
  PclinkPairingStore.kt
  PclinkE2e.kt
  PclinkHandshake.kt
  PclinkClient.kt          # state/lifecycle/pairing only; RPC is C4
android/pclink/src/test/kotlin/com/phonedsh/pclink/
  GoldenVectorHandshakeTest.kt
  GoldenVectorPairingTest.kt
  PclinkPairingFlowTest.kt
  PclinkPersistenceAndLimitsTest.kt
  FakePc.kt
  FakeRelayLink.kt
```

C2 defines one seam and consumes another so it does not depend on C3/C4:

```kotlin
// PclinkSeams.kt (C1) — C3 implements it; C2's tests use a fake
interface PclinkRelayLink {
    suspend fun send(frame: PclinkJson)
    val incoming: Flow<PclinkJson>
    suspend fun close(code: Int, reason: String)
}
interface PclinkRelayLinkFactory { suspend fun connect(url: String): PclinkRelayLink }

// PclinkClient.kt (C2) — C4 implements it; C5 assigns it
interface PclinkRpcHost {
    suspend fun sendInner(inner: PclinkJson)
    fun activeSession(): PclinkE2eSession?
}
```

**Goldens it must pass:**

- `pairing` section: `qr`, `manual` (display/canonical/input/equivalents/
  normalized/secret_hex/rendezvous/pair_key/hello/auth/confirm/final/
  transcript_hash), `rendezvous_s`, `rendezvous_s_other_origin`, `pair_key_s`,
  `hello/auth/confirm/final`, `transcript_hash`, `records`, `approval`, `audit`.
- `handshake` section: `init`, `resp`, `confirm`, `reject`, `transcripts`
  (init/resp/confirm/reject), `dh_hex`, `keys` (4), `confirmations` (2).
- `invalid` rows of `kind`: `qr`, `manual`, `pair_mac`, `handshake_signature`,
  `handshake_transcript`, `x25519`, `aead`, `seq`, `reject`, `reject_transcript`,
  `cross_sid`, `record`, `approval`, `pairing_lookup`, `sid_mismatch`,
  `first_frame`, `slot`.
- `golden/schema-samples.json`: `pairing-record`, `phone-pairing-record`,
  `pairing-message`, `e2e-handshake`, `session.reject` samples.

**Acceptance:**

```sh
bash android/tools/with-android-toolchain.sh ./gradlew :pclink:test \
  --tests 'com.phonedsh.pclink.GoldenVectorHandshakeTest' \
  --tests 'com.phonedsh.pclink.GoldenVectorPairingTest' \
  --tests 'com.phonedsh.pclink.PclinkPairingFlowTest' \
  --tests 'com.phonedsh.pclink.PclinkPersistenceAndLimitsTest' --no-daemon
```

Expected PASS, including:

- QR pin: `pair.hello.publicKey == k` before any record write
  (`spec:702-704`); mismatch `auth_failed`.
- `machineId` derived from every received public key and compared with the
  message (`spec:239-243`).
- Automatic approval: the phone sends `pair.auth` then waits for `pair.confirm`;
  it MUST NOT show a fingerprint card (CCR-1; see PC-ANDROID §2.3).
- `pair.final` only after the record is durably written (`spec:901-905`).
- AEAD open failure → `auth_failed`, seq gap → `bad_frame`, seq <= last →
  `replay` (`spec:1273-1278`, `spec:1302-1307`; `PC-20261110-pclink-ios-app.md` §4.9.1 item 16).
- Rekey at 2^19/1 GiB soft, 2^20/2 GiB hard (`spec:1283-1292`); fresh ephemeral
  for every handshake (`spec:1221-1227`).
- Signed PC reject verification (`spec:1166-1184`); a bad/absent sig never
  deletes the record.

**Size:** ≈3,000 main + ≈1,200 test LOC.

**Definition of done:** C2's tests use `PclinkRelayLink` (C1 interface) with a fake + `FakePc` and pass without C3/C4; `PclinkClient` compiles with a `PclinkRpcHost?` that is null.

---

### C3 — Relay transport, auth, heartbeats, pacing (worker C, 3 days)

**Owned paths:**

```text
android/pclink/src/main/kotlin/com/phonedsh/pclink/
  PclinkWebSocket.kt       # injectable seam + Ktor implementation
  PclinkRelayClient.kt     # challenge/auth/ready/allow/offline/error/replacement
  PclinkPacer.kt
android/pclink/src/test/kotlin/com/phonedsh/pclink/
  PclinkRelayClientTest.kt
  PclinkPacingTest.kt
  FakeWebSocket.kt
```

**Goldens it must pass:**

- `relay_auth` (origin/nonce/transcript/phone+pc signatures).
- `frames` outer shapes (relay frame grammar).
- `invalid` rows of `kind`: `origin`, `replay`, `unknown_code`, `frame`, `size`,
  `slot`, `slots`, `idle`, and the relay-auth signature negatives.
- Pacing constants: `chunking.seq_rekey/seq_max/byte_rekey/byte_hard` and the
  §3.8 reference 0.9 MiB/s / 3.5 MiB burst (`spec:603-616`).

**Acceptance:**

```sh
bash android/tools/with-android-toolchain.sh ./gradlew :pclink:test \
  --tests 'com.phonedsh.pclink.PclinkRelayClientTest' \
  --tests 'com.phonedsh.pclink.PclinkPacingTest' --no-daemon
```

Expected PASS, including:

- Challenge origin equality with the dialed/QR origin, lowercase-only
  (`spec:373-378`); uppercase origin rejected.
- 10 s auth deadline; `relay.ready` machineId/role mismatch closes.
- Heartbeat 20–30 s (reference 25 s ±5 s), two missed pongs close; pongs for
  old nonces ignored (`spec:488-493`).
- Reconnect 0.5/1/2/4/8/16/30/30 s ±20 %, reset after 60 s; foreground resume
  caps at 1 s (`spec:1930-1940`); `replaced` waits ≥30 s.
- `relay.allow` only from `role:"pc"`; Android never sends it.
- `rate_limited` invalidates established sessions, sends best-effort
  `session.close{code:"rate_limited"}`, waits `retryAfterMs` (`spec:629-661`).
- Pacer queues (never drops/coalesces/reorders), single writer, overdrafts a
  frame larger than the burst (`spec:598-627`).

**Size:** ≈1,000 main + ≈700 test LOC.

**Definition of done:** relay client passes with `FakeWebSocket`; no E2E/RPC
class referenced.

---

### C4 — `workspace/1` endpoints, chunks, transport adapter, roster/presence (worker D, 4 days)

**Owned paths:**

```text
android/pclink/src/main/kotlin/com/phonedsh/pclink/
  PclinkRpc.kt             # rpc.call/result/result.chunk/stream.*/cancel
  PclinkDshTransport.kt    # JsonValue <-> PclinkJson; call()/openMux()
  PclinkPresence.kt
  PclinkRosterCache.kt
android/pclink/src/test/kotlin/com/phonedsh/pclink/
  PclinkRpcChunkingTest.kt
  PclinkDshTransportTest.kt
  PclinkRosterCacheTest.kt
  PclinkPresenceTest.kt
  FakePcSession.kt
```

**Goldens it must pass:**

- `chunking` section: `small`, `result_chunk`, `interleave`, `threshold`,
  `too_large`, `cancel`, limits.
- `invalid` rows of `kind`: `chunk`, `seq`, `cross_sid`, `first_frame`,
  `frame` (RPC-related), `idle` (receiver timeout), `forbidden_endpoint`.
- `endpoints.json`: retry classification `read`/`idempotent`/`unsafe`; unknown
  endpoint → `unsafe` but forwarded; the 57-row inventory is the only table (no allowlist).
- `resources.confirm_recheck` / `unpair_abort` state rows for the transport
  teardown.

**Acceptance:**

```sh
bash android/tools/with-android-toolchain.sh ./gradlew :pclink:test \
  --tests 'com.phonedsh.pclink.PclinkRpcChunkingTest' \
  --tests 'com.phonedsh.pclink.PclinkDshTransportTest' \
  --tests 'com.phonedsh.pclink.PclinkRosterCacheTest' \
  --tests 'com.phonedsh.pclink.PclinkPresenceTest' --no-daemon
```

Expected PASS, including:

- Unary call: `rpc.call` → `rpc.result`, `id` uniqueness in flight, duplicate id
  answer `bad_frame` and no execution (`spec:1469-1472`).
- Chunked result: entire `rpc.result` JSON > 1 MiB; `id` matches; 30 s
  inactivity from the **last** chunk; partial discarded; §7 class applied
  (`spec:1583-1607`).
- Streams: one in-flight item/chunk per stream; `rpc.stream.cancel` waits for
  iterator return ≤30 s; late items discarded (`spec:1537-1583`).
- `$events/result` args exactly `{clientId,eventId,outcome}`, one layer
  (`spec:1527-1535`).
- `pclink.admin/` prefix → `forbidden`, never forwarded; the authoritative gate
  is source Peer on the PC (client just doesn't send it).
- Unknown DSH code → display `unavailable` with original message, session stays.
- Roster cache round-trip: envelope/bare/unknown version/bad bytes/limits;
  no pending approvals/queue/stream content; unpair removes only the PC scope.

**Size:** ≈1,900 main + ≈1,000 test LOC.

**Definition of done:** `PclinkDshTransport` can be driven by `FakePcSession`
(the real `PclinkE2eSession` + a fake relay); no Compose/Android import.

---

### C5 — Pages, drawer, settings row, App wiring (worker E, 5 days)

**Owned paths:**

```text
android/lib/src/main/kotlin/com/phonedsh/ui/page/PCPairingPage.kt        # exact `fun PCPairingPage(`
android/lib/src/main/kotlin/com/phonedsh/ui/page/ConnectedComputerPage.kt # exact `fun ConnectedComputerPage(`
android/lib/src/main/kotlin/com/phonedsh/ui/page/PcLinkUiState.kt        # plain state/callbacks
android/lib/src/main/kotlin/com/phonedsh/ui/nav/PcDrawer.kt              # segment + state card + cached note
android/lib/src/main/kotlin/com/phonedsh/ui/nav/HomeDrawer.kt            # insert PcDrawer below 新会话 (~:510)
android/lib/src/main/kotlin/com/phonedsh/ui/page/SettingsPage.kt         # 已连接的电脑 row
android/lib/src/main/kotlin/com/phonedsh/ui/UiStrings.kt                 # zh/en copy
android/lib/src/test/kotlin/com/phonedsh/ui/page/PCPairingPageTest.kt
android/lib/src/test/kotlin/com/phonedsh/ui/page/ConnectedComputerPageTest.kt
android/lib/src/test/kotlin/com/phonedsh/ui/nav/PcDrawerTest.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/PcLinkWorkspace.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/PcWorkspaceController.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/PcChatTurnRunner.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/PcWorkspaceStorage.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/PcDiagnosticsLog.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/SecureStorePclinkIdentityStore.kt
android/app/src/main/kotlin/com/phonedsh/probe/pc/PcQrScanner.kt
android/app/src/main/AndroidManifest.xml                                 # CAMERA permission + feature
android/app/build.gradle.kts                                             # camera/zxing deps
android/app/src/main/kotlin/com/phonedsh/probe/ProbeEngineViewModel.kt   # minimal backend seam only
android/app/src/main/kotlin/com/phonedsh/probe/MainActivity.kt           # CAMERA runtime request only
```

**Page contracts it must satisfy:**

- `spec/ui/v1/pages/pc-pairing.json` (title `连接电脑` at `:52` of the Swift;
  sections at `:118/:128/:159/:201/:210/:224/:253/:267/:278`).
  Static labels: `在电脑终端运行：`, `扫码连接`, `扫描终端里出现的二维码`,
  `相机不可用或未授权。请允许相机，或使用「其他方式」。`,
  `其他方式`/`收起其他方式`, `配对链接`, `用链接配对`, `配对码`,
  `16 位，单次使用，5 分钟内有效。`, `手动连接`, full-owner warning,
  `正在连接电脑…`, `取消配对`, `已连接 {name}`, `完成`, `重试`.
  Actions: `扫码连接`, `其他方式`, `用链接配对`, `手动连接`, `取消配对`
  (×2), `完成`, `重试`, `关闭`, `取消`. No fingerprint card (CCR-1).
- `spec/ui/v1/pages/connected-computer.json` (title `已连接的电脑` at `:31`):
  `电脑` rows `电脑名称`/`DSH 版本`/`在线状态` + `本机` rows
  `本机指纹`/`配对方式`/`配对时间`/`中继`; actions `配对新电脑`/`解除配对`;
  empty `还没有连接电脑` + `连接电脑`; alerts `解除配对？`/
  `这台手机已经配对了一台电脑`/`解除没有完成`. DSH version comes from the
  verified `peer.hello` (C4/CCR-2), not from the record.
- `spec/ui/v1/pages/home-drawer.json` actions `手机` (`:61`) and `PC` (`:76`);
  segment below 新会话 (`examples/probe-app/PhoneDSHProbe/HomeDrawer.swift:44-48`); PC empty/unpaired/offline
  states; cached-list note; grouping by DSH workspace title; selection persists
  in `phone-dsh.drawer.backend` (P18).
- `spec/ui/v1/pages/settings.json`: the `已连接的电脑` action must be the first
  clickable row of its untitled group (contract criterion
  `examples/probe-app/PhoneDSHProbe/SettingsPage.swift:347`), with value `未配对`/`离线`/`<name>`.

**Acceptance:**

```sh
bash android/tools/with-rust-toolchain.sh cargo build --locked \
  --manifest-path shell/Cargo.toml -p pdsh-jni
bash android/tools/with-android-toolchain.sh ./gradlew \
  :lib:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug --no-daemon
python3 spec/ui/v1/tools/extract_ios_pages.py --root . --check   # P09 owner ran --write
python3 spec/ui/v1/tools/page_structure_check.py --root . \
  --baseline spec/ui/v1/pages/_baseline.json
bash scripts/ci/check.sh --only phone-android-structure,phone-android-tests
```

Expected:

- Gradle PASS; `:app:assembleDebug` PASS (missing camera deps are a build
  failure, not a skip).
- `page_structure_check` reports **FAIL (1)**, the pre-existing GAP-32(d)
  `files` `完成` row. The six GAP-35 rows must be gone:
  `home-drawer 手机`, `home-drawer PC`, `pc-pairing <android-screen>`,
  `connected-computer <android-screen>`, `settings 已连接的电脑` action +
  criterion row. The page checker does **not** need a whitelist or a baseline
  edit; the P09 owner regenerates the two page JSONs' `android` blocks with
  `extract_ios_pages.py --root .` after the Kotlin files exist.
- `:lib` tests cover the page state machines and the drawer policy; `:app` tests
  cover the identity adapter, storage, presence and the transport adapter with
  fakes.

**Size:** ≈2,300 main + ≈900 test LOC.

**Dependencies / risks:**

- Camera: Android has no QR decoder. Add `androidx.camera:camera-{core,camera2,
  lifecycle,view}` and `com.google.zxing:core` (pure Java; no Play Services).
  Justification: the iOS page uses `AVCaptureDevice`/`AVCaptureSession`
  (`examples/probe-app/PhoneDSHProbe/PCPairingPage.swift:1-20,300-380`), and Android has no equivalent built-in
  decoder. The scanner lives in `:app`, not `:lib`, so the AAR stays camera-free.
  If the camera dependency is rejected, ship paste-link + manual code first and
  keep the `扫码连接` action opening an honest "相机不可用" sheet — but that does
  not satisfy the page contract's happy path and must be recorded as a GAP.
- `ProbeEngineViewModel.kt` is a shared file; C5 rebases before touching it and
  adds only a `pcWorkspace` seam, no unrelated refactor.
- The page checker labels are Chinese; use the literal Chinese labels in the
  pages (the contract has no `labelAlternatives` for `手机`/`PC`). English copy
  can be added only where the checker resolves alternatives; otherwise it would
  report a mismatch.

---

## 7. Test strategy

### 7.1 Levels

| Level | What it proves | What it does not |
| --- | --- | --- |
| JVM unit + golden (`:pclink:test`) | codec/crypto/state machine bytes; real parser; exact error codes | Android runtime, TLS, Keystore, Doze, camera |
| Robolectric/Compose (`:lib:testDebugUnitTest`) | page state/labels/structure; drawer policy | real rendering, real device gestures |
| App JVM (`:app:testDebugUnitTest`) | storage adapter, identity adapter, presence, transport adapter with fakes | real Keystore/relay |
| Instrumented/device (`:app:connectedDebugAndroidTest`, manual E2E) | Keystore, TLS/WSS, Doze, camera, real relay+`dsh web` | — |

### 7.2 Test file map (proposed)

| Kotlin test | Mirrors Swift test | Checkpoint |
| --- | --- | --- |
| `GoldenVectorCryptoTest` | `GoldenCryptoSmokeTests`, `GoldenVectorTests` (crypto parts) | C1 |
| `PclinkJsonBoundaryTest` | `PCLinkJSONBoundaryTests` | C1 |
| `GoldenSchemaSampleTest` | `GoldenSchemaSampleTests` | C1 |
| `PclinkEndpointsTest` | (endpoint check in `GoldenVectorTests`) | C1 |
| `GoldenVectorHandshakeTest` | `GoldenVectorTests` (handshake) | C2 |
| `GoldenVectorPairingTest` | `GoldenVectorTests` (pairing) | C2 |
| `PclinkPairingFlowTest` | `PCLinkPairingFlowTests` | C2 |
| `PclinkPersistenceAndLimitsTest` | `PCLinkPersistenceAndLimitsTests` | C2 |
| `PclinkRelayClientTest` | `PCLinkRelayClientTests` | C3 |
| `PclinkPacingTest` | `PCLinkPacingTests` | C3 |
| `PclinkRpcChunkingTest` | `GoldenVectorTests` (chunking) | C4 |
| `PclinkDshTransportTest` | `RelayDSHTransportTests` | C4 |
| `PclinkRosterCacheTest` | `PCLinkWorkspaceSimTests` (cache parts, iOS app test) | C4 |
| `PclinkPresenceTest` | `PCLinkWorkspaceSimTests` (presence parts) | C4 |
| `PCPairingPageTest` | `PCLinkWorkspaceSimTests` (pairing state) | C5 |
| `ConnectedComputerPageTest` | `PCLinkWorkspaceSimTests` (connected page) | C5 |
| `PcDrawerTest` | `PCLinkWorkspaceSimTests` / `PCLinkPacingSimTests` | C5 |

### 7.3 Running the vectors

`node spec/pclink/v1/tools/vectors.mjs --check` is the spec checker, **not** a
substitute for the JVM tests; the Kotlin tests must re-read the same JSON and
drive `PclinkCrypto`/`PclinkE2eSession`. A test that only hashes the file does
not count (AGENTS.md §3.2; `spec/pclink/v1/README.md:2091-2095`).

---

## 8. Risks and open questions

1. **CCR-1 (pre-v1.6 PC pairing)** — PC-ANDROID §2.3. Until the owner rules,
   C2 implements the v1.6 happy path and a timeout+upgrade hint; no fingerprint
   card. If the owner chooses the "allow a collapsed fingerprint line" option,
   C2/C5 add exactly one row; the wire is unchanged.
2. **P09 `android.file` regeneration** — the two page JSONs currently say
   `"match":"missing"` (`spec/ui/v1/pages/pc-pairing.json:32-36`,
   `spec/ui/v1/pages/connected-computer.json:28-32`); C5 cannot make the checker green alone.
   The P09 owner runs `extract_ios_pages.py --root .` after the Kotlin pages
   exist; this is a spec change and must be committed by the owner.
3. **BC on Android** — the lightweight API is already packaged in `:app` for
   SSH, but the PCLink paths (X25519 agreement, ChaCha20-Poly1305 with 12-byte
   nonce, HKDF) are new uses. If a device/ART issue appears, the fallback is
   Tink or a JNI libsodium; both are new dependency decisions, not a local
   workaround. Do not fork the vectors to fit.
4. **Ktor CIO on Android** — TLS validation uses the JVM/Android trust store;
   verify against a real `wss://` relay. A proxy/user CA scenario may require
   OkHttp; that is a separate dependency decision.
5. **Keystore** — `AndroidSecureStore` reports `SecurityLevel` but PCLink has no
   device test for seed round-trip, lock-screen change, StrongBox fallback, or
   restore. `not-verified` platform entries stay `not-verified` until then.
6. **Doze/background** — no background receive is promised. If the product
   needs approval delivery while backgrounded, that is a P03/P08 foreground
   service change, not a PCLink wire change.
7. **No P18 shared golden** — the cache tests use the PC-20261110 cases, not a
   cross-end fixture; do not call them conformance.
8. **No real device E2E** — every Android command here is host/JVM until the
   final device run; report `NOT_RUN`/`NOT_VERIFIED` honestly.

---

## 9. Needed outside my scope

I own only the two documents. The following must be done by the named owners;
this design does not edit them.

1. **P28 contract owner** — apply PC-ANDROID §2.1.1–§2.1.8, §2.2, §4;
   resolve or reject CCR-1; update `contract_revision` and the revision log.
2. **P12 owner** — `android/settings.gradle.kts` (`include(":pclink")`),
   `android/pclink/build.gradle.kts` (from §2.3), `spec/platform/android-module-map.json`,
   `android/README.md` (17/17, 14 modules), `android/tools/structure_check.py`
   (`EXPECTED_MODULES`), `android/tools/test_structure_check.py`.
3. **P08 owner** — add the three `spec/platform/whitelist.json` entries from
   PC-ANDROID §4; fix the stale counts in `spec/platform/README.md:21,79,191`;
   run `spec/platform/tools/platform_check.py --root .`.
4. **P18 owner** — register the Android keys/paths from §5.3 (and the
   `pclink-diag.log` path) in the P18 row; add the P18 trigger paths from
   PC-ANDROID §2.1.8; decide whether the roster snapshot uses
   `PreferenceFile` or a JSON file (recommend a file for > 64 KiB); approve the
   scoped `chat.dsh.currentSession.<scope>` key in `ChatSessionStore` rather
   than a second preference authority.
5. **P09 owner** — after C5: `extract_ios_pages.py --root .` (writes the
   `android` blocks for `pc-pairing`/`connected-computer` and any `HomeDrawer`
   provenance), then `page_structure_check.py --baseline` must be **1**
   (GAP-32(d) `files` only). No whitelist/baseline growth.
6. **Android build owner** — camera/zxing dependency approval for C5
   (`android/app/build.gradle.kts`, `android/gradle/libs.versions.toml` for the
   new versions), CAMERA permission + `uses-feature` in
   `android/app/src/main/AndroidManifest.xml`; run `:app:assembleDebug`.
7. **CI** — `phone-android-tests` derives modules from `settings.gradle.kts`
   (`scripts/ci/check.sh:417-487`), so `:pclink` is picked up automatically; no
   stage change is needed if C0 lands. `phone-android-structure` must be green
   for `:pclink` (after C0; the `Bot`/`Venus` readme-map red is pre-existing).
8. **Device lab** — a real Android phone + real relay + real `dsh web`:
   QR scan, manual code, E2E handshake, `session/list`, `session/follow`,
   `session/prompt`, `$events` approval, background/foreground, Doze, Keystore
   restart, unpair. This is required before P28/GAP-35 can be called
   `implemented`/closed; simulator/JVM is not device evidence.
