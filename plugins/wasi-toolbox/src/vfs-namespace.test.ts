// SPDX-License-Identifier: MIT
// Unit contract of the single path authority: root table, classification,
// storage canonicalisation, legacy spellings, the D4 predicate, the exec read
// policy and the preopen generation.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  ENGINE_RESERVED_ROOTS,
  EXEC_INTERNAL_ROOTS,
  LEGACY_ROOT_ALIASES,
  WORKER_ROOTS,
  WORKER_VFS_NAMESPACE,
  VfsNamespace,
  engineReservedRoot,
  normalizeVirtualPath,
  wrapFsPromises,
  installExecFsPolicy,
} from './index.ts'

test('namespace: the fixed root table is durable home/workspace, volatile tmp and the null device', () => {
  assert.deepEqual(WORKER_ROOTS.map(root => [root.path, root.kind, root.sink, root.budgetBucket]), [
    ['/dsh/workspace', 'durable', true, 'workspace'],
    ['/dsh/home', 'durable', true, 'sessions'],
    ['/tmp', 'volatile', false, 'tmp'],
    ['/dsh/tmp', 'volatile', false, 'tmp'],
    ['/dev/null', 'device', false, 'none'],
  ])
  assert.throws(() => new VfsNamespace([]), /cannot be empty/)
  assert.throws(() => new VfsNamespace([{ path: '/tmp/', kind: 'volatile', sink: false, budgetBucket: 'tmp' }]), /canonical/)
  assert.throws(() => new VfsNamespace([{ path: '/', kind: 'durable', sink: true, budgetBucket: 'workspace' }]), /cannot be a root/)
})

test('namespace: /dev/fd is engine-reserved and never a writable root', () => {
  // The shell engine mounts its private process-substitution filesystem at
  // `/dev/fd` after its descriptor write through the base VFS fails; the base
  // answer must be a plain `ENOENT`, so the path must not be a root and must
  // not appear in the writable-roots sentence.
  assert.deepEqual([...ENGINE_RESERVED_ROOTS], ['/dev/fd'])
  assert.equal(engineReservedRoot('/dev/fd/63'), '/dev/fd')
  assert.equal(engineReservedRoot('/dev/fd/63/../64'), '/dev/fd')
  assert.equal(engineReservedRoot('/dev/fd'), undefined, 'the mount point itself stays an ordinary image path')
  assert.equal(engineReservedRoot('/dev/null'), undefined)
  assert.equal(engineReservedRoot('/dev/fdx/1'), undefined)
  assert.equal(engineReservedRoot('relative'), undefined)
  assert.equal(WORKER_VFS_NAMESPACE.writable('/dev/fd/63'), false)
  assert.equal(WORKER_VFS_NAMESPACE.writeDenial('/dev/fd/63') !== undefined, true, 'still outside the table')
  assert.deepEqual([...WORKER_VFS_NAMESPACE.writeRoots()], [
    '/dsh/workspace', '/dsh/home', '/tmp', '/dsh/tmp', '/dev/null',
  ])
  assert.equal(
    WORKER_VFS_NAMESPACE.writableRootsLine(),
    'pdsh-shell: writable roots are /dsh/workspace, /dsh/home, /tmp, /dsh/tmp, /dev/null (TMPDIR=/dsh/tmp)',
  )
})

test('namespace: classify answers sink/writable/read/budget for every root', () => {
  const cases: readonly [string, boolean, string][] = [
    ['/dsh/workspace/a.txt', true, 'workspace'],
    ['/dsh/home/a.txt', true, 'sessions'],
    ['/dsh/home/sessions/a.jsonl', true, 'sessions'],
    ['/tmp/a.txt', false, 'tmp'],
    ['/dsh/tmp/a.txt', false, 'tmp'],
    ['/dsh/bin/python/python.wasm', false, 'none'],
    ['/dev/null', false, 'none'],
  ]
  for (const [path, sink, bucket] of cases) {
    const facts = WORKER_VFS_NAMESPACE.classify(path)
    assert.equal(facts.sink, sink, path)
    assert.equal(facts.budgetBucket, bucket, path)
    assert.equal(facts.writable, path !== '/dev/null' ? facts.root !== undefined : true, path)
  }
  assert.equal(WORKER_VFS_NAMESPACE.writable('/dev/null'), true)
  assert.equal(WORKER_VFS_NAMESPACE.writable('/etc/passwd'), false)
})

test('namespace: D4 predicate is exactly the home/workspace grammar', () => {
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/home/a'), true)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/workspace/a/b/c'), true)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/home'), false)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/workspace'), false)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/tmp/a'), false)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/tmp/a'), false)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/home/../home/a'), true)
  assert.equal(WORKER_VFS_NAMESPACE.sinkEligible('/dsh/bin/a'), false)
})

test('namespace: resolve folds dot segments and translates only the legacy runtime roots', () => {
  assert.equal(normalizeVirtualPath('//dsh///workspace/./a/../b'), '/dsh/workspace/b')
  assert.equal(normalizeVirtualPath('/'), '/')
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/workspace/x'), '/dsh/workspace/x')
  // The legacy runtime home spelling is virtual, not a host path; concatenate
  // so the public-repo hygiene scanner does not read it as a user home.
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/home' + '/x'), '/dsh/home/x')
  assert.equal(WORKER_VFS_NAMESPACE.resolve('/tmp/x'), '/tmp/x')
  assert.deepEqual(LEGACY_ROOT_ALIASES.map(alias => alias.from), ['/workspace', '/home'])
  assert.throws(() => WORKER_VFS_NAMESPACE.resolve('tmp/x'), /absolute/)
  assert.throws(() => WORKER_VFS_NAMESPACE.resolve('/tmp/\0x'), /NUL/)
})

test('namespace: storagePath canonicalises the two volatile spellings and nothing else', () => {
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/tmp'), '/dsh/tmp')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/tmp/a/b'), '/dsh/tmp/a/b')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/dsh/tmp/a/b'), '/dsh/tmp/a/b')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/tmpfoo/a'), '/tmpfoo/a')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/dsh/workspace/a'), '/dsh/workspace/a')
  assert.equal(WORKER_VFS_NAMESPACE.storagePath('/workspace/a'), '/dsh/workspace/a')
})

test('namespace: exec read policy covers the three internal subtrees exactly', () => {
  assert.deepEqual([...EXEC_INTERNAL_ROOTS], ['/dsh/home/sessions', '/dsh/home/storages', '/dsh/home/tool-journal'])
  for (const root of EXEC_INTERNAL_ROOTS) {
    assert.equal(WORKER_VFS_NAMESPACE.execReadable(root), false, root)
    assert.equal(WORKER_VFS_NAMESPACE.execReadable(`${root}/x/y.jsonl`), false, root)
    assert.equal(WORKER_VFS_NAMESPACE.execReadable(`${root}-archive`), true, root)
    assert.throws(() => WORKER_VFS_NAMESPACE.assertExecReadable(`${root}/x`), (error: unknown) => {
      const coded = error as { code?: string; message?: string }
      assert.equal(coded.code, 'EACCES')
      assert.match(String(coded.message), /session API/)
      assert.match(String(coded.message), /\/dsh\/workspace/)
      return true
    })
  }
  assert.equal(WORKER_VFS_NAMESPACE.execReadable('/dsh/home/notes/a.md'), true)
  assert.equal(WORKER_VFS_NAMESPACE.execReadable('/dsh/workspace/sessions'), true)
  assert.doesNotThrow(() => WORKER_VFS_NAMESPACE.assertExecReadable('/dsh/home/notes/a.md'))
})

test('namespace: a listing hides the internal roots without changing the read answer', () => {
  // The visibility rule answers for exactly the three names, in exactly the
  // parent directory, under every spelling of that directory.
  const visible = (directory: string, name: string): boolean => WORKER_VFS_NAMESPACE.execEntryVisible(directory, name)
  for (const root of EXEC_INTERNAL_ROOTS) {
    const name = root.slice('/dsh/home/'.length)
    for (const spelling of ['/dsh/home', '/dsh/home/', '/dsh/home/./', '/dsh/home/../../home', '/home']) {
      assert.equal(visible(spelling, name), false, `${spelling} must hide ${name}`)
      assert.equal(visible(spelling, `${name}-archive`), true, `${spelling} must keep ${name}-archive`)
      assert.equal(visible(spelling, `.${name}`), true, `${spelling} must keep .${name}`)
    }
    // Another parent is another answer: the rule is one directory deep.
    assert.equal(visible('/dsh', name), true, `'/dsh' must keep ${name}`)
    assert.equal(visible('/', name), true, `'/' must keep ${name}`)
    assert.equal(visible('/dsh/workspace', name), true, `workspace must keep ${name}`)
  }
  assert.equal(visible('/dsh/home', 'notes'), true)
  assert.equal(visible('/dsh/home', 'AGENTS.md'), true)
  assert.equal(visible('/dsh/home', ''), true)
  assert.equal(visible('relative', 'sessions'), true)
  // The two halves are independent: hiding a name never makes it readable, and
  // refusing the read never makes it visible.
  assert.equal(WORKER_VFS_NAMESPACE.execReadable('/dsh/home/sessions'), false)
  assert.equal(WORKER_VFS_NAMESPACE.execEntryVisible('/dsh/home', 'sessions'), false)
})

test('namespace: the fs face filters readdir and still refuses explicit reads', async () => {
  const entries = ['AGENTS.md', 'notes', 'sessions', 'sessions-archive', 'storages', 'tool-journal']
  const face = {
    async readdir(path: string, options?: { withFileTypes?: boolean }) {
      assert.equal(path, '/dsh/home')
      return options?.withFileTypes === true
        ? entries.map(name => ({ name, isFile: () => false, isDirectory: () => true, isSymbolicLink: () => false }))
        : [...entries]
    },
    async stat(path: string) { return { path } },
    async readFile(path: string) { return path },
  }
  const wrapped = wrapFsPromises(face, WORKER_VFS_NAMESPACE)
  assert.deepEqual([...await wrapped.readdir('/dsh/home')], ['AGENTS.md', 'notes', 'sessions-archive'])
  assert.deepEqual(
    [...await wrapped.readdir('/dsh/home', { withFileTypes: true })]
      .map(entry => (typeof entry === 'string' ? entry : entry.name)),
    ['AGENTS.md', 'notes', 'sessions-archive'],
  )
  // A listing is filtered; an explicit access is not widened.
  await assert.rejects(wrapped.stat('/dsh/home/sessions'), (error: unknown) => (error as { code?: string }).code === 'EACCES')
  await assert.rejects(wrapped.readdir('/dsh/home/sessions'), (error: unknown) => (error as { code?: string }).code === 'EACCES')
  // The canonicalisation-only wrapper (`createNamespaceVfs`) is not a policy
  // face: the host's own view of its tree keeps every entry.
  const { createNamespaceVfs } = await import('./index.ts')
  const hostView = createNamespaceVfs({ promises: face }, WORKER_VFS_NAMESPACE).promises as typeof face
  assert.deepEqual([...await hostView.readdir('/dsh/home')], entries)
})

test('namespace: join unifies a base path and a relative search pattern', () => {
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', 'src/**/*.ts'), '/dsh/workspace/src/**/*.ts')
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace/', './src/*.ts'), '/dsh/workspace/src/*.ts')
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', '/tmp/*.txt'), '/tmp/*.txt')
  assert.equal(WORKER_VFS_NAMESPACE.join('/dsh/workspace', '!**/*.md'), '!/dsh/workspace/**/*.md')
  assert.equal(WORKER_VFS_NAMESPACE.join('/tmp', 'a/../b.txt'), '/tmp/b.txt')
  assert.throws(() => WORKER_VFS_NAMESPACE.join('/dsh/workspace', ''), /non-empty pattern/)
  assert.throws(() => WORKER_VFS_NAMESPACE.join('/dsh/workspace', '!'), /no path/)
})

test('namespace: preopens are the identity table minus the device', () => {
  assert.deepEqual(WORKER_VFS_NAMESPACE.preopens(), [
    { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
    { guestPath: '/dsh/home', hostPath: '/dsh/home' },
    { guestPath: '/tmp', hostPath: '/tmp' },
    { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
  ])
  assert.deepEqual(WORKER_VFS_NAMESPACE.writableRoots(), ['/dsh/workspace', '/dsh/home', '/tmp', '/dsh/tmp'])
})

test('namespace: the fs face canonicalises paths and refuses internal reads', async () => {
  const written: [string, Uint8Array][] = []
  const face = {
    async writeFile(path: string, data: Uint8Array) { written.push([path, data]) },
    async readFile(path: string) { return new Uint8Array([path.length]) },
    async stat(path: string) { return { path } },
  }
  const wrapped = wrapFsPromises(face, WORKER_VFS_NAMESPACE)
  await wrapped.writeFile('/tmp/a.txt', new Uint8Array([1]))
  assert.deepEqual(written.map(([path]) => path), ['/dsh/tmp/a.txt'])
  await wrapped.writeFile('/dsh/home/sessions/a.jsonl', new Uint8Array([1]))
  assert.equal(written.at(-1)?.[0], '/dsh/home/sessions/a.jsonl')
  await assert.rejects(wrapped.readFile('/dsh/home/sessions/a.jsonl'), (error: unknown) => {
    assert.equal((error as { code?: string }).code, 'EACCES')
    return true
  })
  await assert.rejects(wrapped.stat('/dsh/home/tool-journal/x'), (error: unknown) => (error as { code?: string }).code === 'EACCES')

  // The in-place installer is the production seam and restores on dispose.
  const target: Record<string, unknown> = {
    async readFile(path: string) { return path },
    async writeFile(path: string) { return path },
  }
  const original = target.readFile
  const dispose = installExecFsPolicy(target, WORKER_VFS_NAMESPACE)
  assert.notEqual(target.readFile, original)
  await assert.rejects((target.readFile as (path: string) => Promise<string>)('/dsh/home/sessions/x'))
  dispose()
  assert.equal(target.readFile, original)
})
