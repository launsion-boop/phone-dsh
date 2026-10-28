// SPDX-License-Identifier: MIT
// The runtime's child_process shim is the Worker's /bin: `bash -c` and `sh -c`
// pass because the shim owns a shell interpreter, while any other name must
// fail exactly like Node's missing-binary ENOENT.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'
import type { ProbeChildProcess } from '../src/probe-types.ts'

interface ChildOutcome {
  readonly stdout: string
  readonly stderr: string
  readonly code: number | null
  readonly signal: string | null
  readonly timedOut: boolean
  readonly error: {
    readonly code: string | undefined
    readonly errno: number | undefined
    readonly path: string | undefined
    readonly syscall: string | undefined
  } | undefined
}

/**
 * Run one child process to settlement.
 * @param probe - checkout probe.
 * @param program - program name.
 * @param args - program arguments.
 * @returns captured output, status and any spawn error.
 */
function runChild(
  probe: Awaited<ReturnType<typeof loadProbe>>,
  program: string,
  args: readonly string[],
): Promise<ChildOutcome> {
  return new Promise(resolve => {
    let stdout = ''
    let stderr = ''
    let code: number | null = null
    let signal: string | null = null
    let timedOut = false
    let error: ChildOutcome['error']
    let settled = false
    let timer: NodeJS.Timeout | undefined
    const finish = (): void => {
      if (settled) return
      settled = true
      if (timer !== undefined) clearTimeout(timer)
      resolve({ stdout, stderr, code, signal, timedOut, error })
    }
    const child: ProbeChildProcess = probe.spawn(program, args, { cwd: '/dsh/workspace', env: {} })
    child.stdout?.on('data', (chunk) => { stdout += Buffer.from(chunk as Uint8Array).toString('utf8') })
    child.stderr?.on('data', (chunk) => { stderr += Buffer.from(chunk as Uint8Array).toString('utf8') })
    child.on('error', (reason) => {
      const failure = reason as {
        code?: unknown
        errno?: unknown
        path?: unknown
        syscall?: unknown
      }
      error = {
        code: typeof failure.code === 'string' ? failure.code : undefined,
        errno: typeof failure.errno === 'number' ? failure.errno : undefined,
        path: typeof failure.path === 'string' ? failure.path : undefined,
        syscall: typeof failure.syscall === 'string' ? failure.syscall : undefined,
      }
      finish()
    })
    child.on('close', (exitCode, exitSignal) => {
      code = typeof exitCode === 'number' ? exitCode : null
      signal = typeof exitSignal === 'string' ? exitSignal : null
      finish()
    })
    timer = setTimeout(() => { timedOut = true; finish() }, 10_000)
  })
}

test('child process: bash and sh -c pass the ENOENT gate', async (t) => {
  const probe = await loadProbe()
  const vfs = new probe.MemoryVfs()
  probe.setActiveVfs(vfs)
  vfs.seedDirectory('/dsh/workspace')
  const bash = await runChild(probe, 'bash', ['-c', 'echo hi-from-bash'])
  const sh = await runChild(probe, 'sh', ['-c', 'printf sh-ran'])
  observe(t, 'shellScriptGate', { bash, sh })
  for (const [name, outcome] of [['bash', bash], ['sh', sh]] as const) {
    assert.equal(outcome.error, undefined, `${name} -c must not fail the ENOENT gate`)
    assert.equal(outcome.timedOut, false)
    assert.equal(outcome.code, 0, `${name} -c must run to a zero exit`)
  }
  assert.equal(bash.stdout, 'hi-from-bash\n')
  assert.equal(sh.stdout, 'sh-ran')
})

test('child process: unknown programs report ENOENT like a missing binary', async (t) => {
  const probe = await loadProbe()
  const vfs = new probe.MemoryVfs()
  probe.setActiveVfs(vfs)
  vfs.seedDirectory('/dsh/workspace')
  const missing = await runChild(probe, 'definitely-not-a-program', [])
  const syncMissing = probe.spawnSync('definitely-not-a-program')
  const syncKnown = probe.spawnSync('cat', ['/dsh/workspace/none'])
  observe(t, 'enoentGate', {
    async: { code: missing.code, error: missing.error ?? null, stdout: missing.stdout, stderr: missing.stderr },
    spawnSyncUnknown: { status: syncMissing.status, code: syncMissing.error?.code, errno: syncMissing.error?.errno, path: syncMissing.error?.path, syscall: syncMissing.error?.syscall },
    spawnSyncKnown: { status: syncKnown.status, code: syncKnown.error?.code ?? null, message: syncKnown.error?.message ?? null },
  })
  assert.equal(missing.error?.code, 'ENOENT')
  assert.equal(missing.error?.errno, -2)
  assert.equal(missing.error?.path, 'definitely-not-a-program')
  assert.equal(missing.error?.syscall, 'spawn definitely-not-a-program')
  assert.equal(syncMissing.error?.code, 'ENOENT')
  assert.equal(syncKnown.error?.code, undefined, 'a known program must not be misreported as ENOENT')
})
