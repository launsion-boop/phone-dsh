# Security checklist — host-side threat model (P0)

Status: P0 deliverable of the Android port plan (§15, review item B14). It turns the seven
threats of §15 into checks that a gate can run. Items marked **static** are checkable in this
repository today; items marked **device** need the P2 device gate. Nothing here is implemented
Android code yet: the checklist fixes *what must be proven*, and every row names the phase that
owns the proof.

## 1. Scope and the one structural fact

On Android **any local app can connect to `127.0.0.1`**. The loopback origin is therefore not a
trust boundary by itself; the token is. That single fact drives items S1 and S2, and it is the
reason the loopback server must never treat "the request came from localhost" as authentication.

The second structural fact is the Play policy one: a WebView that loads untrusted content *and*
exposes a JavaScript interface is a named violation. The engine's JavaScript is packaged in the
app (the worker image is an asset), so the architecture is compliant today; the check exists to
keep it that way.

## 2. Checklist

| # | Threat | Required property | Verification | Kind | Owner |
|---|---|---|---|---|---|
| S1 | loopback token leak | The launch token never appears in a URL query, a cookie, a referer, a log line or a crash report. It travels in memory and in the first-frame header only. | **static**: grep the loopback request builder for token-in-query and token-in-cookie; assert the token field is a header member of the HELLO frame in `spec/v1/channel.md`; **device**: capture a full request log for a boot and assert the token appears zero times | static + device | P2 |
| S2 | unconditional local trust | The server rejects every request without a valid token, including `/` and `/v1/*`; the port is random per launch and the token rotates per launch. | **static**: the auth middleware covers all routes (a route table test that fails when a new route is added without the middleware); **device**: two consecutive launches use different ports and different tokens | static + device | P2 |
| S3 | JS bridge scope | The bridge is visible to the same-origin main frame only. Cross-origin frames and iframes cannot reach it. | **static**: the Android bridge install must gate on frame origin (`shouldInterceptRequest` / navigation allow-list) — a review item until the bridge lands; **device**: load a cross-origin iframe and assert the bridge object is undefined | static + device | P2/P3 |
| S4 | release build switches | Release builds disable WebView debugging, disable file and content access, block navigation outside the allowed origins, and never enable universal access from file URLs. | **static**: a build-variant check that fails when any of the four switches is enabled in a release configuration; **device**: inspect the running WebView flags on a release build | static + device | P2 |
| S5 | backup and device transfer | WAL segments, the materialized copy, workspace files and credential metadata never leave the device through auto backup; a restored-but-unreadable keystore fails loud on first launch. | **static**: the manifest declares backup exclusion rules that name those paths; **device**: backup and restore to a second device, assert the first launch reports the unrecoverable key instead of silently starting empty | static + device | P3 |
| S6 | keystore degradation dishonesty | A credential store that falls back from StrongBox to TEE to software encryption reports the level it actually got, in the UI, not the level it wanted. | **static**: the secure-store SPI returns a level enum, and the UI reads that enum rather than a constant; **device**: force each fallback and assert the reported level changes | static + device | P3 |
| S7 | model credentials at the worker | The worker never holds a model credential. Injection happens host-side, on the outbound request, after the worker's bytes are sealed. | **static**: `spec/v1/golden/gateway/*.json` — the credential-injection, header-strip and redirect-scope vectors must pass on both hosts; a worker-side grep for credential-shaped string handling | static | P1 |
| S8 | untrusted device input | Device and connector input is untrusted: the default tool set is empty, and every write path goes through the capability gate. | **static**: the device envelope schema (`spec/host/v1`) carries `origin`; the tool registry starts empty; **device**: a device-originated turn cannot call a write tool without an explicit grant | static + device | P6 |
| S9 | packaged JavaScript | The page's JavaScript is packaged in the app or fetched from a verifiable HTTPS origin. No dynamic JS download. | **static**: the worker image is a build asset with a recorded hash; a check that fails when the page loads a script from a non-packaged origin | static | P0/P1 |
| S10 | debugging surface | Debug bridges, remote debugging and test hooks are compiled out of release builds. | **static**: a release-configuration scan for the debug switch; **device**: a release build exposes no debugging socket | static + device | P2 |

## 3. Explicitly out of scope

- Privileged helper paths (Shizuku, root, accessibility automation) are a non-goal of the plan
  (§2 non-goals 4). No checklist item may be satisfied by them.
- Per-OEM hardening is not a security control. OEM kill behaviour is a reliability concern
  handled by the background section, not here.
- The remote handoff channel's TLS and bearer credential rules are already fixed by
  `spec/v1/handoff.md` D15 and are not restated here.

## 4. What this checklist does not claim

It does not claim any threat was *mitigated* — only that the property is now named, owned and
assigned a verification. A row moves to "verified" only with a receipt naming the command, the
build and the device. Static rows can move in P0/P1; device rows cannot move before P2, and the
plan's evidence discipline forbids substituting simulator evidence for device evidence.
