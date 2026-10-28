// SPDX-License-Identifier: MIT
// G2-FIX-16: DSH's glob/grep tools spawn the packaged ripgrep by absolute
// path. When the host advertises no `accelerator:rg`, subprocess-xl routes
// that spawn to the Worker's local `rg`. just-bash's built-in `rg` does not
// implement the globset contract: a leading `**/` matches one-or-more path
// components (so root-level files disappear) and the paired VCS excludes
// (`!**/.git`, `!**/.git/**`) never match. The Worker table therefore needs
// an `rg` shim with ripgrep/globset semantics for `--files` and for the
// `--glob` include filter of `--json` grep.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { buildGlobCommand, buildGrepCommand, parseGrepMatches } from '@deepseek-ai/dsh-tool-fs-search'
import {
  RipgrepGlobSet,
  VfsFileSystem,
  WorkerShell,
  createWorkerCommands,
  parseRipgrepGlobs,
} from '../shell-ext/src/index.ts'
import { workerRipgrepArgv } from '../subprocess-xl/src/index.ts'

const CWD = '/dsh/workspace'
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

interface Workspace {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/** Root-level and nested Python/text files, a `.git` tree and a `.github` tree. */
function workspace(): Workspace {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-rg-'))
  roots.push(root)
  for (const directory of ['dsh/workspace/src/deep', 'dsh/workspace/.git/objects', 'dsh/workspace/.github']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  const files: Record<string, string> = {
    'alpha.py': 'needle alpha\n',
    'beta.py': 'plain beta\n',
    'notes.txt': 'plain notes\n',
    'src/gamma.py': 'needle gamma\n',
    'src/deep/delta.py': 'print("delta")\n',
    'src/notes.txt': 'plain nested notes\n',
    '.git/config': '[core]\n',
    '.git/objects/thing.py': 'needle git\n',
    '.github/workflow.py': 'needle workflow\n',
  }
  for (const [name, content] of Object.entries(files)) {
    writeFileSync(join(root, 'dsh/workspace', name), content)
  }
  // DSH's glob argv is `--sort=modified`; the shim now honours it. Pin mtimes
  // in the alphabetical order the glob vectors below expect so the vectors
  // stay about glob semantics, not filesystem write order.
  for (const [index, name] of [
    '.github/workflow.py',
    'alpha.py',
    'beta.py',
    'notes.txt',
    'src/deep/delta.py',
    'src/gamma.py',
    'src/notes.txt',
    '.git/config',
    '.git/objects/thing.py',
  ].entries()) {
    const mtime = new Date(Date.UTC(2024, 0, 1, 0, 0, index))
    utimesSync(join(root, 'dsh/workspace', name), mtime, mtime)
  }
  const fs = new VfsFileSystem({ root })
  return {
    root,
    fs,
    shell: new WorkerShell({ fs, commands: createWorkerCommands({ git: false, curl: false, toolbox: false }) }),
  }
}

function lines(stdout: string): string[] {
  return stdout === '' ? [] : stdout.trimEnd().split('\n')
}

/** The exact Worker-local argv subprocess-xl builds for one DSH spawn. */
function workerArgv(dshArgv: readonly string[]): string[] {
  return workerRipgrepArgv(['/plugins/node_modules/@vscode/ripgrep/bin/rg', '--no-config', ...dshArgv])
}

const ALL_GLOB_MATCHES = [
  '.github/workflow.py',
  'alpha.py',
  'beta.py',
  'notes.txt',
  'src/deep/delta.py',
  'src/gamma.py',
  'src/notes.txt',
]

test('regression G2-B08: the DSH glob argv returns root-level and nested .py files and prunes .git', async () => {
  const { shell } = workspace()
  const result = await shell.run([
    'rg',
    '--files',
    '--glob=**/*.py',
    '--sort=path',
    '--no-ignore',
    '--hidden',
    '--glob=!**/.git',
    '--glob=!**/.git/**',
  ], { cwd: CWD })
  assert.equal(result.exitCode, 0, `stderr: ${result.stderr}`)
  assert.deepEqual(lines(result.stdout), [
    '.github/workflow.py',
    'alpha.py',
    'beta.py',
    'src/deep/delta.py',
    'src/gamma.py',
  ])
  assert.equal(result.stderr, '')
})

test('glob vectors: the DSH tool argv keeps globset semantics in the Worker', async () => {
  const { shell } = workspace()
  const vectors: ReadonlyArray<{ name: string; input: { pattern: string; path?: string }; expected: string[] }> = [
    {
      name: 'globstar matches zero or more directory components',
      input: { pattern: '**/*.py' },
      expected: ['.github/workflow.py', 'alpha.py', 'beta.py', 'src/deep/delta.py', 'src/gamma.py'],
    },
    {
      name: 'a pattern without a slash matches basenames at any depth',
      input: { pattern: '*.py' },
      expected: ['.github/workflow.py', 'alpha.py', 'beta.py', 'src/deep/delta.py', 'src/gamma.py'],
    },
    {
      name: 'a pattern with a slash is rooted',
      input: { pattern: 'src/*.py' },
      expected: ['src/gamma.py'],
    },
    {
      name: 'globstar matches zero components inside a rooted pattern',
      input: { pattern: 'src/**/*.py' },
      expected: ['src/deep/delta.py', 'src/gamma.py'],
    },
    {
      name: 'brace alternation combines with globstar',
      input: { pattern: '**/*.{py,txt}' },
      expected: ALL_GLOB_MATCHES,
    },
    {
      name: 'the VCS exclude pair keeps .github and prunes only .git metadata',
      input: { pattern: '*' },
      expected: ALL_GLOB_MATCHES,
    },
    {
      name: 'a search root scopes the glob',
      input: { pattern: '**/*.py', path: 'src' },
      expected: ['src/deep/delta.py', 'src/gamma.py'],
    },
  ]
  for (const vector of vectors) {
    const argv = workerArgv(buildGlobCommand(vector.input))
    const result = await shell.run(argv, { cwd: CWD })
    assert.equal(result.exitCode, 0, `${vector.name}: ${result.stderr}`)
    assert.deepEqual(lines(result.stdout), vector.expected, vector.name)
  }

  // DSH's paired exclude exists for the case where the search root IS the VCS
  // directory: the bare `!**/.git` never matches root-prefixed paths there, so
  // the contents glob must carry the exclusion.
  const rooted = await shell.run(workerArgv(buildGlobCommand({ pattern: '*', path: '.git' })), { cwd: CWD })
  assert.equal(rooted.exitCode, 1, `a VCS root has no glob results: ${JSON.stringify(rooted.stdout)}`)
  assert.equal(rooted.stdout, '')
})

test('glob vectors: plain *.py still matches the root-level files', async () => {
  const { shell } = workspace()
  const result = await shell.run(workerArgv(buildGlobCommand({ pattern: '*.py' })), { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  const found = lines(result.stdout)
  for (const rootFile of ['alpha.py', 'beta.py']) assert.ok(found.includes(rootFile), `${rootFile} missing from ${JSON.stringify(found)}`)
})

test('grep include: --glob=*.py searches only .py files and keeps root-level ones', async () => {
  const { shell } = workspace()
  const result = await shell.run(workerArgv(buildGrepCommand({ pattern: 'needle', include: '*.py' })), { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(parseGrepMatches(result.stdout).map(match => match.path).sort(), ['alpha.py', 'src/gamma.py'])
})

test('grep include: a globstar include keeps root-level and nested .py files', async () => {
  const { shell } = workspace()
  const result = await shell.run(workerArgv(buildGrepCommand({ pattern: 'needle', include: '**/*.py' })), { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(parseGrepMatches(result.stdout).map(match => match.path).sort(), ['alpha.py', 'src/gamma.py'])
})

test('grep include: an include-matched file with no matches still exits 1 (no clean-empty lie)', async () => {
  const { shell } = workspace()
  const result = await shell.run(workerArgv(buildGrepCommand({ pattern: 'not-present-anywhere', include: '*.py' })), { cwd: CWD })
  assert.equal(result.exitCode, 1)
  assert.equal(parseGrepMatches(result.stdout).length, 0)
})

test('glob errors: an invalid glob fails loud with ripgrep wording', async () => {
  const { shell } = workspace()
  const result = await shell.run(['rg', '--files', '--glob=['], { cwd: CWD })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /error parsing glob/i)
})

test('globset: include and negated globs combine with later-wins precedence', () => {
  const set = new RipgrepGlobSet([
    { pattern: '**/*.py' },
    { pattern: '!**/skip*.py' },
  ])
  assert.equal(set.matches('a.py'), true)
  assert.equal(set.matches('src/keep.py'), true)
  assert.equal(set.matches('src/skip_me.py'), false)
  assert.equal(set.matches('notes.txt'), false)

  const negated = new RipgrepGlobSet([{ pattern: '!**/.git' }, { pattern: '!**/.git/**' }])
  assert.equal(negated.matches('.git/config'), false)
  assert.equal(negated.matches('sub/.git/objects/o.py'), false)
  assert.equal(negated.matches('.github/workflow.py'), true)

  const iglob = new RipgrepGlobSet([{ pattern: '**/*.PY', caseInsensitive: true }])
  assert.equal(iglob.matches('src/tool.PY'), true)
  assert.equal(iglob.matches('src/tool.py'), true)
  assert.equal(iglob.matches('src/tool.ts'), false)
})

test('glob argv parse: globs are removed from the delegated argv and -- keeps roots', () => {
  const parsed = parseRipgrepGlobs(['--no-config', '--files', '--glob=**/*.py', '--sort=modified', '--no-ignore', '--hidden', '--', 'src'])
  assert.ok(parsed !== undefined)
  assert.deepEqual(parsed.argv, ['--files', '--sort=none', '--no-ignore', '--hidden', 'src'])
  assert.deepEqual(parsed.patterns, [{ pattern: '**/*.py', caseInsensitive: false }])
  assert.equal(parsed.sort, 'modified')
  assert.equal(parseRipgrepGlobs(['--files', '--sort=path']), undefined, 'no glob keeps the built-in path')
  assert.equal(parseRipgrepGlobs(['--json', '--regexp=needle']), undefined, 'grep without include keeps the built-in path')
})
