// SPDX-License-Identifier: MIT
/**
 * Worker workflow bridge, executed for real.
 *
 * The test builds the package and its isolate from the plugin sources plus the
 * pinned checkout's official workflow runtime, then runs scripts in an actual
 * `worker_threads` isolate whose guest executes in QuickJS/WASM. It covers
 * constructor/dynamic-import/EventSource escapes (no parent sentinel, module
 * loader, token, VFS or network), the child-agent JSON bridge, fatal-error
 * identity, realm-level synchronous-loop interruption, cancellation/child
 * cleanup, and a successful next run. A browser-port fixture imports the same
 * built isolate with a browser-like `postMessage` pair so the production
 * Worker transport path is exercised too.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { spawn } from 'node:child_process'
import { after, before, test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { Context } from '@deepseek-ai/cordis'
import vmShim, { Script, createContext, isContext, runInContext } from '../worker-entry/src/vm-shim.ts'
import { hideHostGlobals, openPort } from '../workflow-worker/src/isolate-ports.ts'
import { WORKFLOW_BUDGET_ERROR_NAME } from '../workflow-worker/src/budget-error.ts'
import type {} from '@deepseek-ai/dsh-workflow'
import { build } from 'esbuild'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the official workflow runtime comes from the pinned checkout'
  : false

let scratch: string | undefined
let isolatePath: string | undefined
let engineModule: { default: new (ctx: Context, config: Record<string, unknown>) => { start(request: unknown): WorkflowRunLike } } | undefined

interface WorkflowRunLike {
  readonly result: Promise<{ value: unknown; stopReason: string; error?: string; agentsStarted: number }>
  cancel(reason?: string): void
  dispose(): Promise<void>
}

/** Checkout source faces the package's image bundle would resolve. */
function checkoutFaces(options: { isolate?: boolean } = {}): { name: string; setup(build: unknown): void } {
  return {
    name: 'pdsh-workflow-source-faces',
    setup(builder: unknown) {
      const setup = builder as {
        onResolve(options: { filter: RegExp }, callback: (args: { path: string }) => { path: string } | undefined): void
      }
      setup.onResolve({ filter: /^@deepseek-ai\/dsh-workflow-ptc\/src\/[^/]+\.ts$/ }, (args) => {
        const name = args.path.slice('@deepseek-ai/dsh-workflow-ptc/src/'.length)
        return { path: join(checkout as string, 'packages/workflow/workflow-ptc/src', name) }
      })
      setup.onResolve({ filter: /^(?:node:)?vm$/ }, () => ({
        path: join(root, options.isolate === true ? 'workflow-worker/src/quickjs-vm.ts' : 'worker-entry/src/vm-shim.ts'),
      }))
      setup.onResolve({ filter: /^(?:node:)?module$/ }, () => ({
        path: join(root, 'workflow-worker/src/node-module-shim.ts'),
      }))
      if (options.isolate === true) {
        setup.onResolve({ filter: /^@deepseek-ai\/dsh-tools$/ }, () => ({
          path: join(checkout as string, 'packages/core/tools/src/json-schema.ts'),
        }))
      }
    },
  }
}

before(async () => {
  if (skip !== false) return
  scratch = mkdtempSync(join(root, 'node_modules', '.pdsh-workflow-worker-'))
  const plugin = checkoutFaces()
  const packageBundle = join(scratch, 'workflow-worker.mjs')
  await build({
    entryPoints: [join(root, 'workflow-worker/src/index.ts')],
    outfile: packageBundle,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    external: ['node:*', '@deepseek-ai/*'],
    absWorkingDir: root,
    logLevel: 'silent',
    plugins: [plugin],
  })
  const isolateBundle = join(scratch, 'workflow-isolate.js')
  writeFileSync(join(scratch, 'package.json'), '{"type":"module"}\n')
  const isolateBuild = await build({
    entryPoints: [join(root, 'workflow-worker/src/isolate-runner.ts')],
    outfile: isolateBundle,
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    loader: { '.wasm': 'binary' },
    metafile: true,
    nodePaths: [join(checkout as string, 'node_modules'), join(root, 'node_modules')],
    absWorkingDir: root,
    logLevel: 'silent',
    plugins: [checkoutFaces({ isolate: true })],
  })
  const isolateOutput = Object.values(isolateBuild.metafile?.outputs ?? {}).find(output => output.entryPoint !== undefined)
  const externalNode = (isolateOutput?.imports ?? []).filter(imported => imported.external === true && imported.path.startsWith('node:'))
  assert.deepEqual(externalNode, [], `the isolate bundle must not leave Node imports for the browser Worker: ${JSON.stringify(externalNode)}`)
  assert.match(readFileSync(isolateBundle, 'utf8'), /pdsh-quickjs-workflow-realm-v1/)
  isolatePath = isolateBundle
  process.env.PDSH_WORKFLOW_ISOLATE_PATH = isolateBundle
  engineModule = await import(packageBundle) as typeof engineModule
})

after(() => {
  if (scratch !== undefined) rmSync(scratch, { recursive: true, force: true })
})

/** One recorded `startActivation` request. */
interface StartSpec {
  provider: string
  label: string
  delivery: string
  signal: AbortSignal
  abortedAtStart?: boolean
  request: {
    cwd?: string
    prompt: { type: string; text: string }[]
    parent: unknown
    outputSchema?: unknown
    agentOptions?: unknown
  }
}

/** A deferred for child results. */
function deferred<T>(): { promise: Promise<T>; resolve(value: T): void; reject(reason: unknown): void } {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((accept, refuse) => { resolve = accept; reject = refuse })
  return { promise, resolve, reject }
}

/** One fake child activation returned by the provider seam. */
interface Activation {
  readonly childId: string
  readonly result: Promise<{ output: { type: 'text'; text: string }[]; stopReason: string }>
  dispose(): Promise<void>
}

/** Build an engine context with one fake child provider. */
function engineContext(options: {
  result?: () => Promise<{ output: { type: 'text'; text: string }[]; stopReason: string }>
  starts?: StartSpec[]
  disposals?: string[]
  startError?: unknown
  startActivation?: (spec: StartSpec) => Promise<Activation>
} = {}): Context {
  const ctx = new Context()
  const starts = options.starts ?? []
  const disposals = options.disposals ?? []
  const result = options.result ?? (async () => ({
    output: [{ type: 'text' as const, text: 'CHILD_OK' }],
    stopReason: 'completed',
  }))
  ctx.provide('subagents' as never, {
    getProvider: (name: string) => name === 'spawn' ? { name } : undefined,
    startActivation: async (spec: StartSpec) => {
      spec.abortedAtStart = spec.signal.aborted
      starts.push(spec)
      if (options.startError !== undefined) throw options.startError
      if (options.startActivation !== undefined) return await options.startActivation(spec)
      return {
        childId: `session-child-${String(starts.length)}`,
        result: result(),
        dispose: async () => { disposals.push(spec.request.prompt[0]?.text ?? '') },
      }
    },
  } as never)
  ctx.provide('workingDirectory' as never, {
    ensure: async (_parent: unknown, signal: AbortSignal) => {
      signal.throwIfAborted()
      return '/dsh/workspace'
    },
  } as never)
  return ctx
}

const engines = new WeakMap<Context, { start(request: unknown): WorkflowRunLike }>()
const PARENT = { id: 'session-parent' }

/** Start one run with a valid meta block. */
function start(
  ctx: Context,
  script: string,
  config: Record<string, unknown> = {},
  signal?: AbortSignal,
  args?: unknown,
): WorkflowRunLike {
  const loaded = engineModule
  if (loaded === undefined) throw new Error('workflow worker test module did not build')
  let engine = engines.get(ctx)
  if (engine === undefined) {
    const Engine = loaded.default
    engine = new Engine(ctx, {
      provider: 'spawn',
      maxConcurrentAgents: 1,
      maxTotalAgents: 10,
      maxItemsPerCall: 64,
      syncTimeoutMs: 5_000,
      ...config,
    })
    engines.set(ctx, engine)
  }
  return engine.start({
    script,
    meta: { name: 'worker-test', description: 'Worker workflow bridge test' },
    parent: PARENT,
    ...signal === undefined ? {} : { signal },
    ...args === undefined ? {} : { args },
  })
}

/** Let the isolate boot before a cancellation test starts. */
async function waitFor(check: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!check()) {
    if (Date.now() > deadline) throw new Error('condition did not settle')
    await new Promise(resolveWait => setTimeout(resolveWait, 20))
  }
}

/** The user-visible contract for a real realm deadline. */
function budgetFailureText(limitMs: number): string {
  return 'WorkflowBudgetError [WORKFLOW_SYNC_BUDGET]: '
    + `workflow script exceeded its ${String(limitMs)}ms synchronous execution budget `
    + 'and was terminated by the isolated realm'
}

/**
 * A real interrupt must expose the controlled realm diagnostic, not whatever
 * frame list the engine's `Error.stack` happens to use (JavaScriptCore's native
 * stack is only `budgetError@<url>`).
 */
function assertBudgetFailure(
  result: { readonly stopReason: string; readonly error?: string },
  limitMs: number,
): void {
  assert.equal(result.stopReason, 'error')
  assert.equal(result.error, budgetFailureText(limitMs))
}

test('the vm shim compiles and runs a Script against a created context without host globals', () => {
  const context = createContext({ x: 2 })
  assert.equal(isContext(context), true)
  assert.equal(new Script('x + 1').runInContext(context), 3)
  assert.equal(runInContext('x * 3', context), 6)
  const probe = new Script(`({
    fetchType: typeof fetch,
    processType: typeof process,
    globalThisType: typeof globalThis,
    selfType: typeof self,
    requireType: typeof require,
  })`).runInContext(createContext({}))
  assert.deepEqual(probe, {
    fetchType: 'undefined',
    processType: 'undefined',
    globalThisType: 'undefined',
    selfType: 'undefined',
    requireType: 'undefined',
  })
  assert.equal(typeof vmShim.Script, 'function')
})

test('the browser Worker port keeps working after host globals are hidden', () => {
  const sent: unknown[] = []
  const received: unknown[] = []
  let listener: ((event: { readonly data: unknown }) => void) | undefined
  const scope = {
    postMessage(message: unknown): void { sent.push(message) },
    addEventListener(type: string, callback: (event: { readonly data: unknown }) => void): void {
      assert.equal(type, 'message')
      listener = callback
    },
  }
  const port = openPort(scope)
  assert.equal(typeof scope.postMessage, 'function')
  hideHostGlobals(scope as unknown as Record<string, unknown>)
  // The lazy-reference bug made this a no-op once the global was hidden.
  assert.equal(scope.postMessage, undefined)
  port.send({ type: 'sync-yield' })
  assert.deepEqual(sent, [{ type: 'sync-yield' }])
  port.onMessage(message => { received.push(message) })
  assert.equal(typeof listener, 'function')
  listener?.({ data: { type: 'done' } })
  assert.deepEqual(received, [{ type: 'done' }])
  // PTC/PTY/network globals are hidden on the isolate's own realm too.
  for (const name of ['fetch', 'EventSource', 'WebTransport', 'process', 'Worker']) {
    assert.equal((scope as Record<string, unknown>)[name], undefined, `${name} must be hidden`)
  }
})

test('the built isolate runs a standard workflow through the browser Worker port path', { skip, timeout: 60_000 }, async () => {
  assert.ok(isolatePath !== undefined)
  const messages: { type?: string; callId?: number; childId?: string; result?: unknown; error?: string }[] = []
  const child = spawn(process.execPath, [join(here, 'fixtures', 'browser-isolate-host.mjs'), isolatePath], {
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
  })
  const stderr: string[] = []
  child.stderr?.on('data', chunk => stderr.push(String(chunk)))
  let fixtureReady!: () => void
  const ready = new Promise<void>((resolveReady) => { fixtureReady = resolveReady })
  const done = new Promise<{ type?: string; result?: { value?: unknown; stopReason?: string; error?: string } }>((resolveDone, rejectDone) => {
    child.on('error', rejectDone)
    child.on('exit', status => {
      if (status !== 0) rejectDone(new Error(`isolate host exited ${String(status)}: ${stderr.join('')}`))
    })
    child.on('message', (message: { type?: string; callId?: number; childId?: string; result?: { value?: unknown; stopReason?: string; error?: string }; error?: string }) => {
      if (message.type === '__fixture_ready__') { fixtureReady(); return }
      messages.push(message)
      switch (message.type) {
        case 'child-start':
          child.send({ type: 'child-started', callId: message.callId, childId: 'browser-child-1' })
          break
        case 'child-result':
          child.send({
            type: 'child-result-ok',
            callId: message.callId,
            result: { output: [{ type: 'text', text: 'BROWSER_CHILD_OK' }], stopReason: 'completed' },
          })
          break
        case 'child-dispose':
          child.send({ type: 'child-disposed', callId: message.callId })
          break
        case 'done':
          resolveDone(message)
          break
        case 'fatal':
          rejectDone(new Error(`isolate fatal: ${message.error ?? 'unknown'}`))
          break
      }
    })
  })
  await ready
  child.send({
    type: 'run',
    meta: { name: 'browser-port', description: 'browser Worker port path' },
    body: 'return await agent("browser child")',
    limits: { maxConcurrentAgents: 1, maxTotalAgents: 4, maxItemsPerCall: 8, syncTimeoutMs: 5_000 },
  })
  const terminal = await done
  child.kill()
  assert.equal(terminal.result?.stopReason, 'completed', terminal.result?.error)
  assert.equal(terminal.result?.value, 'BROWSER_CHILD_OK')
  assert.ok(messages.some(message => message.type === 'ready'), 'the isolate must announce realm readiness')
  assert.ok(messages.some(message => message.type === 'child-start'), 'the browser postMessage path must deliver child-start')
})

test('vm scope exposes ECMAScript values, args and hooks but not host globals', { skip }, async () => {
  ;(globalThis as Record<string, unknown>).__PDSH_PARENT_SENTINEL__ = 'parent-secret'
  ;(globalThis as Record<string, unknown>).__PDSH_MODULE_LOADER__ = { parent: true }
  ;(globalThis as Record<string, unknown>).__PDSH_TOKEN__ = 'parent-token'
  ;(globalThis as Record<string, unknown>).__PDSH_VFS__ = { parent: true }
  try {
  const ctx = engineContext()
  const run = start(ctx, `{
    const guestGlobal = ({}).constructor.constructor('return globalThis')()
    const attempt = fn => { try { return fn() } catch { return 'blocked' } }
    const asyncAttempt = async fn => { try { await fn(); return 'reached' } catch { return 'blocked' } }
    return {
      sum: args.a + args.b,
      list: [1, 2, 3].map(n => n * 2),
      parentSentinel: typeof guestGlobal.__PDSH_PARENT_SENTINEL__,
      moduleLoader: typeof guestGlobal.__PDSH_MODULE_LOADER__,
      token: typeof guestGlobal.__PDSH_TOKEN__,
      vfs: typeof guestGlobal.__PDSH_VFS__,
      fetchType: typeof fetch,
      processType: typeof process,
      globalThisType: typeof globalThis,
      selfType: typeof self,
      requireType: typeof require,
      workerType: typeof Worker,
      importScriptsType: typeof importScripts,
      eventSourceType: typeof guestGlobal.EventSource,
      webTransportType: typeof guestGlobal.WebTransport,
      fetchBlocked: attempt(() => guestGlobal.fetch('http://127.0.0.1:1')),
      importerBlocked: await asyncAttempt(async () => {
        await ({}).constructor.constructor('return import("node:fs")')()
      }),
      evalImporterBlocked: await asyncAttempt(async () => {
        await (0, eval)('import("node:fs")')
      }),
      eventSourceBlocked: attempt(() => new guestGlobal.EventSource('http://127.0.0.1:1')),
      webTransportBlocked: attempt(() => new guestGlobal.WebTransport('https://127.0.0.1:1')),
      workerBlocked: attempt(() => new guestGlobal.Worker('data:text/javascript,')),
    }
  }`, {}, undefined, { a: 1, b: 2 })
  const result = await run.result
  assert.equal(result.stopReason, 'completed', result.error)
  assert.deepEqual(result.value, {
    sum: 3,
    list: [2, 4, 6],
    parentSentinel: 'undefined',
    moduleLoader: 'undefined',
    token: 'undefined',
    vfs: 'undefined',
    fetchType: 'undefined',
    processType: 'undefined',
    // A real independent realm has its own global object; what matters is that
    // it carries none of the host's sentinels/module loader/token/VFS.
    globalThisType: 'object',
    selfType: 'undefined',
    requireType: 'undefined',
    workerType: 'undefined',
    importScriptsType: 'undefined',
    eventSourceType: 'undefined',
    webTransportType: 'undefined',
    fetchBlocked: 'blocked',
    importerBlocked: 'blocked',
    evalImporterBlocked: 'blocked',
    eventSourceBlocked: 'blocked',
    webTransportBlocked: 'blocked',
    workerBlocked: 'blocked',
  })
  } finally {
    delete (globalThis as Record<string, unknown>).__PDSH_PARENT_SENTINEL__
    delete (globalThis as Record<string, unknown>).__PDSH_MODULE_LOADER__
    delete (globalThis as Record<string, unknown>).__PDSH_TOKEN__
    delete (globalThis as Record<string, unknown>).__PDSH_VFS__
  }
})

test('the child bridge starts a real caller-delivery activation with cwd and returns its text', { skip }, async () => {
  const starts: StartSpec[] = []
  const disposals: string[] = []
  const events: string[] = []
  const ctx = engineContext({ starts, disposals })
  ctx.on('workflow/agent-start', () => { events.push('start') })
  ctx.on('workflow/agent-end', () => { events.push('end') })
  const run = start(ctx, `phase('work'); log('hello'); return await agent('do the work', { label: 'kid' })`)
  const result = await run.result
  assert.equal(result.stopReason, 'completed', result.error)
  assert.equal(result.value, 'CHILD_OK')
  assert.equal(starts.length, 1)
  assert.equal(starts[0]?.delivery, 'caller')
  assert.equal(starts[0]?.provider, 'spawn')
  assert.equal(starts[0]?.request.cwd, '/dsh/workspace')
  assert.equal(starts[0]?.request.prompt[0]?.text, 'do the work')
  assert.equal(starts[0]?.request.parent, PARENT)
  assert.ok(starts[0]?.signal instanceof AbortSignal)
  assert.equal(starts[0]?.abortedAtStart, false)
  assert.deepEqual(disposals, ['do the work'])
  assert.deepEqual(events, ['start', 'end'])
})

test('a fatal host workflow error keeps its identity across the QuickJS bridge', { skip }, async () => {
  const ctx = engineContext()
  const run = start(ctx, `const result = await parallel([
    async () => 'ordinary',
    async () => await agent('bad option', { notAnOption: true }),
  ]); return result`)
  const result = await run.result
  assert.equal(result.stopReason, 'error')
  // A lost host-error identity would make official parallel() dissolve the
  // item to null and report a completed workflow instead.
  assert.match(result.error ?? '', /notAnOption|not recognized/u)
})

test('a synchronous loop is terminated at the deadline and the next workflow still runs', { skip }, async () => {
  const ctx = engineContext()
  const started = Date.now()
  const hung = start(ctx, 'while (true) {}', { syncTimeoutMs: 600 })
  const result = await hung.result
  const elapsed = Date.now() - started
  assert.equal(result.stopReason, 'error')
  assertBudgetFailure(result, 600)
  assert.ok(elapsed < 5_000, `deadline took ${String(elapsed)}ms`)
  const next = await start(ctx, 'return 2 + 2').result
  assert.equal(next.stopReason, 'completed', next.error)
  assert.equal(next.value, 4)
})

test('a loop after an await is also terminated at the activity deadline', { skip }, async () => {
  const ctx = engineContext()
  const started = Date.now()
  const hung = start(ctx, 'await Promise.resolve(); while (true) {}', { syncTimeoutMs: 600 })
  const result = await hung.result
  assert.equal(result.stopReason, 'error')
  assertBudgetFailure(result, 600)
  assert.ok(Date.now() - started < 5_000)
  const next = await start(ctx, 'return "after-loop"').result
  assert.equal(next.stopReason, 'completed', next.error)
  assert.equal(next.value, 'after-loop')
})

test('a child that takes longer than syncTimeoutMs is not mistaken for a hung script', { skip }, async () => {
  const slow = deferred<{ output: { type: 'text'; text: string }[]; stopReason: string }>()
  const ctx = engineContext({ result: () => slow.promise })
  const run = start(ctx, `return await agent('slow child')`, { syncTimeoutMs: 250 })
  await new Promise(resolveWait => setTimeout(resolveWait, 800))
  slow.resolve({ output: [{ type: 'text', text: 'SLOW_OK' }], stopReason: 'completed' })
  const result = await run.result
  assert.equal(result.stopReason, 'completed', result.error)
  assert.equal(result.value, 'SLOW_OK')
})

test('a loop after a child result is terminated at the activity deadline', { skip }, async () => {
  const ctx = engineContext()
  const hung = start(ctx, `await agent('quick child'); while (true) {}`, { syncTimeoutMs: 600 })
  const result = await hung.result
  assert.equal(result.stopReason, 'error')
  assertBudgetFailure(result, 600)
  const next = await start(ctx, 'return "after-child-loop"').result
  assert.equal(next.stopReason, 'completed', next.error)
  assert.equal(next.value, 'after-child-loop')
})

test('cancel terminates the isolate, disposes a running child, and leaves the engine reusable', { skip }, async () => {
  const starts: StartSpec[] = []
  const disposals: string[] = []
  const child = deferred<{ output: { type: 'text'; text: string }[]; stopReason: string }>()
  const ctx = engineContext({
    starts,
    disposals,
    result: () => child.promise,
  })
  const run = start(ctx, `return await agent('long child')`)
  await waitFor(() => starts.length === 1)
  run.cancel('test cancel')
  const result = await run.result
  assert.equal(result.stopReason, 'cancelled')
  assert.match(result.error ?? '', /test cancel/)
  await waitFor(() => disposals.length === 1)
  assert.deepEqual(disposals, ['long child'])
  const next = await start(ctx, 'return "next"').result
  assert.equal(next.stopReason, 'completed', next.error)
  assert.equal(next.value, 'next')
})

test('a pre-aborted request publishes a cancelled run and disposes children', { skip }, async () => {
  const starts: StartSpec[] = []
  const disposals: string[] = []
  const ctx = engineContext({ starts, disposals })
  const controller = new AbortController()
  controller.abort('already cancelled')
  const run = start(ctx, `return await agent('never')`, {}, controller.signal)
  const result = await run.result
  assert.equal(result.stopReason, 'cancelled')
  await run.dispose()
  assert.equal(starts.length, 0)
})

test('a non-awaited agent call before a synchronous loop still hits the realm deadline', { skip }, async () => {
  const ctx = engineContext()
  const started = Date.now()
  const hung = start(ctx, `agent('not awaited'); while (true) {}`, { syncTimeoutMs: 600 })
  const result = await hung.result
  assert.equal(result.stopReason, 'error')
  assertBudgetFailure(result, 600)
  assert.ok(Date.now() - started < 5_000, `deadline took ${String(Date.now() - started)}ms`)
  const next = await start(ctx, 'return "after-unawaited-agent-loop"').result
  assert.equal(next.stopReason, 'completed', next.error)
  assert.equal(next.value, 'after-unawaited-agent-loop')
})

test('a synchronous loop inside a parallel thunk is terminated, not reported as a child failure', { skip }, async () => {
  const ctx = engineContext()
  const started = Date.now()
  const hung = start(ctx, 'return await parallel([() => { while (true) {} }])', { syncTimeoutMs: 600 })
  const result = await hung.result
  assert.equal(result.stopReason, 'error')
  assertBudgetFailure(result, 600)
  assert.ok(Date.now() - started < 5_000, `deadline took ${String(Date.now() - started)}ms`)
  const next = await start(ctx, 'return 6 * 7').result
  assert.equal(next.stopReason, 'completed', next.error)
  assert.equal(next.value, 42)
})

test('a guest error that imitates the interrupt sentinel is not reported as a budget termination', { skip }, async () => {
  const ctx = engineContext()
  // Both shapes the old name/message test treated as the interrupt: a forged
  // `InternalError` name and the literal `interrupted` message. Neither came
  // from the QuickJS interrupt callback, so both must keep their own identity.
  const byName = await start(ctx, `const error = new Error('guest-name-sentinel'); error.name = 'InternalError'; throw error`).result
  assert.equal(byName.stopReason, 'error')
  assert.match(byName.error ?? '', /guest-name-sentinel/u)
  assert.ok(!(byName.error ?? '').startsWith(WORKFLOW_BUDGET_ERROR_NAME),
    `a guest InternalError must not become the typed deadline: ${byName.error ?? ''}`)
  const byMessage = await start(ctx, `throw new Error('interrupted')`).result
  assert.equal(byMessage.stopReason, 'error')
  assert.match(byMessage.error ?? '', /interrupted/u)
  assert.ok(!(byMessage.error ?? '').startsWith(WORKFLOW_BUDGET_ERROR_NAME),
    `a guest "interrupted" message must not become the typed deadline: ${byMessage.error ?? ''}`)
})

test('agent provider/model overrides stay in agentOptions and never select the subagent backend', { skip }, async () => {
  const starts: StartSpec[] = []
  const ctx = engineContext({ starts })
  const run = start(ctx, `return await agent('override child', { provider: 'deepseek-official', model: 'deepseek-chat' })`)
  const result = await run.result
  assert.equal(result.stopReason, 'completed', result.error)
  assert.equal(result.value, 'CHILD_OK')
  assert.equal(starts.length, 1)
  assert.equal(starts[0]?.provider, 'spawn')
  assert.deepEqual(starts[0]?.request.agentOptions, {
    provider: 'deepseek-official',
    model: 'deepseek-chat',
  })
})

test('agentsStarted counts an accepted start attempt even when the provider refuses it', { skip }, async () => {
  const starts: StartSpec[] = []
  const ctx = engineContext({ starts, startError: new Error('provider unavailable') })
  const run = start(ctx, `return await agent('cannot start')`)
  const result = await run.result
  assert.equal(result.stopReason, 'error')
  assert.match(result.error ?? '', /provider unavailable/)
  assert.equal(result.agentsStarted, 1)
  assert.equal(starts.length, 1)
})

test('a cancelled in-flight child start is disposed before the result settles', { skip }, async () => {
  const starts: StartSpec[] = []
  const order: string[] = []
  let release!: () => void
  const gate = new Promise<void>((resolveGate) => { release = resolveGate })
  const ctx = engineContext({
    starts,
    startActivation: async () => {
      await gate
      order.push('activation')
      return {
        childId: 'session-child-race',
        result: new Promise(() => {}),
        dispose: async () => { order.push('dispose') },
      }
    },
  })
  const run = start(ctx, `return await agent('race child')`)
  await waitFor(() => starts.length === 1)
  run.cancel('race cancel')
  release()
  const result = await run.result
  assert.equal(result.stopReason, 'cancelled')
  assert.deepEqual(order, ['activation', 'dispose'])
})

test('an isolate load failure becomes a workflow error instead of crashing the parent', { skip, timeout: 20_000 }, async () => {
  assert.ok(scratch !== undefined)
  const previous = process.env.PDSH_WORKFLOW_ISOLATE_PATH
  writeFileSync(join(scratch, 'broken-isolate.mjs'), "throw new Error('isolate load exploded')\n")
  process.env.PDSH_WORKFLOW_ISOLATE_PATH = join(scratch, 'broken-isolate.mjs')
  try {
    const run = start(engineContext(), 'return 1')
    const result = await run.result
    assert.equal(result.stopReason, 'error')
    assert.match(result.error ?? '', /isolate load exploded|workflow isolate failed/)
  } finally {
    if (previous === undefined) delete process.env.PDSH_WORKFLOW_ISOLATE_PATH
    else process.env.PDSH_WORKFLOW_ISOLATE_PATH = previous
  }
})

test('an isolate exit before completion becomes a workflow error with its exit code', { skip, timeout: 20_000 }, async () => {
  assert.ok(scratch !== undefined)
  const previous = process.env.PDSH_WORKFLOW_ISOLATE_PATH
  writeFileSync(join(scratch, 'exiting-isolate.mjs'), 'process.exit(7)\n')
  process.env.PDSH_WORKFLOW_ISOLATE_PATH = join(scratch, 'exiting-isolate.mjs')
  try {
    const run = start(engineContext(), 'return 1')
    const result = await run.result
    assert.equal(result.stopReason, 'error')
    assert.match(result.error ?? '', /exited before completing.*7/u)
  } finally {
    if (previous === undefined) delete process.env.PDSH_WORKFLOW_ISOLATE_PATH
    else process.env.PDSH_WORKFLOW_ISOLATE_PATH = previous
  }
})

test('a browser Worker onerror becomes a workflow error and the isolate is terminated', { skip }, async () => {
  interface FakeBrowserWorker {
    onerror: ((event: { message?: string; filename?: string; lineno?: number; preventDefault?(): void }) => void) | null
    terminated: boolean
  }
  const instances: FakeBrowserWorker[] = []
  class BrowserWorker implements FakeBrowserWorker {
    onerror: FakeBrowserWorker['onerror'] = null
    terminated = false
    constructor() { instances.push(this) }
    postMessage(message: unknown): void {
      if (typeof message === 'object' && message !== null && (message as { type?: string }).type === 'run') {
        queueMicrotask(() => {
          this.onerror?.({ message: 'browser isolate load exploded', filename: 'workflow-isolate.js', lineno: 3 })
        })
      }
    }
    addEventListener(): void {}
    terminate(): void { this.terminated = true }
  }
  const scope = globalThis as unknown as {
    Worker?: typeof BrowserWorker
    location?: { href?: string }
  }
  const previousWorker = scope.Worker
  const previousLocation = scope.location
  scope.Worker = BrowserWorker
  scope.location = { href: 'https://phone.test/worker-entry.js' }
  try {
    const result = await start(engineContext(), 'return 1').result
    assert.equal(result.stopReason, 'error')
    assert.match(result.error ?? '', /browser isolate load exploded/u)
    assert.equal(instances.length, 1)
    assert.equal(instances[0]?.terminated, true)
  } finally {
    if (previousWorker === undefined) delete scope.Worker
    else scope.Worker = previousWorker
    if (previousLocation === undefined) delete scope.location
    else scope.location = previousLocation
  }
})
