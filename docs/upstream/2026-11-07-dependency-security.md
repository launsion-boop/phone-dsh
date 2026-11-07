# Dependency security findings for the pinned DSH runtime

Status: **upstream investigation requested; not fixed or submitted**. This note
records dependency and interoperability evidence for maintainers; it does not
assert that the reported SDK behavior is reachable in a shipped phone app.

## Baseline and scope

The phone-dsh integration pins DeepSeek Harness (DSH) `0.2.1-rc.2`, commit
`7be5505b0be06009d74891c869063c9cf19a0df0`, in
[`plugins/dsh-pin.json`](../../plugins/dsh-pin.json). The npm workspace manifest,
lockfile and pin are unchanged relative to phone-dsh base `9b3b31e`. PR #59 adds
device-facing behavior and profile entries but did not introduce the audited
versions in those files. That comparison alone does not establish that a newly
added use of an existing dependency is safe.

On 2026-11-07, the workspace npm audit reported 198 affected *package entries*:
189 high and 9 moderate. These include parents marked through transitive
propagation; they are not 198 independent vulnerabilities. The direct advisory
records in that report concern four package families:

| Package | Evidence and possible exposure | Upstream action to evaluate |
| --- | --- | --- |
| `@modelcontextprotocol/client` | DSH `dsh-mcp-client` declares exactly `2.2.0`. [GHSA-6prh-2h8m-c8cw](https://github.com/advisories/GHSA-6prh-2h8m-c8cw) describes cross-origin redirect forwarding of custom headers and bodies; the report identifies 2.3.0 as outside the affected range. The phone profile uses the DSH Streamable HTTP MCP client. | Evaluate and test a coordinated client **and core** upgrade. Client 2.3.0 declares `@modelcontextprotocol/core: 2.3.0` exactly. The pinned DSH client declares `@modelcontextprotocol/client: 2.2.0` exactly; changing only the phone lockfile does not satisfy that declaration. |
| `zod` | The lock contains `4.4.3`, including exact dependencies of several DSH packages. [GHSA-mrhx-c7xc-m3w5](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5) describes resource exhaustion while validating oversized constrained collections. Session controller and preset registry packages appear in the phone profile; affected runtime inputs have not been demonstrated. | Assess a compatible upstream Zod update and bound the inputs at their actual boundaries. Confirm which copies occur in the built Worker image. |
| `undici` | The lock includes `7.29.0` under `guarded-fetch` and `8.11.2` under DSH HTTP proxy dependencies. The report contains 26 advisory records with 18 distinct URLs, including [GHSA-2m5v-pch6-74hx](https://github.com/advisories/GHSA-2m5v-pch6-74hx). `just-bash` is used through its browser entry, so an npm dependency edge alone does not prove that an Undici feature is present or reachable in the Worker. | Assess upstream compatible versions, the DSH and `guarded-fetch` constraints, and actual build/Worker entry points. Do not assume every reported Node API runs in WebKit. |
| `fflate` | The reported vulnerable `0.8.2` copy is under the dev-flagged `@deepseek-ai/libreoffice-kit`, which declares `0.8.2` exactly. [GHSA-px8p-9vwx-vf98](https://github.com/advisories/GHSA-px8p-9vwx-vf98) describes malformed ZIP64 handling. The phone workspace `wasi-toolbox` directly pins `0.8.3`; it is not the reported `0.8.2` node. | Evaluate the upstream dependency update and affected build/test or runtime use. The audit's `fixAvailable` flag is not evidence that an update respects the exact parent constraint or is compatible. |

The lockfile's development/production flags describe npm's dependency graph,
not the exact contents or reachability of a generated Worker. The packer stages
phone workspace bundles and resolves DSH roster packages from the pinned
checkout; compare the built image and its actual resolved files before making
production claims. The checked-in lockfile alone cannot prove which package
code is executed in WebKit.

## MCP redirect experiment

Using Node `v22.21.1`, the real installed SDK's
`StreamableHTTPClientTransport.send`, and two local HTTP servers on different
ports, a dummy authenticated POST received a 307 or 308 redirect. The observed
results were:

| Client and fetch | Cross-origin 307 / 308 | Same-origin 307 / 308 |
| --- | --- | --- |
| 2.2.0, Node fetch | Destination received the dummy custom header and full POST body; Node stripped the dummy `Authorization`. | Destination received both dummy headers and body. |
| 2.2.0, phone-dsh `createNodeFetch()` | Same observation. | Same observation. |
| 2.3.0, either fetch | Default policy rejected the redirect; destination received no request. | Destination received both dummy headers and body. |

This is SDK/Node behavior, not an iOS exploit demonstration. It requires an
initial endpoint able to return a redirect with a `Location` header. The 2.3.0
experiment exercised the same public transport API and the three exports used
by `dsh-mcp-client` were present, but it did **not** establish full DSH API,
core, package-resolution or Worker compatibility. In particular, 2.3.0 still
allows same-origin redirects, whereas the LAN device contract separately says
not to redirect credential-bearing requests and grants an exact URL.

### Reproduce without credentials or external endpoints

From the phone-dsh repository root, with Node >=22.19 and an existing
`plugins/node_modules` from the pinned lockfile, run the following. The 2.3.0
comparison is installed in a new temporary directory, not in the repository.
The two HTTP servers bind only to `127.0.0.1`; all secrets and body data are
synthetic. No upstream DSH source is modified.

```bash
repo_root="$(pwd -P)"
repro_tmp="$(mktemp -d)"
npm install --prefix "$repro_tmp" --ignore-scripts --no-audit --no-fund \
  --save-exact @modelcontextprotocol/client@2.3.0
PDSH_REPRO_ROOT="$repo_root" PDSH_REPRO_TMP="$repro_tmp" \
  node --experimental-strip-types --input-type=module <<'JS'
import assert from 'node:assert/strict'
import http from 'node:http'
import { pathToFileURL } from 'node:url'

const root = process.env.PDSH_REPRO_ROOT
const temp = process.env.PDSH_REPRO_TMP
const old = await import(pathToFileURL(`${root}/plugins/node_modules/@modelcontextprotocol/client/dist/index.mjs`))
const current = await import(pathToFileURL(`${temp}/node_modules/@modelcontextprotocol/client/dist/index.mjs`))
const { createNodeFetch } = await import(pathToFileURL(`${root}/plugins/llm-bridge/src/node-fetch.ts`))
const oldVersion = JSON.parse(await (await import('node:fs/promises')).readFile(
  `${root}/plugins/node_modules/@modelcontextprotocol/client/package.json`, 'utf8')).version
assert.equal(oldVersion, '2.2.0')

const message = { jsonrpc: '2.0', id: 42, method: 'tools/call',
  params: { name: 'example', arguments: { payload: 'DUMMY_BODY_ONLY' } } }
const auth = 'Bearer DUMMY_AUTH_ONLY'
const secret = 'DUMMY_CUSTOM_HEADER_ONLY'
const serve = handler => new Promise(resolve => {
  const server = http.createServer(handler)
  server.listen(0, '127.0.0.1', () => resolve(server))
})

async function check(version, sdk, fetchMode, status, sameOrigin) {
  let destination
  const reply = async (req, res) => {
    const parts = []
    for await (const chunk of req) parts.push(chunk)
    destination = { auth: req.headers.authorization === auth,
      custom: req.headers['x-dummy-secret'] === secret,
      body: Buffer.concat(parts).toString() === JSON.stringify(message),
      method: req.method }
    res.writeHead(202).end()
  }
  const target = await serve(reply)
  const origin = await serve(async (req, res) => {
    if (req.url === '/destination') return reply(req, res)
    for await (const _ of req) { /* drain the synthetic request */ }
    const port = sameOrigin ? origin.address().port : target.address().port
    res.writeHead(status, { location: `http://127.0.0.1:${port}/destination` }).end()
  })
  const transport = new sdk.StreamableHTTPClientTransport(
    new URL(`http://127.0.0.1:${origin.address().port}/mcp`), {
      fetch: fetchMode === 'nodebridge' ? createNodeFetch() : globalThis.fetch,
      requestInit: { headers: { Authorization: auth, 'X-Dummy-Secret': secret } },
    })
  transport.onerror = () => {}
  await transport.start()
  let rejected = false
  try { await transport.send(message) } catch { rejected = true }
  await transport.close()
  origin.closeAllConnections(); target.closeAllConnections()
  await Promise.all([new Promise(r => origin.close(r)), new Promise(r => target.close(r))])
  const allowed = version === '2.2.0' || sameOrigin
  if (allowed) {
    assert.equal(rejected, false)
    assert.deepEqual(destination, { auth: sameOrigin, custom: true, body: true, method: 'POST' })
  } else {
    assert.equal(rejected, true)
    assert.equal(destination, undefined)
  }
  console.log(`${version} ${fetchMode} ${status} ${sameOrigin ? 'same' : 'cross'}: PASS`)
}

for (const [version, sdk] of [['2.2.0', old], ['2.3.0', current]])
  for (const mode of ['native', 'nodebridge'])
    for (const status of [307, 308])
      for (const same of [false, true]) await check(version, sdk, mode, status, same)
JS
```

The temporary comparison package is obtained from npm; its dependency tree is
not the phone lockfile or the pinned DSH checkout. The 2.2.0 transport above is
loaded from the phone's actual installed lockfile. npm metadata and advisory
results can change; preserve the audit output and package integrity hashes in an
upstream investigation.

## Current host boundaries and limits

The phone's [`LoopbackServer`](../../Sources/PhoneDSHLoopback/LoopbackServer.swift)
route for `/mcp/native` obtains status and body from `NativeMCPServing` and
constructs its response with `Content-Type` only; it does not propagate a
`Location` header. The streaming egress response writer in
[`HTTPTransport.swift`](../../Sources/PhoneDSHLoopback/HTTPTransport.swift)
removes `Location` from 3xx responses before they reach the Worker. A separate
Node experiment drove the real `installNodeFetch()` routing code with a test
host that emulated that 3xx filtering; cross-origin 307/308 did not reach the
second server. A deliberately redirecting replacement for `/mcp/native` did
reach it under Node, but that replacement did not model the real host's header
construction. It is evidence about the JS composition only.

These checks do not establish actual reachability through the production Swift
host, WKWebView, iPhone, or a physical LAN device. No real credentials were
used. No production server or device was modified. Existing P05
[`gateway-security.md`](../../spec/v1/gateway-security.md) defines general
redirect behavior; changing all fetch behavior is a contract decision, not a
safe automatic consequence of this report.

## Requested upstream work and acceptance

1. Review and update DSH's exact MCP client/core dependencies together, plus
   the affected Zod, Undici and fflate parent constraints as appropriate.
   Identify supported versions and retain a reproducible dependency lock.
   Do not patch or vendor DSH source in phone-dsh, run `npm audit fix --force`,
   or claim an upgrade is compatible solely because audit counts fall.
2. For MCP, define the exact redirect policy for credentials, arbitrary custom
   headers, request body and exact-URL grants. Reconcile the LAN no-redirect
   requirement with the SDK's same-origin default and record compatibility
   for configured older endpoints. Any change to P05/P07/P13 behavior requires
   the owning contract, shared fixtures and both affected ends to agree before
   implementation; preserve existing general gateway semantics unless that
   contract is deliberately changed.
3. Add repeatable 307/308 cross-origin rejection and same-origin policy tests
   using synthetic credentials and bodies; test POST, sensitive custom headers,
   Authorization, redirect chains, blocked destination contact, and connection
   error handling. Drive the real SDK and transport, not a copied redirect
   algorithm. Keep the legitimate non-redirect MCP flow passing.
4. Test the actual phone Worker and native host together, including
   `/mcp/native`, external MCP via `/v1/http`, a deliberately redirecting test
   server, and the same vectors through Android/Harmony where they implement
   the affected boundary. Run pinned DSH compatibility, typecheck, tests,
   image packaging and phone conformance gates. Record simulator and physical
   device results separately, including WKWebView and real LAN evidence.
5. For the other advisory families, record actual built-image reachability and
   regression tests for the relevant vulnerable functionality. Treat a missing
   package in one build, a development-only lock flag, or a passing synthetic
   MCP test as evidence only for its measured scope.
