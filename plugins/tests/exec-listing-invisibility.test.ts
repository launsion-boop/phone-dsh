// SPDX-License-Identifier: MIT
/**
 * P20: the visibility half of the execution read policy.
 *
 * `channel.md` §VFS makes `/dsh/home/{sessions,storages,tool-journal}` DSH
 * internal. P12/P16/P17 gave the *access* half one answer (`EACCES` plus one
 * remediation sentence, never `ENOENT`); the WASI guest already hid the names
 * as a side effect of the snapshot capture, but the shell still showed them:
 * `ls`, `ls -la`, `find`, `find -maxdepth 1`, `tree`, `du` and `echo
 * /dsh/home/*` all named the three internal roots.
 *
 * The fix is one rule (`VfsNamespace.execEntryVisible`) applied at the two
 * faces a shell listing can reach: the policy-wrapped `node:fs.promises` face
 * and the shell's own `VfsFileSystem`. No command was patched, which is why
 * this suite asserts through the production command table (`ls`, `find`,
 * `tree`, `du`, glob) and not only against the adapter.
 *
 * The two halves are deliberately independent mechanisms: this file keeps the
 * listing tests separate from the access tests so removing either half turns
 * only its own half red (verified by the P20 reverse checks).
 *
 * The fixture is a real temp tree behind a policy-wrapped `node:fs/promises`
 * face — the same shape the Worker installs — so `ls -la`, `tree` and the glob
 * engine render exactly what they render on the device.
 */
import assert from 'node:assert/strict'
import { promises as fsp, chmodSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import {
  EXEC_INTERNAL_ROOTS,
  WORKER_VFS_NAMESPACE,
  wrapFsPromises,
} from '../wasi-toolbox/src/index.ts'
import {
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  type VfsFileSystemIo,
} from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

/** Names that must never appear in a listing of `/dsh/home`. */
const HIDDEN = EXEC_INTERNAL_ROOTS.map(root => root.slice('/dsh/home/'.length))

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** A `node:fs/promises`-shaped face rooted at one real temp directory. */
function createFace(root: string): VfsFileSystemIo {
  const real = (path: string): string => join(root, path.replace(/^\/+/, ''))
  return {
    readFile: (path: string) => fsp.readFile(real(path)) as never,
    writeFile: (path: string, data: never, options: never) => fsp.writeFile(real(path), data, options),
    appendFile: (path: string, data: never, options: never) => fsp.appendFile(real(path), data, options),
    mkdir: (path: string, options: never) => fsp.mkdir(real(path), options),
    readdir: (path: string, options: never) => (options === undefined
      ? fsp.readdir(real(path)) as never
      : fsp.readdir(real(path), options) as never),
    stat: (path: string) => fsp.stat(real(path)) as never,
    lstat: (path: string) => fsp.lstat(real(path)) as never,
    access: (path: string) => fsp.access(real(path)),
    rm: (path: string, options: never) => fsp.rm(real(path), options),
    rename: (from: string, to: string) => fsp.rename(real(from), real(to)),
    link: (existing: string, next: string) => fsp.link(real(existing), real(next)),
    cp: (from: string, to: string, options: never) => fsp.cp(real(from), real(to), options as never),
    chmod: (path: string, mode: number) => fsp.chmod(real(path), mode),
    utimes: (path: string, atime: Date, mtime: Date) => fsp.utimes(real(path), atime, mtime),
  }
}

/** One directory entry as the policy face returns it in `withFileTypes` mode. */
interface PolicyDirent {
  readonly name: string
}

/** The `node:fs/promises` members this suite reads through the policy face. */
interface PolicyFace {
  readdir(path: string, options?: { readonly withFileTypes?: boolean }):
    Promise<readonly (string | PolicyDirent)[]>
  stat(path: string): Promise<unknown>
  lstat(path: string): Promise<unknown>
  readFile(path: string): Promise<unknown>
  access(path: string): Promise<void>
}

interface Fixture {
  /** Policy-wrapped promise face (what the Worker's shell adapter holds). */
  readonly policy: PolicyFace
  /** The shell's own filesystem (the whole `IFileSystem` every command shares). */
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/**
 * The Worker tree: three internal roots with real bytes, a visible sibling
 * directory, a file, and a `sessions-archive` directory that must stay visible
 * (the rule is name equality, not a prefix).
 */
function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-exec-listing-'))
  roots.push(root)
  for (const directory of [
    'dsh/home/notes',
    'dsh/home/sessions/project',
    'dsh/home/storages',
    'dsh/home/tool-journal',
    'dsh/home/sessions-archive',
    'dsh/workspace',
    'dsh/tmp',
  ]) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  writeFileSync(join(root, 'dsh/home/AGENTS.md'), 'agents\n')
  writeFileSync(join(root, 'dsh/home/capabilities.json'), '{"format":"pdsh-capabilities/1"}\n')
  writeFileSync(join(root, 'dsh/home/notes/public.md'), 'public\n')
  writeFileSync(join(root, 'dsh/home/sessions/project/session.jsonl'), '{"secret":true}\n')
  writeFileSync(join(root, 'dsh/home/storages/store.json'), '{"secret":true}\n')
  writeFileSync(join(root, 'dsh/home/tool-journal/tool.jsonl'), '{"secret":true}\n')
  writeFileSync(join(root, 'dsh/home/sessions-archive/kept.txt'), 'kept\n')
  writeFileSync(join(root, 'dsh/workspace/ok.txt'), 'ok\n')
  chmodSync(join(root, 'dsh/home'), 0o755)
  const face = createFace(root)
  const policy = wrapFsPromises(face as object, WORKER_VFS_NAMESPACE) as unknown as PolicyFace
  const fs = new VfsFileSystem({
    nodeFs: policy as never,
    root: '',
    workerPaths: true,
    // `getAllPaths()` walks the adapter's *sync* face. In the Worker that face
    // is the runtime VFS; here it must be the temp tree, never the host root.
    readdirSync: (path: string, options: { withFileTypes: true }) =>
      readdirSync(join(root, path.replace(/^\/+/, '')), options),
  })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, curl: false, toolbox: false }),
  })
  return { policy, fs, shell }
}

/** Run one shell command through the production command table. */
async function run(shell: WorkerShell, command: string): Promise<{ code: number, stdout: string, stderr: string }> {
  const result = await shell.run(['bash', '-c', command], { cwd: CWD })
  return { code: result.exitCode, stdout: result.stdout, stderr: result.stderr }
}

/** True when any internal root name appears as a whole word in `text`. */
function namesAnInternalRoot(text: string): string | undefined {
  return HIDDEN.find(name => new RegExp(`(^|[\\s/'"])${name}(?=$|[\\s/'":])`, 'u').test(text))
}

// ------------------------------------------------------------------ listing

test('P20 listing: no shell listing command names a DSH-internal root', async () => {
  const cases: readonly (readonly [string, string])[] = [
    ['ls', 'ls /dsh/home'],
    ['ls -a', 'ls -a /dsh/home'],
    ['ls -la', 'ls -la /dsh/home'],
    ['ls equivalent spelling', 'ls /dsh/home/../../home'],
    ['find', 'find /dsh/home'],
    ['find -maxdepth 1', 'find /dsh/home -maxdepth 1'],
    ['tree', 'tree /dsh/home'],
    ['du -a', 'du -a /dsh/home'],
    ['du -s', 'du -s /dsh/home'],
    ['glob', 'echo /dsh/home/*'],
    ['glob (dirs only spelling)', 'echo /dsh/home/*/'],
    ['find -name', 'find /dsh/home -name "*.jsonl"'],
  ]
  for (const [label, command] of cases) {
    const { shell } = fixture()
    const result = await run(shell, command)
    const leaked = namesAnInternalRoot(result.stdout) ?? namesAnInternalRoot(result.stderr)
    assert.equal(leaked, undefined, `${label} leaked ${String(leaked)} (stdout=${result.stdout} stderr=${result.stderr})`)
    assert.equal(result.code, 0, `${label} must succeed once the names are invisible: ${result.stderr}`)
    assert.equal(result.stderr, '', `${label} must not report a refusal for a name it never saw`)
  }
})

test('P20 listing: the two filesystem faces hide the same names, and nothing else', async () => {
  const { fs, policy } = fixture()

  // The shell adapter's own face (what every command and the glob engine use).
  assert.deepEqual(
    [...await fs.readdir('/dsh/home')].sort(),
    ['AGENTS.md', 'capabilities.json', 'notes', 'sessions-archive'],
  )
  assert.deepEqual(
    [...await fs.readdirWithFileTypes('/dsh/home')].map(entry => entry.name).sort(),
    ['AGENTS.md', 'capabilities.json', 'notes', 'sessions-archive'],
  )
  // The whole-tree walk is a listing too: hidden names are not pushed, and the
  // walk does not descend into them either.
  const all = fs.getAllPaths()
  for (const name of HIDDEN) {
    assert.equal(all.some(path => path === `/dsh/home/${name}` || path.startsWith(`/dsh/home/${name}/`)),
      false, `getAllPaths leaked ${name}`)
  }
  assert.ok(all.includes('/dsh/home/notes/public.md'))

  // The policy-wrapped promise face, in both `readdir` shapes.
  assert.deepEqual(
    [...await policy.readdir('/dsh/home')].sort(),
    ['AGENTS.md', 'capabilities.json', 'notes', 'sessions-archive'],
  )
  assert.deepEqual(
    [...await policy.readdir('/dsh/home', { withFileTypes: true })]
      .map(entry => (typeof entry === 'string' ? entry : entry.name)).sort(),
    ['AGENTS.md', 'capabilities.json', 'notes', 'sessions-archive'],
  )

  // A sibling directory is untouched, and the exact name is the rule: the
  // `sessions-archive` prefix is not an internal root.
  assert.deepEqual([...await fs.readdir('/dsh/home/notes')], ['public.md'])
  assert.deepEqual([...await fs.readdir('/dsh/home/sessions-archive')], ['kept.txt'])
  assert.ok(fs.getAllPaths().includes('/dsh/home/sessions-archive/kept.txt'))
})

// ------------------------------------------------------------------- access

test('P20 access: an explicit internal path still answers EACCES, never ENOENT', async () => {
  const { fs, policy } = fixture()
  const secret = '/dsh/home/sessions/project/session.jsonl'

  // The filesystem faces refuse the read; the code is EACCES, not ENOENT.
  for (const [label, read] of [
    ['stat', () => policy.stat('/dsh/home/sessions')],
    ['lstat', () => policy.lstat('/dsh/home/sessions')],
    ['readdir', () => policy.readdir('/dsh/home/sessions')],
    ['readFile', () => policy.readFile(secret)],
    ['access', () => policy.access('/dsh/home/sessions')],
  ] as const) {
    await assert.rejects(read, (error: unknown) => {
      const coded = error as { code?: string, message?: string }
      assert.equal(coded.code, 'EACCES', `${label} must be EACCES: ${String(coded.code)} ${String(coded.message)}`)
      assert.match(String(coded.message), /session-internal state under \/dsh\/home\/sessions/u)
      return true
    })
  }
  // The adapter reports the same denial to a command that formats its own text.
  assert.match(String(fs.execReadDenial('/dsh/home/sessions')), /^EACCES: session-internal state under /u)

  // And the commands: the refusal is the policy sentence, not "No such file".
  const shellCases: readonly (readonly [string, string])[] = [
    ['ls', 'ls /dsh/home/sessions'],
    ['ls -l', 'ls -l /dsh/home/storages'],
    ['find', 'find /dsh/home/tool-journal'],
    ['cat', `cat ${secret}`],
    ['stat', 'stat /dsh/home/sessions'],
    ['stat -c', 'stat -c %n /dsh/home/sessions'],
    ['du', 'du -s /dsh/home/sessions'],
    ['echo glob (explicit)', 'echo /dsh/home/sessions/*'],
  ]
  for (const [label, command] of shellCases) {
    const { shell } = fixture()
    const result = await run(shell, command)
    assert.notEqual(result.code, 0, `${label} must fail: ${result.stderr}`)
    assert.equal(/No such file or directory|Permission denied/u.test(result.stderr), false,
      `${label} must not claim absence or a bare errno: ${result.stderr}`)
    assert.match(result.stderr, /EACCES: session-internal state under \/dsh\/home\/(sessions|storages|tool-journal) is not readable/u)
    assert.doesNotMatch(result.stdout, /secret/u, `${label} must not read the bytes`)
  }
})
