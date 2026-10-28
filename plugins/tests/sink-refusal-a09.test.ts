// SPDX-License-Identifier: MIT
/**
 * G2-ENG-03 regression: a resource refusal from the VFS sink (EFBIG/ENOSPC/
 * quota) is a diagnostic, not a protocol violation.
 *
 * The G2-A09 batch transcript shows the defect this test reproduces: an
 * over-limit write landed in the Worker VFS, the sink's publish-time guard
 * called `failLoud`, closed the ordered channel, and the in-flight tool call
 * never produced a result. The session then emitted no further events until
 * the wall-clock budget expired.
 *
 * The fix classifies the refusal: the sink sends one `ERROR VFS_REFUSED`
 * frame with `path`/`limit`/`reason` (plus a CONSOLE audit line), consumes no
 * `mseq`, keeps the channel open, and poisons `flush()` until a later
 * mutation repairs the refused path. The tool-journal boundary flush then
 * fails as that tool step with a node-errno-shaped error whose message ends in
 * the shared `pdsh-shell:` trailer, so the model sees the failure and can
 * delete or chunk the file instead of waiting on a dead connection.
 */
import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import {
  createMemoryChannelPair, decodeUtf8, decodeVfsMutation, encodeUtf8,
  FrameType, MAX_MUTATION_DATA,
  type Frame, type MemoryChannelPair,
} from '../channel/src/index.ts'
import {
  installSink, VfsRefusalError, vfsRefusalHint, vfsRefusalReason, vfsRefusalRecordFromError,
  type WorkerEntryMutation,
} from '../worker-entry/src/entry.ts'
import { parseShellTrailer } from '../shell-ext/src/index.ts'
import { ToolJournal } from '../tool-journal/src/index.ts'

type MutationListener = (mutation: WorkerEntryMutation) => void

// The corpus trailer audit is plain ESM with no declaration file; load the
// same helper the `npm test` corpus gate uses through require so typecheck does
// not need a second copy of its grammar.
const requireCorpus = createRequire(import.meta.url)
const { trailersOf } = requireCorpus('../tools/shell-corpus/contract.mjs') as {
  trailersOf: (stderr: string) => { reason?: string }[]
}

/**
 * Deterministic in-memory VFS with the runtime's publish contract: the tree
 * changes first and observers are called synchronously; an observer failure
 * is recorded and swallowed so the caller still sees a successful write.
 */
class MemoryVfs {
  private readonly files = new Map<string, Uint8Array>()
  private readonly listeners = new Set<MutationListener>()
  /** Observer failures the runtime would swallow, kept for assertions. */
  readonly observerErrors: unknown[] = []

  subscribe(listener: MutationListener): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  async flush(): Promise<void> {}

  write(path: string, bytes: Uint8Array): void {
    this.files.set(path, new Uint8Array(bytes))
    this.publish({ kind: 'write', path, bytes: new Uint8Array(bytes), mode: 0o644, entryChanged: true })
  }

  remove(path: string): void {
    this.files.delete(path)
    this.publish({ kind: 'remove', path })
  }

  /** Publish a hand-built mutation, for structural-failure fixtures. */
  emitForTest(mutation: WorkerEntryMutation): void {
    this.publish(mutation)
  }

  private publish(mutation: WorkerEntryMutation): void {
    for (const listener of [...this.listeners]) {
      try {
        listener(mutation)
      } catch (error) {
        this.observerErrors.push(error)
      }
    }
  }
}

function fixture(): { vfs: MemoryVfs; pair: MemoryChannelPair; hostFrames: Frame[]; dispose: () => void } {
  const vfs = new MemoryVfs()
  const pair = createMemoryChannelPair({ autoConnect: true, nextMseq: 1n, autoAck: true })
  const hostFrames: Frame[] = []
  pair.host.onFrame(frame => hostFrames.push(frame))
  // Pin the single-file budget to the old 15 MiB value: this regression is
  // about the refusal class, not the tier default (which is now 64 MiB).
  const dispose = installSink(vfs, pair.worker, { maxFileBytes: MAX_MUTATION_DATA })
  return { vfs, pair, hostFrames, dispose }
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
}

/** Fail with a clear message instead of letting a hung session stall the test. */
function withDeadline<T>(promise: Promise<T>, what: string, ms = 1_000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`session hung: ${what} did not settle in ${ms} ms`)), ms)
    promise.then(
      (value) => { clearTimeout(timer); resolve(value) },
      (error: unknown) => { clearTimeout(timer); reject(error) },
    )
  })
}

function errorFrames(frames: readonly Frame[]): Frame[] {
  return frames.filter(frame => frame.type === FrameType.ERROR)
}

function jsonOf(frame: Frame): Record<string, unknown> {
  return JSON.parse(decodeUtf8(frame.payload)) as Record<string, unknown>
}

function consoleLines(frames: readonly Frame[]): Record<string, unknown>[] {
  return frames.filter(frame => frame.type === FrameType.CONSOLE).map(jsonOf)
}

/** Assert one shared-contract trailer is the last line of a model-facing error. */
function assertRefusalTrailer(text: string, path: string): void {
  const trailer = parseShellTrailer(text.trimEnd().split('\n').at(-1) as string)
  assert.notEqual(trailer, undefined, `error text carries a parseable trailer: ${JSON.stringify(text)}`)
  assert.equal(trailer?.exitCode, 1)
  assert.equal(trailer?.program, 'vfs')
  assert.equal(trailer?.reason, 'limit-refused')
  assert.equal(trailer?.hint?.includes(String(MAX_MUTATION_DATA)), true)
  assert.match(trailer?.hint ?? '', /15 MiB/)
  assert.equal(trailersOf(text).length, 1, 'the corpus trailer audit parses exactly one trailer')
  assert.match(text, new RegExp(path.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')))
}

/**
 * The tool-journal boundary contract: flush the session before dispatching the
 * tool. A failed flush ends this step as a tool error (DSH's registry wraps
 * the thrown message as `Error: ...`); the tool body never runs.
 */
async function journalBoundary(
  vfs: MemoryVfs,
  body: () => Promise<void>,
): Promise<{ isError: boolean; text: string; executed: boolean }> {
  try {
    await withDeadline(vfs.flush(), 'tool-journal session flush')
  } catch (error) {
    return { isError: true, text: `Error: ${error instanceof Error ? error.message : String(error)}`, executed: false }
  }
  await body()
  return { isError: false, text: '', executed: true }
}

test('G2-ENG-03: an over-limit write refuses without closing the ordered channel', async () => {
  const { vfs, pair, hostFrames, dispose } = fixture()
  try {
    const path = '/dsh/workspace/testdata.bin.tmp'
    vfs.write(path, new Uint8Array(MAX_MUTATION_DATA + 1))
    await settle()

    // The refusal is classified at the sink: EFBIG carries the exact limit.
    assert.equal(vfs.observerErrors.length, 1)
    const refusal = vfs.observerErrors[0] as { code?: string; path?: string; limit?: number }
    assert.equal(refusal.code, 'EFBIG')
    assert.equal(refusal.path, path)
    assert.equal(refusal.limit, MAX_MUTATION_DATA)

    // One structured ERROR VFS_REFUSED frame, not a teardown.
    const errors = errorFrames(hostFrames)
    assert.equal(errors.length, 1, 'the refusal is one ERROR frame')
    const payload = jsonOf(errors[0] as Frame)
    assert.equal(payload['code'], 'VFS_REFUSED')
    assert.equal(payload['path'], path)
    assert.equal(payload['limit'], MAX_MUTATION_DATA)
    assert.equal(payload['reason'], 'file-too-large')
    assert.equal(typeof payload['message'], 'string')
    assert.match(String(payload['message']), /EFBIG/)

    // A refused mutation consumes no mseq and never reaches the host.
    assert.equal(pair.worker.nextMseq(), 1n)
    assert.equal(hostFrames.some(frame => frame.type === FrameType.VFS_MUT), false)

    // The entry also emits a CONSOLE line for the host's diagnostics.
    const refusalLines = consoleLines(hostFrames).filter(line => line['level'] === 'error')
    assert.equal(refusalLines.length, 1)
    assert.match(String(refusalLines[0]?.['text']), /EFBIG/)

    // The session did not hang: the refused temp file is removed (the write
    // tool's atomic-write cleanup), the poisoned flush heals, and the next
    // ordinary mutation travels on the same channel with its original mseq.
    vfs.remove(path)
    await withDeadline(vfs.flush(), 'flush after cleanup')
    vfs.write('/dsh/workspace/after.txt', encodeUtf8('ok'))
    await withDeadline(vfs.flush(), 'flush of the follow-up write')
    const mutations = hostFrames
      .filter(frame => frame.type === FrameType.VFS_MUT)
      .map(frame => decodeVfsMutation(frame.payload))
    const followUp = mutations.find(mutation => mutation.path === '/dsh/workspace/after.txt')
    assert.notEqual(followUp, undefined, 'the follow-up write reached the still-open channel')
    assert.equal(decodeUtf8(followUp?.data as Uint8Array), 'ok')
    assert.equal(mutations.filter(mutation => mutation.path === path).length, 1, 'the cleanup remove is mirrored')
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('G2-ENG-03: a refusal poisons the tool-journal boundary until the path is repaired', async () => {
  const { vfs, pair, hostFrames, dispose } = fixture()
  try {
    const path = '/dsh/workspace/testdata.bin'
    vfs.write(path, new Uint8Array(16 * 1024 * 1024))
    await settle()

    // First flush is the write tool's own fsync: it fails with the node errno
    // shape and a model-visible trailer instead of a channel close.
    const first = await journalBoundary(vfs, async () => {
      throw new Error('the refused write must not be reported as a success')
    })
    assert.equal(first.isError, true)
    assert.equal(first.executed, false)
    assert.match(first.text, /^Error: EFBIG/)
    assertRefusalTrailer(first.text, path)

    // The poison is persistent: another tool boundary still fails the same way
    // while the oversized file remains in the Worker VFS.
    const second = await journalBoundary(vfs, async () => {
      throw new Error('the poisoned boundary must run no tool body')
    })
    assert.equal(second.isError, true)
    assert.equal(second.executed, false)
    assert.match(second.text, /^Error: EFBIG/)
    assertRefusalTrailer(second.text, path)

    // Deleting the file repairs the condition; the next tool step succeeds.
    vfs.remove(path)
    const repaired = await journalBoundary(vfs, async () => {
      vfs.write('/dsh/workspace/small.txt', encodeUtf8('small'))
    })
    assert.equal(repaired.isError, false)
    assert.equal(repaired.executed, true)
    await withDeadline(vfs.flush(), 'flush of the repaired session')
    const mutations = hostFrames
      .filter(frame => frame.type === FrameType.VFS_MUT)
      .map(frame => decodeVfsMutation(frame.payload))
    assert.equal(mutations.at(-1)?.path, '/dsh/workspace/small.txt')
    assert.equal(pair.worker.nextMseq() > 1n, true)
  } finally {
    dispose()
    await pair.worker.close()
  }
})

test('G2-ENG-03: structural failures remain protocol errors that close the channel', async () => {
  const { vfs, pair, hostFrames, dispose } = fixture()
  try {
    // An append offset outside the post-write bytes is a structural violation;
    // the fail-loud class must not be softened into a resource refusal.
    vfs.emitForTest({
      kind: 'write',
      path: '/dsh/workspace/bad-append.bin',
      bytes: encodeUtf8('abc'),
      mode: 0o644,
      entryChanged: false,
      appendedFrom: 9,
    })
    await settle()
    // A structural failure still fails loud: the frame may race the immediate
    // close on the in-memory link, so assert the observable close contract.
    assert.equal(hostFrames.some(frame => frame.type === FrameType.ERROR
      && jsonOf(frame)['code'] === 'VFS_REFUSED'), false)
    assert.equal(hostFrames.some(frame => frame.type === FrameType.VFS_MUT), false)
    assert.equal(pair.worker.nextMseq(), 1n)
    await assert.rejects(vfs.flush(), (error: unknown) => (error as { code?: string }).code === 'EINVAL')
    await assert.rejects(pair.worker.waitAck(1, 1n), /closed/)
  } finally {
    dispose()
  }
})


test('G2-ENG-03: the real tool-journal boundary ends the step with the trailer, not a hang', async () => {
  const ctx = new Context()
  const path = '/dsh/workspace/testdata.bin'
  const hint = vfsRefusalHint('EFBIG', MAX_MUTATION_DATA, path)
  let flushes = 0
  ctx.provide('sessions', {
    flush: async () => {
      flushes += 1
      throw new VfsRefusalError({ code: 'EFBIG', path, limit: MAX_MUTATION_DATA, hint })
    },
  })
  ctx.provide('tools', { get: () => undefined })
  await ctx.plugin(ToolJournal, {
    root: mkdtempSync(join(tmpdir(), 'pdsh-sink-refusal-')),
    profile: 'pdsh-phone/1+refusal',
    classes: {},
    rerun: true,
    rerunTimeoutMs: 1_000,
  })
  try {
    const journal = ctx.get('toolJournal') as ToolJournal
    let executed = false
    const boundary = ctx.waterfall('tools/execute', {
      agent: { session: { id: 'sess_eng03' } },
      name: 'write',
      callId: 'call_eng03',
      arguments: {},
      signal: new AbortController().signal,
    } as never, (async () => {
      executed = true
      return { content: [], isError: false }
    }) as never).then(
      () => ({ isError: false, text: '' }),
      (error: unknown) => ({ isError: true, text: `Error: ${error instanceof Error ? error.message : String(error)}` }),
    )
    const step = await withDeadline(boundary, 'tool-journal boundary')
    assert.equal(executed, false, 'the tool body never ran behind a failed boundary flush')
    assert.equal(flushes, 1)
    assert.equal(step.isError, true)
    assertRefusalTrailer(step.text, path)
    assert.equal(journal.store.entries('sess_eng03').calls.size, 0, 'no start record was written for the failed step')
  } finally {
    await ctx.fiber.dispose()
  }
})

test('G2-ENG-03: ENOSPC and quota errno shapes take the same refusal path', () => {
  const cases = [
    { code: 'ENOSPC', reason: 'no-space' },
    { code: 'EDQUOT', reason: 'quota-exceeded' },
  ] as const
  for (const item of cases) {
    const error = Object.assign(new Error('resource bound reached'), {
      code: item.code,
      path: '/dsh/workspace/full.bin',
      limit: 50 * 1024 * 1024,
      hint: 'delete files or write less',
    })
    const record = vfsRefusalRecordFromError(error)
    assert.notEqual(record, undefined)
    assert.equal(record?.code, item.code)
    assert.equal(vfsRefusalReason(item.code), item.reason)
    assert.equal(record?.path, '/dsh/workspace/full.bin')
    assert.equal(record?.limit, 50 * 1024 * 1024)
  }
  assert.equal(vfsRefusalRecordFromError(Object.assign(new Error('bad'), { code: 'EINVAL' })), undefined)
})
