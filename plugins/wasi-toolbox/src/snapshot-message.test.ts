// SPDX-License-Identifier: MIT
/**
 * G2-FIX-54: the snapshot fallback crosses a Worker thread boundary as one
 * large structured-clone message. Both tool workers must validate the body
 * instead of casting it: a malformed snapshot must fail loud and never seed a
 * half-parsed file view.
 * @module @phone-dsh/dsh-wasi-toolbox/snapshot-message.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { installPythonToolWorker } from '../python/python-worker-runtime.ts'
import { installToolWorker } from './tool-worker-runtime.ts'
import { isVfsSnapshot } from './vfs-snapshot.ts'
import type { ToolWorkerScope } from './worker-scope.ts'

const EMPTY_MODULE = new WebAssembly.Module(new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]))

const VALID_SNAPSHOT = {
  roots: ['/dsh/workspace'],
  missing: [],
  entries: [
    { path: '/dsh/workspace', kind: 'directory' as const, mode: 0o755, mtimeMs: 1, ino: 1 },
    {
      path: '/dsh/workspace/main.py', kind: 'file' as const, mode: 0o644, mtimeMs: 1, ino: 2,
      bytes: new Uint8Array([0x70, 0x72, 0x69, 0x6e, 0x74, 0x0a]),
    },
  ],
  bytes: 6,
  truncated: false,
  omitted: 0,
}

interface FakeScope {
  readonly posted: unknown[]
  readonly scope: ToolWorkerScope
  send(message: unknown): void
}

/** A Worker global scope whose message listeners the test drives directly. */
function fakeScope(): FakeScope {
  const listeners = new Set<(message: unknown) => void>()
  const posted: unknown[] = []
  return {
    posted,
    scope: {
      postMessage: (message: unknown): void => { posted.push(message) },
      onMessage: (handler: (message: unknown) => void): (() => void) => {
        listeners.add(handler)
        return (): void => { listeners.delete(handler) }
      },
    },
    send: (message: unknown): void => {
      for (const listener of [...listeners]) listener(message)
    },
  }
}

test('isVfsSnapshot accepts a captured snapshot and rejects malformed bodies', () => {
  assert.equal(isVfsSnapshot(VALID_SNAPSHOT), true)
  assert.equal(isVfsSnapshot(null), false)
  assert.equal(isVfsSnapshot('snapshot'), false)
  assert.equal(isVfsSnapshot({ ...VALID_SNAPSHOT, roots: '/dsh/workspace' }), false)
  assert.equal(isVfsSnapshot({ ...VALID_SNAPSHOT, missing: [1] }), false)
  assert.equal(isVfsSnapshot({ ...VALID_SNAPSHOT, entries: [null] }), false)
  assert.equal(isVfsSnapshot({
    ...VALID_SNAPSHOT,
    entries: [{ path: '/dsh/workspace', kind: 'directory', mode: 0o755, mtimeMs: 1, ino: 1, bytes: new Uint8Array(1) }],
  }), false)
  assert.equal(isVfsSnapshot({
    ...VALID_SNAPSHOT,
    entries: [{ path: '/dsh/workspace/main.py', kind: 'file', mode: 0o644, mtimeMs: 1, ino: 2, bytes: [1, 2] }],
  }), false)
  assert.equal(isVfsSnapshot({ ...VALID_SNAPSHOT, bytes: '6' }), false)
  assert.equal(isVfsSnapshot({ ...VALID_SNAPSHOT, truncated: 'no' }), false)
})

test('the generic tool worker rejects a malformed snapshot message', () => {
  const fake = fakeScope()
  const dispose = installToolWorker(fake.scope)
  try {
    fake.send({ type: 'init', program: 'tool', module: EMPTY_MODULE, preopens: [], snapshot: VALID_SNAPSHOT })
    assert.ok(fake.posted.some(message => (message as { type?: unknown }).type === 'ready'))
    fake.posted.length = 0
    fake.send({ type: 'snapshot', snapshot: { roots: 'not-an-array' } })
    const error = fake.posted.find(message => (message as { type?: unknown }).type === 'error')
    assert.ok(error !== undefined, 'a malformed snapshot must be reported')
    assert.match(String((error as { message?: unknown }).message), /malformed snapshot/)
  } finally {
    dispose()
  }
})

test('the python tool worker rejects a malformed snapshot message', () => {
  const fake = fakeScope()
  const dispose = installPythonToolWorker(fake.scope)
  try {
    fake.send({
      type: 'init',
      program: 'python',
      module: EMPTY_MODULE,
      preopens: [],
      snapshot: VALID_SNAPSHOT,
      python: {
        stdlibZip: new Uint8Array([0x50, 0x4b]),
        guestPath: '/dsh/lib/python313.zip',
        hostRoot: '/dsh/lib',
      },
    })
    assert.ok(fake.posted.some(message => (message as { type?: unknown }).type === 'ready'))
    fake.posted.length = 0
    fake.send({ type: 'snapshot' })
    const error = fake.posted.find(message => (message as { type?: unknown }).type === 'error')
    assert.ok(error !== undefined, 'a malformed snapshot must be reported')
    assert.match(String((error as { message?: unknown }).message), /malformed snapshot/)
  } finally {
    dispose()
  }
})
