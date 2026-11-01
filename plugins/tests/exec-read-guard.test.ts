// SPDX-License-Identifier: MIT
/**
 * The Worker layer of the execution read policy, through the real shell path.
 *
 * A `bash -c 'rg ...'` on the phone Worker reaches the host accelerator through
 * `createExecBridgeAccelerators`. Before P12 that request left the Worker and
 * the host's Rust `rg` read `/dsh/home/sessions` in full. This test locks the
 * Worker half of the fix: the guard answers the command locally with the
 * contract's `EACCES` sentence and the fake transport records no EXEC_REQ.
 *
 * The host half is exercised by `shell/crates/pdsh-rg/tests/internal_roots.rs`,
 * `pdsh-jaq/tests/internal_roots.rs` and `pdsh-ffi/src/lib.rs`; this file proves
 * the Worker does not depend on it.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { ExecClient, ExecEvent, ExecRequest, EventStream } from '@phone-dsh/dsh-exec-bridge'
import {
  createNamespaceVfs,
  EXEC_INTERNAL_ROOTS,
  execReadDeniedMessage,
  wrapFsPromises,
  WORKER_VFS_NAMESPACE,
} from '../wasi-toolbox/src/index.ts'
import {
  VfsFileSystem,
  WorkerShell,
  createAcceleratorCommands,
  createExecBridgeAccelerators,
  guardExecClient,
} from '../shell-ext/src/index.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { TreeVfs } from './tree-vfs.ts'

/** One fake transport that records requests and answers a fixed stream. */
class FakeClient {
  readonly requests: ExecRequest[] = []
  stdout = ''

  async exec(request: ExecRequest): Promise<EventStream> {
    this.requests.push(request)
    const events: readonly ExecEvent[] = [
      { type: 'start', exec_id: request.exec_id, seq: 0 },
      { type: 'output', exec_id: request.exec_id, seq: 1, stream: 'stdout', data: Buffer.from(this.stdout).toString('base64') },
      { type: 'exit', exec_id: request.exec_id, seq: 2, code: 0, signal: null, status: 'exited', quiescent: true },
    ]
    return {
      async *[Symbol.asyncIterator]() {
        for (const event of events) yield event
      },
      close() {},
    }
  }

  async hello(): Promise<never> {
    throw new Error('not used')
  }

  async events(): Promise<never> {
    throw new Error('not used')
  }

  async cancel(): Promise<void> {}

  async stdin(): Promise<void> {}

  async lifecycle(): Promise<never> {
    throw new Error('not used')
  }

  destroy(): void {}
}

interface Fixture {
  readonly shell: WorkerShell
  readonly client: FakeClient
}

/** A Worker-shaped tree with real secrets under all internal roots. */
function fixture(): Fixture {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  for (const root of EXEC_INTERNAL_ROOTS) {
    vfs.mkdirSync(root, { recursive: true })
    vfs.writeFileSync(`${root}/secret.json`, '{"secret":true}\n')
  }
  vfs.mkdirSync('/dsh/home/notes', { recursive: true })
  vfs.writeFileSync('/dsh/home/capabilities.json', '{"capabilities":true}\n')
  vfs.mkdirSync('/dsh/workspace', { recursive: true })
  vfs.writeFileSync('/dsh/workspace/ok.txt', 'ok\n')
  const nodeFs = wrapFsPromises(base.promises as never, WORKER_VFS_NAMESPACE)
  const fs = new VfsFileSystem({ nodeFs: nodeFs as never, root: '', workerPaths: true })
  const client = new FakeClient()
  client.stdout = 'match\n'
  const host = createExecBridgeAccelerators({
    client: guardExecClient(client as unknown as ExecClient),
    hello: { capabilities: { exec: true, accelerators: ['rg', 'jaq'] } },
    revision: () => 0n,
    toolCall: () => ({ sessionId: 's', turnId: '1', stepId: '1', key: 'a'.repeat(64), callId: 'c1', spawns: 0 }),
    graceMs: 1_000,
  })
  return { shell: new WorkerShell({ fs, commands: createAcceleratorCommands(host) }), client }
}

/** The exact sentence for one refused path, from the one authority. */
function expected(path: string, root: string): string {
  return `EACCES: ${execReadDeniedMessage(path, root)}`
}

test('worker policy: bash rg and jaq are refused for every internal root and send no EXEC_REQ', async () => {
  for (const root of EXEC_INTERNAL_ROOTS) {
    // A directory operand and a file operand are the same refusal.
    for (const path of [root, `${root}/secret.json`]) {
      const { shell, client } = fixture()
      const result = await shell.run(['bash', '-c', `rg -n secret ${path}`], { cwd: '/dsh/workspace' })
      assert.notEqual(result.exitCode, 0, `${path}: rg must fail`)
      assert.equal(/secret:true/u.test(result.stdout), false, `${path}: rg printed the bytes`)
      assert.ok(result.stderr.includes(expected(path, root)), `${path}: ${result.stderr}`)
      assert.equal(client.requests.length, 0, `${path}: the Worker sent an EXEC_REQ`)

      const jaq = await shell.run(['bash', '-c', `jaq .secret ${path}`], { cwd: '/dsh/workspace' })
      assert.notEqual(jaq.exitCode, 0, `${path}: jaq must fail`)
      assert.equal(/secret:true/u.test(jaq.stdout), false, `${path}: jaq printed the bytes`)
      assert.ok(jaq.stderr.includes(expected(path, root)), `${path}: ${jaq.stderr}`)
      assert.equal(client.requests.length, 0, `${path}: the Worker sent an EXEC_REQ`)
    }
  }
})

test('worker policy: rg --files on an internal root is refused before dispatch', async () => {
  for (const root of EXEC_INTERNAL_ROOTS) {
    const { shell, client } = fixture()
    const result = await shell.run(['bash', '-c', `rg --files ${root}`], { cwd: '/dsh/workspace' })
    assert.notEqual(result.exitCode, 0, `${root}: --files must fail`)
    assert.equal(result.stdout, '', `${root}: --files listed internal state`)
    assert.ok(result.stderr.includes(expected(root, root)), `${root}: ${result.stderr}`)
    assert.equal(client.requests.length, 0, `${root}: the Worker sent an EXEC_REQ`)
  }
})

test('worker policy: a readable home file still crosses the bridge', async () => {
  const { shell, client } = fixture()
  const result = await shell.run(['bash', '-c', 'rg -n capabilities /dsh/home/capabilities.json'], { cwd: '/dsh/workspace' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'match\n')
  assert.equal(client.requests.length, 1)
  assert.deepEqual(client.requests[0]?.argv, ['rg', '-n', 'capabilities', '/dsh/home/capabilities.json'])
})
