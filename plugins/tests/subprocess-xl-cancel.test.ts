// SPDX-License-Identifier: MIT
// G2 loop regression: a cancelled `bash -c` is an interruption, never the
// shell engine's deadline status. just-bash reports every abort through its
// deadline error (`throwIfAborted` -> 124), so when the caller's abort and the
// wall-clock timer collide the engine can settle with 124 before the abort
// promise wins the race. The Worker shell and the subprocess handle must both
// decide by the first interruption cause, not by the engine's status.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import type { SubprocessSpawnSpec } from '@deepseek-ai/dsh-subprocess'
import type { CustomCommand } from 'just-bash/browser'
import { VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import { ShellWorkerProcess } from '../subprocess-xl/src/shell-process.ts'

const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

function virtualRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-cancel-'))
  roots.push(root)
  mkdirSync(join(root, 'dsh/workspace'), { recursive: true })
  mkdirSync(join(root, 'dsh/home'), { recursive: true })
  return root
}

const collect = { maxBytes: 16 * 1024 }

test('a cancelled handle is SIGTERM even when the engine settles with its 124', async () => {
  const controller = new AbortController()
  const spec: SubprocessSpawnSpec = {
    argv: ['bash', '-c', 'sleep 5; echo never'],
    cwd: '/dsh/workspace',
    graceMs: 3_000,
    stdio: { stdin: 'ignore', stdout: collect, stderr: collect },
    signal: controller.signal,
  }
  // The real engine settles a cancelled command with 124 (just-bash maps its
  // abort path onto the execution-deadline error). This fake models exactly
  // that settlement so the handle's own decision is pinned deterministically.
  const engine = {
    async run(_argv: readonly string[], options: { readonly signal?: AbortSignal | undefined }) {
      await new Promise<void>((resolve) => {
        if (options.signal?.aborted === true) resolve()
        else options.signal?.addEventListener('abort', () => { resolve() }, { once: true })
      })
      return {
        stdout: '',
        stderr: 'bash: execution aborted\n',
        exitCode: 124,
        timedOut: false,
        aborted: false,
        stdoutTruncated: false,
        stderrTruncated: false,
      }
    },
  }
  const handle = new ShellWorkerProcess(
    spec,
    { spillDir: tmpdir(), onSpillFailure: () => {} },
    engine as unknown as WorkerShell,
  )
  handle.begin()
  const timer = setTimeout(() => { controller.abort(new Error('test cancel')) }, 10)
  try {
    assert.deepEqual(await handle.done, { exitCode: null, signal: 'SIGTERM' })
    assert.equal(handle.collected.stdout?.readFrom(0).text, '')
    assert.equal(handle.collected.stderr?.readFrom(0).text, '')
  } finally {
    clearTimeout(timer)
  }
})

test("a shell abort during PATH setup reports 130, not the engine's 124", async () => {
  const root = virtualRoot()
  const controller = new AbortController()
  const base = new VfsFileSystem({ root })
  let abortInjected = false
  // The abort lands in the window between the pre-Bash bootstrap check and
  // the interpreter existing: the PATH sanitisation stat() is the seam. The
  // engine then settles with its own deadline status (124) before any abort
  // promise observer exists; the shell must still report cancellation.
  const fs = new Proxy(base, {
    get(target, property) {
      if (property === 'stat' && !abortInjected) {
        return async (path: string) => {
          abortInjected = true
          controller.abort(new Error('test cancel'))
          return await target.stat(path)
        }
      }
      const value = Reflect.get(target, property, target)
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
  const shell = new WorkerShell({ fs, timeoutMs: 30_000 })
  const result = await shell.run(['bash', '-c', 'echo never'], {
    cwd: '/dsh/workspace',
    signal: controller.signal,
  })
  assert.equal(abortInjected, true)
  assert.equal(result.exitCode, 130)
  assert.equal(result.aborted, true)
  assert.equal(result.timedOut, false)
  assert.equal(result.stdout, '')
})
