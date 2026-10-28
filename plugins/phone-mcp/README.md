# @phone-dsh/dsh-phone-mcp — HTTP MCP management for the phone Worker

> **Integration status (this snapshot).** The package is a `plugins/package.json`
> workspace and `profile/phone.worker.cordis.patch.yml` mounts the host row;
> `./client` is packed as a DSH page asset with the shared React/module table.
> The MCP tab calls the same `phone` Remote namespace and `/api` carrier.

MIT. One phone-owned registry for **Streamable HTTP MCP** servers. The host
reads `/dsh/home/mcp.json` at boot, mounts every enabled row through the
official [`@deepseek-ai/dsh-mcp-client`](../README.md) package, and exposes
`phone/mcp` (generic action dispatcher) plus `phone/mcpList`, `phone/mcpUpsert`,
`phone/mcpRemove`, and `phone/mcpReconnect` on the existing `phone` Remote namespace. The browser half registers one tab
in `settings.plugins.tab` and calls those methods over the same DSH Connection.

There is no stdio transport, no child process, no remote-PC endpoint, and no
second protocol. Header **values** are never accepted in JSON: a row stores
header name → environment-variable name. On the phone, a header listed in
`hostManagedHeaders` is sent with the non-secret
`phone-host-injects-mcp-key` placeholder; the native gateway drops it and
injects the device-Keychain value for that exact URL. Without the phone bridge
the legacy `process.env` resolution still applies.

## Configuration

`/dsh/home/mcp.json` (or `$DSH_HOME/mcp.json`), versioned and strict:

```json
{
  "version": 1,
  "servers": [
    {
      "serverName": "github",
      "url": "https://mcp.example.invalid/mcp",
      "headersFromEnv": { "Authorization": "GITHUB_MCP_TOKEN" },
      "hostManagedHeaders": ["Authorization"],
      "enabled": true,
      "toolCallTimeoutMs": 60000
    }
  ]
}
```

Rules enforced before a write or mount:

- `serverName` matches `[A-Za-z0-9_-]{1,32}` (the official client's namespace).
- `url` is absolute and `http:`/`https:`; embedded credentials are refused.
- `headersFromEnv` values must be POSIX environment-variable names. A missing
  or empty variable refuses the upsert/reconnect with its variable name; no
  empty header is sent. A header in `hostManagedHeaders` must also be present
  in `headersFromEnv` and receives the placeholder instead of an environment
  lookup.
- Unknown fields (including `transport`, `command`, `headers`, and `token`) are
  refused. `enabled` defaults to `true`, `toolCallTimeoutMs` to `60000`.
- Duplicate `serverName` rows are refused by the file schema.
- Writes go to a private temporary file in the same directory and are renamed
  over `mcp.json`; a failed write leaves the previous file and mount intact.

## Behavior

- `list` reads the persisted rows, the live child-fiber mount state, and the
  **exact** ToolRuntime registrations owned by each mount
  (`mcp__<serverName>__<tool>`), tracked through the registrations' own
  disposers. It never fabricates a list and never infers ownership by string
  prefix, so servers named `a` and `a__b` cannot see each other's tools.
  `authentication` tells the UI explicitly whether the row has no credentials
  (`none`), resolves environment values in the Worker (`headers-env`), or is
  injected by the native host from the dedicated Keychain (`host-managed`).
- `upsert` validates, resolves the environment, mounts a fresh
  `dsh-mcp-client` child fiber with `failOnStartupError: true`, and writes the
  file only after the initial connection and tool sync succeed. A duplicate
  namespace (another live `mcp-client`) or a failed connect is returned as a
  safe, redacted diagnostic and nothing is written.
- Connection failures from the official client can include the server's HTTP
  response body. Row errors, thrown errors, and the official client's own
  log lines are redacted against the resolved header values and bounded before
  they leave the manager; the raw transport cause is never attached.
- `remove` disposes the child fiber first (tools leave the registry), then
  rewrites the file; a write failure restores the previous mount.
- `reconnect` disposes and remounts one row, re-reading environment values.
- Startup mounts enabled rows only. A corrupt file or one row's connection
  failure is reported in the snapshot instead of taking down the Host; a
  later valid upsert repairs the file.
- After the initial mount, reconnect/backoff is owned by the official client.
  The status shown here is the authenticated initial connection plus the live
  tool projection; a transport loss that the official supervisor is silently
  retrying is not separately exported by that package.

## Exports and integration contract

| Export | Meaning |
|---|---|
| `.` | Cordis host plugin (`name`, `inject: ['tools']`, `apply`) and `PhoneMcpManager` |
| `./client` | Browser entry (`inject: ['slots','locale','connection']`) registering `settings.plugins.tab` id `phone-mcp` |
| `protocol.ts` (source) | Shared host/client types; no runtime dependency |

The final integration owns the shared profile, workspace list, and build:

1. Add `phone-mcp` to `plugins/package.json` workspaces.
2. Add one enabled host/client row named `@phone-dsh/dsh-phone-mcp` to the phone
   profile. No generated Typert artifact is needed: the Remote service uses the
   same source-mode decorators as `surface-phone`.
3. Build `./client` with DSH's own client bundle path so `react`,
   `react/jsx-runtime`, and the `@deepseek-ai/dsh-client-*` packages resolve to
   the shared module loader. The generic esbuild staging pass in
   `scripts/pack-image.mjs` bundles ESM and would inline a second React; do not
   ship that output as a page asset.

## Tests

```sh
cd plugins
node --test tests/phone-mcp.test.ts
npx tsc -p phone-mcp/tsconfig.json
```

The Node test starts a local authenticated Streamable HTTP MCP fixture, proves
`add → list → real tool call → reconnect → remove`, checks that tools disappear,
and asserts rejected URL/duplicate/missing-env writes leave no file and no
token in the JSON. A second fixture proves that host-managed headers send only
the placeholder and persist no value. It runs under Node, not WKWebView;
Mac/iPhone acceptance is still required (see the reporting boundary below).

The phone client (`./client`) posts a pre-upsert grant transaction to the native
`pdshMcpControl` bridge and upserts the bridge's canonical `grant.url`. The
native side compares canonical endpoints (scheme/host/effective port/normalized
path/query; fragments never participate), so a trailing slash or explicit
default port is not mistaken for the old row. A successful upsert closes the
transaction; a failed upsert rolls back the previous grant/Keychain value only
after the real registry confirms that exact old row. A lost reply, page exit,
crash or timeout with no verdict keeps durable abandoned staging for the next
real `phone/mcpList` or materialized-registry read instead of blindly rolling
back. A native commit/cleanup failure is commit-pending and never re-enables
rollback for the already committed Worker row. A row that still needs a native
value rolls back and opens the **MCP 网络与密钥** sheet with its non-secret
fields; the sheet stores the values and drives the same `phone/mcp*` methods.
Removal revokes the exact grant and Keychain value. See the repository root
the maintainer guide.

## Mac acceptance (NOT_RUN on Linux)

Build and run the normal phone app on a Mac, open Settings → Plugins → **MCP**,
add a local Streamable HTTP MCP and confirm that its `mcp__<server>__<tool>`
names appear in the model tool list; remove it and confirm they disappear.
For an authenticated server, open **设备网络与密钥**, enter the header value in
the dedicated MCP Keychain sheet, then reconnect. An unapproved host must still
be refused (no `*`, no global allowlist edit). This remains NOT_RUN on Linux.
