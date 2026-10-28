// SPDX-License-Identifier: MIT
/**
 * G2-FIX-103: one proxied write is awaitable-with-outcome.
 *
 * The old proxy answered a WASI `fd_write` as soon as the Worker memory VFS
 * accepted the bytes. A host resource refusal (`ERROR VFS_REFUSED`) or a D3
 * flow-control stall therefore never reached the interpreter: it either
 * reported a successful write the host had refused, or parked the command in a
 * `VFS_ACK` wait with no bound on the write path. These unit tests pin the
 * tracker contract the proxy and the sink share, including refusal dedupe:
 * one diagnostic delivered twice is applied once, while a genuine refusal of a
 * different mutation the channel renumbered into the same slot still settles it.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { VfsProxyError } from './errors.ts'
import { WASI_ERRNO, errnoFromError } from './wasi-errno.ts'
import {
  DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS,
  DEFAULT_UNACKED_VFS_WINDOW_BYTES,
  MAX_VFS_FLOW_CONTROL_TIMEOUT_MS,
  VfsFlowControlError,
  VfsWriteOutcomes,
  resolveVfsFlowControlTimeoutMs,
  vfsWriteRefusalMessage,
} from './write-outcomes.ts'

/** Fail with a clear message instead of letting a hung test stall the suite. */
function withWatchdog<T>(promise: Promise<T>, what: string, ms = 1_000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`watchdog: ${what} did not settle in ${ms} ms`)), ms)
    promise.then(
      (value) => { clearTimeout(timer); resolve(value) },
      (error: unknown) => { clearTimeout(timer); reject(error) },
    )
  })
}

test('G2-FIX-103: a level-1 ack covering every mutation settles the write', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const ticket = outcomes.begin('/dsh/workspace/report.bin')
  outcomes.notePublished('/dsh/workspace/report.bin', 1n, 4096)
  outcomes.notePublished('/dsh/workspace/report.bin', 2n, 4096)
  outcomes.endPublishing(ticket)
  // Nothing acked yet: the write is genuinely pending.
  assert.equal(outcomes.pending, 1)
  outcomes.noteAck(1, 1n)
  assert.equal(outcomes.pending, 1, 'a partial ack does not settle a two-frame write')
  outcomes.noteAck(1, 2n)
  assert.equal(outcomes.pending, 0)
  await withWatchdog(outcomes.awaitOutcome(ticket), 'acked proxied write')
})

test('G2-FIX-103: a level-2 ack is cumulative and covers level-1 frames', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const ticket = outcomes.begin('/dsh/workspace/report.bin')
  outcomes.notePublished('/dsh/workspace/report.bin', 7n, 1024)
  outcomes.endPublishing(ticket)
  outcomes.noteAck(2, 7n)
  await withWatchdog(outcomes.awaitOutcome(ticket), 'durable ack')
})

test('G2-FIX-103: an ack during publication cannot settle a multi-frame write early', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const path = '/dsh/workspace/large.bin'
  const ticket = outcomes.begin(path)
  outcomes.notePublished(path, 7n, 15 * 1024 * 1024)
  // A synchronous channel can answer the first frame from inside send(), while
  // the sink is still publishing the appended suffix frames.
  outcomes.noteAck(1, 7n)
  assert.equal(outcomes.pending, 1, 'the publication window is still open')
  outcomes.notePublished(path, 8n, 1024)
  outcomes.endPublishing(ticket)
  assert.equal(outcomes.pending, 1, 'the second frame has no ack yet')
  outcomes.noteAck(1, 8n)
  assert.equal(outcomes.pending, 0)
  await withWatchdog(outcomes.awaitOutcome(ticket), 'multi-frame write')
})

test('G2-FIX-103: a stale refusal cannot fail a newer write to the same path', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const path = '/dsh/workspace/reused.bin'
  const first = outcomes.begin(path)
  outcomes.notePublished(path, 1n, 8)
  outcomes.endPublishing(first)
  outcomes.noteAck(1, 1n)
  await withWatchdog(outcomes.awaitOutcome(first), 'first write')

  const second = outcomes.begin(path)
  outcomes.notePublished(path, 2n, 8)
  outcomes.endPublishing(second)
  // A duplicate refusal for the already-acked mseq 1 must not reject mseq 2.
  outcomes.noteRefusal({ code: 'EFBIG', path, limit: 1024 }, 1n)
  assert.equal(outcomes.pending, 1)
  outcomes.noteAck(1, 2n)
  await withWatchdog(outcomes.awaitOutcome(second), 'second write')
})

test('G2-FIX-103: a host VFS_REFUSED rejects the write as EFBIG with the limit and remediation', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const path = '/dsh/workspace/limit_probe.bin'
  const ticket = outcomes.begin(path)
  outcomes.notePublished(path, 1n, 1_048_576)
  outcomes.endPublishing(ticket)
  outcomes.noteRefusal({
    code: 'EFBIG',
    path,
    limit: 67_108_864,
    hint: 'File too large: split the data into chunks under 67108864 bytes (64 MiB)',
  }, 1n)
  await assert.rejects(withWatchdog(outcomes.awaitOutcome(ticket), 'refused proxied write'), (error: unknown) => {
    assert.ok(error instanceof VfsProxyError)
    assert.equal(error.code, 'EFBIG')
    assert.equal(error.path, path)
    assert.match(error.message, /67108864 bytes/)
    assert.match(error.message, /64 MiB/)
    assert.match(error.message, /chunk/i, 'the message carries the split/chunk remediation')
    return true
  })
  assert.equal(outcomes.pending, 0, 'the refusal settles the ticket instead of leaving it pending')
})

test('G2-FIX-103: a refusal consumes no mseq, so later frames are renumbered down', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const refused = outcomes.begin('/dsh/workspace/refused.bin')
  outcomes.notePublished('/dsh/workspace/refused.bin', 3n, 10)
  outcomes.endPublishing(refused)
  const later = outcomes.begin('/dsh/workspace/later.bin')
  outcomes.notePublished('/dsh/workspace/later.bin', 4n, 10)
  outcomes.endPublishing(later)

  outcomes.noteRefusal({ code: 'ENOSPC', path: '/dsh/workspace/refused.bin', limit: 1024 }, 3n)
  await assert.rejects(withWatchdog(outcomes.awaitOutcome(refused), 'refused write'), /ENOSPC: VFS refused/)
  // The channel client renumbers the remaining unacked buffer into the freed
  // slot; the later ticket follows it and settles on the new mseq.
  outcomes.noteAck(1, 3n)
  await withWatchdog(outcomes.awaitOutcome(later), 'renumbered write')
})

test('G2-FIX-103: one refusal delivered twice renumbers every in-flight write exactly once', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const refusedPath = '/dsh/workspace/refused-twice.bin'
  const laterPath = '/dsh/workspace/later-in-flight.bin'
  const thirdPath = '/dsh/workspace/third-in-flight.bin'
  const refused = outcomes.begin(refusedPath)
  outcomes.notePublished(refusedPath, 3n, 10)
  outcomes.endPublishing(refused)
  const later = outcomes.begin(laterPath)
  outcomes.notePublished(laterPath, 4n, 10)
  outcomes.endPublishing(later)
  const third = outcomes.begin(thirdPath)
  outcomes.notePublished(thirdPath, 5n, 10)
  outcomes.endPublishing(third)

  // The sink's `onFrame` hook and the command-boundary `flush()` both observe
  // the same host diagnostic; the second delivery must be a no-op. Pre-fix it
  // renumbers the later writes a second time and settles the one that moved
  // into the refused slot as if it had been refused itself.
  const refusal = { code: 'EFBIG' as const, path: refusedPath, limit: 1_024 }
  outcomes.noteRefusal(refusal, 3n)
  outcomes.noteRefusal(refusal, 3n)

  await assert.rejects(withWatchdog(outcomes.awaitOutcome(refused), 'refused write'), /EFBIG: VFS refused/)
  assert.equal(outcomes.pending, 2, 'the duplicate delivery must leave both in-flight writes pending')

  // The refusal consumed mseq 3, so 4 -> 3 and 5 -> 4; each write settles on
  // its own ack and ack 3 must not cover the second write.
  outcomes.noteAck(1, 3n)
  await withWatchdog(outcomes.awaitOutcome(later), 'first renumbered write')
  assert.equal(outcomes.pending, 1, 'ack 3 covers only the first renumbered write')
  outcomes.noteAck(1, 4n)
  await withWatchdog(outcomes.awaitOutcome(third), 'second renumbered write')
  assert.equal(outcomes.pending, 0)
})

test('G2-FIX-103: a genuine second refusal of a renumbered write at the reused slot is not deduplicated', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const firstPath = '/dsh/workspace/twice-refused-first.bin'
  const secondPath = '/dsh/workspace/twice-refused-second.bin'
  const survivorPath = '/dsh/workspace/twice-refused-survivor.bin'
  const first = outcomes.begin(firstPath)
  outcomes.notePublished(firstPath, 1n, 10)
  outcomes.endPublishing(first)
  const second = outcomes.begin(secondPath)
  outcomes.notePublished(secondPath, 2n, 10)
  outcomes.endPublishing(second)
  const survivor = outcomes.begin(survivorPath)
  outcomes.notePublished(survivorPath, 3n, 10)
  outcomes.endPublishing(survivor)

  const firstRefusal = { code: 'EFBIG' as const, path: firstPath, limit: 1_024 }
  outcomes.noteRefusal(firstRefusal, 1n)
  // The sink frame hook and the parked flush both see the same diagnostic: the
  // second delivery must stay a no-op and renumber the survivors exactly once.
  outcomes.noteRefusal(firstRefusal, 1n)
  await assert.rejects(withWatchdog(outcomes.awaitOutcome(first), 'first refused write'), /EFBIG: VFS refused/)
  assert.equal(outcomes.pending, 2, 'the duplicate delivery left both survivors pending')

  // The channel renumbered `second` into the refused slot 1 and re-sent it; the
  // host now genuinely refuses that mutation. It is a different mutation at the
  // same reused slot, so keying the dedupe set by mseq alone would drop it.
  outcomes.noteRefusal({ code: 'ENOSPC', path: secondPath, limit: 2_048 }, 1n)
  await assert.rejects(withWatchdog(
    outcomes.awaitOutcome(second),
    'write refused at the reused slot',
  ), (error: unknown) => {
    assert.ok(error instanceof VfsProxyError)
    assert.equal(error.code, 'ENOSPC')
    assert.equal(error.path, secondPath)
    assert.match(error.message, /2048 bytes/)
    return true
  })
  assert.equal(outcomes.pending, 1, 'only the third write survives the second refusal')

  // The second refusal freed slot 1 again: the surviving write was renumbered
  // into it and must settle on the host's renumbered ack.
  outcomes.noteAck(1, 1n)
  await withWatchdog(outcomes.awaitOutcome(survivor), 'survivor renumbered after the second refusal')
  assert.equal(outcomes.pending, 0)
})

test('G2-FIX-103: a new write published into a freed refused slot re-arms the dedupe set', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const path = '/dsh/workspace/rearmed-slot.bin'
  const first = outcomes.begin(path)
  outcomes.notePublished(path, 1n, 10)
  outcomes.endPublishing(first)
  const refusal = { code: 'EFBIG' as const, path, limit: 1_024 }
  outcomes.noteRefusal(refusal, 1n)
  outcomes.noteRefusal(refusal, 1n)
  await assert.rejects(withWatchdog(outcomes.awaitOutcome(first), 'first refused write'), /EFBIG: VFS refused/)

  // The refusal consumed no mseq, so the channel reuses slot 1 for a later
  // mutation of the same path. Publishing into the slot re-arms the dedupe:
  // a genuine refusal of the new occupant must not be dropped as a duplicate
  // of the previous occupant's refusal.
  const second = outcomes.begin(path)
  outcomes.notePublished(path, 1n, 10)
  outcomes.endPublishing(second)
  outcomes.noteRefusal(refusal, 1n)
  await assert.rejects(withWatchdog(
    outcomes.awaitOutcome(second),
    'write refused after the slot was reused',
  ), (error: unknown) => {
    assert.ok(error instanceof VfsProxyError)
    assert.equal(error.code, 'EFBIG')
    assert.equal(error.path, path)
    return true
  })
  assert.equal(outcomes.pending, 0)
})

test('G2-FIX-103: a stalled ack stream fails loud with a typed bounded error, not a hang', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 40, windowBytes: DEFAULT_UNACKED_VFS_WINDOW_BYTES })
  const path = '/dsh/workspace/stalled.bin'
  const ticket = outcomes.begin(path)
  outcomes.notePublished(path, 1n, 1_048_576)
  outcomes.endPublishing(ticket)

  const started = Date.now()
  await assert.rejects(withWatchdog(outcomes.awaitOutcome(ticket), 'stalled write'), (error: unknown) => {
    assert.ok(error instanceof VfsFlowControlError, `expected the typed error, got ${String(error)}`)
    assert.equal(error.code, 'ETIMEDOUT')
    assert.equal(error.timeoutMs, 40)
    assert.equal(error.pendingBytes, 1_048_576)
    assert.match(error.message, /flow control/)
    assert.match(error.message, /40 ms/)
    assert.match(error.message, /33554432 bytes/)
    return true
  })
  assert.ok(Date.now() - started >= 30, 'the bound actually waited before failing')
  assert.equal(outcomes.failure instanceof VfsFlowControlError, true,
    'the failure is exposed for the command boundary')

  // The channel was not touched: an ack that finally arrives clears the
  // failure and a new write on the same tracker succeeds.
  outcomes.noteAck(1, 1n)
  assert.equal(outcomes.failure, undefined)
  const next = outcomes.begin('/dsh/workspace/after.bin')
  outcomes.notePublished('/dsh/workspace/after.bin', 2n, 4)
  outcomes.endPublishing(next)
  outcomes.noteAck(1, 2n)
  await withWatchdog(outcomes.awaitOutcome(next), 'write after the stall recovered')
})

test('G2-FIX-103: a write that never reached the sink resolves without waiting', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 30 })
  // A volatile root is never published by the sink; there is no host outcome.
  const ticket = outcomes.begin('/dsh/tmp/scratch.bin')
  outcomes.endPublishing(ticket)
  await withWatchdog(outcomes.awaitOutcome(ticket), 'volatile write')
  assert.equal(outcomes.pending, 0)
})

test('G2-FIX-103: closing the tracker rejects every pending write', async () => {
  const outcomes = new VfsWriteOutcomes({ timeoutMs: 500 })
  const ticket = outcomes.begin('/dsh/workspace/pending.bin')
  outcomes.notePublished('/dsh/workspace/pending.bin', 1n, 8)
  outcomes.endPublishing(ticket)
  outcomes.close()
  await assert.rejects(withWatchdog(outcomes.awaitOutcome(ticket), 'closed tracker'), /closed/)
})

test('G2-FIX-103: the flow-control window is a validated config field', () => {
  assert.equal(resolveVfsFlowControlTimeoutMs(), DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS)
  assert.equal(DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS, 30_000)
  assert.equal(new VfsWriteOutcomes().timeoutMs, DEFAULT_VFS_FLOW_CONTROL_TIMEOUT_MS)
  assert.equal(resolveVfsFlowControlTimeoutMs(1_234), 1_234)
  assert.throws(() => resolveVfsFlowControlTimeoutMs(0), RangeError)
  assert.throws(() => resolveVfsFlowControlTimeoutMs(-1), RangeError)
  assert.throws(() => resolveVfsFlowControlTimeoutMs(1.5), RangeError)
  assert.throws(() => resolveVfsFlowControlTimeoutMs(MAX_VFS_FLOW_CONTROL_TIMEOUT_MS + 1), RangeError)
})

test('G2-FIX-103: the refusal text always names the exact byte limit and a split remediation', () => {
  const message = vfsWriteRefusalMessage({ code: 'EFBIG', path: '/dsh/workspace/a.bin', limit: 15_728_640 })
  assert.match(message, /15728640 bytes/)
  assert.match(message, /15 MiB/)
  assert.match(message, /split/i)
  assert.equal(message.includes('\n'), false, 'the diagnostic is one line')
})

test('G2-FIX-103: a quota refusal reaches the guest as the bounded-resource errno', () => {
  // WASI preview1 has no quota errno; EDQUOT is a space condition and must not
  // degrade to EIO (which a guest cannot tell apart from a transport failure).
  assert.equal(
    errnoFromError(new VfsProxyError('EDQUOT', 'workspace quota exceeded', '/dsh/workspace/a.bin')),
    WASI_ERRNO.NOSPC,
  )
})
