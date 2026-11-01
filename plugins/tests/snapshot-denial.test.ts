// SPDX-License-Identifier: MIT
/**
 * P16: an execution surface that names a DSH-internal path must be told
 * `EACCES`, never `ENOENT`.
 *
 * On Android the Worker is not cross-origin isolated, so `python3` and `jq`
 * have no SharedArrayBuffer VFS: the toolbox captures the preopened trees and
 * the guest resolves paths against that local snapshot. Before the fix the
 * capture omitted a denied subtree exactly like an absent one, so the guest's
 * own resolver produced `No such file or directory` for
 * `/dsh/home/sessions` — a false claim that the path does not exist, made by
 * the one surface that never reached the host's `EACCES`.
 *
 * These tests run the real artifacts (jaq built for wasm32-wasi, CPython) over
 * the real toolbox in snapshot-fallback mode against a backend that applies
 * the real exec read policy, and assert the exact lines the guest prints. They
 * are artifact-gated like the jq engine suite: without a built artifact they
 * report NOT_RUN instead of pretending the engine ran.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { VfsProxyError } from '../wasi-toolbox/src/errors.ts'
import { workerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/message-endpoint.ts'
import { MemoryVfsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import { EXEC_INTERNAL_ROOTS, execReadDeniedMessage } from '../wasi-toolbox/src/vfs-namespace.ts'
import { normalizeAbsolutePath } from '../wasi-toolbox/src/vfs-paths.ts'
import { setWorkerToolbox } from '../wasi-toolbox/src/toolbox.ts'
import type { ToolboxResult } from '../wasi-toolbox/src/types.ts'
import { discoverJqArtifact } from '../wasi-toolbox/jq/artifacts.ts'
import { discoverPythonArtifacts } from '../wasi-toolbox/python/python-artifacts.ts'
import { disposePythonToolbox, installPythonToolbox } from '../worker-entry/src/python-toolbox.ts'
import { installJqToolbox } from '../worker-entry/src/jq-toolbox.ts'
import type { WorkerEntryVfs } from '../worker-entry/src/entry.ts'

const decoder = new TextDecoder()

/**
 * The execution surface's view of the live VFS: every read of a DSH-internal
 * path is refused with the policy's `EACCES` and the one remediation sentence,
 * which is what `installExecFsPolicy` makes `node:fs/promises` answer in the
 * Worker.
 */
class PolicyBackend extends MemoryVfsBackend {
  private deny(path: string): void {
    const target = normalizeAbsolutePath(path)
    for (const root of EXEC_INTERNAL_ROOTS) {
      if (target !== root && !target.startsWith(`${root}/`)) continue
      throw new VfsProxyError('EACCES', execReadDeniedMessage(target, root))
    }
  }

  override stat(path: string) {
    this.deny(path)
    return super.stat(path)
  }

  override readdir(path: string) {
    this.deny(path)
    return super.readdir(path)
  }

  override readFile(path: string) {
    this.deny(path)
    return super.readFile(path)
  }
}

/** One Worker-shaped image exposing the artifact bytes `readImageArtifact` reads. */
function image(files: Readonly<Record<string, Uint8Array>>): WorkerEntryVfs {
  const stored = new Map(Object.entries(files))
  return {
    subscribe: () => () => {},
    flush: async () => {},
    readFileSync: (path: string): Uint8Array => {
      const bytes = stored.get(path)
      if (bytes === undefined) {
        throw Object.assign(new Error(`ENOENT: no such file or directory, open '${path}'`), { code: 'ENOENT', path })
      }
      return bytes
    },
  }
}

/**
 * The preopened tree the guest is given: a readable `/dsh/home` whose internal
 * siblings are refused, exactly like the device's.
 */
function backend(): PolicyBackend {
  const seeded = new PolicyBackend()
  seeded.seedDirectory('/dsh/workspace')
  seeded.seedDirectory('/dsh/home')
  seeded.seedDirectory('/dsh/home/sessions')
  seeded.seedFile('/dsh/home/sessions/project/session.v4.jsonl', '{"secret":true}\n')
  seeded.seedFile('/dsh/home/notes.md', '# notes\n')
  seeded.seedDirectory('/dsh/tmp')
  return seeded
}

const genericWorker = (): ToolWorkerTransport => workerTransport(
  new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
)

const pythonWorker = (): ToolWorkerTransport => workerTransport(
  new Worker(new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url)) as unknown as WorkerLike,
)

interface Outcome {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

async function run(
  toolbox: { run(request: {
    program: string
    argv?: readonly string[]
    cwd?: string
    env?: Readonly<Record<string, string>>
    stdin?: Uint8Array
    onStdout?: (chunk: Uint8Array) => void
    onStderr?: (chunk: Uint8Array) => void
  }): Promise<ToolboxResult> },
  program: string,
  argv: readonly string[],
): Promise<Outcome> {
  const out: Uint8Array[] = []
  const err: Uint8Array[] = []
  const result = await toolbox.run({
    program,
    argv,
    cwd: '/dsh/workspace',
    env: {},
    stdin: new Uint8Array(0),
    onStdout: chunk => { out.push(Uint8Array.from(chunk)) },
    onStderr: chunk => { err.push(Uint8Array.from(chunk)) },
  })
  const join = (chunks: readonly Uint8Array[]): string => {
    const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
    const joined = new Uint8Array(total)
    let offset = 0
    for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength }
    return decoder.decode(joined)
  }
  return { code: result.exitCode, stdout: join(out), stderr: join(err) }
}

const jqArtifact = discoverJqArtifact()
const pythonArtifact = discoverPythonArtifacts()

/** The sentence the policy gives one path, exactly as the guest must print it. */
function denialLine(path: string): string {
  const root = EXEC_INTERNAL_ROOTS.find(candidate => path === candidate || path.startsWith(`${candidate}/`)) ?? path
  return `EACCES: ${execReadDeniedMessage(path, root)}`
}

test(
  'jq (snapshot fallback): a denied path prints the policy EACCES, not "No such file or directory"',
  { skip: jqArtifact.skipReason, timeout: 120_000 },
  async () => {
    const artifact = jqArtifact.artifact
    if (artifact === undefined) return
    const wiring = await installJqToolbox({
      vfs: image({
        '/dsh/bin/jq/jq.wasm': new Uint8Array(readFileSync(artifact.wasm)),
        '/dsh/bin/jq/engine.json': new Uint8Array(readFileSync(artifact.engine)),
      }),
      backend: backend(),
      crossOriginIsolated: false,
      spawnWorker: genericWorker,
      log: () => {},
    })
    assert.ok(wiring !== undefined)
    try {
      const denied = await run(wiring.toolbox, 'jq-wasi', ['.', '/dsh/home/sessions'])
      // The host's diagnostic line carries the whole remediation sentence; the
      // engine's own line carries the errno the guest saw.
      assert.equal(denied.stderr.split('\n')[0], denialLine('/dsh/home/sessions'))
      assert.match(denied.stderr, /jq: error: Could not open file \/dsh\/home\/sessions: Permission denied \(os error 2\)/)
      assert.doesNotMatch(denied.stderr, /No such file or directory/)

      // A child named explicitly is refused too, not resolved to a local ENOENT.
      // The diagnostic sentence names the denied root (that is the path the
      // live VFS refused and the remediation is about); the engine's own line
      // names the file it tried to open.
      const child = await run(wiring.toolbox, 'jq-wasi', ['.', '/dsh/home/sessions/project/session.v4.jsonl'])
      assert.equal(child.stderr.split('\n')[0], denialLine('/dsh/home/sessions'))
      assert.match(child.stderr, /Permission denied \(os error 2\)/)
      assert.doesNotMatch(child.stderr, /No such file or directory/)

      // A readable sibling still works: the guard is a prefix, not "any file
      // under /dsh/home".
      const readable = await run(wiring.toolbox, 'jq-wasi', ['-r', '.', '/dsh/home/notes.md'])
      assert.equal(readable.stderr, '')
    } finally {
      await wiring.toolbox.dispose()
    }
  },
)

test(
  'python3 (snapshot fallback): denied open() raises PermissionError with the policy sentence',
  { skip: pythonArtifact.skipReason ?? pythonArtifact.failure, timeout: 180_000 },
  async () => {
    const pair = pythonArtifact.pair
    if (pair === undefined) return
    const wiring = await installPythonToolbox({
      vfs: image({
        '/dsh/bin/python/python.wasm': new Uint8Array(readFileSync(pair.wasm)),
        '/dsh/bin/python/python313.zip': new Uint8Array(readFileSync(pair.stdlib)),
      }),
      backend: backend(),
      crossOriginIsolated: false,
      spawnWorker: pythonWorker,
      log: () => {},
    })
    assert.ok(wiring !== undefined)
    try {
      const denied = await run(wiring.toolbox, 'python3', ['-c', 'open("/dsh/home/sessions")'])
      assert.equal(denied.code, 1)
      assert.equal(denied.stderr.split('\n')[0], denialLine('/dsh/home/sessions'))
      // wasi-libc numbers its errnos like WASI preview1 itself (EACCES = 2), so
      // the interpreter reports [Errno 2] — the *name* is what the model reads.
      assert.match(denied.stderr, /PermissionError: \[Errno 2\] Permission denied: '\/dsh\/home\/sessions'/)
      assert.doesNotMatch(denied.stderr, /FileNotFoundError/)

      const child = await run(wiring.toolbox, 'python3', ['-c', 'open("/dsh/home/sessions/project/session.v4.jsonl")'])
      assert.equal(child.code, 1)
      assert.match(child.stderr, /PermissionError: \[Errno 2\] Permission denied/)
      assert.doesNotMatch(child.stderr, /FileNotFoundError/)

      // The listing half of the contract: the name does not appear at all.
      const listing = await run(wiring.toolbox, 'python3', ['-c', 'import os; print(sorted(os.listdir("/dsh/home")))'])
      assert.equal(listing.code, 0, listing.stderr)
      assert.equal(listing.stdout, "['notes.md']\n")
      assert.doesNotMatch(listing.stdout, /sessions/)
    } finally {
      await disposePythonToolbox(wiring)
      setWorkerToolbox(undefined)
    }
  },
)
