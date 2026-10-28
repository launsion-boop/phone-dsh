// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MessageChannel } from 'node:worker_threads'
import type { MessagePort } from 'node:worker_threads'
import { MemoryVfsBackend } from './vfs-backends.ts'
import { AsyncVfsClient } from './vfs-client.ts'
import type { MessageEndpoint } from './message-endpoint.ts'
import { VfsProxyServer } from './vfs-server.ts'
import { decodeResponses, encodeRequests } from './vfs-protocol.ts'
import type { VfsBackend, VfsValue } from './types.ts'

function portEndpoint(port: MessagePort): MessageEndpoint {
  return {
    postMessage: message => { port.postMessage(message) },
    onMessage(handler) {
      const listener = (message: unknown): void => { handler(message) }
      port.on('message', listener)
      return () => { port.off('message', listener) }
    },
  }
}

function fixture(): {
  backend: MemoryVfsBackend
  client: AsyncVfsClient
  close: () => void
} {
  const backend = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  backend.seedFile('/dsh/workspace/in.txt', 'hello world')
  backend.seedDirectory('/dsh/home')
  const server = new VfsProxyServer({
    backend,
    preopens: [
      { guestPath: '/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/home', hostPath: '/dsh/home' },
    ],
  })
  const { port1, port2 } = new MessageChannel()
  const detach = server.attach(portEndpoint(port1))
  const client = new AsyncVfsClient(portEndpoint(port2), { timeoutMs: 2000 })
  return {
    backend,
    client,
    close() {
      client.close()
      detach()
      port1.close()
      port2.close()
    },
  }
}

function text(value: VfsValue | undefined): string {
  assert.ok(value !== undefined)
  assert.equal(value.kind, 'data')
  return new TextDecoder().decode(value.data)
}

test('vfs proxy: stat and read follow the preopen mapping', async () => {
  const { client, close } = fixture()
  try {
    const stat = await client.call({ op: 'stat', path: '/dsh/workspace/in.txt' })
    assert.equal(stat.kind, 'stat')
    if (stat.kind !== 'stat') return
    assert.equal(stat.stat.kind, 'file')
    assert.equal(stat.stat.size, 11)

    const data = await client.call({ op: 'read', path: '/dsh/workspace/in.txt', offset: 6, length: 5 })
    assert.equal(text(data), 'world')

    const directory = await client.call({ op: 'stat', path: '/dsh/home' })
    assert.equal(directory.kind, 'stat')
    if (directory.kind === 'stat') assert.equal(directory.stat.kind, 'directory')
  } finally {
    close()
  }
})

test('vfs proxy: write, append, truncate and read-back land in the backend', async () => {
  const { backend, client, close } = fixture()
  try {
    const created = await client.call({
      op: 'write', path: '/dsh/workspace/out.txt', offset: 0, append: false, create: true, data: new TextEncoder().encode('abcd'),
    })
    assert.deepEqual(created, { kind: 'written', written: 4 })

    await client.call({
      op: 'write', path: '/dsh/workspace/out.txt', offset: 1, append: false, create: false, data: new TextEncoder().encode('XY'),
    })
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/out.txt')), 'aXYd')

    await client.call({
      op: 'write', path: '/dsh/workspace/out.txt', offset: 0, append: true, create: false, data: new TextEncoder().encode('!'),
    })
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/out.txt')), 'aXYd!')

    await client.call({ op: 'truncate', path: '/dsh/workspace/out.txt', length: 2 })
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/out.txt')), 'aX')

    const read = await client.call({ op: 'read', path: '/dsh/workspace/out.txt', offset: 0, length: 32 })
    assert.equal(text(read), 'aX')
  } finally {
    close()
  }
})

test('vfs proxy: open applies create, exclusive and truncate semantics', async () => {
  const { client, close } = fixture()
  try {
    await assert.rejects(
      client.call({
        op: 'open', path: '/dsh/workspace/missing.txt', create: false, truncate: false, exclusive: false, directory: false,
      }),
      /ENOENT/,
    )
    const opened = await client.call({
      op: 'open', path: '/dsh/workspace/new.txt', create: true, truncate: false, exclusive: false, directory: false,
    })
    assert.equal(opened.kind, 'stat')
    if (opened.kind === 'stat') assert.equal(opened.stat.size, 0)

    await assert.rejects(
      client.call({
        op: 'open', path: '/dsh/workspace/new.txt', create: true, truncate: false, exclusive: true, directory: false,
      }),
      /EEXIST/,
    )

    await client.call({
      op: 'write', path: '/dsh/workspace/new.txt', offset: 0, append: false, create: false, data: new TextEncoder().encode('content'),
    })
    const truncated = await client.call({
      op: 'open', path: '/dsh/workspace/new.txt', create: false, truncate: true, exclusive: false, directory: false,
    })
    assert.equal(truncated.kind, 'stat')
    if (truncated.kind === 'stat') assert.equal(truncated.stat.size, 0)
  } finally {
    close()
  }
})

test('vfs proxy: mkdir, rename and unlink keep POSIX-ish errors', async () => {
  const { backend, client, close } = fixture()
  try {
    await client.call({ op: 'mkdir', path: '/dsh/workspace/dir' })
    const entries = await client.call({ op: 'readdir', path: '/dsh/workspace' })
    assert.equal(entries.kind, 'entries')
    if (entries.kind === 'entries') {
      assert.deepEqual(entries.entries.map(entry => [entry.name, entry.kind]), [
        ['dir', 'directory'],
        ['in.txt', 'file'],
      ])
    }

    await client.call({ op: 'mkdir', path: '/dsh/workspace/dir/inner' })
    await assert.rejects(
      client.call({ op: 'unlink', path: '/dsh/workspace/dir', directory: true }),
      /ENOTEMPTY/,
    )

    await client.call({ op: 'rename', from: '/dsh/workspace/in.txt', to: '/dsh/workspace/moved.txt' })
    assert.equal(backend.peek('/dsh/workspace/in.txt'), undefined)
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/moved.txt')), 'hello world')

    await client.call({ op: 'unlink', path: '/dsh/workspace/moved.txt', directory: false })
    assert.equal(backend.peek('/dsh/workspace/moved.txt'), undefined)
    await client.call({ op: 'unlink', path: '/dsh/workspace/dir/inner', directory: true })
    await client.call({ op: 'unlink', path: '/dsh/workspace/dir', directory: true })
    await assert.rejects(client.call({ op: 'stat', path: '/dsh/workspace/dir' }), /ENOENT/)
  } finally {
    close()
  }
})

test('vfs proxy: a batch answers several operations in one frame', async () => {
  const { backend, client, close } = fixture()
  try {
    const values = await client.batch([
      { op: 'stat', path: '/dsh/workspace/in.txt' },
      { op: 'readdir', path: '/dsh/workspace' },
      {
        op: 'write', path: '/dsh/workspace/batch.txt', offset: 0, append: false, create: true, data: new TextEncoder().encode('batched'),
      },
      { op: 'read', path: '/dsh/workspace/batch.txt', offset: 0, length: 7 },
    ])
    assert.equal(values[0]?.kind, 'stat')
    assert.equal(values[1]?.kind, 'entries')
    assert.equal(values[2]?.kind, 'written')
    assert.equal(text(values[3]), 'batched')
    assert.equal(new TextDecoder().decode(backend.peek('/dsh/workspace/batch.txt')), 'batched')

    const settled = await client.batchSettled([
      { op: 'stat', path: '/dsh/workspace/nope.txt' },
      { op: 'stat', path: '/dsh/workspace/in.txt' },
    ])
    assert.equal(settled[0]?.error?.code, 'ENOENT')
    assert.equal(settled[1]?.value?.kind, 'stat')
  } finally {
    close()
  }
})

test('vfs proxy: paths outside the preopens never reach the backend', async () => {
  const { backend, client, close } = fixture()
  try {
    await assert.rejects(client.call({ op: 'stat', path: '/etc/passwd' }), /ENOTCAPABLE/)
    await assert.rejects(client.call({ op: 'read', path: '/dsh/workspace/../../etc/passwd', offset: 0, length: 1 }), /ENOTCAPABLE/)
    await assert.rejects(client.call({ op: 'stat', path: '/dsh/workspace/bad\0name' }), /EINVAL/)
    await assert.rejects(
      client.call({ op: 'write', path: '/dsh/home/../workspace/../../../tmp/x', offset: 0, append: false, create: true, data: new Uint8Array(0) }),
      /ENOTCAPABLE/,
    )
    assert.deepEqual(backend.list(), ['/', '/dsh', '/dsh/home', '/dsh/workspace', '/dsh/workspace/in.txt'])
  } finally {
    close()
  }
})

test('vfs proxy: async request frames are applied in arrival order', async () => {
  const inner = new MemoryVfsBackend({ clock: () => 1_700_000_000_000 })
  inner.seedDirectory('/dsh/workspace')
  const gate = Promise.withResolvers<void>()
  const calls: string[] = []
  const backend: VfsBackend = {
    stat: path => inner.stat(path),
    readdir: path => inner.readdir(path),
    readFile: path => inner.readFile(path),
    writeFile: async (path, data, options = {}) => {
      const create = options.create !== false
      calls.push(create ? 'create' : 'write')
      // Hold the create; an unordered server would start the dependent write
      // against a file that does not exist yet.
      if (create) await gate.promise
      inner.writeFile(path, data, options)
    },
    mkdir: (path, mode) => inner.mkdir(path, mode),
    unlink: (path, options) => inner.unlink(path, options),
    rename: (from, to) => inner.rename(from, to),
    truncate: (path, length) => inner.truncate(path, length),
    sync: () => inner.sync?.(),
  }
  const server = new VfsProxyServer({
    backend,
    preopens: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
  })
  const { port1, port2 } = new MessageChannel()
  const detach = server.attach(portEndpoint(port1))
  try {
    const received: Uint8Array[] = []
    port2.on('message', message => {
      const frame = (message as { frame?: unknown }).frame
      if (frame instanceof Uint8Array) received.push(frame)
    })
    port2.postMessage({
      type: 'vfs-request',
      frame: encodeRequests([{
        id: 1,
        request: {
          op: 'write',
          path: '/dsh/workspace/new.txt',
          offset: 0,
          append: false,
          create: true,
          data: new Uint8Array(0),
        },
      }]),
    })
    port2.postMessage({
      type: 'vfs-request',
      frame: encodeRequests([{
        id: 2,
        request: {
          op: 'write',
          path: '/dsh/workspace/new.txt',
          offset: 0,
          append: false,
          create: false,
          data: new TextEncoder().encode('x'),
        },
      }]),
    })
    await new Promise(resolve => setTimeout(resolve, 20))
    assert.deepEqual(calls, ['create'], 'the dependent write waits for the create')
    gate.resolve()
    while (received.length < 2) await new Promise(resolve => setTimeout(resolve, 5))
    const answers = received.map(frame => decodeResponses(frame)[0]?.response)
    assert.equal(answers[0]?.ok, true)
    assert.equal(answers[1]?.ok, true)
    assert.deepEqual(calls, ['create', 'write'])
    assert.equal(new TextDecoder().decode(inner.peek('/dsh/workspace/new.txt')), 'x')
  } finally {
    detach()
    port1.close()
    port2.close()
  }
})
