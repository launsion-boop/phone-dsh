// SPDX-License-Identifier: MIT
// MemoryVfs is the Worker-side VFS authority. The phone host's sink depends on
// record() being synchronous, flush() awaiting the sink, and the observer
// stream carrying every mutation (including append offsets).
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'
import type { ProbeMutation } from '../src/probe-types.ts'

const decoder = new TextDecoder()

/**
 * Convert a mutation into a printable observation.
 * @param mutation - mutation published by the VFS.
 * @returns a JSON-safe description.
 */
function describeMutation(mutation: ProbeMutation): Record<string, unknown> {
  if (mutation.kind === 'write') {
    return {
      kind: mutation.kind,
      path: mutation.path,
      text: decoder.decode(mutation.bytes),
      mode: mutation.mode,
      entryChanged: mutation.entryChanged,
      appendedFrom: mutation.appendedFrom ?? null,
    }
  }
  if (mutation.kind === 'mkdir' || mutation.kind === 'chmod') {
    return { kind: mutation.kind, path: mutation.path, mode: mutation.mode }
  }
  return { kind: mutation.kind, path: mutation.path }
}

test('memory vfs: record() is synchronous and flush() awaits the sink', async (t) => {
  const probe = await loadProbe()
  let releaseFlush: () => void = () => {}
  const flushGate = new Promise<void>((resolve) => { releaseFlush = resolve })
  const records: ProbeMutation[] = []
  let flushCalls = 0
  const vfs = new probe.MemoryVfs({
    sink: {
      record(mutation) { records.push(mutation) },
      flush() { flushCalls += 1; return flushGate },
    },
  })
  vfs.seedDirectory('/dsh/home')
  vfs.writeFileSync('/dsh/home/a.txt', 'hello')
  const afterWrite = { records: records.length, flushCalls }
  observe(t, 'recordIsSynchronous', afterWrite)
  assert.equal(afterWrite.records, 1, 'record() must run before writeFileSync returns')
  assert.equal(afterWrite.flushCalls, 0, 'writeFileSync must not flush the sink')

  let flushSettled = false
  const flushing = vfs.flush().then(() => { flushSettled = true })
  await Promise.resolve()
  const beforeRelease = { flushCalls, flushSettled }
  observe(t, 'flushAwaitsSink', beforeRelease)
  assert.equal(beforeRelease.flushCalls, 1, 'flush() must call the sink flush')
  assert.equal(beforeRelease.flushSettled, false, 'flush() must await the sink promise')

  releaseFlush()
  await flushing
  assert.equal(flushSettled, true, 'flush() resolves after the sink resolves')
})

test('memory vfs: observers see every mutation including appendedFrom', async (t) => {
  const probe = await loadProbe()
  const events: ProbeMutation[] = []
  const sinkRecords: ProbeMutation[] = []
  const vfs = new probe.MemoryVfs({
    sink: {
      record(mutation) { sinkRecords.push(mutation) },
      flush() { return Promise.resolve() },
    },
  })
  const dispose = vfs.subscribe(mutation => { events.push(mutation) })
  vfs.seedDirectory('/dsh/home')
  const seeded = events.length
  vfs.writeFileSync('/dsh/home/a.txt', 'hello')
  vfs.appendFileSync('/dsh/home/a.txt', ' world')
  vfs.mkdirSync('/dsh/home/sub', { recursive: true })
  vfs.chmodSync('/dsh/home/a.txt', 0o600)
  vfs.rmSync('/dsh/home/a.txt')
  dispose()
  vfs.writeFileSync('/dsh/home/b.txt', 'after dispose')

  const described = events.map(describeMutation)
  const sinks = sinkRecords.map(describeMutation)
  observe(t, 'mutationStream', { seeded, described, sinkKinds: sinks.map(item => item['kind']) })
  assert.equal(seeded, 0, 'image seeding must stay silent')
  assert.deepEqual(described.map(item => item['kind']), ['write', 'write', 'mkdir', 'chmod', 'remove'])
  assert.equal(described[0]?.['entryChanged'], true)
  assert.equal(described[1]?.['entryChanged'], false)
  assert.equal(described[1]?.['appendedFrom'], 5)
  const appendedText = described[1]?.['text']
  assert.equal(typeof appendedText, 'string')
  assert.equal((appendedText as string).slice(5), ' world', 'appendedFrom must name the offset the mutation appends at')
  assert.deepEqual(
    sinks.slice(0, described.length).map(item => item['kind']),
    described.map(item => item['kind']),
    'the sink and subscribe listeners must observe the same mutations',
  )
  assert.equal(events.length, 5, 'a disposed listener must stop receiving mutations')
  assert.equal(sinkRecords.length, 6, 'the sink keeps receiving mutations after a listener is disposed')
})
