// SPDX-License-Identifier: MIT
/**
 * `channel.md` §VFS gives one answer when an execution surface reaches for
 * DSH-internal state: `EACCES` plus one remediation sentence, whichever
 * program asked.
 *
 * P2 fixed only `ls`, and its own suite documented the remaining gap: "the
 * just-bash core renders every failed open with its own fixed 'No such file or
 * directory' text ... Surfacing the adapter message through `cat`/`ls` is a
 * shell-core change outside this package". This file locks that change:
 *
 *  - `cat`, `head`, `tail`, `find`, `stat`, `du`, `sort`, `od`, `cp`, `mv`,
 *    `ln`, `grep`, `awk` and `sed` all answer a refused operand with the
 *    contract's sentence;
 *  - the sentence is the one `VfsNamespace.execReadDenial` produced (the test
 *    builds the expectation from `execReadDeniedMessage`, not from a literal),
 *    so the shell cannot drift from `python3`;
 *  - the layer is command-agnostic: a custom command that catches the error
 *    and reports success still gets the denial, and an `exists()` predicate
 *    that answers "no" still names the refusal;
 *  - an unrelated `ENOENT` keeps its own wording — the rewrite only fires for
 *    a path this execution was actually refused.
 *
 * The harness is the same one `namespace-matrix.test.ts` uses: the real
 * `VfsFileSystem` over the real `wrapFsPromises` policy, with a `TreeVfs`
 * standing in for the runtime VFS.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { defineCommand } from 'just-bash/browser'
import {
  createNamespaceVfs,
  execReadDeniedMessage,
  wrapFsPromises,
  EXEC_INTERNAL_ROOTS,
  WORKER_VFS_NAMESPACE,
} from '../wasi-toolbox/src/index.ts'
import { VfsFileSystem, WorkerShell } from '../shell-ext/src/index.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { TreeVfs } from './tree-vfs.ts'

const INTERNAL_ROOTS = EXEC_INTERNAL_ROOTS
const FILE_UNDER: Readonly<Record<string, string>> = Object.freeze({
  '/dsh/home/sessions': '/dsh/home/sessions/project/session.jsonl',
  '/dsh/home/storages': '/dsh/home/storages/store.json',
  '/dsh/home/tool-journal': '/dsh/home/tool-journal/tool.jsonl',
})

interface Fixture {
  readonly vfs: TreeVfs
  readonly shell: WorkerShell
}

/**
 * One Worker-shaped tree: the namespace view every surface writes through,
 * the policy-wrapped promise face the shell adapter reads, and DSH-internal
 * state with real bytes so a leak would be visible in stdout.
 */
function fixture(options: { readonly commands?: readonly CustomCommandLike[] } = {}): Fixture {
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  for (const path of Object.values(FILE_UNDER)) {
    vfs.mkdirSync(path.slice(0, path.lastIndexOf('/')), { recursive: true })
    vfs.writeFileSync(path, '{"secret":true}')
  }
  vfs.mkdirSync('/dsh/home/notes', { recursive: true })
  vfs.writeFileSync('/dsh/home/notes/public.md', 'public')
  vfs.mkdirSync('/dsh/workspace', { recursive: true })
  vfs.writeFileSync('/dsh/workspace/ok.txt', 'ok\n')
  const nodeFs = wrapFsPromises(base.promises, WORKER_VFS_NAMESPACE)
  const fs = new VfsFileSystem({ nodeFs: nodeFs as never, root: '', workerPaths: true })
  return { vfs, shell: new WorkerShell({ fs, commands: [...options.commands ?? []] }) }
}

/** A custom permission: the shell table accepts plain `{name, execute}` commands. */
type CustomCommandLike = ReturnType<typeof defineCommand>

/** The exact refusal sentence for one virtual path, from the one authority. */
function expectedDenial(path: string): string {
  const root = INTERNAL_ROOTS.find(candidate => path === candidate || path.startsWith(`${candidate}/`))
  assert.notEqual(root, undefined, `${path} must be under a DSH-internal root`)
  return `EACCES: ${execReadDeniedMessage(path, root as string)}`
}

/** How often `needle` occurs in `text`. */
function occurrences(text: string, needle: string): number {
  return text.split(needle).length - 1
}

/** Every command that reads a path, in the spelling the check matrix uses. */
const DIRECTORY_OPERAND: Readonly<Record<string, (path: string) => readonly string[]>> = Object.freeze({
  cat: path => ['cat', path],
  head: path => ['head', '-n', '1', path],
  tail: path => ['tail', '-n', '1', path],
  find: path => ['find', path, '-type', 'f'],
  stat: path => ['stat', path],
  'stat -c': path => ['stat', '-c', '%n', path],
  du: path => ['du', '-s', path],
  sort: path => ['sort', path],
  od: path => ['od', '-c', path],
  ls: path => ['ls', path],
  'ls -l': path => ['ls', '-l', path],
  'cp -r': path => ['cp', '-r', path, '/dsh/workspace/copied'],
  mv: path => ['mv', path, '/dsh/workspace/moved'],
  ln: path => ['ln', path, '/dsh/workspace/hard-linked'],
  grep: path => ['grep', 'secret', path],
  awk: path => ['awk', '{print}', path],
  sed: path => ['sed', '-n', '1p', path],
})

test('exec policy: every command answers a refused directory with EACCES and the remediation line', async () => {
  for (const [name, argv] of Object.entries(DIRECTORY_OPERAND)) {
    for (const path of INTERNAL_ROOTS) {
      const { shell } = fixture()
      const result = await shell.run(argv(path), { cwd: '/dsh/workspace' })
      const label = `${name} ${path}`
      assert.notEqual(result.exitCode, 0, `${label} must fail (stderr: ${result.stderr})`)
      assert.equal(/secret/u.test(result.stdout), false, `${label} must not read the bytes`)
      assert.equal(occurrences(result.stderr, 'EACCES: session-internal'), 1, `${label} must print one denial: ${result.stderr}`)
      assert.ok(result.stderr.includes(expectedDenial(path)), `${label} must print the contract's sentence: ${result.stderr}`)
      assert.doesNotMatch(result.stderr, /No such file or directory|Permission denied/u, `${label} must not report absence or a bare errno: ${result.stderr}`)
    }
  }
})

test('exec policy: a refused file under an internal root gets the same answer as its directory', async () => {
  const commands: readonly (readonly string[])[] = [
    ['cat'],
    ['head', '-n', '1'],
    ['tail', '-n', '1'],
    ['find'],
    ['stat', '-c', '%n'],
    ['du', '-s'],
    ['sort'],
    ['od', '-c'],
    ['ls'],
    ['grep', 'secret'],
    ['awk', '{print}'],
    ['sed', '-n', '1p'],
  ]
  for (const argv of commands) {
    for (const path of Object.values(FILE_UNDER)) {
      const { shell } = fixture()
      const result = await shell.run([...argv, path], { cwd: '/dsh/workspace' })
      const label = `${argv[0] as string} ${path}`
      assert.notEqual(result.exitCode, 0, `${label} must fail (stderr: ${result.stderr})`)
      assert.equal(occurrences(result.stderr, 'EACCES: session-internal'), 1, `${label} must print one denial: ${result.stderr}`)
      assert.ok(result.stderr.includes(expectedDenial(path)), `${label} must name the file it refused: ${result.stderr}`)
      assert.doesNotMatch(result.stderr, /No such file or directory|Permission denied/u, `${label}: ${result.stderr}`)
    }
  }
})

test('exec policy: the rendering layer is command-agnostic', async () => {
  // A command the layer has never heard of — it swallows the refusal and
  // reports success, exactly the shape `cat`/`head`/`awk` produce internally.
  // A per-command patch would miss this completely; the per-execution record
  // cannot, because the read still went through the one filesystem wrapper.
  const swallow = defineCommand('swallow', async (args, ctx) => {
    try {
      await ctx.fs.readFile(ctx.fs.resolvePath(ctx.cwd, args[0] as string))
    } catch {
      // Deliberately discarded, like just-bash's built-in readers do.
    }
    return { stdout: '', stderr: '', exitCode: 0 }
  })
  const refused = '/dsh/home/sessions'
  const { shell } = fixture({ commands: [swallow] })
  const denied = await shell.run(['bash', '-c', `swallow ${refused}`], { cwd: '/dsh/workspace' })
  assert.equal(denied.exitCode, 2, 'a swallowed hard refusal must not exit 0')
  assert.equal(denied.stderr, `bash: ${refused}: ${expectedDenial(refused)}\n`)

  const readable = await shell.run(['bash', '-c', 'swallow /dsh/workspace/ok.txt'], { cwd: '/dsh/workspace' })
  assert.equal(readable.exitCode, 0)
  assert.equal(readable.stderr, '')
})

test('exec policy: an exists() predicate names the refusal without failing a handled script', async () => {
  const refused = '/dsh/home/sessions'
  const { shell } = fixture()
  const predicate = await shell.run(['bash', '-c', `[ -e ${refused} ] || echo missing`], { cwd: '/dsh/workspace' })
  // `[ -e ]` decides "no", so the script's own status is what it always was;
  // the stderr still names why the path could not be read.
  assert.equal(predicate.exitCode, 0)
  assert.equal(predicate.stdout, 'missing\n')
  assert.equal(occurrences(predicate.stderr, 'EACCES: session-internal'), 1, predicate.stderr)
  assert.ok(predicate.stderr.includes(expectedDenial(refused)), predicate.stderr)
})

test('exec policy: a genuine ENOENT keeps its POSIX wording', async () => {
  const { shell } = fixture()
  const missing = await shell.run(['cat', '/dsh/workspace/absent.txt'], { cwd: '/dsh/workspace' })
  assert.equal(missing.exitCode, 1)
  assert.equal(missing.stderr, 'cat: /dsh/workspace/absent.txt: No such file or directory\n')
  const readable = await shell.run(['cat', '/dsh/home/notes/public.md'], { cwd: '/dsh/workspace' })
  assert.equal(readable.exitCode, 0)
  assert.equal(readable.stdout, 'public')
  assert.equal(readable.stderr, '')
})

test('exec policy: a relative operand and a mixed operand list keep the answer exact', async () => {
  const { shell } = fixture()
  // The command resolves relative to a cwd the renderer never sees (the script
  // changes it), so the refusal is matched by the path the adapter was refused.
  const relative = await shell.run(['bash', '-c', 'cd /dsh/home && cat sessions'], { cwd: '/dsh/workspace' })
  assert.equal(relative.exitCode, 1)
  assert.equal(relative.stderr, `cat: sessions: ${expectedDenial('/dsh/home/sessions')}\n`)

  const mixed = await shell.run(['bash', '-c', 'cat /dsh/home/sessions /dsh/workspace/ok.txt'], { cwd: '/dsh/workspace' })
  assert.equal(mixed.exitCode, 1)
  assert.equal(mixed.stdout, 'ok\n', 'the allowed operand is still read')
  assert.equal(occurrences(mixed.stderr, 'EACCES: session-internal'), 1, mixed.stderr)
})

test('exec policy: an already-correct line is not duplicated', async () => {
  // `ls` (P2) and `cp`/`mv` already spell the refusal; the renderer must leave
  // exactly one line, and a nested shell must not render the same denial again.
  const { shell } = fixture()
  for (const argv of [['ls', '/dsh/home/sessions'], ['cp', '-r', '/dsh/home/sessions', '/dsh/workspace/x']]) {
    const result = await shell.run(argv, { cwd: '/dsh/workspace' })
    assert.equal(occurrences(result.stderr, 'EACCES: session-internal'), 1, `${argv[0] as string}: ${result.stderr}`)
  }
  const nested = await shell.run(['bash', '-c', 'bash -c "cat /dsh/home/tool-journal"'], { cwd: '/dsh/workspace' })
  assert.equal(nested.exitCode, 1)
  assert.equal(occurrences(nested.stderr, 'EACCES: session-internal'), 1, nested.stderr)
})

test('exec policy: a glob under a refused directory is one refusal, not two', async () => {
  // A failed expansion reports the directory it could not list and then hands
  // the literal pattern to the command, which tries to open it. Both reads are
  // refused, but the user asked one question: the answer must be one line, not
  // a rewritten line plus an appended duplicate for the literal pattern.
  const cases: readonly (readonly [string, string])[] = [
    ['cat /dsh/home/sessions/*/session.jsonl', '/dsh/home/sessions'],
    ['stat /dsh/home/storages/*', '/dsh/home/storages'],
    ['ln /dsh/home/storages/* /dsh/workspace/linked', '/dsh/home/storages'],
    ['grep secret /dsh/home/tool-journal/*', '/dsh/home/tool-journal'],
  ]
  for (const [line, refused] of cases) {
    const { shell } = fixture()
    const result = await shell.run(['bash', '-c', line], { cwd: '/dsh/workspace' })
    assert.notEqual(result.exitCode, 0, `${line} must fail`)
    assert.equal(occurrences(result.stderr, 'EACCES: session-internal'), 1, `${line}: ${result.stderr}`)
    assert.ok(result.stderr.includes(`session-internal state under ${refused}`), `${line}: ${result.stderr}`)
    assert.doesNotMatch(result.stderr, /No such file or directory|Permission denied/u, `${line}: ${result.stderr}`)
  }
  // The internal roots are invisible to a listing (P20), so `find /dsh/home`
  // never sees them: no refusal is produced for a name that is not there. An
  // explicit operand still gets the sentence — invisible is not absent.
  const { shell } = fixture()
  const find = await shell.run(['bash', '-c', 'find /dsh/home -name "*.jsonl"'], { cwd: '/dsh/workspace' })
  assert.equal(find.exitCode, 0, find.stderr)
  assert.equal(find.stderr, '')
  assert.doesNotMatch(find.stdout, /sessions|storages|tool-journal/u, find.stdout)
  const explicit = await shell.run(['bash', '-c', 'find /dsh/home/sessions -name "*.jsonl"'], { cwd: '/dsh/workspace' })
  assert.equal(occurrences(explicit.stderr, 'EACCES: session-internal'), 1, explicit.stderr)
  assert.ok(explicit.stderr.includes('session-internal state under /dsh/home/sessions'), explicit.stderr)
  assert.doesNotMatch(explicit.stderr, /Permission denied/u, explicit.stderr)
})
