// SPDX-License-Identifier: MIT
/**
 * G2-FIX-57 unit tests: the bounded stdin frames, the tool-worker assembly
 * that refuses a truncated delivery, and the WASI feed's explicit EOF.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  MAX_STDIN_BYTES, STDIN_CHUNK_BYTES, StdinAssembly, StdinDeliveryError, WasiStdin, isStdinFrame, splitStdinFrames,
} from './stdin-delivery.ts'

test('stdin frames: a payload is split into bounded chunks with one EOF frame', () => {
  const payload = new Uint8Array(STDIN_CHUNK_BYTES + 17).fill(7)
  const frames = splitStdinFrames(3, payload)
  assert.equal(frames.length, 2)
  assert.deepEqual(frames.map(frame => frame.seq), [0, 1])
  assert.deepEqual(frames.map(frame => frame.data.byteLength), [STDIN_CHUNK_BYTES, 17])
  assert.deepEqual(frames.map(frame => frame.eof), [false, true])
  assert.equal(frames.every(frame => frame.id === 3 && isStdinFrame(frame)), true)
  // One owned buffer per frame: a shared view would make structured clone
  // copy the whole payload for every frame.
  assert.equal(frames.every(frame => frame.data.buffer !== payload.buffer), true)
  assert.equal(frames.every(frame => frame.data.byteOffset === 0), true)

  const assembled = new StdinAssembly()
  for (const frame of frames) assembled.accept(frame)
  assert.equal(assembled.isComplete(3), true)
  const bytes = assembled.take(3)
  assert.equal(bytes.byteLength, payload.byteLength)
  assert.deepEqual(bytes, payload)
  assert.equal(assembled.isComplete(3), false, 'take consumes the assembly')
})

test('stdin frames: an empty delivery still carries the EOF marker', () => {
  const frames = splitStdinFrames(1, new Uint8Array(0))
  assert.equal(frames.length, 1)
  assert.equal(frames[0]?.eof, true)
  assert.equal(frames[0]?.data.byteLength, 0)
  const assembly = new StdinAssembly()
  assembly.accept(frames[0]!)
  assert.equal(assembly.take(1).byteLength, 0)
})

test('stdin frames: the payload bound refuses an oversized script before dispatch', () => {
  assert.throws(
    () => splitStdinFrames(1, new Uint8Array(MAX_STDIN_BYTES + 1)),
    (error: unknown) => error instanceof StdinDeliveryError && error.code === 'E_STDIN_OVERSIZE',
  )
})

test('stdin assembly: a missing EOF frame is a structured failure, not an empty script', () => {
  const assembly = new StdinAssembly()
  const [frame] = splitStdinFrames(9, new TextEncoder().encode('print(1)\n'))
  assert.ok(frame !== undefined)
  // Strip the EOF marker, as a transport that lost the last message would.
  assembly.accept({ ...frame, eof: false })
  assert.throws(
    () => assembly.take(9),
    (error: unknown) => error instanceof StdinDeliveryError
      && error.code === 'E_STDIN_INCOMPLETE'
      && /without the EOF frame/.test(error.message),
  )
})

test('stdin assembly: out-of-order and post-EOF frames are refused', () => {
  assert.throws(
    () => new StdinAssembly().accept({ type: 'stdin', id: 4, seq: 1, data: new Uint8Array(1), eof: true }),
    (error: unknown) => error instanceof StdinDeliveryError && error.code === 'E_STDIN_SEQUENCE',
  )
  const [first, second] = splitStdinFrames(4, new Uint8Array(STDIN_CHUNK_BYTES + 1))
  assert.ok(first !== undefined && second !== undefined)
  const assembly = new StdinAssembly()
  assembly.accept(first)
  assert.throws(
    () => assembly.accept(first),
    (error: unknown) => error instanceof StdinDeliveryError && error.code === 'E_STDIN_SEQUENCE',
  )
  assembly.accept(second)
  assert.throws(
    () => assembly.accept({ ...second, seq: 2, eof: true }),
    (error: unknown) => error instanceof StdinDeliveryError && error.code === 'E_STDIN_UNEXPECTED',
  )
  const eof = splitStdinFrames(5, new Uint8Array(0))[0]!
  const single = new StdinAssembly()
  single.accept(eof)
  assert.throws(
    () => single.accept({ ...eof, seq: 1 }),
    (error: unknown) => error instanceof StdinDeliveryError && error.code === 'E_STDIN_UNEXPECTED',
  )
})

test('stdin feed: bytes are read in order and EOF is reported only when complete', () => {
  const feed = new WasiStdin(new TextEncoder().encode('abcdef'), true)
  assert.equal(feed.atEof, false)
  assert.equal(new TextDecoder().decode(feed.read(2)), 'ab')
  assert.equal(new TextDecoder().decode(feed.read(10)), 'cdef')
  assert.equal(feed.atEof, true)
  assert.equal(feed.read(10).byteLength, 0)
  assert.equal(feed.totalBytes, 6)
  assert.equal(feed.bytesRead, 6)

  const incomplete = new WasiStdin(new TextEncoder().encode('ab'), false)
  assert.equal(incomplete.read(10).byteLength, 2)
  assert.equal(incomplete.atEof, false, 'an incomplete delivery never claims EOF')
})
