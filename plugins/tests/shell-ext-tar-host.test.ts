// SPDX-License-Identifier: MIT
// G2-A05 compression interoperability:
//
// - the Worker `tar` archive is read and listed by the host's bsdtar (and the
//   host's bsdtar archive is read and extracted by the Worker `tar`);
// - the Worker `gzip` member is decompressed by the reference zlib the host
//   carries, and a reference zlib member is decompressed by `zcat`/`gunzip`;
// - `tar -z` and the `gzip` family are the same codec, so all three legs
//   roundtrip: Worker gzip <-> reference zlib <-> Worker tar -z.
//
// The reference leg is `node:zlib`, the RFC 1952 implementation the host
// exposes. It is the same member format CPython's `zlib` module produces; the
// committed corpus exercises the pure shell side of the triangle, this test
// exercises the host interop side.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { gunzipSync, gzipSync } from 'node:zlib'
import { VfsFileSystem, WorkerShell, createWorkerCommands } from '../shell-ext/src/index.ts'

const pluginRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const CWD = '/dsh/workspace'

/** The host bsdtar binary, or undefined on a host without libarchive. */
function hostBsdtar(): string | undefined {
  for (const candidate of ['/usr/bin/bsdtar', 'bsdtar']) {
    if (candidate.startsWith('/') ? existsSync(candidate) : spawnSync('which', [candidate]).status === 0) return candidate
  }
  return undefined
}

function bsdtarAvailable(binary: string): boolean {
  const probe = spawnSync(binary, ['--version'], { encoding: 'utf8' })
  return probe.status === 0 && /bsdtar/u.test(`${probe.stdout}${probe.stderr}`)
}

/**
 * Environment for a bsdtar invocation that creates the comparison archive.
 *
 * macOS libarchive encodes extended attributes and resource forks as
 * AppleDouble sidecar members (`._name`, `dir/._name`) when it copies file
 * metadata with `copyfile(3)`. Whether a bare temp file carries such metadata
 * differs between macOS versions and filesystems, so the recorded gate passed
 * on one machine and listed `._notes`, `notes/._a.md` and `notes/._b.md` on
 * another. `COPYFILE_DISABLE` (the documented switch behind bsdtar's
 * `--disable-copyfile`) makes the source archive a pure payload archive and
 * therefore makes the host-dependent comparison reproducible.
 */
function hostArchiveEnv(): NodeJS.ProcessEnv {
  return { ...process.env, COPYFILE_DISABLE: '1' }
}

/** Create one host archive through the shared, sidecar-free path. */
function createHostArchive(
  binary: string,
  flag: '-cf' | '-czf',
  archive: string,
  source: string,
  cwd: string,
): { status: number | null; stdout: string; stderr: string } {
  return spawnSync(binary, [flag, archive, source], { cwd, encoding: 'utf8', env: hostArchiveEnv() })
}

/** True for an AppleDouble metadata sidecar member (`._name`). */
function isAppleDoubleMember(member: string): boolean {
  const trimmed = member.endsWith('/') ? member.slice(0, -1) : member
  const base = trimmed.slice(trimmed.lastIndexOf('/') + 1)
  return base.startsWith('._') && base.length > 2
}

/**
 * Payload members of an archive listing.
 *
 * The Worker `tar` lists every member the host archive really holds, including
 * AppleDouble sidecars, because dropping a real member would be a lie about
 * the archive. They are host metadata, not payload, so the interop comparison
 * excludes exactly those names and still fails on any other unexpected member.
 */
function payloadMembers(listing: string): string[] {
  return listing
    .trimEnd()
    .split('\n')
    .filter(member => member !== '' && !isAppleDoubleMember(member))
    .sort()
}

interface Fixture {
  readonly shell: WorkerShell
  readonly root: string
  readonly host: string
  readonly cleanup: () => void
}

/** A Worker VFS rooted at a temp dir plus a host directory bsdtar can use. */
function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-tar-interop-'))
  const host = mkdtempSync(join(tmpdir(), 'pdsh-tar-host-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  mkdirSync(join(root, CWD, 'notes'), { recursive: true })
  writeFileSync(join(root, CWD, 'notes/a.md'), 'alpha\n')
  writeFileSync(join(root, CWD, 'notes/b.md'), 'beta\n')
  mkdirSync(join(host, 'notes'), { recursive: true })
  writeFileSync(join(host, 'notes/a.md'), 'alpha\n')
  writeFileSync(join(host, 'notes/b.md'), 'beta\n')
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: createWorkerCommands({ git: false, toolbox: false, curl: false }),
  })
  return {
    shell,
    root,
    host,
    cleanup: () => {
      rmSync(root, { recursive: true, force: true })
      rmSync(host, { recursive: true, force: true })
    },
  }
}

async function run(shell: WorkerShell, script: string) {
  return await shell.run(['bash', '-c', script], { cwd: CWD, timeoutMs: 30_000 })
}

/** Copy a Worker VFS file to the host directory. */
function copyToHost(root: string, host: string, relative: string): string {
  const target = join(host, relative)
  mkdirSync(dirname(target), { recursive: true })
  writeFileSync(target, readFileSync(join(root, CWD, relative)))
  return target
}

/** Copy a host file into the Worker VFS. */
function copyToWorker(host: string, root: string, relative: string): void {
  const target = join(root, CWD, relative)
  mkdirSync(dirname(target), { recursive: true })
  writeFileSync(target, readFileSync(join(host, relative)))
}

test('host interop: Worker tar archives and host bsdtar agree in both directions', async (t) => {
  const binary = hostBsdtar()
  if (binary === undefined || !bsdtarAvailable(binary)) {
    // The ts gate must run on macOS so this comparison cannot silently drop
    // out. CI cannot pass a flag from this write scope; PDSH_TAR_HOST_REQUIRED=1
    // turns the skip into a hard failure for a runner that declares the
    // dependency (scripts/ci/check.sh: add it to the ts stage).
    if (process.env.PDSH_TAR_HOST_REQUIRED === '1') {
      assert.fail('bsdtar is required by the tar host-interop test; no macOS bsdtar was found')
    }
    t.skip('bsdtar is not available on this host: the tar/bsdtar comparison needs macOS libarchive (/usr/bin/bsdtar)')
    return
  }
  const { shell, root, host, cleanup } = fixture()
  t.after(cleanup)

  // 1. Worker creates plain and gzip archives; bsdtar lists both.
  assert.equal((await run(shell, 'tar -cf notes.tar notes')).exitCode, 0)
  assert.equal((await run(shell, 'tar -czf notes.tgz notes')).exitCode, 0)
  copyToHost(root, host, 'notes.tar')
  copyToHost(root, host, 'notes.tgz')
  for (const [archive, flag] of [['notes.tar', '-tf'], ['notes.tgz', '-tzf']] as const) {
    const listed: { status: number | null; stdout: string; stderr: string } = spawnSync(binary, [flag, archive], { cwd: host, encoding: 'utf8' })
    assert.equal(listed.status, 0, `${String(listed.stderr)}`)
    assert.deepEqual(
      payloadMembers(listed.stdout),
      ['notes/', 'notes/a.md', 'notes/b.md'],
      `${archive} listing`,
    )
  }

  // 2. Host bsdtar creates plain and gzip archives; the Worker lists and
  //    extracts both.
  for (const [archive, flag] of [['host.tar', '-cf'], ['host.tgz', '-czf']] as const) {
    const created = createHostArchive(binary, flag, archive, 'notes', host)
    assert.equal(created.status, 0, `${String(created.stderr)}`)
    copyToWorker(host, root, archive)
    const listFlag = archive.endsWith('.tgz') ? '-tzf' : '-tf'
    const listed = await run(shell, `tar ${listFlag} ${archive}`)
    assert.equal(listed.exitCode, 0, `${archive} (${listFlag}): ${listed.stderr}`)
    assert.deepEqual(payloadMembers(listed.stdout), ['notes/', 'notes/a.md', 'notes/b.md'], `${archive} members`)
    const extracted = await run(shell, `mkdir out-${archive.replaceAll('.', '-')} && tar -xf ${archive} -C out-${archive.replaceAll('.', '-')} && cat out-${archive.replaceAll('.', '-')}/notes/b.md`)
    assert.equal(extracted.exitCode, 0, `${archive} extract: ${extracted.stderr}`)
    assert.equal(extracted.stdout, 'beta\n')
  }
})

test('host interop: the archive-creation path disables AppleDouble copyfile', (t) => {
  // Component regression for the recorded gate failure: the two bsdtar
  // invocations that create the comparison archive must carry
  // COPYFILE_DISABLE=1. The stub makes the requirement observable on every
  // host, including one whose libarchive would not emit sidecars at all.
  const { host, cleanup } = fixture()
  t.after(cleanup)
  const stub = join(host, 'bsdtar-stub')
  writeFileSync(
    stub,
    '#!/bin/sh\n'
      + '[ "${COPYFILE_DISABLE:-}" = "1" ] || { echo "COPYFILE_DISABLE is not set" >&2; exit 42; }\n'
      + 'exit 0\n',
  )
  chmodSync(stub, 0o755)
  const created = createHostArchive(stub, '-cf', 'stub.tar', 'notes', host)
  assert.equal(created.status, 0, `the host archive must be created with COPYFILE_DISABLE=1: ${created.stderr}`)

  // On macOS with a real bsdtar, a source carrying a resource fork must still
  // produce a payload-only archive through this path.
  const binary = hostBsdtar()
  if (binary === undefined || !bsdtarAvailable(binary)) {
    t.diagnostic('bsdtar is not available on this host: the real-archive half of the check is skipped')
    return
  }
  const fork = join(host, 'notes/a.md/..namedfork/rsrc')
  try {
    writeFileSync(fork, 'resource-fork-bytes')
  } catch {
    t.diagnostic('this filesystem cannot store a resource fork: only the stub half of the check runs')
    return
  }
  const real = createHostArchive(binary, '-cf', 'clean.tar', 'notes', host)
  assert.equal(real.status, 0, String(real.stderr))
  const listed = spawnSync(binary, ['-tf', 'clean.tar'], { cwd: host, encoding: 'utf8' })
  assert.equal(listed.status, 0, String(listed.stderr))
  assert.equal(
    listed.stdout.split('\n').filter(member => member !== '' && isAppleDoubleMember(member)).length,
    0,
    `COPYFILE_DISABLE must keep host metadata sidecars out of the comparison archive: ${JSON.stringify(listed.stdout)}`,
  )
  assert.deepEqual(payloadMembers(listed.stdout), ['notes/', 'notes/a.md', 'notes/b.md'])
})

test('host interop: AppleDouble sidecars in an archive never count as payload', async (t) => {
  // Reproduces the acceptance-machine archive shape deterministically: bsdtar
  // with copyfile enabled lists `._notes`, `notes/._a.md` and `notes/._b.md`
  // next to the payload. The Worker tar lists them because they are real
  // members; the interop comparison must ignore exactly them, not every
  // unexpected name.
  const { shell, root, cleanup } = fixture()
  t.after(cleanup)
  writeFileSync(join(root, CWD, '._notes'), 'apple-double-for-the-directory')
  writeFileSync(join(root, CWD, 'notes/._a.md'), 'apple-double-for-a')
  writeFileSync(join(root, CWD, 'notes/._b.md'), 'apple-double-for-b')
  const created = await run(shell, 'tar -cf host-sidecars.tar notes ._notes')
  assert.equal(created.exitCode, 0, created.stderr)
  const listed = await run(shell, 'tar -tf host-sidecars.tar')
  assert.equal(listed.exitCode, 0, listed.stderr)
  const raw = listed.stdout.trimEnd().split('\n').sort()
  for (const sidecar of ['._notes', 'notes/._a.md', 'notes/._b.md']) {
    assert.ok(raw.includes(sidecar), `the fixture archive must really carry ${sidecar}: ${JSON.stringify(raw)}`)
  }
  assert.deepEqual(payloadMembers(listed.stdout), ['notes/', 'notes/a.md', 'notes/b.md'])
  // The filter is exact, not a blanket "drop anything odd".
  assert.deepEqual(payloadMembers('notes/\nnotes/extra.md\nnotes/._x.md\n'), ['notes/', 'notes/extra.md'])
  const extracted = await run(shell, 'mkdir out-sidecars && tar -xf host-sidecars.tar -C out-sidecars && cat out-sidecars/notes/b.md')
  assert.equal(extracted.exitCode, 0, extracted.stderr)
  assert.equal(extracted.stdout, 'beta\n')
})

test('host interop: Worker gzip members and the reference zlib agree in both directions', async (t) => {
  const { shell, root, cleanup } = fixture()
  t.after(cleanup)
  const payload = 'hello from the Worker gzip codec\n'

  // Worker gzip -> host zlib decompress.
  assert.equal((await run(shell, `printf '%s' '${payload}' | gzip -c > out.gz`)).exitCode, 0)
  const member = readFileSync(join(root, CWD, 'out.gz'))
  assert.equal(gunzipSync(member).toString('utf8'), payload, 'the reference zlib must expand the Worker member')

  // Host zlib gzip -> Worker zcat / gunzip.
  writeFileSync(join(root, CWD, 'ref.gz'), gzipSync(Buffer.from(payload, 'utf8')))
  const zcat = await run(shell, 'zcat ref.gz')
  assert.equal(zcat.exitCode, 0, zcat.stderr)
  assert.equal(zcat.stdout, payload)
  const gunzip = await run(shell, 'gunzip -c ref.gz')
  assert.equal(gunzip.exitCode, 0, gunzip.stderr)
  assert.equal(gunzip.stdout, payload)
})

test('host interop: gzip <-> reference zlib <-> tar -z is one codec triangle', async (t) => {
  const { shell, root, cleanup } = fixture()
  t.after(cleanup)

  // Worker gzip -> reference decompress -> reference recompress -> Worker tar -z read.
  assert.equal((await run(shell, "printf 'shared payload\\n' | gzip > payload.gz")).exitCode, 0)
  const payload = gunzipSync(readFileSync(join(root, CWD, 'payload.gz')))
  assert.equal(payload.toString('utf8'), 'shared payload\n')
  writeFileSync(join(root, CWD, 'payload.txt'), payload)
  assert.equal((await run(shell, 'tar -czf payload.tgz payload.txt')).exitCode, 0)
  const tarMember = gunzipSync(readFileSync(join(root, CWD, 'payload.tgz')))
  assert.equal(tarMember.subarray(257, 262).toString('latin1'), 'ustar', 'the tar leg must be a ustar archive')

  // Reference tar archived bytes -> reference gzip -> Worker tar -xzf.
  const ustar = tarMember
  writeFileSync(join(root, CWD, 'reference.tgz'), gzipSync(ustar))
  const listed = await run(shell, 'tar -tzf reference.tgz')
  assert.equal(listed.exitCode, 0, listed.stderr)
  assert.equal(listed.stdout, 'payload.txt\n')
  const extracted = await run(shell, 'mkdir restored && tar -xzf reference.tgz -C restored && cat restored/payload.txt')
  assert.equal(extracted.exitCode, 0, extracted.stderr)
  assert.equal(extracted.stdout, 'shared payload\n')

  // The same payload through the pure shell triangle: gzip -> gunzip -> tar -z -> tar -x.
  const triangle = await run(shell, 'gzip -c payload.txt > a.gz && gunzip -c a.gz > b.txt && tar -czf b.tgz b.txt && tar -xzf b.tgz -C . && diff payload.txt b.txt && echo triangle-ok')
  assert.equal(triangle.exitCode, 0, triangle.stderr)
  assert.equal(triangle.stdout, 'triangle-ok\n')
})
