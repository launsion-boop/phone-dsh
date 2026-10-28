// SPDX-License-Identifier: MIT
// G2-FIX-74: the Worker shell's gzip family must implement the RFC 1952
// container itself on top of the Web compression streams.
//
// `DecompressionStream('gzip')` decodes exactly one member and rejects any
// trailing bytes ("Trailing junk found after the end of the compressed
// stream" in Node, "Extra bytes past the end."/"Failed to Decode Data." in
// WebKit). A gzip file may legally hold any number of concatenated members,
// which is what the real-model batch produced (G2-E10): every decode failed
// and the command wrote a 0-byte output. The Worker codec must split the
// members, inflate each raw DEFLATE payload, and check the CRC32 and ISIZE
// trailer itself so a checksum failure still keeps the bytes it decoded.
//
// These tests drive the production `gzip`/`gunzip`/`zcat` command table
// through `WorkerShell` over a temp VFS. `node:zlib` is used only as the
// reference encoder that builds the golden files; the command side prefers the
// Web Compression Streams backend exactly as it does in the browser Worker.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { gunzipSync, gzipSync } from 'node:zlib'
import { VfsFileSystem, WorkerShell, createWorkerCommands } from '../shell-ext/src/index.ts'

const CWD = '/dsh/workspace'
const MAX_OUTPUT = 4 * 1024 * 1024

interface Fixture {
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly root: string
  readonly cleanup: () => void
}

/** One Worker shell over a temp directory with the production command table. */
function fixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-gzip-framing-'))
  mkdirSync(join(root, CWD), { recursive: true })
  const fs = new VfsFileSystem({ root, workerPaths: true })
  const shell = new WorkerShell({
    fs,
    commands: createWorkerCommands({ git: false, curl: false, toolbox: false }),
    maxOutputBytes: MAX_OUTPUT,
  })
  return { fs, shell, root, cleanup: () => rmSync(root, { recursive: true, force: true }) }
}

async function run(shell: WorkerShell, script: string) {
  return await shell.run(['bash', '-c', script], { cwd: CWD, timeoutMs: 30_000, maxOutputBytes: MAX_OUTPUT })
}

async function write(fs: VfsFileSystem, name: string, bytes: Uint8Array): Promise<void> {
  await fs.writeFile(`${CWD}/${name}`, bytes)
}

async function read(fs: VfsFileSystem, name: string): Promise<Uint8Array> {
  return await fs.readFileBuffer(`${CWD}/${name}`)
}

/** A gzip member with extra header fields (FEXTRA + FNAME) before the payload. */
function withHeaderFields(member: Uint8Array, name: string, extra: Uint8Array): Uint8Array {
  assert.equal(member[3], 0, 'the reference member starts with an empty FLG byte')
  const header = Uint8Array.from(member.subarray(0, 10))
  header[3] = 0x04 | 0x08
  const extraLength = Uint8Array.of(extra.byteLength & 0xff, (extra.byteLength >>> 8) & 0xff)
  const nameBytes = new TextEncoder().encode(`${name}\0`)
  return Uint8Array.from([...header, ...extraLength, ...extra, ...nameBytes, ...member.subarray(10)])
}

/** Replace one 32-bit little-endian trailer field (0 = CRC32, 1 = ISIZE). */
function corruptTrailer(member: Uint8Array, field: 0 | 1): Uint8Array {
  const out = Uint8Array.from(member)
  out[out.byteLength - 8 + field * 4] = (out[out.byteLength - 8 + field * 4] as number) ^ 0xff
  return out
}

const text = new TextEncoder().encode('invoice summary\nsecond line\n')

test('gzip: a golden single-member file decodes byte-exact with exit 0', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    await write(fs, 'golden.gz', gzipSync(text))
    const decoded = await run(shell, 'gzip -dc golden.gz > decoded.bin')
    assert.equal(decoded.exitCode, 0, decoded.stderr)
    assert.deepEqual(await read(fs, 'decoded.bin'), text)
    const tested = await run(shell, 'gzip -t golden.gz')
    assert.equal(tested.exitCode, 0, tested.stderr)
  } finally {
    cleanup()
  }
})

test('gzip: concatenated gzip members decode all members in order', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    // A gzip file is a sequence of members; DecompressionStream('gzip') only
    // accepts one and rejects the rest, which is the G2-E10 zero-byte failure.
    const first = new TextEncoder().encode('first member\n')
    const second = new TextEncoder().encode('second member\n')
    const third = new TextEncoder().encode('third member\n')
    const concatenated = Uint8Array.from([
      ...gzipSync(first),
      ...gzipSync(second),
      ...gzipSync(third),
    ])
    await write(fs, 'multi.gz', concatenated)
    const decoded = await run(shell, 'gzip -dc multi.gz > decoded.bin')
    assert.equal(decoded.exitCode, 0, decoded.stderr)
    assert.deepEqual(await read(fs, 'decoded.bin'), Uint8Array.from([...first, ...second, ...third]))
  } finally {
    cleanup()
  }
})

test('gzip: members with FEXTRA/FNAME header fields decode normally', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    const member = withHeaderFields(gzipSync(text), 'invoice-summary.txt', Uint8Array.of(1, 2, 3, 4))
    await write(fs, 'named.gz', member)
    const decoded = await run(shell, 'gzip -dc named.gz > decoded.bin')
    assert.equal(decoded.exitCode, 0, decoded.stderr)
    assert.deepEqual(await read(fs, 'decoded.bin'), text)
  } finally {
    cleanup()
  }
})

test('gzip: an empty member between payload members decodes to the payload only', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    const payload = new TextEncoder().encode('non-empty payload\n')
    const concatenated = Uint8Array.from([
      ...gzipSync(new Uint8Array(0)),
      ...gzipSync(payload),
      ...gzipSync(new Uint8Array(0)),
    ])
    await write(fs, 'empty-members.gz', concatenated)
    const decoded = await run(shell, 'gzip -dc empty-members.gz > decoded.bin')
    assert.equal(decoded.exitCode, 0, decoded.stderr)
    assert.deepEqual(await read(fs, 'decoded.bin'), payload)
  } finally {
    cleanup()
  }
})

test('gzip: a wrong CRC keeps the decoded bytes and reports the checksum on stderr', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    await write(fs, 'bad-crc.gz', corruptTrailer(gzipSync(text), 0))
    const decoded = await run(shell, 'gzip -dc bad-crc.gz > decoded.bin')
    assert.equal(decoded.exitCode, 1, 'a checksum failure is exit 1')
    assert.match(decoded.stderr, /invalid compressed data--crc error/u)
    assert.deepEqual(await read(fs, 'decoded.bin'), text, 'the bytes decoded before the trailer check are kept')
  } finally {
    cleanup()
  }
})

test('gzip: a wrong ISIZE keeps the decoded bytes and reports the length error', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    await write(fs, 'bad-isize.gz', corruptTrailer(gzipSync(text), 1))
    const decoded = await run(shell, 'gzip -dc bad-isize.gz > decoded.bin')
    assert.equal(decoded.exitCode, 1, 'a length failure is exit 1')
    assert.match(decoded.stderr, /invalid compressed data--length error/u)
    assert.deepEqual(await read(fs, 'decoded.bin'), text, 'the bytes decoded before the trailer check are kept')
  } finally {
    cleanup()
  }
})

test('gzip: a truncated member exits 1 with a diagnostic, never a silent success', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    const member = gzipSync(text)
    await write(fs, 'truncated.gz', member.subarray(0, member.byteLength - 12))
    const decoded = await run(shell, 'gzip -dc truncated.gz > decoded.bin')
    assert.equal(decoded.exitCode, 1, 'truncated input must not exit 0')
    assert.match(decoded.stderr, /(unexpected end of file|incomplete|truncated)/iu)
    assert.doesNotMatch(decoded.stderr, /^gzip: Failed to Decode Data\.$/mu)
  } finally {
    cleanup()
  }
})

test('gzip: gzip -c output piped back through gzip -dc is byte-identical', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    // Every byte value, so a text-shaped pipe would be caught too.
    const input = Uint8Array.from({ length: 512 }, (_, index) => (index * 37) & 0xff)
    await write(fs, 'input.bin', input)
    const roundtrip = await run(shell, 'gzip -c input.bin > encoded.gz && gzip -dc encoded.gz > decoded.bin && cmp input.bin decoded.bin')
    assert.equal(roundtrip.exitCode, 0, roundtrip.stderr)
    assert.deepEqual(await read(fs, 'decoded.bin'), input)
    const encoded = await read(fs, 'encoded.gz')
    assert.deepEqual([...encoded.subarray(0, 2)], [0x1f, 0x8b], 'gzip -c emits a gzip member')
    // The reference RFC 1952 implementation on the host agrees.
    const reference = gunzipSync(encoded)
    assert.deepEqual(new Uint8Array(reference), input)
  } finally {
    cleanup()
  }
})

test('gzip: the empty payload encodes to a decodable member and roundtrips', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    const roundtrip = await run(shell, "printf '' > empty.bin; gzip -c empty.bin > empty.gz && gzip -dc empty.gz > restored.bin")
    assert.equal(roundtrip.exitCode, 0, roundtrip.stderr)
    assert.equal((await read(fs, 'restored.bin')).byteLength, 0)
    const encoded = await read(fs, 'empty.gz')
    assert.deepEqual([...encoded.subarray(0, 2)], [0x1f, 0x8b])
    const reference = gunzipSync(encoded)
    assert.equal(reference.byteLength, 0)
  } finally {
    cleanup()
  }
})

test('gzip: two gzip -c members concatenated on the VFS decode to the joined payload', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    const joined = await run(shell, [
      "printf 'alpha\\n' > a.txt",
      "printf 'beta\\n' > b.txt",
      'gzip -c a.txt > a.gz',
      'gzip -c b.txt > b.gz',
      'cat a.gz b.gz > both.gz',
      'gzip -dc both.gz > both.txt',
    ].join('; '))
    assert.equal(joined.exitCode, 0, joined.stderr)
    assert.equal(new TextDecoder().decode(await read(fs, 'both.txt')), 'alpha\nbeta\n')
  } finally {
    cleanup()
  }
})

test('gzip: a non-gzip file still fails loud with no output', async () => {
  const { fs, shell, cleanup } = fixture()
  try {
    await write(fs, 'not-gzip.bin', new TextEncoder().encode('definitely not gzip'))
    const decoded = await run(shell, 'gunzip not-gzip.bin')
    assert.equal(decoded.exitCode, 1)
    assert.match(decoded.stderr, /not in gzip format/u)
    assert.equal(decoded.stdout, '')
  } finally {
    cleanup()
  }
})
