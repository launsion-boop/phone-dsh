// SPDX-License-Identifier: MIT
/**
 * Image-boot harness for `tests/image-boot.test.ts`.
 *
 * The test compiles this file with esbuild against the pinned checkout's
 * webworker-runtime sources and runs it as a child process. The child installs
 * the platform globals the Worker entry installs (process, crypto,
 * async-context), applies the profile stub overlay the Worker entry builds,
 * mounts the packed image, and reports every captured console line as one JSON
 * line prefixed `__PDSH_BOOT_RESULT__`.
 *
 * `PDSH_EMULATE_JSC=1` reproduces WebKit's native-function source format (the
 * system `jsc` prints `function Object() {\n    [native code]\n}`), which DSH
 * 0.2.1's plain-JSON record check rejects unless the phone profile normalizes
 * it before the tool rows mount. That is what makes the test fail on the tree
 * before the profile fix.
 *
 * This file is not a test: it is the process the test boots.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/worker-boot-harness
 */
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { basename, dirname, join } from 'node:path'

import { requireActiveModuleLoader } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/module-system/module-loader.ts'
import { createSyntheticExchange } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/transport/synthetic-http.ts'

import { installJscCompat } from '../../worker-entry/src/jsc-compat.ts'
// The production host factory, not a locally assembled `createWorkerHost`: this
// keeps the packed-image probe on the same app-boot wrapper that installs the
// module-import diagnostics (and the fs read-state shim) in the real Worker.
import { createPhoneWorkerHost, whenRequestListener } from '../../worker-entry/src/runtime-binding.ts'
import { startMcpFixture } from './phone-mcp-fixture.ts'
import { startScriptedMessages } from './scripted-messages.ts'

import { createPhoneProfileOverlay } from '../../worker-entry/src/profile-overlay.ts'

interface CapturedLine {
  level: 'log' | 'warn' | 'error' | 'uncaught' | 'unhandled'
  text: string
}

/** First-use workspace facts the image-boot test asserts against the real API. */
interface WorkspaceProbe {
  workspacePath?: string
  workspaceTitle?: string
  sessionId?: string
  importedWorkspacePath?: string
  importedAbsolutePath?: string
  readText?: string
  presets?: { id: string; isDefault: boolean; broken?: string }[]
  presetSessions?: Record<string, string>
  presetErrors?: Record<string, string>
  workflowFileText?: string
  workflowChildResultSeen?: boolean
  workflowTextSeen?: boolean
  mcpFile?: string
  mcpInitialServers?: number
  mcpUpsertStatus?: string
  mcpTools?: string[]
  mcpListStatus?: string
  mcpListTools?: string[]
  mcpRemoved?: boolean
  mcpAfterRemove?: number
  mcpCallIsError?: boolean
  mcpCallContent?: string
  mcpToolsAfterRemove?: string[]
  importDiagnosticName?: string
  importDiagnosticMessage?: string
  importDiagnosticFirstStackLine?: string
  importDiagnosticCause?: string
}

/** Native functions before the runtime replaces the global `process`. */
const nativeExit = process.exit.bind(process)
const rawSetTimeout = globalThis.setTimeout.bind(globalThis)
const rawLog = console.log.bind(console)
const rawError = console.error.bind(console)
const lines: CapturedLine[] = []

const capture = (level: CapturedLine['level']) => (...args: unknown[]): void => {
  const text = args
    .map(value => typeof value === 'string' ? value : value instanceof Error ? value.stack ?? value.message : String(value))
    .join(' ')
  lines.push({ level, text })
  rawError(`[${level}] ${text}`)
}

const result = (ok: boolean, thrown?: string, probe?: WorkspaceProbe): void => {
  rawLog(`__PDSH_BOOT_RESULT__ ${JSON.stringify({ ok, thrown, lines, probe })}`)
}

// Fail the test by exiting, never by hanging: the runtime keeps long-lived
// timers (exec-bridge reconnect) alive after the tree is active.
rawSetTimeout(() => {
  rawError('boot harness watchdog expired')
  result(false, 'boot harness watchdog expired')
  nativeExit(7)
}, 60_000)

// WebKit's JavaScriptCore prints native function sources on several lines.
// Reproduce that shape before the runtime installs anything, exactly as the
// image sees it in WKWebView (the repo records the system jsc output).
const nativeToString = Function.prototype.toString
if (process.env.PDSH_EMULATE_JSC === '1') {
  Function.prototype.toString = function (this: unknown): string {
    const source = nativeToString.call(this)
    if (source.includes('[native code]') && typeof this === 'function' && (this as { name?: string }).name !== '') {
      return `function ${(this as { name: string }).name}() {\n    [native code]\n}`
    }
    return source
  } as typeof Function.prototype.toString
}

// `runtime-binding.ts` installs the async-context, timer and crypto globals at
// module load, exactly as the production Worker does before it creates the
// host. Capture the console after that so watchdog/handshake internals do not
// become test assertions.
console.log = capture('log') as typeof console.log
console.warn = capture('warn') as typeof console.warn
console.error = capture('error') as typeof console.error
process.on('uncaughtException', (error) => {
  const text = error.stack ?? String(error)
  lines.push({ level: 'uncaught', text })
  rawError(`[uncaught] ${text}`)
})
process.on('unhandledRejection', (reason) => {
  const text = (reason as Error)?.stack ?? String(reason)
  lines.push({ level: 'unhandled', text })
  rawError(`[unhandled] ${text}`)
})

// The ordered-channel stub the Worker entry installs before DSH boots. Boot
// only needs the host HELLO facts and a monotonic mseq; this test drives no
// command or API request across the channel.
const hostHello = {
  proto: 1,
  role: 'host',
  boot_id: '0'.repeat(32),
  session_epoch: 0n,
  fence: { owner: 'test', generation: 0n, wal_seq: 0n },
  caps: ['channel/1'],
  next_mseq: 1n,
  acked_mseq: 0n,
  durable_mseq: 0n,
}
;(globalThis as Record<string, unknown>).__PDSH_CHANNEL__ = {
  hostHello,
  onHostHello: () => () => {},
  nextMseq: () => 1n,
  ackedMseq: () => 0n,
  waitAck: async () => {},
  barrier: async () => {},
  journalAcked: () => 0n,
  waitJournalAck: async () => {},
  send: () => 1n,
  onFrame: () => () => {},
  request: async () => { throw new Error('boot harness does not serve API requests') },
  connect: async () => {},
  close: async () => {},
}

const imagePath = process.argv[2] ?? ''
if (imagePath === '') {
  result(false, 'usage: worker-boot-harness <image.tar.gz>')
  throw new Error('boot harness: image path is required')
}

// A URL-backed image is required once the roster contains client chunks: the
// runtime defers those archives and resolves each archive name against the
// image URL. Serve the packed directory (image + sibling lazy/) in-process so
// the harness exercises the same lazy-closure contract as the loopback host.
const imageDirectory = dirname(imagePath)
const server = createServer(async (request, response) => {
  const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname
  // The Worker's llm-bridge carries every MCP request through the host
  // `/v1/http` route. Stand in for the Swift gateway: restore the upstream
  // Authorization the Worker moved aside and forward to the target fixture.
  if (pathname === '/v1/http') {
    const target = request.headers['x-pdsh-target-url']
    if (typeof target !== 'string') {
      response.writeHead(400)
      response.end()
      return
    }
    const headers = new Headers()
    for (const [name, value] of Object.entries(request.headers)) {
      if (name === 'x-pdsh-target-url' || name === 'x-pdsh-upstream-authorization' || value === undefined) continue
      for (const member of Array.isArray(value) ? value : [value]) headers.append(name, member)
    }
    const upstreamAuthorization = request.headers['x-pdsh-upstream-authorization']
    if (typeof upstreamAuthorization === 'string') headers.set('authorization', upstreamAuthorization)
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(chunk as Buffer)
    try {
      const upstream = await nativeFetch(target, {
        method: request.method,
        headers,
        body: chunks.length === 0 ? undefined : Buffer.concat(chunks),
      })
      const responseHeaders: Record<string, string> = {}
      upstream.headers.forEach((value, name) => { responseHeaders[name] = value })
      delete responseHeaders['content-length']
      response.writeHead(upstream.status, responseHeaders)
      if (upstream.body === null) {
        response.end()
        return
      }
      request.once('close', () => { void upstream.body?.cancel().catch(() => {}) })
      const reader = upstream.body.getReader()
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        response.write(Buffer.from(value))
      }
      response.end()
    } catch {
      if (!response.headersSent) response.writeHead(502)
      response.end()
    }
    return
  }
  const relative = pathname === '/image.tar.gz'
    ? basename(imagePath)
    : pathname.startsWith('/lazy/') ? join('lazy', basename(pathname)) : undefined
  if (relative === undefined) {
    response.writeHead(404)
    response.end()
    return
  }
  try {
    const bytes = readFileSync(join(imageDirectory, relative))
    response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': String(bytes.byteLength) })
    response.end(bytes)
  } catch {
    response.writeHead(404)
    response.end()
  }
})
await new Promise<void>((resolve, reject) => {
  server.once('error', reject)
  server.listen(0, '127.0.0.1', resolve)
})
const address = server.address()
if (address === null || typeof address === 'string') throw new Error('boot harness: image server has no port')
const imageUrl = `http://127.0.0.1:${String(address.port)}/image.tar.gz`
const imageOrigin = `http://127.0.0.1:${String(address.port)}`
// Capture the Node fetch before the image's llm-bridge replaces globalThis.fetch
// with the host /v1/http carrier; the harness gateway must dial the fixture
// directly, never recursively through the Worker route.
const nativeFetch = globalThis.fetch.bind(globalThis)

// The tunnel never posts here; it only needs a message port to exist.
;(globalThis as Record<string, unknown>).postMessage = () => {}

// The Worker entry applies this data overlay before the base image (the image
// records the `web` profile template, which names the browser bundle the image
// deliberately does not carry). Pass the same overlay the production entry
// builds, so this harness boots exactly what the App boots.
const profileOverlay = await createPhoneProfileOverlay()
// One authenticated Streamable HTTP MCP server in the harness process. The
// Worker reaches it through its real fetch; no credential is printed.
const mcpFixture = await startMcpFixture()
// A local Messages-compatible endpoint. It only scripts model output; every
// tool result still comes from the real Worker shell/VFS and child bridge.
const scriptedModel = await startScriptedMessages()
// The Node image harness cannot construct a nested Web Worker, so the workflow
// bridge falls back to `node:worker_threads` through `process.getBuiltinModule`.
// Capture the real builtin before the runtime installs its process shim; after
// start, restore only this id and leave every other builtin on the production
// shim.
const nodeWorkerThreads = process.getBuiltinModule('node:worker_threads')

// A WKWebView Worker has no Node `global` alias. Remove Node's so the packed
// image's isexe/which path evaluates without it. This is a function-level
// simulation only: the harness calls the installer directly after deleting the
// alias. That the production entry/bundle installs it from its first import is
// proven separately by `jsc-compat.test.ts`, whose stub entry deletes `global`
// before its dynamic import. This run proves the packed image still boots once
// the alias exists, not that entry.ts installed it.
if (process.env.PDSH_EMULATE_WORKER_GLOBAL === '1') {
  delete (globalThis as { global?: unknown }).global
  const compat = installJscCompat()
  if (!compat.nodeGlobal) throw new Error('boot harness: the prelude did not install the Node global alias')
}

// The runtime does not expose the live Cordis context, so the harness asks the
// production host factory's app-boot seam for the module it loaded and wraps
// only `boot()` to observe the context it returns. The wrapper adds no plugin,
// tool or API behavior: it only lets the probe execute the tool the real
// phone-mcp mount registered through that same context. The factory itself
// still installs the module-import diagnostics on the active loader first.
interface LiveHostContext {
  tools: {
    execute(exec: {
      callId: string
      name: string
      arguments: unknown
      signal: AbortSignal
    }): Promise<{ isError: boolean; content: unknown }>
    schemas(): { name: string }[]
  }
}
let hostContext: LiveHostContext | undefined
const host = createPhoneWorkerHost({
  image: imageUrl,
  overlays: [profileOverlay],
  env: {
    PDSH_DSH_LAUNCH_TOKEN: 'test-launch-token',
    PDSH_DSH_PORT: '0',
    PDSH_SANDBOX_MODE: process.env.PDSH_BOOT_SANDBOX_MODE ?? 'workspace-write',
    PDSH_SHELL: 'runtime',
    DSH_HOME: '/dsh/home',
    // Keep the boot channel global for the entry-facing contracts, but give
    // llm-bridge no host-route token: this harness's model traffic goes to the
    // local scripted Messages server over the platform fetch, not through a
    // host `/v1/http` route this process does not serve.
    PDSH_CHANNEL_URL: 'ws://127.0.0.1:1/channel',
    DEEPSEEK_BASE_URL: scriptedModel.url,
    DEEPSEEK_API_KEY: 'dummy-not-a-secret',
    ...process.env.PDSH_WORKFLOW_ISOLATE_PATH === undefined
      ? {}
      : { PDSH_WORKFLOW_ISOLATE_PATH: process.env.PDSH_WORKFLOW_ISOLATE_PATH },
    PDSH_CHANNEL_TOKEN: 'test-channel-token',
    PDSH_CHANNEL_ORIGIN: imageOrigin,
    DSH_TELEMETRY_DISABLED: '1',
    PHONE_MCP_TEST_TOKEN: `Bearer ${mcpFixture.token}`,
  },
  wrapAppBoot: (module) => ({
    ...module,
    async boot(...args: unknown[]) {
      const ctx = await module.boot.apply(module, args) as LiveHostContext
      hostContext = ctx
      return ctx
    },
  }),
})

let ok = false
let thrown: string | undefined
const probe: WorkspaceProbe = {}
try {
  await host.start()
  ok = true

  // Production maps node:worker_threads to the runtime's notImplemented stub.
  // This Node harness runs the real worker_threads isolate instead, while every
  // other builtin still comes from the production process shim.
  const hostProcess = globalThis.process as unknown as {
    getBuiltinModule?: (id: string) => unknown
  }
  const runtimeGetBuiltinModule = hostProcess.getBuiltinModule?.bind(hostProcess)
  hostProcess.getBuiltinModule = (id: string) => id === 'node:worker_threads' || id === 'worker_threads'
    ? nodeWorkerThreads
    : runtimeGetBuiltinModule?.(id)

  // The production factory installed the import diagnostic seam on the active
  // loader. Trigger a real resolution failure through that same seam so the
  // shape is proven on the packed-image loader, not only on a fake object.
  let importFailure: unknown
  try {
    await requireActiveModuleLoader().internal.import(
      '@phone-dsh/__missing_module_import_probe__',
      '/dsh/home/profiles/web/',
    )
  } catch (error) {
    importFailure = error
  }
  if (importFailure === undefined) {
    throw new Error('the missing image module import unexpectedly resolved')
  }
  const diagnostic = importFailure as Error & { cause?: unknown }
  probe.importDiagnosticName = diagnostic.name
  probe.importDiagnosticMessage = diagnostic.message
  probe.importDiagnosticFirstStackLine = (diagnostic.stack ?? '').split('\n', 1)[0]
  probe.importDiagnosticCause = diagnostic.cause === undefined ? 'absent' : 'present'

  // First-use workspace through the real /api Remote carrier. This is the
  // path the App's complete Web page takes after boot; it must use the same
  // Worker, Session store and VFS rather than a test-only workspace.
  const listen = await whenRequestListener()
  let nextRequestID = 1
  const callEnvelope = async (method: string, args: unknown): Promise<{
    ok: boolean
    value: Record<string, unknown>
    error: unknown
  }> => {
    const rpcId = randomUUID()
    const encoded = new TextEncoder().encode(JSON.stringify({
      type: 'client-request', rpcId, method, payload: { args },
    }))
    const body = encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength)
    return await new Promise((resolveCall, rejectCall) => {
      const chunks: Uint8Array[] = []
      const sink = {
        head: () => {},
        chunk: (bytes: Uint8Array) => { chunks.push(bytes) },
        end: (payload?: { status: number; headers: Record<string, string>; body?: Uint8Array }) => {
          try {
            const bytes = payload?.body
              ?? (chunks.length === 0
                ? new Uint8Array(0)
                : new Uint8Array(chunks.reduce((total, chunk) => total + chunk.byteLength, 0)))
            if (payload?.body === undefined && chunks.length > 0) {
              let offset = 0
              for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength }
            }
            const envelope = JSON.parse(new TextDecoder().decode(bytes)) as {
              type?: string
              rpcId?: string
              result?: { ok?: boolean; value?: Record<string, unknown>; error?: unknown }
            }
            if (envelope.type !== 'server-response' || envelope.rpcId !== rpcId) {
              throw new Error(`unexpected API envelope for ${method}: ${JSON.stringify(envelope).slice(0, 400)}`)
            }
            resolveCall({
              ok: envelope.result?.ok === true,
              value: envelope.result?.value ?? {},
              error: envelope.result?.error,
            })
          } catch (error) {
            rejectCall(error)
          }
        },
        fail: (message: string) => rejectCall(new Error(`API ${method} transport failed: ${message}`)),
      }
      const exchange = createSyntheticExchange({
        t: 'req',
        id: nextRequestID++,
        url: `/api/${method}`,
        method: 'POST',
        headers: {
          host: '127.0.0.1:3080',
          'content-type': 'application/json',
          // The Worker entry sets this after verifying the ordered channel;
          // the harness runs with the same channel coordinates.
          'x-pdsh-channel-authenticated': '1',
        },
        body,
      }, sink)
      listen(exchange.req, exchange.res)
    })
  }
  const call = async (method: string, args: unknown): Promise<Record<string, unknown>> => {
    const envelope = await callEnvelope(method, args)
    if (!envelope.ok) throw new Error(`API ${method} failed: ${JSON.stringify(envelope.error)}`)
    return envelope.value
  }
  const tryCall = callEnvelope

  const initialized = await call('workspace/initializeDefault', {})
  const workspace = initialized.workspace as Record<string, unknown> | undefined
  if (workspace === undefined) throw new Error('workspace/initializeDefault returned no workspace')
  probe.workspacePath = typeof workspace.path === 'string' ? workspace.path : undefined
  probe.workspaceTitle = typeof workspace.title === 'string' ? workspace.title : undefined
  const workspaceId = workspace.workspaceId
  if (typeof workspaceId !== 'string' || typeof probe.workspacePath !== 'string') {
    throw new Error(`workspace/initializeDefault returned an invalid workspace: ${JSON.stringify(workspace)}`)
  }

  const created = await call('session/create', { request: { workspaceId } })
  probe.sessionId = typeof created.sessionId === 'string' ? created.sessionId : undefined
  if (probe.sessionId === undefined) {
    throw new Error(`session/create returned no sessionId: ${JSON.stringify(created)}`)
  }

  const text = 'hello workspace'
  const begin = await call('phone/importBegin', {
    request: {
      v: 1,
      sessionId: probe.sessionId,
      targetDirectory: probe.workspacePath,
      entryName: 'first-launch',
      directories: ['nested'],
      files: [{ path: 'hello.txt', size: text.length }],
      totalBytes: text.length,
    },
  })
  const importId = begin.importId
  if (typeof importId !== 'string' || importId === '') throw new Error('phone/importBegin returned no importId')
  await call('phone/importWrite', {
    request: {
      v: 1,
      sessionId: probe.sessionId,
      importId,
      path: 'hello.txt',
      offset: 0,
      dataBase64: Buffer.from(text).toString('base64'),
    },
  })
  const committed = await call('phone/importCommit', {
    request: { v: 1, sessionId: probe.sessionId, importId },
  })
  probe.importedWorkspacePath = typeof committed.workspacePath === 'string' ? committed.workspacePath : undefined
  probe.importedAbsolutePath = typeof committed.absolutePath === 'string' ? committed.absolutePath : undefined
  if (probe.importedWorkspacePath === undefined) {
    throw new Error(`phone/importCommit returned no workspacePath: ${JSON.stringify(committed)}`)
  }
  const read = await call('workspaceFiles/read', {
    workspaceFileScopeId: probe.sessionId,
    path: `${probe.importedWorkspacePath}/hello.txt`,
    range: { offset: 1, limit: 10 },
  })
  probe.readText = typeof read.text === 'string' ? read.text : undefined

  // The shipped roster and its health, through the real preset Remote. The
  // default must be standard; unsupported presets stay listed with their own
  // real diagnostics instead of being hidden.
  const listed = await call('agentPresets/list', {})
  const presetRows = Array.isArray(listed.presets) ? listed.presets as Record<string, unknown>[] : []
  probe.presets = presetRows.map(row => ({
    id: String(row.id),
    isDefault: row.isDefault === true,
    ...typeof row.broken === 'string' ? { broken: row.broken } : {},
  }))
  probe.presetSessions = {}
  probe.presetErrors = {}
  for (const preset of ['standard', 'ptc', 'minimal', 'cordis']) {
    const created = await tryCall('session/create', { request: { workspaceId, agentPreset: preset } })
    if (created.ok && typeof created.value.sessionId === 'string') {
      probe.presetSessions[preset] = created.value.sessionId
    } else {
      probe.presetErrors[preset] = JSON.stringify(created.error)
    }
  }

  // One real turn on the standard preset: parent asks for `workflow`, the
  // workflow child asks for `bash`, and the child's text flows back into the
  // parent Session. Only model output is scripted.
  const workflowSession = probe.presetSessions.standard
  if (workflowSession === undefined) throw new Error(`standard session/create failed: ${probe.presetErrors.standard ?? 'unknown'}`)
  await call('session/prompt', {
    request: {
      requestId: randomUUID(),
      sessionId: workflowSession,
      mode: 'queue',
      content: [{ type: 'text', text: 'Run the workflow probe.' }],
    },
  })
  // `session/page` is a cold-history read; the live turn's events reach the
  // durable log first. Read that log from the real Worker VFS and wait for its
  // terminal turn event.
  const vfs = host.vfs as unknown as {
    readdirSync?: (path: string) => string[]
    readFileSync?: (path: string, encoding?: string) => string
  } | undefined
  const sessionLogOf = (sessionId: string): { text: string } => {
    const root = '/dsh/home/sessions'
    const buckets = vfs?.readdirSync?.(root) ?? []
    for (const bucket of buckets) {
      const entries = vfs?.readdirSync?.(`${root}/${bucket}`) ?? []
      const dir = entries.find(name => name.includes(sessionId))
      if (dir === undefined) continue
      const files = vfs?.readdirSync?.(`${root}/${bucket}/${dir}`) ?? []
      const log = files.find(name => name.endsWith('.jsonl'))
      if (log === undefined) continue
      const text = vfs?.readFileSync?.(`${root}/${bucket}/${dir}/${log}`, 'utf8') ?? ''
      return { text }
    }
    return { text: '' }
  }
  let sessionLog = ''
  const pageDeadline = Date.now() + 45_000
  while (Date.now() < pageDeadline) {
    sessionLog = sessionLogOf(workflowSession).text
    if (sessionLog.includes('turn/end')) break
    await new Promise<void>(resolveWait => { rawSetTimeout(resolveWait, 250) })
  }
  probe.workflowChildResultSeen = sessionLog.includes('WORKFLOW_BASH_OK')
  probe.workflowTextSeen = sessionLog.includes('WORKFLOW_DONE') && sessionLog.includes('"kind":"completed"')
  const workflowRead = await call('workspaceFiles/read', {
    workspaceFileScopeId: workflowSession,
    path: 'workflow.txt',
    range: { offset: 1, limit: 64 },
  })
  probe.workflowFileText = typeof workflowRead.text === 'string' ? workflowRead.text : undefined
  // The real phone/mcp Remote in this same Worker: a real local Streamable HTTP
  // server is mounted through the official client, registers its tools, and is
  // removed. The Node behavior test calls one registered tool directly; this
  // boot proves the packed image exposes the Remote and the live registration in
  // the Worker process.
  const initialMcp = await call('phone/mcpList', {})
  probe.mcpFile = typeof initialMcp.file === 'string' ? initialMcp.file : undefined
  probe.mcpInitialServers = Array.isArray(initialMcp.servers) ? initialMcp.servers.length : undefined
  const addedMcp = await call('phone/mcpUpsert', {
    request: {
      serverName: 'image',
      url: mcpFixture.url,
      headersFromEnv: { Authorization: 'PHONE_MCP_TEST_TOKEN' },
      enabled: true,
      toolCallTimeoutMs: 5_000,
    },
  })
  probe.mcpUpsertStatus = typeof addedMcp.status === 'string' ? addedMcp.status : undefined
  probe.mcpTools = Array.isArray(addedMcp.tools) ? addedMcp.tools as string[] : undefined
  const listedMcp = await call('phone/mcpList', {})
  const listedServer = Array.isArray(listedMcp.servers) ? listedMcp.servers[0] as Record<string, unknown> | undefined : undefined
  probe.mcpListStatus = typeof listedServer?.status === 'string' ? listedServer.status : undefined
  probe.mcpListTools = Array.isArray(listedServer?.tools) ? listedServer.tools as string[] : undefined
  if (hostContext === undefined) throw new Error('boot harness did not observe the live app-boot context')
  const executedMcp = await hostContext.tools.execute({
    callId: 'image-mcp-echo',
    name: 'mcp__image__echo',
    arguments: { message: 'from-image' },
    signal: new AbortController().signal,
  })
  probe.mcpCallIsError = executedMcp.isError
  probe.mcpCallContent = JSON.stringify(executedMcp.content)
  const removedMcp = await call('phone/mcpRemove', { request: { serverName: 'image' } })
  probe.mcpRemoved = removedMcp.removed === true
  const afterRemove = await call('phone/mcpList', {})
  probe.mcpAfterRemove = Array.isArray(afterRemove.servers) ? afterRemove.servers.length : undefined
  probe.mcpToolsAfterRemove = hostContext.tools.schemas()
    .map(schema => schema.name)
    .filter(name => name.startsWith('mcp__image__'))
} catch (error) {
  thrown = (error as Error)?.stack ?? String(error)
  lines.push({ level: 'uncaught', text: thrown })
}
// Let the appReady line and any activation audit run before reporting.
await new Promise<void>(resolve => { rawSetTimeout(resolve, 1_500) })
result(ok, thrown, probe)
try { await host.stop?.() } catch { /* the process exits below */ }
try { await scriptedModel.close() } catch { /* the process exits below */ }
await mcpFixture.close().catch(() => {})
server.closeAllConnections()
await new Promise<void>(resolve => { server.close(() => resolve()) })
nativeExit(ok ? 0 : 1)
