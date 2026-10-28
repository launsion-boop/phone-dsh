// SPDX-License-Identifier: MIT
// G2-FIX-58 repair: the boot-published capability manifest has one owner.
//
// Before the repair `materializeCapabilityManifest` compared
// `/dsh/home/capabilities.json` with the shell's minimal
// `{format, programs}` payload and overwrote the file on the first `bash -c`.
// That deleted the `pdsh-capabilities/1` document the Worker boot publishes
// (ENG-05: limits, Python modules, egress, bash deviations), so the hint's
// referent existed but no longer answered the questions it promised to
// answer — and the next Worker boot had to rewrite it (an extra VFS_MUT).
//
// This regression covers the combined path the acceptance names: boot
// publish, a bash command in the same Worker, then a Worker rebuild over the
// persisted home.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  SHELL_MANIFEST_PATH,
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  parseShellTrailer,
} from '../shell-ext/src/index.ts'
import {
  buildCapabilityManifest,
  publishCapabilityManifest,
  workerCommandSurface,
  type CapabilityVfs,
} from '../worker-entry/src/capabilities.ts'

const CWD = '/dsh/workspace'

/** The promise face the boot publisher needs over the shell's VFS. */
function capabilityVfs(fs: VfsFileSystem): CapabilityVfs {
  return {
    promises: {
      async readFile(path: string): Promise<string> {
        return await fs.readFile(path)
      },
      async writeFile(path: string, data: Uint8Array): Promise<void> {
        await fs.writeFile(path, data)
      },
      async mkdir(path: string, options?: { readonly recursive?: boolean }): Promise<void> {
        await fs.mkdir(path, options)
      },
    },
  }
}

/** The one trailer in a failing command's stderr. */
function trailerOf(stderr: string) {
  const lines = stderr.split('\n').filter(line => line.startsWith('pdsh-shell: exit='))
  assert.equal(lines.length, 1, `expected exactly one trailer in ${JSON.stringify(stderr)}`)
  const trailer = parseShellTrailer(lines[0] as string)
  assert.notEqual(trailer, undefined, `unparseable trailer ${JSON.stringify(lines[0])}`)
  return trailer as NonNullable<typeof trailer>
}

test('boot manifest + bash command + Worker rebuild: the shell never overwrites the boot document', async (t) => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-manifest-owner-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })

  // 1. Boot: worker-entry publishes the full document from the real registry.
  const commands = createWorkerCommands({ git: false, toolbox: false, curl: false })
  const surface = workerCommandSurface({ toolbox: false, git: false, curl: false })
  const boot = buildCapabilityManifest({
    commands: surface.commands,
    egressAllow: ['gateway.example.test'],
  })
  const bootFs = new VfsFileSystem({ root, workerPaths: true })
  const firstPublish = await publishCapabilityManifest(capabilityVfs(bootFs), boot)
  assert.deepEqual(
    [...firstPublish.written].sort(),
    ['/dsh/home/AGENTS.md', SHELL_MANIFEST_PATH].sort(),
    'the boot publishes both environment priors',
  )
  const booted = await bootFs.readFile(SHELL_MANIFEST_PATH)
  const bootedDocument = JSON.parse(booted) as { schema?: string; commands?: string[] }
  assert.equal(bootedDocument.schema, 'pdsh-capabilities/1')
  assert.equal(bootedDocument.commands?.includes('stat'), true)

  // 2. A bash command in that Worker. The shell bootstrap used to replace the
  //    boot document with the minimal {format, programs} payload; the status
  //    of stat is the command's own and the 127 hint still names the same,
  //    now-full document.
  const shell = new WorkerShell({ fs: bootFs, commands })
  const stat = await shell.run(['bash', '-c', "stat -c '%n' /dsh/workspace/absent"], { cwd: CWD })
  assert.equal(stat.exitCode, 1)
  assert.equal(trailerOf(stat.stderr).reason, 'command-exited')
  assert.equal(await bootFs.readFile(SHELL_MANIFEST_PATH), booted, 'the bash step left the boot document byte-identical')

  const unknown = await shell.run(['bash', '-c', 'pdsh-definitely-not-a-program'], { cwd: CWD })
  assert.equal(unknown.exitCode, 127)
  const notAvailable = trailerOf(unknown.stderr)
  assert.equal(notAvailable.reason, 'not-available')
  assert.equal(notAvailable.hint?.includes(SHELL_MANIFEST_PATH), true, unknown.stderr)
  assert.equal(await bootFs.readFile(SHELL_MANIFEST_PATH), booted, 'the advertised manifest keeps the same bytes')

  // 3. Worker rebuild over the persisted home: a new VFS object and a new boot
  //    publish find the boot document unchanged (no VFS_MUT), and a new shell
  //    adopts it again instead of writing its fallback.
  const rebuiltFs = new VfsFileSystem({ root, workerPaths: true })
  const secondPublish = await publishCapabilityManifest(capabilityVfs(rebuiltFs), boot)
  assert.deepEqual(secondPublish.written, [], 'the rebuild rewrites neither prior')
  const rebuilt = new WorkerShell({ fs: rebuiltFs, commands })
  const afterRebuild = await rebuilt.run(['bash', '-c', 'true'], { cwd: CWD })
  assert.equal(afterRebuild.exitCode, 0)
  assert.equal(await rebuiltFs.readFile(SHELL_MANIFEST_PATH), booted, 'the rebuilt shell left the boot document byte-identical')
})

test('any manifest already at the path satisfies the hint, whatever its schema', async (t) => {
  // The acceptance allows either a single writer or "treat any existing schema
  // manifest as the hint referent and do not write". This pins the second
  // reading for a future schema the shell does not know: a file is a file, and
  // the shell's minimal payload must not replace it.
  const root = mkdtempSync(join(tmpdir(), 'pdsh-manifest-schema-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const seeded = '{"schema":"pdsh-capabilities/2","commands":["bash"]}\n'
  await fs.writeFile(SHELL_MANIFEST_PATH, seeded)

  const shell = new WorkerShell({ fs, commands: createWorkerCommands({ git: false, toolbox: false, curl: false }) })
  const result = await shell.run(['bash', '-c', 'pdsh-definitely-not-a-program'], { cwd: CWD })
  assert.equal(result.exitCode, 127)
  assert.equal(trailerOf(result.stderr).reason, 'not-available')
  assert.equal(await fs.readFile(SHELL_MANIFEST_PATH), seeded, 'the unknown schema was not overwritten')
})
