// SPDX-License-Identifier: MIT
/**
 * G2-FIX-104 regression: external settlement of an interpreter job blocked in
 * a proxied syscall.
 *
 * The G2-A09 batch declared `timeoutMs: 120000` on a `python3` probe, the
 * WASI instance blocked inside a proxied `fd_write`, and nothing settled at
 * +120 s: no `tool/result`, no journal end, no D13 step terminal, no
 * partial-write marker, and the runner's abort + 20 s drain left the turn
 * open. G2-FIX-82 (job account + per-handle deadline) and G2-FIX-84 (abort
 * wrapper) could not preempt it because the settlement waited in band behind
 * the per-workspace execution lane the blocked instance held.
 *
 * The tests below drive the real `ToolJournal` boundary and the real
 * `XlSubprocessRuntime` with a WASI toolbox whose tool worker is a stub that
 * writes one file and then blocks forever in a VFS syscall. The external job
 * owner must settle the dispatch at its `timeoutMs` and again on a host drain,
 * inside a drain window much shorter than the pre-fix settle grace, while:
 *
 *  - the tool result is terminal and marks the timeout/cancellation,
 *  - the journal has a `done` record (the host's D13 `journaled` evidence),
 *  - the materialized file carries a terminal `*.pdsh-partial` marker (or is
 *    cleaned when the marker cannot be written),
 *  - the execution lane is released for the next command.
 *
 * Before the fix the dispatch promise never settles (the stub's `terminate()`
 * never resolves and the handle's grace is 60 s), so the test-side watchdog
 * fails the case.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { FrameType, encodeUtf8 } from '../channel/src/index.ts'
import { XlExecBridge } from '../exec-bridge/src/index.ts'
import { XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import type { XlWorkerSpawnSpec } from '../subprocess-xl/src/index.ts'
import type { WorkerJobEvent } from '../subprocess-xl/src/jobs.ts'
import { ToolJournal } from '../tool-journal/src/index.ts'
import type { ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import {
  MemoryVfsBackend, PARTIAL_WRITE_SUFFIX, VfsProxyError, WasiToolbox, encodeRequests,
  setWorkerToolbox,
} from '../wasi-toolbox/src/index.ts'
import type { ToolWorkerTransport, VfsRequest } from '../wasi-toolbox/src/index.ts'
import { MockChannel } from './test-channel.ts'

const SAVED_ENV = {
  PDSH_SHELL: process.env.PDSH_SHELL,
  PDSH_VFS_ROOT: process.env.PDSH_VFS_ROOT,
}
const roots: string[] = []
const encoder = new TextEncoder()
const decoder = new TextDecoder()
const PROBE_WASM = readFileSync(new URL('../wasi-toolbox/src/testdata/fd-echo.wasm', import.meta.url))
const PARTIAL_PATH = '/dsh/workspace/partial.bin'
const SESSION_ID = 'session-fix-104'

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  for (const [name, value] of Object.entries(SAVED_ENV)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
})

/** Test-side watchdog: the pre-fix dispatch never settles. */
function within<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${label} did not settle within ${milliseconds} ms`))
    }, milliseconds)
    timer.unref?.()
    promise.then(
      value => { clearTimeout(timer); resolve(value) },
      error => { clearTimeout(timer); reject(error) },
    )
  })
}

/** One fake tool worker that writes a file through the proxy and then wedges. */
interface WedgedWorker {
  readonly transport: ToolWorkerTransport
  /** Resolves when the stub received the exec (the interpreter started). */
  readonly started: Promise<void>
  /** Resolves when the stub's write completed through the proxy. */
  readonly written: Promise<void>
  /** True once the external settlement asked the transport to terminate. */
  terminated(): boolean
}

function wedgedWorker(writePath = PARTIAL_PATH): WedgedWorker {
  const handlers = new Set<(message: unknown) => void>()
  const started = Promise.withResolvers<void>()
  const written = Promise.withResolvers<void>()
  let terminated = false
  let requestId = 1
  const transport: ToolWorkerTransport = {
    postMessage(message) {
      for (const handler of [...handlers]) {
        try { handler(message) } catch { /* the fake never changes a dispatch */ }
      }
    },
    onMessage(handler) {
      handlers.add(handler)
      return () => { handlers.delete(handler) }
    },
    onError() { return () => {} },
    terminate() {
      terminated = true
      // A worker wedged in a syscall does not resolve its terminate promise;
      // settlement must not await it.
      return new Promise<void>(() => {})
    },
  }
  const emit = (message: unknown): void => { transport.postMessage(message) }
  transport.onMessage((message: unknown) => {
    if (typeof message !== 'object' || message === null) return
    const type = (message as { type?: unknown }).type
    if (type === 'init') {
      emit({ type: 'ready' })
      return
    }
    if (type === 'exec') {
      const request: VfsRequest = {
        op: 'write',
        path: writePath,
        offset: 0,
        append: false,
        create: true,
        data: encoder.encode('half-written probe bytes'),
      }
      emit({ type: 'vfs-request', frame: encodeRequests([{ id: requestId++, request }]) })
      started.resolve()
      return
    }
    if (type === 'vfs-response') written.resolve()
  })
  return { transport, started: started.promise, written: written.promise, terminated: () => terminated }
}

interface Fixture {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly runtime: XlSubprocessRuntime
  readonly toolbox: WasiToolbox
  readonly backend: MemoryVfsBackend
  readonly worker: WedgedWorker
  readonly events: WorkerJobEvent[]
  readonly controller: AbortController
  readonly callId: string
  dispose(): Promise<void>
}

async function fixture(options: { readonly backend?: MemoryVfsBackend } = {}): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-fix-104-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  mkdirSync(join(root, 'journal'), { recursive: true })
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  // The command-boundary durability fence is exactly where an interpreter
  // blocked in a proxied write leaves the dispatch: the sink has an
  // unacknowledged mutation. A host that is draining (or a channel that stood
  // still) never acks it, so the flush must not be part of settlement.
  ;(globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> }).__PDSH_VFS_FLUSH__ = () => new Promise<void>(() => {})
  const worker = wedgedWorker()
  const backend = options.backend ?? new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  const toolbox = new WasiToolbox({
    commands: [{ program: 'probe', module: new WebAssembly.Module(PROBE_WASM) }],
    backend,
    // The async proxy path keeps the stub a plain in-process MessageEndpoint.
    crossOriginIsolated: false,
    spawnWorker: () => worker.transport,
    workerReadyTimeoutMs: 5_000,
  })
  setWorkerToolbox(toolbox)
  const mock = new MockChannel({ caps: [], nextMseq: 1n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  ctx.provide('sessions', { flush: async () => {} })
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_FIX104_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_FIX104_UNUSED_TOKEN_FILE',
    connectTimeoutMs: 1_000,
  })
  await ctx.plugin(XlSubprocessRuntime)
  await ctx.plugin(ToolJournal, {
    root: join(root, 'journal'),
    profile: 'pdsh-phone/1+g2-fix-104',
    classes: {},
    rerun: false,
    rerunTimeoutMs: 1_000,
    abortSettleMs: 100,
  })
  const runtime = ctx.get('subprocess') as XlSubprocessRuntime
  const events: WorkerJobEvent[] = []
  runtime.jobs.onEvent(event => { events.push(event) })
  return {
    ctx,
    mock,
    runtime,
    toolbox,
    backend,
    worker,
    events,
    controller: new AbortController(),
    callId: `call_${Math.random().toString(16).slice(2)}`,
    async dispose() {
      await ctx.fiber.dispose()
      await toolbox.dispose().catch(() => {})
      setWorkerToolbox(undefined)
      delete (globalThis as { __PDSH_VFS_FLUSH__?: unknown }).__PDSH_VFS_FLUSH__
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
    },
  }
}

/** The model-facing result a `bash` tool produces from the handle outcome. */
function toolResult(outcome: { exitCode: number | null; signal: string | null }, timeoutMs: number): ToolExecutionResult {
  if (outcome.signal !== null) {
    return {
      isError: true,
      error: { message: 'command aborted', info: { name: 'AbortError', code: 'ABORTED' } },
      content: [{ type: 'text', text: `Error: the command was cancelled by the host drain (signal ${outcome.signal})` }],
    }
  }
  if (outcome.exitCode === 124) {
    return {
      isError: true,
      error: { message: 'command timed out', info: { name: 'TimeoutError', code: 'TIMEOUT' } },
      content: [{ type: 'text', text: `Error: command timed out after ${timeoutMs} ms` }],
    }
  }
  return { isError: false, value: null, content: [{ type: 'text', text: 'ok' }] }
}

/** Run one tool call through the real journal boundary. */
async function dispatchThroughJournal(
  fixture: Fixture,
  timeoutMs: number,
  graceMs = 60_000,
): Promise<{ result: ToolExecutionResult; elapsed: number }> {
  const { runtime, controller, callId } = fixture
  const startedAt = Date.now()
  const body = (): Promise<ToolExecutionResult> => {
    const spec: XlWorkerSpawnSpec = {
      argv: ['bash', '-c', 'probe'],
      cwd: '/dsh/workspace',
      graceMs,
      timeoutMs,
      stdio: {
        stdin: 'ignore',
        stdout: { maxBytes: 64 * 1024 },
        stderr: { maxBytes: 64 * 1024 },
      },
    }
    const handle = runtime.spawn(spec)
    // A timeout or a host cancellation is a normal terminal handle outcome;
    // only an infrastructure failure rejects.
    return handle.done.then(outcome => toolResult(outcome, timeoutMs))
  }
  const exec = {
    agent: { session: { id: SESSION_ID } },
    parent: undefined,
    name: 'bash',
    callId,
    arguments: { command: 'probe' },
    signal: controller.signal,
  }
  const result = await within(
    fixture.ctx.waterfall('tools/execute', exec as never, body as never) as unknown as Promise<ToolExecutionResult>,
    5_000,
    'the interpreter tool call',
  )
  // The real DSH tool layer emits this after the body returns; the journal's
  // `done` record (the D13 `journaled` evidence) follows from it.
  fixture.ctx.emit('tools/result', exec as never, result)
  return { result, elapsed: Date.now() - startedAt }
}


/** Re-open the command-boundary fence for the post-settlement lane check. */
function drainFlushBudget(): void {
  ;(globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> }).__PDSH_VFS_FLUSH__ = () => Promise.resolve()
}
function settledJob(events: readonly WorkerJobEvent[]): WorkerJobEvent['job'] | undefined {
  return events.find(event => event.type === 'job/settled')?.job
}

function journalRecords(fixture: Fixture): Array<{ t: string; result?: { isError?: boolean } }> {
  const journal = fixture.ctx.get('toolJournal') as ToolJournal
  const text = readFileSync(journal.store.path(SESSION_ID), 'utf8')
  return text.trim().split('\n').map(line => JSON.parse(line) as { t: string; done?: { isError?: boolean } })
}

/**
 * The journal append and the `tools/result` observer are asynchronous (the
 * store waits for its channel ack). Wait for the terminal record instead of
 * racing the write with the assertion.
 */
async function waitForJournalDone(
  fixture: Fixture,
): Promise<Array<{ t: string; result?: { isError?: boolean } }>> {
  const deadline = Date.now() + 3_000
  for (;;) {
    try {
      const records = journalRecords(fixture)
      if (records.at(-1)?.t === 'done') return records
    } catch {
      // The journal file is not there yet.
    }
    if (Date.now() > deadline) assert.fail('the tool journal never recorded its terminal done record')
    await new Promise(resolve => setTimeout(resolve, 10))
  }
}

function markerFor(fixture: Fixture): Record<string, unknown> | undefined {
  const marker = fixture.backend.peek(`${PARTIAL_PATH}${PARTIAL_WRITE_SUFFIX}`)
  return marker === undefined ? undefined : JSON.parse(decoder.decode(marker)) as Record<string, unknown>
}

test('G2-FIX-104: timeoutMs hard-terminates a WASI job blocked in a proxied syscall and marks the partial write', {
  timeout: 20_000,
}, async () => {
  const h = await fixture()
  try {
    const { result, elapsed } = await dispatchThroughJournal(h, 500)
    assert.equal(result.isError, true, `the tool result is terminal: ${JSON.stringify(result)}`)
    assert.match(String((result.content as Array<{ text?: string }>)[0]?.text), /timed out/i,
      'the tool result carries the timeout marker')
    assert.ok(elapsed < 3_000, `the job settled after ${elapsed} ms, not near its 500 ms deadline`)
    assert.equal(h.worker.terminated(), true, 'the wedged WASI tool worker was hard-terminated')

    const job = settledJob(h.events)
    assert.equal(job?.status, 'settled')
    assert.equal(job?.cause, 'timeout')
    assert.deepEqual(job?.outcome, { exitCode: 124, signal: null })

    // The command-boundary marker: the materialized workspace must not carry
    // an unmarked half-written file.
    await h.toolbox.partialWritesSettled()
    const marker = markerFor(h)
    assert.notEqual(marker, undefined, 'the half-written file has a terminal marker')
    assert.equal(marker?.['kind'], 'pdsh-partial-write')
    assert.equal(marker?.['cause'], 'timeout')
    assert.equal(marker?.['program'], 'probe')
    assert.equal(marker?.['path'], PARTIAL_PATH)

    // Journal end: start, executed and done all exist (the host's D13 step
    // machine turns `done` into `journaled`).
    const records = await waitForJournalDone(h)
    assert.deepEqual(records.map(record => record.t), ['header', 'start', 'executed', 'done'])

    // The execution lane is released: the next command runs on the same
    // workspace even though the wedged dispatch was cut off.
    drainFlushBudget()
    const next = h.runtime.spawn({
      argv: ['bash', '-c', 'echo lane-alive'],
      cwd: '/dsh/workspace',
      graceMs: 3_000,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
    })
    assert.deepEqual(await within(next.done, 5_000, 'the follow-up command'), { exitCode: 0, signal: null })
  } finally {
    await h.dispose()
  }
})

test('G2-FIX-104: a host drain settles the blocked interpreter inside the window, journals the end and releases the lane', {
  timeout: 20_000,
}, async () => {
  const h = await fixture()
  try {
    const dispatch = dispatchThroughJournal(h, 60_000)
    // Wait until the interpreter is genuinely blocked in the proxied write;
    // this is the G2-A09 shape the drain has to preempt.
    await within(h.worker.started, 3_000, 'the interpreter dispatch')
    await within(h.worker.written, 3_000, 'the proxied write')
    const drainedAt = Date.now()
    h.mock.emit(FrameType.LIFECYCLE, encodeUtf8(JSON.stringify({
      state: 'drain',
      budget: 0,
      admission: 'closed',
      reason: 'park',
    })))
    const { result } = await dispatch
    const drainElapsed = Date.now() - drainedAt
    assert.ok(drainElapsed < 2_000, `the drain settled the interpreter after ${drainElapsed} ms (window is 20 s)`)
    assert.equal(result.isError, true, `the drained tool result is terminal: ${JSON.stringify(result)}`)
    assert.equal(h.worker.terminated(), true)

    const job = settledJob(h.events)
    assert.equal(job?.status, 'settled')
    assert.equal(job?.cause, 'drain')

    await h.toolbox.partialWritesSettled()
    const marker = markerFor(h)
    assert.notEqual(marker, undefined, 'the drained dispatch left a terminal marker')
    assert.equal(marker?.['cause'], 'drain')

    const records = await waitForJournalDone(h)
    assert.equal(records.at(-1)?.t, 'done', `the journal ends even when the drain cut the command off`)
    assert.equal(records.at(-1)?.result?.isError, true)

    // Admission reopens (a park/resume path): the lane is usable again.
    h.mock.emit(FrameType.LIFECYCLE, encodeUtf8(JSON.stringify({
      state: 'run',
      budget: 0,
      admission: 'open',
      reason: 'resume',
    })))
    drainFlushBudget()
    const next = h.runtime.spawn({
      argv: ['bash', '-c', 'echo lane-alive'],
      cwd: '/dsh/workspace',
      graceMs: 3_000,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
    })
    assert.deepEqual(await within(next.done, 5_000, 'the follow-up command after drain'), { exitCode: 0, signal: null })
  } finally {
    await h.dispose()
  }
})

test('G2-FIX-104: when the marker cannot be written the half-written file is cleaned instead', {
  timeout: 20_000,
}, async () => {
  // A backend that refuses the marker write (a full/poisoned workspace): the
  // terminal state must then be cleanup, never an unmarked partial file.
  class MarkerRefusingBackend extends MemoryVfsBackend {
    override writeFile(
      path: string,
      data: Uint8Array,
      options?: { readonly create?: boolean; readonly append?: boolean; readonly truncate?: boolean; readonly mode?: number },
    ): void {
      if (path.endsWith(PARTIAL_WRITE_SUFFIX)) {
        throw new VfsProxyError('ENOSPC', 'no space for the partial marker', path)
      }
      super.writeFile(path, data, options)
    }
  }
  const h = await fixture({ backend: new MarkerRefusingBackend() })
  try {
    setWorkerToolbox(h.toolbox)
    const running = h.toolbox.run({ program: 'probe' })
    await within(h.worker.started, 3_000, 'the interpreter dispatch')
    await within(h.worker.written, 3_000, 'the proxied write')
    const stopped = h.toolbox.terminate('drain')
    assert.equal(stopped, 1, 'the active interpreter dispatch was stopped')
    const result = await within(running, 3_000, 'the hard-stopped interpreter run')
    assert.equal(result.failureCode, 'E_JOB_DRAIN')
    assert.equal(result.cancelled, true)
    await h.toolbox.partialWritesSettled()

    assert.equal(h.backend.peek(PARTIAL_PATH), undefined,
      'the unmarked half-written file was removed instead of being materialized')
    assert.equal(h.backend.peek(`${PARTIAL_PATH}${PARTIAL_WRITE_SUFFIX}`), undefined)
    assert.equal(h.toolbox.stats().hotInstances, 0)
  } finally {
    await h.dispose()
  }
})
