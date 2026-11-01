<!-- SPDX-License-Identifier: MIT -->
# `:net` — loopback origin (D1-b lane)

One HTTP origin per App process: `127.0.0.1`, random port, per-start 128-bit token.
ordered binary WebSocket of `spec/v1/channel.md`. Pure JVM (`java-library` +
`kotlin.jvm`): no `android.*`, file access is `java.nio`.

```kotlin
val server = LoopbackServer(handler = engineChannelHandler) // :engine supplies the codec bridge
val endpoint = server.start(assetsDir)                      // Path, from the APK assets
// endpoint.port / .token / .origin / .urlFor(path) / .channelUrl() / .launchUrl(params)
server.stop()                                               // repeatable; no thread survives it
```

## Token gate

Every request needs `Authorization: Bearer <token>`; a missing or wrong token is
**401 with one constant body** (no `403`, no echo of the request, no log line —
this package installs no call logging and `LoopbackEndpoint.toString()` redacts
the token). **The only path that also accepts `?token=` is the launch page**
(`GET /` and `GET /index.html`) — the worker reads its launch token from its own
query string (`examples/probe-app/Bundle/worker/boot.js`), so that exception is
mandatory while every other path, `/channel` included, stays header-only.

`LoopbackConfiguration.allowQueryTokenOnChannel` (default **off**) widens the
query exception to the `/channel` upgrade for `:engine`: a browser
`new WebSocket(...)` cannot set a header, and the packaged worker appends the
token to its own channel URL (`worker-entry.js`, `resolveChannelUrl()` →
`resolveUrl()`). Turning it on keeps the token rule at "one path + one opted-in
upgrade"; it is not enabled by default because the requirement is header-only.

Do not install `CallLogging` on this origin: the launch page's `?token=` would
land in the access log. This package logs nothing and every 401 body is constant.

## Channel

Frames are whole binary payloads moved **unchanged and in order**; the 16-byte
header, `seq`/`mseq` and every other protocol rule belong to `:core` (A1: one
codec, in Rust). The transport rules this module does enforce:

- binary only (a text frame closes 1003), one active channel at a time
  (a second upgrade is 409, a raced one closes 1013, reconnect is accepted),
- inbound backpressure by construction: the reader does not take frame N+1
  before the handler returned for frame N, so a slow consumer closes the TCP
  window instead of filling the heap (no payload queue exists in this module),
- outbound backpressure needs an explicit `flush()` per send: Ktor 3.2.3's
  `send` alone buffered 64 MiB in 5 ms for a peer that was not reading, while
  `send` + `flush` stalls at the kernel buffer (~2 MiB) — measured, see
  `LoopbackChannelTest.outboundSendsSuspendWhenThePeerStopsReading`,
- the peer's close frame is the half-close this transport offers: exactly one
  `onClosed(CLIENT_CLOSED)`, the origin keeps serving.

## Static assets

Served from the directory passed to `start()`: `.wasm → application/wasm`,
`.js`/`.mjs → text/javascript`, `.json`/`.map → application/json`, plus
`Cache-Control: no-store` (this origin serves one boot; nothing may be cached).
Paths with `.`/`..`/`%`/backslash/NUL segments and symlinks that resolve outside
the asset root are 404.

## Ktor pin

`ktor-server-{core,cio,websockets}:3.2.3` — the newest 3.x built with Kotlin
2.1.21, so its metadata is readable by the Kotlin 2.1.0 compiler pinned in
`gradle/libs.versions.toml` (3.3.x is built with Kotlin 2.2.21 and does not
compile here). Pins live in this module's `build.gradle.kts`, not in the shared
version catalog.

## Tests

```sh
./gradlew :net:test --no-daemon --console=plain
```

**56** JUnit4 tests in `com.phonedsh.loopback`: random port and start/stop thread
hygiene, the full token matrix, media types, traversal, channel order/binary
fidelity, both backpressure directions, half-close, text/oversize/failing-handler
endings, and admission under concurrency.

The module total is **148** = 56 loopback + 92 `com.phonedsh.gateway` (60 of
those are the two assertions per golden vector × **30** vectors that
`spec/v1/tools/gateway_check.py` reports, plus rules, mutation, catalog and
HTTP egress). Counted with `bash android/tools/test-count.sh :net` after a
`--rerun-tasks` run; per-class counts come from the same XML.

## Launch cookie (D22)

The loopback origin is not a static file server: a page opened without a session is useless to the
worker, because `plugins/surface-phone` builds its `Connection` from `process.env.PDSH_DSH_LAUNCH_TOKEN`
and the browser cannot put a token on a `WebSocket`.

- `GET /?token=<launch token>` answers **303** with `Location: /` and
  `Set-Cookie: xl_launch_token=<token>; Path=/; HttpOnly; SameSite=Strict` (no `Secure`: this is
  loopback HTTP; no `Domain`: host-only). The name and attributes come from the iOS baseline
  (`Sources/PhoneDSHLoopback/LoopbackServer.swift`).
- A plain `GET /` that passes the cookie also carries it in the response, so a page reload keeps the
  session.
- The cookie is accepted **only** when the request `Host` is `127.0.0.1:<the bound port>`; anything
  else gets `403 {"error":"authority_mismatch"}` and no `Set-Cookie`.
- `/channel` accepts the cookie as well as the query token. That is an Android difference and is
  registered in `spec/platform` as `platform.loopback-cookie-auth`.
- The token never appears in a log line, an exception message, `lastError` or a response body.

