// SPDX-License-Identifier: MIT
// G2-FIX-80: byte fidelity of the park/resume persistence boundaries.
//
// The parking host answers an appended base mismatch with a `0x13 VFS_RESYNC`
// and the Worker re-sends the whole file as a normal complete write (D8). That
// re-read is the one place in the persistence chain where a VFS value becomes a
// string before it enters the WAL; the shell/VFS convention in this layer is
// just-bash's latin1-shaped `ByteString` (one JS character per byte), so
// re-encoding that string as UTF-8 silently double-encodes every byte ≥ 0x80.
// These tests pin the three payload classes the real-model batch exposed
// (two-byte UTF-8, four-byte UTF-8, non-UTF-8 binary) at that boundary and at
// the sink -> 0x10 encode boundary.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createMemoryChannelPair,
  decodeVfsMutation,
  encodeVfsMutation,
  encodeVfsResync,
  FrameType,
  type Frame,
} from '../channel/src/index.ts'
import { installResyncHandler, installSink } from '../worker-entry/src/entry.ts'
import type {
  WorkerEntryMutation,
  WorkerEntryVfs,
} from '../worker-entry/src/entry.ts'
import { eventually } from './test-channel.ts'

/** The three payload classes of the defect: 2-byte and 4-byte UTF-8, and binary. */
const PAYLOADS: readonly { readonly name: string; readonly bytes: Uint8Array }[] = [
  { name: 'two-byte UTF-8', bytes: new TextEncoder().encode('name = "García"\n') },
  { name: 'four-byte UTF-8', bytes: new TextEncoder().encode('face = "\u{1F600}"\n') },
  // 0x80/0xff are invalid UTF-8 on their own and ed a0 80 is a surrogate.
  { name: 'non-UTF-8 binary', bytes: new Uint8Array([0x00, 0x01, 0xff, 0x80, 0xc3, 0x28, 0xed, 0xa0, 0x80, 0x0a]) },
]

/** just-bash's ByteString: one JS character per byte, never decoded text. */
function byteString(bytes: Uint8Array): string {
  let out = ''
  for (const byte of bytes) out += String.fromCharCode(byte)
  return out
}

/** A static VFS exposing exactly the resync face the handler consumes. */
function resyncVfs(contents: Uint8Array | string): WorkerEntryVfs {
  return {
    subscribe: () => () => {},
    flush: async () => {},
    readFileSync: () => contents,
    statSync: () => ({ mode: 0o100644, isFile: () => true }),
  }
}

/** Send one host VFS_RESYNC and resolve the Worker's complete-write answer. */
async function requestResync(
  vfs: WorkerEntryVfs,
  path: string,
): Promise<ReturnType<typeof decodeVfsMutation>> {
  const pair = createMemoryChannelPair({ autoConnect: true })
  const received: ReturnType<typeof decodeVfsMutation>[] = []
  pair.host.onFrame((frame: Frame) => {
    if (frame.type === FrameType.VFS_MUT) received.push(decodeVfsMutation(frame.payload))
  })
  const dispose = installResyncHandler(vfs, pair.worker)
  try {
    pair.host.send(FrameType.VFS_RESYNC, encodeVfsResync({ path }))
    await eventually(() => received.length > 0, 3_000)
    assert.equal(received.length, 1, 'the Worker must answer one VFS_RESYNC with one complete write')
    return received[0]!
  } finally {
    dispose()
    pair.setDrop(() => true)
    pair.disconnect()
  }
}

for (const payload of PAYLOADS) {
  test(`resync: a ByteString VFS re-read keeps every byte (${payload.name})`, async () => {
    const path = '/dsh/workspace/g2-fix-80.txt'
    const mutation = await requestResync(resyncVfs(byteString(payload.bytes)), path)
    assert.equal(mutation.path, path)
    assert.equal(mutation.mflags & 0x02, 0, 'the repair is a complete write, not an append')
    assert.deepEqual([...mutation.data], [...payload.bytes])
  })

  test(`resync: a bytes VFS re-read keeps every byte (${payload.name})`, async () => {
    const path = '/dsh/workspace/g2-fix-80.bin'
    const mutation = await requestResync(resyncVfs(payload.bytes), path)
    assert.deepEqual([...mutation.data], [...payload.bytes])
  })

  test(`sink -> 0x10 keeps every byte (${payload.name})`, async () => {
    const pair = createMemoryChannelPair({ autoConnect: true })
    const received: ReturnType<typeof decodeVfsMutation>[] = []
    pair.host.onFrame((frame: Frame) => {
      if (frame.type === FrameType.VFS_MUT) received.push(decodeVfsMutation(frame.payload))
    })
    let listener: ((mutation: WorkerEntryMutation) => void) | undefined
    const vfs: WorkerEntryVfs = {
      subscribe: (next) => { listener = next; return () => { listener = undefined } },
      flush: async () => {},
      readFileSync: () => payload.bytes,
      statSync: () => ({ mode: 0o100644, isFile: () => true }),
    }
    const dispose = installSink(vfs, pair.worker)
    try {
      assert.notEqual(listener, undefined)
      listener?.({
        kind: 'write',
        path: '/dsh/workspace/sink.bin',
        bytes: payload.bytes,
        mode: 0o644,
        entryChanged: true,
      } as WorkerEntryMutation)
      await eventually(() => received.length > 0, 3_000)
      assert.deepEqual([...received[0]!.data], [...payload.bytes])
      assert.deepEqual([...decodeVfsMutation(encodeVfsMutation(received[0]!)).data], [...payload.bytes])
    } finally {
      dispose()
      pair.setDrop(() => true)
      pair.disconnect()
    }
  })
}
