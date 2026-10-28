# `@phone-dsh/dsh-phone-shell` — real command console, no PTY

> **Integration status (this snapshot).** The package is a `plugins/package.json`
> workspace, `phone-shell/src/index.ts` is in the aggregate TypeScript project,
> and `profile/phone.worker.cordis.patch.yml` mounts the host row. The packer
> builds `./client` as a DSH page asset (React and the client module rows stay
> external), so the console is in the real right Sidebar next to the complete
> Web UI. The official xterm tab is disabled because iOS has no PTY.

MIT. This package is the phone Web command console. It is deliberately **not**
a terminal: there is no xterm, no PTY, no `spawnTerminal`, no terminal session
protocol, and no fake prompt. The title has to say so, and the UI has one
control path to the Host Remote.

## What is real

| Path | Where it runs |
| --- | --- |
| `command` | `ctx.subprocess.spawn(['bash', '-c', command])` in the Worker's just-bash over the VFS; writes are normal VFS mutations |
| `argv` whose `argv[0]` the host advertised | the host's read-only xz-shell accelerator, as one `EXEC_REQ` |
| any other `argv` | the Worker command table (no host claim) |
| `caps()` | the live `ctx.xlExecBridge.hello`: real `capabilities.accelerators`; provider/mounts/limits only when that HELLO carries them |
| any request on `node-http`, or on a transport that cannot be confirmed as `channel`/`fetch` | rejected before normalize/spawn: `command`, bare name, path-form name and advertised accelerator all fail closed; `node-http` would submit every request verbatim to the Host PC |

`caps()` never synthesizes a command list. When the host advertises no
accelerator, `linked` is false, the UI says `xz-shell 未链接`, and only Worker
bash remains available. On `node-http` (or any unconfirmed transport) `caps`
also reports `transportSupported: false`, `linked: false` and an empty
`accelerators` list: the transport itself is unusable for the phone console,
so no advertised name is offered as a runnable accelerator.

The ordered channel HELLO (`channel.md` §4.1) publishes `caps` only. Its
transport-local provider/mounts/limits placeholders are not projected: `caps`
reports `factsSource: "channel-caps"` and omits `provider`, `mounts` and
`hostLimits` rather than rendering `phone-channel` or a synthetic `/` mount as
xz-shell facts. `limits` is explicitly the console's own local bound.

cwd ownership follows the actual executor, not the presence of mounts: a
Worker `command` and every `argv` whose `argv[0]` the caps do not advertise are
validated against the real Worker VFS roots (`/dsh/workspace`, `/dsh/home`); a
host-only cwd is never passed to the Worker. An advertised accelerator argv
uses the real host guest mounts when the HELLO published them. The ordered
channel publishes caps only (no `mounts`), so its accelerator stays inside the
same Worker roots through the trusted Native guest-path protocol. A real HELLO
that explicitly publishes `mounts: []` fails the advertised accelerator closed
instead of falling back to an implicit host `/`. The exec bridge uses a
guest-only path mapper for the channel HELLO: guest paths pass through, while
`paths.toHost('/etc')` is `undefined` and no `host=/ -> guest=/` mount is ever
synthesized. A real HTTP/fetch/node-http HELLO with zero mounts is rejected.
The desktop `node-http` transport is never a phone-console route: it submits
every argv verbatim to the Host, so the console rejects every request -
`command`, bare name, path-form program (even `/tmp/evil/rg` or the packaged
ripgrep path whose basename the caps advertise) and every advertised
accelerator - before `normalize`/`spawn`. Any transport that cannot be
confirmed as `channel`/`fetch` fails closed the same way, so an unknown route
can never degrade into a Host shell. Only the Worker `channel`/`fetch`
transports dispatch an advertised accelerator; there `subprocess-xl`
normalizes a path-form program to its advertised bare identity. Final
integration is expected to carry the real `PDSHShellProvider`
provider/mounts/limits in the channel host HELLO; this package reads them only
when present.

## Host Remote

`src/service.ts` exports `PhoneShellRemote`, a `TypertRemoteService` under the
existing `phone` namespace:

| Method | Wire endpoint | Meaning |
| --- | --- | --- |
| `caps()` | `phone/shellCaps` | live accelerators, mounts, and local limits |
| `run(request, signal?)` | `phone/shellRun` | one command/argv, bounded output, exit facts |
| `cancel(execId)` | `phone/shellCancel` | terminate the request with that client-generated id |

The profile row for final integration is one ordinary host row:

```yaml
- id: phone-shell
  name: '@phone-dsh/dsh-phone-shell'
```

`apply(ctx)` registers `PhoneShellRemote`. The service injects `subprocess` and
`xlExecBridge`; it adds no second execution provider and no session/chat
protocol.

`PhoneShellRunRequest` is `{ command?, argv?, cwd?, timeoutMs?, execId? }` with
exactly one of `command`/`argv`. Invalid argv (empty, non-string, NUL, too
long), relative/escaping cwd, an invalid execution id (D6
`^[A-Za-z0-9._-]{1,64}$`, capped at 61 characters here so the accelerator
`-aN` suffix still fits), and a non-positive, non-integer or over-limit timeout
are rejected before `spawn`. `PhoneShellRemote.run` checks the live
`ctx.xlExecBridge.transport.kind` before caps or normalization: only `channel`
and `fetch` proceed. `node-http` is rejected unconditionally - `command`, bare
name, path-form name and advertised accelerator alike - before any
`subprocess.spawn`, and any unconfirmed transport fails closed the same way,
so the console can never fall back to a Host shell. Output is read from the
provider's bounded collectors; the result
reports the real exit code, signal, deadline (`124`), cancellation, collector
truncation, and duration. On channel/fetch, routing uses the same
`isAccelerator` predicate as `subprocess-xl` (including path-form programs it
normalizes to the advertised bare identity), so only an argv that will
actually execute on the Host is validated against host mounts. A console run
is not a model tool call, so the client `execId` is passed to `subprocess-xl`
**out of band** as the accelerator identity; the shell environment is never an
identity source. The requested `timeoutMs` is the host `EXEC_REQ.deadline`;
`graceMs` only bounds cancel/force settlement, and the Remote settles a
provider that ignores cancel or never reports quiescence.

Forced settlement is a real provider release, not just a Remote return: on
timeout/cancel the BridgeProcess is force-settled (quiescent, `done` and
`waitForExit` settled, stream closed, re-issue stopped) so the per-workspace
execution lane can run the next command even when the host ignores `EXEC_CTL`
and sends no `EXEC_EVT`. Late events for the released execution have no
observer.

## Client

`src/client/index.ts` registers the `phone-shell` `sidebarRightTabs` kind, the
keyed `sidebar.right.pane.tab` body and `sidebar.right.pane.tab.title` chip,
and one guide entry that opens the page. The body asks `phone/shellCaps` on
mount, offers exactly the advertised accelerator names, an exact-argv editor
(one argument per line, no shell parsing), a cwd, a timeout, Run/Cancel, and a
real stdout/stderr/exit view. It reuses the page's `ctx.slots`, locale,
Connection RPC and React instance; it creates no second React root.

### Build integration note

The full DSH Web client resolves `react`, `react/jsx-runtime` and
`@deepseek-ai/dsh-client-ui-primitives` through its module table. The final
image/build integration must build this package's `./client` face into DSH's
client-bundle form (`window.__ModuleLoader__.load({ id, factory })`, with those
specifiers resolved through the loader's `require`) rather than serving the
source ESM with bare imports. Do not bundle a second React copy; that build
change belongs to the integration task, not this package.

This task intentionally does not edit `plugins/package.json` workspaces or
`plugins/profile/*.yml`; final integration adds the workspace, the profile row
and the packer externalization.

## Tests

From `plugins/`:

```sh
node --test tests/phone-shell.test.ts
npx tsc -p phone-shell/tsconfig.json
```

The test runs the real `subprocess-xl` provider and the real just-bash command
table over a temporary VFS root. It covers `printf`, a VFS write, the
advertised-accelerator `EXEC_REQ` path (`rg`/`jq` argv), the no-caps state,
timeout/cancel (including a host stream that never reports quiescence or
ignores cancel), the `EXEC_REQ.deadline` vs termination grace split, an
accelerator that runs longer than that grace, an unresponsive host whose lane
is reused after a hard settlement (with late events ignored), D6 exec-id
boundaries, invalid argv/cwd/timeout/id rejection, a real zero/missing-mount
HTTP HELLO failing closed, and asserts that `spawnTerminal` was never called.
The route tests cover node-http rejecting `command`, bare names, path-form
names and advertised accelerators before any `spawn`/`EXEC_REQ`, its caps not
offering those accelerators, unknown routes failing closed, and the real
channel path-form accelerator still reaching the Host under its bare identity.
The cwd tests cover an unadvertised argv with host-only mounts (it stays in the
Worker VFS roots) and an advertised argv with `mounts: []` (it is rejected).
`tests/shell-ext-bridge.test.ts` and `tests/subprocess-xl-shell.test.ts` cover
the out-of-band identity rule (an exported `XL_IDEMPOTENCY_KEY` cannot override
the tool-call key) and the direct-argv host deadline.
