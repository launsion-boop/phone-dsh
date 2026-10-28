// SPDX-License-Identifier: MIT
/**
 * G2-FIX-82 regression: every command that stays in the Worker has a job
 * lifecycle with a bounded settlement.
 *
 * The G2-A10 batch dispatch (`python3 - <<'PY'`, `timeoutMs: 30000`) produced
 * no `tool/result` at all: the shell call never settled, so the per-workspace
 * execution mutex stayed held, no journal/step event followed `tool_dispatched`,
 * and the turn only ended with the runner's wall-clock kill. The same shape is
 * reproduced here without a model:
 *
 *  - a real, deliberately non-terminating Worker shell command with an explicit
 *    `timeoutMs` must settle at that bound, emit job events, and leave the lane
 *    usable;
 *  - a command stuck at its command-boundary VFS durability flush (the one await
 *    in the In-Worker path that no abort can interrupt) must still be bounded by
 *    the job deadline and force-settled;
 *  - a host LIFECYCLE drain must reach the command already executing and settle
 *    it instead of being dropped.
 *
 * Before the fix (no job account, no deadline on the Worker-local handle, no
 * bounded settlement, no host-drain routing) each dispatch hangs until the
 * test-side deadline fails the case.
 */
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import { LocalBashExecutor } from '@deepseek-ai/dsh-bash-local'
import type { SubprocessRuntime, SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import { FrameType, encodeUtf8 } from '../channel/src/index.ts'
import { XlExecBridge } from '../exec-bridge/src/index.ts'
import { XlSubprocessRuntime } from '../subprocess-xl/src/index.ts'
import type { WorkerJobEvent, WorkerJobRegistry } from '../subprocess-xl/src/jobs.ts'
import { MockChannel } from './test-channel.ts'

const roots: string[] = []
const SAVED_ENV = {
  PDSH_SHELL: process.env.PDSH_SHELL,
  PDSH_VFS_ROOT: process.env.PDSH_VFS_ROOT,
  PDSH_SHELL_TIMEOUT_MS: process.env.PDSH_SHELL_TIMEOUT_MS,
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  restoreEnv()
})

function restoreEnv(): void {
  for (const [name, value] of Object.entries(SAVED_ENV)) {
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
}

interface Harness {
  readonly ctx: Context
  readonly mock: MockChannel
  readonly runtime: XlSubprocessRuntime
  readonly subprocess: SubprocessRuntime
  dispose(): Promise<void>
}

async function harness(): Promise<Harness> {
  const mock = new MockChannel({ caps: [], nextMseq: 1n })
  ;(globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__ = mock
  const ctx = new Context()
  await ctx.plugin(XlExecBridge, {
    transport: 'channel',
    tokenEnv: 'PDSH_JOBS_UNUSED_TOKEN',
    tokenFileEnv: 'PDSH_JOBS_UNUSED_TOKEN_FILE',
    connectTimeoutMs: 1_000,
  })
  await ctx.plugin(XlSubprocessRuntime)
  const runtime = ctx.get('subprocess') as XlSubprocessRuntime
  return {
    ctx,
    mock,
    runtime,
    subprocess: runtime,
    async dispose() {
      await ctx.fiber.dispose()
      delete (globalThis as { __PDSH_CHANNEL__?: unknown }).__PDSH_CHANNEL__
      restoreEnv()
    },
  }
}

function virtualRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-subprocess-jobs-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  return root
}

const collect = { maxBytes: 64 * 1024 }

/** A spawn spec plus the Worker deadline extension. */
type JobSpec = SubprocessSpawnSpec & { readonly timeoutMs?: number }

function spec(cwd: string, argv: string[], extra: Partial<JobSpec> = {}): JobSpec {
  return { argv, cwd, graceMs: 3_000, stdio: { stdin: 'ignore', stdout: collect, stderr: collect }, ...extra }
}

/**
 * Await one settlement but fail the test when it never arrives.
 *
 * This is the test-side deadline the pre-fix code cannot pass: without the job
 * lifecycle the dispatch promise stays pending forever.
 */
async function within<T>(promise: Promise<T>, timeoutMs: number, what: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => {
          reject(new Error(`${what} never settled: no terminal result within ${timeoutMs} ms`))
        }, timeoutMs)
        timer.unref?.()
      }),
    ])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

async function waitForFile(path: string, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!existsSync(path)) {
    if (Date.now() > deadline) assert.fail('the Worker command never started executing')
    await new Promise(resolve => setTimeout(resolve, 2))
  }
}

function settledJob(events: readonly WorkerJobEvent[]): WorkerJobEvent['job'] | undefined {
  return events.find(event => event.type === 'job/settled')?.job
}

test('G2-FIX-82: timeoutMs settles a never-ending Worker shell command, emits job events and frees the lane', {
  timeout: 30_000,
}, async () => {
  const root = virtualRoot()
  const h = await harness()
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  const events: WorkerJobEvent[] = []
  // Absent on the pre-fix tree, where the case below must fail on its own
  // test-side deadline (the dispatch never settles) rather than in setup.
  const jobs = (h.runtime as { jobs?: WorkerJobRegistry }).jobs
  const off = jobs?.onEvent(event => { events.push(event) }) ?? (() => {})
  try {
    const started = Date.now()
    const handle = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', 'echo started > started.txt; sleep 100000',
    ], { timeoutMs: 1_000, graceMs: 1_000 }))
    const outcome = await within(handle.done, 8_000, 'the timeoutMs=1000 dispatch')
    const elapsed = Date.now() - started
    // The upstream `bash` tool's timeout becomes a deadline on the execution;
    // the shell reports the conventional timeout status at that bound.
    assert.deepEqual(outcome, { exitCode: 124, signal: null })
    assert.ok(elapsed < 5_000, `the dispatch settled after ${elapsed} ms, not within a bounded multiple of timeoutMs`)

    const types = events.map(event => event.type)
    for (const expected of ['job/registered', 'job/started', 'job/settling', 'job/settled']) {
      assert.ok(types.includes(expected as WorkerJobEvent['type']), `missing ${expected} in ${JSON.stringify(types)}`)
    }
    const settled = settledJob(events)
    assert.equal(settled?.status, 'settled')
    assert.equal(settled?.cause, 'timeout')
    assert.equal(settled?.timeoutMs, 1_000)
    assert.deepEqual(settled?.outcome, { exitCode: 124, signal: null })

    // The mutex was released: a later command executes on the same workspace.
    const next = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'echo lane-alive']))
    assert.deepEqual(await within(next.done, 5_000, 'the follow-up command'), { exitCode: 0, signal: null })
    assert.equal(next.collected.stdout?.readFrom(0).text, 'lane-alive\n')
  } finally {
    off()
    await h.dispose()
  }
})

test('G2-FIX-82: a command stuck at its VFS durability fence is force-settled at the job deadline and releases the lane', {
  timeout: 30_000,
}, async () => {
  const root = virtualRoot()
  const h = await harness()
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  // The host stopped acknowledging the first command's VFS mutations, so its
  // boundary flush can never resolve. Nothing in the shell's abort path reaches
  // this await, which is exactly the unbounded shape the real run hit. Later
  // commands see a healthy host again.
  let releaseFlush: (() => void) | undefined
  const stalled = new Promise<void>((resolve) => { releaseFlush = resolve })
  let fenced = true
  ;(globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> }).__PDSH_VFS_FLUSH__ = () => {
    if (!fenced) return Promise.resolve()
    fenced = false
    return stalled
  }
  const events: WorkerJobEvent[] = []
  // Absent on the pre-fix tree, where the case below must fail on its own
  // test-side deadline (the dispatch never settles) rather than in setup.
  const jobs = (h.runtime as { jobs?: WorkerJobRegistry }).jobs
  const off = jobs?.onEvent(event => { events.push(event) }) ?? (() => {})
  try {
    const started = Date.now()
    const handle = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'echo fenced'], {
      timeoutMs: 1_000,
      graceMs: 500,
    }))
    // Queued behind the fenced command on the same workspace. Before the fix
    // the never-settling first command holds the mutex, so this one waits
    // forever and emits nothing either.
    const queued = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'echo lane-alive']))
    const outcome = await within(handle.done, 8_000, 'the dispatch stuck at its durability fence')
    const elapsed = Date.now() - started
    assert.deepEqual(outcome, { exitCode: null, signal: 'SIGTERM' })
    assert.ok(elapsed < 5_000, `the fenced dispatch settled after ${elapsed} ms`)

    const settled = settledJob(events)
    assert.equal(settled?.status, 'settled')
    assert.equal(settled?.cause, 'timeout')

    assert.deepEqual(await within(queued.done, 5_000, 'the queued follow-up command'), { exitCode: 0, signal: null })
    assert.equal(queued.collected.stdout?.readFrom(0).text, 'lane-alive\n')
  } finally {
    releaseFlush?.()
    delete (globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> }).__PDSH_VFS_FLUSH__
    off()
    await h.dispose()
  }
})

test('G2-FIX-82: a host LIFECYCLE drain reaches the executing Worker command and settles its job', {
  timeout: 30_000,
}, async () => {
  const root = virtualRoot()
  const h = await harness()
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  const events: WorkerJobEvent[] = []
  // Absent on the pre-fix tree, where the case below must fail on its own
  // test-side deadline (the dispatch never settles) rather than in setup.
  const jobs = (h.runtime as { jobs?: WorkerJobRegistry }).jobs
  const off = jobs?.onEvent(event => { events.push(event) }) ?? (() => {})
  try {
    const marker = join(root, 'dsh/workspace/drain-me.txt')
    // A budget far above the test keeps the job deadline out of this case: the
    // only thing that may settle the command is the host's drain.
    const handle = h.subprocess.spawn(spec('/dsh/workspace', [
      'bash', '-c', 'echo started > drain-me.txt; sleep 100000',
    ], { timeoutMs: 60_000, graceMs: 500 }))
    await waitForFile(marker)
    h.mock.emit(FrameType.LIFECYCLE, encodeUtf8(JSON.stringify({
      state: 'drain',
      budget: 0,
      admission: 'closed',
      reason: 'park',
    })))
    const outcome = await within(handle.done, 5_000, 'the host-drained command')
    assert.deepEqual(outcome, { exitCode: null, signal: 'SIGTERM' })
    const settled = settledJob(events)
    assert.equal(settled?.status, 'settled')
    assert.equal(settled?.cause, 'drain')

    // The lane is free again once admission reopens.
    const next = h.subprocess.spawn(spec('/dsh/workspace', ['bash', '-c', 'echo lane-alive']))
    assert.deepEqual(await within(next.done, 5_000, 'the follow-up command'), { exitCode: 0, signal: null })
  } finally {
    off()
    await h.dispose()
  }
})

test('G2-FIX-82: the upstream bash executor deadline produces the tool-bash timed-out result at the bound', {
  timeout: 30_000,
}, async () => {
  const root = virtualRoot()
  const h = await harness()
  process.env.PDSH_SHELL = 'just-bash'
  process.env.PDSH_VFS_ROOT = root
  try {
    // `LocalBashExecutor` is the pinned executor the `bash` tool resolves its
    // `timeoutMs` through: it fuses the deadline into the spawn signal and
    // classifies the result as `timedOut`. This asserts the Worker's settlement
    // is the one upstream expects (a timeout result, not a hang and not an
    // unclassified kill).
    await h.ctx.plugin(LocalBashExecutor, {
      cwd: '/dsh/workspace',
      timeoutMs: 60_000,
      maxTimeoutMs: 600_000,
      maxOutputBytes: 64 * 1024,
      maxSpillBytes: 1024 * 1024,
      graceMs: 300,
    })
    const shell = h.ctx.get('shell') as LocalBashExecutor
    const started = Date.now()
    const execution = await shell.execute(shell.resolve({ command: 'sleep 100000', timeoutMs: 1_000 }))
    const result = await within(execution.result(), 5_000, 'the upstream bash executor deadline')
    assert.equal(result.timedOut, true)
    assert.equal(result.aborted, false)
    assert.equal(result.timeoutMs, 1_000)
    assert.equal(result.exitCode, null)
    assert.equal(result.signal, 'SIGTERM')
    assert.ok(Date.now() - started < 5_000)
  } finally {
    await h.dispose()
  }
})
