# PCLink v1 — PC plugin, CLI and shared Node core (P28)

PCLink pairs one iPhone with one PC running `dsh web`. The phone gets the DSH
owner API through the PC plugin; every end-to-end payload is encrypted and
authenticated before it reaches the untrusted relay. The frozen contract is
`spec/pclink/v1/README.md` (revision `pclink-v1.2`). This tree is the **C end**:
`dsh-pclink` (Cordis plugin), `npx pclink` CLI and the shared Node core. It has
no npm runtime dependencies beyond Node built-ins.

## One-line install (from a checkout)

```sh
node pclink/cli/bin.mjs install
```

`install` finds `dsh` (`DSH_BIN`, `PATH`, or `DSH_SOURCE`/`DSH_PIN_ROOT`),
checks the tested range `>=0.2.2-rc.1 <0.3.0`, checks the host native module
(`native/system/packages/darwin-arm64/bin/system.node` for a source checkout),
prints the plugin package SHA-256, runs
`dsh plugin --profile web add <spec>`, warns that a build-script approval may
appear, asks whether to restart `dsh web`, waits for the loopback admin API, and
starts QR pairing.

For a published/git form, set the package spec explicitly:

```sh
PCLINK_PLUGIN_SPEC='github:<owner>/<repo>#<commit>&path:/pclink' \
  node pclink/cli/bin.mjs install --spec "$PCLINK_PLUGIN_SPEC"
```

The installable package root is **`pclink/`** because it carries `core/`,
`plugin/` and `cli/`. `pclink/plugin/` also declares the same bundle; a local
`dsh plugin add /abs/path/to/pclink/plugin` works through pnpm's `link:`, while
git installs should use the `/pclink` package root above.

## Pairing and approval

Default pairing is QR only; explicit `--manual` (CLI) or `mode:"manual"` (API)
is the only way to open the 80-bit manual-code slot.

```sh
pclink pair            # QR URI (and a terminal QR if qrencode is installed)
pclink pair --manual   # XXXX-XXXX-XXXX-XXXX (Crockford, 80 bit)
pclink status
pclink unpair <name|machineId|fingerprint>
pclink unpair --all
pclink rotate-identity
```

Both paths require the compare-the-phone approval:

1. the phone reads the PC public key from the QR/manual code and displays its
   **own** `machineId[0:12]` fingerprint as `xxxx-xxxx-xxxx`;
2. the PC CLI/Web UI shows only the verified phone name and asks the operator to
   type the fingerprint from the phone screen;
3. the plugin derives the phone machineId from the verified `pair.auth` public
   key and compares it. A mismatch sends
   `relay.pair.close{reason:"auth_failed"}`, destroys the single-use slot and
   writes nothing;
4. only after `pair.final` does the PC append the `pair` audit line and replace
   `pairs.json`. A storage failure sends `relay.pair.close{reason:"storage"}`.

`pclink pair` requires a TTY. `y`/`N`, Enter, redirected stdin, `--yes` or a
non-TTY stdin never approve. The phone's own fingerprint is the only one the
operator compares; the PC never prints the pending peer's machineId,
publicKey or fingerprint while approval is pending.

The terminal QR renderer is optional: with `qrencode` on `PATH` the CLI prints
an ANSI QR, otherwise it prints the standard `pclink://pair?...` URI and says
so. The URI is the complete pairing payload and can be rendered by a future Web
UI page.

## Web UI

The plugin registers the six owner-only DSH routes required by the contract on
the normal `/api` carrier:

- `POST /api/pclink.admin/status`
- `POST /api/pclink.admin/pair`
- `POST /api/pclink.admin/pair/approve`
- `POST /api/pclink.admin/pair/cancel`
- `POST /api/pclink.admin/unpair`
- `POST /api/pclink.admin/rotate-identity`

They use the normal DSH browser/owner authentication; the browser never sees
`admin.json` or its token. The authoritative remote-admin fence is the request
**source Peer** (an `AsyncLocalStorage` marker set by the PCLink forwarder), not
the endpoint spelling; the `pclink.admin/` prefix check in the forwarder is only
a fast path. Remote PCLink `rpc.call`/`rpc.stream.open` calls get the PCLink
`forbidden` error.

**Trade-off:** a bundled front-end plugin page (QR image, persistent
new-pairing banner, revoke buttons) is deferred to a follow-up UI change. The
owner routes already expose the same operations and the status body includes a
persistent `warnings` banner entry for the most recent successful pairing; a
future page only needs to consume these routes. The CLI is the supported UI in
this phase.

## Configuration and environment

| Variable | Default | Meaning |
|---|---|---|
| `PCLINK_RELAY_URL` | `wss://relay.example.invalid` | Relay origin or `ws(s)://` URL. **The default is a placeholder; replace it before pairing.** Origin must be lowercase `https://host[:port]`, default port omitted. |
| `PCLINK_PC_NAME` | hostname | PC display name, 1–64 UTF-8 bytes, NFC, no C0/C1/Cf. |
| `DSH_HOME` | `$HOME/.dsh` | State is `$DSH_HOME/pclink/`. |
| `PCLINK_PLUGIN_SPEC` | this checkout | Package spec used by `install`. |

A still-placeholder relay is reported as a warning in admin status. The plugin
logs `unsupported-profile` and does not dial the relay when the DSH profile has
no `typertGateway`; it never starts a degraded unary-only service.

## State files

`$DSH_HOME/pclink/` is `0700`; every file is `0600` and written by atomic
replace (temp file in the same directory, fsync, rename, directory fsync):

- `identity.key` — raw 32-byte Ed25519 seed. It is never printed, logged or
  copied. Missing while pair records exist => a new identity is generated; old
  records are stale, preserved for inspection (`pairs.log` retains their
  audit) and never used. A later new pairing writes a fresh `pairs.json` under
  the new identity and does not re-adopt stale records.
- `pairs.json` — `{"v":1,"pcMachineId":"...","pairs":[record...]}`, max 1024.
- `pairs.log` — append-only NDJSON (`pair`, `unpair`, `rotate`) with
  `recordSha256` over the canonical record. Deleting it makes records unusable
  (`usable:false, reason:"unapproved"`); a later `unpair` makes them
  `revoked`. An unpair appends the tombstone and fsyncs **before** removing the
  record. If the tombstone append fails, the plugin stops its relay connection
  and stays fail-closed until the retry succeeds.
- `admin.json` — `{"v":1,"port":49152-65535,"token":"<32B b64url>"}`, replaced
  on every plugin start. The loopback server binds `127.0.0.1` only, requires
  exact `Host`, no `Origin`, JSON `Content-Type`, a constant-time Bearer token
  and the HMAC server-proof challenge before the token is sent.

## Security notes

- The phone has **full owner authority** on the PC while paired: chats, shell
  execution, file read/write, approvals, settings and plugin management. There
  is deliberately no endpoint allowlist; only the remote `pclink.admin/` call
  is forbidden.
- The relay is untrusted: it sees outer headers, machineIds, roles, pairing
  public keys/names/MACs and byte lengths, but not end-to-end plaintext.
  PCLink v1 provides no identity hiding.
- Approval is a human process, not a hardware boundary. A same-user PC process,
  a pty that bypasses the TTY check, or an agent on an already-paired phone
  with PC shell can still drive the flow. The audit log, the paired notice,
  `pairs.log` and the source-Peer admin fence raise the cost and improve
  detection.
- **Stolen or lost phone:** revoke **all** pairings, then run
  `pclink rotate-identity`. A phone-only local removal is not authoritative.
  Every phone must re-pair after rotation. A phone that is offline during
  rotation cannot learn the new machineId; it shows the long-offline hint and
  the user must remove its stale record manually.
- After a durable new pairing, the PC sends
  `pclink.notice{kind:"paired",name,fingerprint,at}` to every other established
  phone and keeps a warning banner entry in admin status. This is detection,
  not prevention.
- Replay, gap, AEAD, transcript and MAC failures close the affected session or
  handshake; the plugin validates every frame locally and never trusts the
  relay's allowlist.

## Architecture

```
core/     pure Node built-ins: canonical JSON, strict JSON reader, b64url,
          base32, machineId, Ed25519/X25519, relay auth, handshake, HKDF,
          ChaCha20-Poly1305 frames, chunking, pairing, records/audit,
          inner codecs, admin client, backoff and schema subset
plugin/   Cordis bundle (`inject=['connection']`): relay supervisor,
          pairing state machine, per-session owner Peer + shared fetch,
          unary/stream forwarding, chunking/backpressure/cancel, admin
          plane/loopback server, owner `/api/pclink.admin/*` routes
cli/      `pclink` bin: install, pair (TTY compare-the-phone), status,
          unpair, rotate-identity; prints the package SHA-256
test/     node:test suites plus a test-only relay double and phone client;
          the integration test boots the real pinned `dsh web`
```

The plugin opens one owner `interactions:'answer'` Peer per E2E session and
forwards unary calls through `createSharedFetchHandler('/api')` with
`payload:{args}` exactly once (`$events/result` keeps its one-layer args shape).
Streams use `typertGateway.wireStream.open` with an empty uplink; cancel aborts
the controller and waits for `iterator.return()` before `rpc.stream.end`.
`task.*`/`call.*` receive the `unavailable` error. 1 MiB items are chunked; a
value/result over 8 MiB becomes `frame_too_large`. Every `ok:true` unary result
carries `result`; a DSH endpoint with no return value is sent as `result:null`
(§6.1). Both the inner encoder and the unary-result encoder validate the exact
serialized frame, so an illegal `rpc.result` is refused before sealing. Relay
reconnects use 0.5 s → 30 s backoff with ±20 % jitter, reset after 60 s healthy;
replacement waits at least 30 s. Every failed connection attempt (error without
close, non-101 upgrade, connect timeout, heartbeat timeout, close) enters that
schedule. The PC E2E idle timeout is 15 minutes.

## JSON NUL boundary (pending v1.3 CCR)

The strict reader rejects a **raw** NUL byte in the JSON text. An escaped
`\u0000` in a DSH passthrough value (`rpc.call.args`, `rpc.result.result`,
`rpc.stream.item.value`, `error.details`) is valid JSON data and is carried
unchanged. PCLink-owned fields keep their narrower rules: `name`/`peerName`
reject C0/C1/Cf, PCLink-owned `message` fields reject U+0000, and the PC
sanitizes a DSH error message before placing it in a PCLink error frame.

## Tests

```sh
cd pclink
npm ci
npm test
```

`npm test` runs 80+ `node:test` cases: the full golden vector document and every
invalid crypto/model row through the real codecs/state machines, every schema
sample through the shared validator, plugin pairing/admin/unpair/fail-closed
tests, CLI TTY/install planning, a real-DSH integration, and a real-relay
restart regression. `test/relay-restart.test.mjs` imports `relay/src/server.mjs`
itself (not the test double), authenticates the real `RelayLink`, closes the
relay, starts a fresh one on the same origin/port, and asserts a new
`peer.auth` plus a re-sent `relay.allow` inside the §10 backoff ceiling.

The integration test needs the pinned checkout (default
`/private/tmp/dsh-0.2.2`, override `DSH_PIN_ROOT`) and
`.spike/home/.credentials.yaml`; it skips cleanly when either is absent. Each
run:

1. creates a fresh `DSH_HOME` with `mkdtemp` under `.spike/` and copies only
   `.credentials.yaml` into it with mode 0600; the directory is removed in the
   test's `finally`, and the credentials are never printed;
2. writes the launch overlay into that temporary home. The overlay inserts the
   PCLink plugin and the test-only bash approval policy, points PCLink at the
   test relay double, and pins the session permission preset;
3. boots `dsh web` with `DSH_HOME` pointing at the temp home and
   `DSH_PERMISSION_MODE=workspace-write`, then drives a core-based phone
   through wrong-fingerprint approval (slot voided), QR pairing through the real
   TTY-gated CLI path, handshake, `session/list`, `session/create`, stream
   cancel, the owner `/api/pclink.admin/status` route, remote
   `pclink.admin/*` rejection, unpair (session close `unpaired`, relay allowlist
   update) and a signed `unpaired` reject.

### Deterministic approval

The shipped pinned profile has no built-in "always ask for bash" switch: its
approval policy is `ask`/`never` in the profile `approval` row (the base bundle
derives it from `DSH_PERMISSION_MODE`; `danger-full-access` selects `never`),
and a request is created only by a sandbox escalation or by a composed
`tools/pre-execute` policy. The integration test therefore inserts a test-only
policy plugin (`test/dsh-approval-policy.mjs`) through the temp-home overlay;
it returns `{kind:"ask"}` for every `bash` call, which goes through the real
`ctx.approval` seam and the same `$events` waterfall a production approval uses.
The session is pinned to a `danger-full-access` sandbox + `ask` approval preset
because this host cannot start the `sandbox-exec` backend; that removes the
model's sandbox-escalation decision without bypassing the approval path. The
test answers the waterfall and asserts at least one answered approval plus a
bash `tool/result`. The policy-based trigger is preferred over a prompt that
writes outside the workspace because it is independent of the model's command
and escalation choices.

The prompt turn, duplicate-`requestId` check and approval turn are one subtest.
`PCLINK_SKIP_MODEL=1` skips it with an explicit
`# SKIP PCLINK_SKIP_MODEL=1`; pairing, handshake, session bootstrap, owner
route, stream cancel, admin fence, unpair and signed reject still run. Runtime
output/logs stay under the gitignored `.spike/pclink-c-integration` directory,
and the temporary `DSH_HOME` is deleted after every run.
