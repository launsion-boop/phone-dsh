// SPDX-License-Identifier: MIT
// G2-FIX-80: byte-faithful string writes at the pinned runtime's `node:fs` seam.
//
// The Worker shell hands just-bash's redirection writes to `node:fs` as a
// latin1-shaped ByteString with Node's `{encoding: 'binary'}`. The pinned
// runtime ignores the declared encoding and stores the UTF-8 encoding of the
// string, so every byte >= 0x80 is double-encoded (`c3 ad` -> `c3 83 c2 ad`);
// the sink, WAL, materialized copy and resume overlay then faithfully persist
// the damage. This test drives the real Worker shell and the real VfsFileSystem
// over an encoding-ignoring promise face (the runtime's behavior) and pins the
// three payload classes of the defect.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import { createMemoryChannelPair } from '../channel/src/index.ts'
import { createNamespaceVfs, WORKER_VFS_NAMESPACE, wrapFsPromises } from '../wasi-toolbox/src/index.ts'
import { startPhoneWorker } from '../worker-entry/src/entry.ts'
import type { PhoneWorkerRuntime, WorkerEntrySynthesize } from '../worker-entry/src/entry.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { encodeTextForVfs, installByteFaithfulWrites } from '../worker-entry/src/write-encoding.ts'
import { TreeVfs } from './tree-vfs.ts'

const encoder = new TextEncoder()

/** just-bash's ByteString: one JS character per byte, never decoded text. */
function byteString(bytes: Uint8Array): string {
  let out = ''
  for (const byte of bytes) out += String.fromCharCode(byte)
  return out
}

/** One Worker-shell tree with the runtime's encoding-ignoring promise face. */
function fixture(): {
  readonly base: TreeVfs
  readonly face: ReturnType<typeof wrapFsPromises>
  readonly shell: WorkerShell
} {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  // `TreeVfs` mirrors the runtime's `MemoryVfs`: a string is stored as its
  // UTF-8 encoding and `options.encoding` is ignored, so this face reproduces
  // the pinned runtime contract gap without vendoring it.
  const face = wrapFsPromises(base.promises, WORKER_VFS_NAMESPACE)
  const fs = new VfsFileSystem({ nodeFs: face as never, root: '', workerPaths: true })
  return { base, face, shell: new WorkerShell({ fs }) }
}

const PAYLOADS: readonly { readonly name: string; readonly bytes: Uint8Array }[] = [
  { name: 'two-byte UTF-8', bytes: encoder.encode('name = "García"\n') },
  { name: 'four-byte UTF-8', bytes: encoder.encode('face = "\u{1F600}"\n') },
  // 0x80/0xff are invalid UTF-8 alone; ed a0 80 is a UTF-8 surrogate.
  { name: 'non-UTF-8 binary', bytes: new Uint8Array([0x00, 0x01, 0xff, 0x80, 0xc3, 0x28, 0xed, 0xa0, 0x80, 0x0a]) },
]

for (const payload of PAYLOADS.filter(candidate => candidate.name !== 'non-UTF-8 binary')) {
  test(`shell redirection keeps every byte (${payload.name})`, async () => {
    const { base, face, shell } = fixture()
    installByteFaithfulWrites(face as never)
    // The heredoc delivers its text through just-bash's ByteString pipeline and
    // the redirection writes it with `{encoding:'binary'}` — the exact G2-B05
    // write shape.
    const result = await shell.runScript(
      `cat > /dsh/workspace/written.txt <<'PY'\n${new TextDecoder().decode(payload.bytes)}PY\n`,
      { cwd: '/dsh/workspace' })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.deepEqual([...base.readFileSync('/dsh/workspace/written.txt') as Uint8Array], [...payload.bytes])
  })
}

for (const payload of PAYLOADS) {
  test(`encoded write face keeps every byte (${payload.name})`, async () => {
    const { base, face } = fixture()
    const dispose = installByteFaithfulWrites(face as never)
    try {
      // The direct seam the shell's `writeFile`/`appendFile` uses: a string plus
      // Node's byte encoding must store exactly those bytes.
      await (face as unknown as {
        writeFile(path: string, data: string, options: { encoding: 'binary' }): Promise<void>
      }).writeFile('/dsh/workspace/blob.bin', byteString(payload.bytes), { encoding: 'binary' })
      assert.deepEqual([...base.readFileSync('/dsh/workspace/blob.bin') as Uint8Array], [...payload.bytes])

      await (face as unknown as {
        appendFile(path: string, data: string, options: { encoding: 'latin1' }): Promise<void>
      }).appendFile('/dsh/workspace/blob.bin', byteString(payload.bytes), { encoding: 'latin1' })
      assert.deepEqual([...base.readFileSync('/dsh/workspace/blob.bin') as Uint8Array],
        [...payload.bytes, ...payload.bytes])
    } finally {
      dispose()
    }
  })
}

test('encoded write helper materializes the declared Node encodings', () => {
  const payload = PAYLOADS[2]!.bytes
  assert.deepEqual([...encodeTextForVfs(byteString(payload), 'binary')!], [...payload])
  assert.deepEqual([...encodeTextForVfs(byteString(payload), 'latin1')!], [...payload])
  assert.deepEqual([...encodeTextForVfs('00ff80', 'hex')!], [0x00, 0xff, 0x80])
  assert.deepEqual([...encodeTextForVfs('AP+A', 'base64')!], [0x00, 0xff, 0x80])
  assert.equal(encodeTextForVfs('plain', 'utf8'), undefined, 'UTF-8 keeps the runtime path')
})

test('dispose restores the original write faces', async () => {
  const { base, face } = fixture()
  const dispose = installByteFaithfulWrites(face as never)
  dispose()
  const original = (face as unknown as { writeFile: (path: string, data: string, options: unknown) => Promise<void> }).writeFile
  // After the restore the encoding-ignoring runtime behavior is back (the
  // shim never leaks past a stopped Worker).
  await original('/dsh/workspace/x.txt', 'García', { encoding: 'binary' } as never)
  assert.deepEqual([...base.readFileSync('/dsh/workspace/x.txt') as Uint8Array],
    [...encoder.encode('García')])
})

test('startPhoneWorker installs and disposes the byte-faithful write shim', async () => {
  const pair = createMemoryChannelPair({ autoConnect: true })
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  let installed = 0
  let disposed = 0
  const synthesize: WorkerEntrySynthesize = (_request, sink) => {
    const res: Record<string, unknown> = {
      writeHead: () => res,
      write: () => true,
      end: () => { sink.end({ status: 200, headers: {}, body: new Uint8Array(0) }); return res },
      destroy: () => { sink.fail('destroyed') },
    }
    return { req: {}, res, aborted: false, abort: () => {} }
  }
  const runtime: PhoneWorkerRuntime = {
    createHost: () => ({ handleMessage: () => {}, start: async () => {}, stop: async () => {}, vfs }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize,
    installByteFaithfulWrites: () => {
      installed += 1
      return () => { disposed += 1 }
    },
  }
  const handle = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    imageURL: 'image.tar.gz',
    runtime,
    python: false,
    pagePost: () => {},
  })
  try {
    assert.equal(installed, 1, 'the entry installs the write-encoding shim before the tree boots')
    assert.equal(disposed, 0)
  } finally {
    await handle.stop()
    pair.setDrop(() => true)
    pair.disconnect()
  }
  assert.equal(disposed, 1, 'an orderly stop restores the original write faces')
})
