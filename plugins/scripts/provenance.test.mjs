// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { gzipSync } from 'node:zlib'
import { createBundleProvenance, verifyBundleProvenance, writeImageProvenance } from './provenance.mjs'

const scratch = []
after(() => { for (const path of scratch) rmSync(path, { recursive: true, force: true }) })

function tarArchive(entries) {
  const blocks = []
  for (const [path, value] of Object.entries(entries)) {
    const data = Buffer.from(value)
    const header = Buffer.alloc(512)
    header.write(path, 0, 100, 'utf8')
    header.write(`${data.byteLength.toString(8).padStart(11, '0')}\0`, 124, 12, 'ascii')
    header[156] = 48
    const checksumHeader = Buffer.from(header)
    checksumHeader.fill(32, 148, 156)
    const checksum = [...checksumHeader].reduce((sum, byte) => sum + byte, 0)
    header.write(`${checksum.toString(8).padStart(6, '0')}\0 `, 148, 8, 'ascii')
    blocks.push(header, data, Buffer.alloc((512 - (data.byteLength % 512)) % 512))
  }
  blocks.push(Buffer.alloc(1024))
  return Buffer.concat(blocks)
}

function fixture(python) {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-provenance-'))
  scratch.push(root)
  const source = join(root, 'source')
  const imageOut = join(root, 'image')
  const bundle = join(root, 'bundle')
  mkdirSync(source)
  mkdirSync(imageOut)
  mkdirSync(bundle)
  writeFileSync(join(source, 'dsh-pin.json'), JSON.stringify({ commit: 'f'.repeat(40) }))
  writeFileSync(join(source, 'input.ts'), 'source identity')
  const tar = python
    ? tarArchive({ 'bin/python/python.wasm': 'W', 'bin/python/python313.zip': 'Z' })
    : tarArchive({ 'notes.txt': 'bin/python/python.wasm bin/python/python313.zip appear only in this body' })
  writeFileSync(join(imageOut, 'image.tar.gz'), gzipSync(tar))
  writeFileSync(join(imageOut, 'manifest.json'), JSON.stringify({ root: '/dsh', profile: 'web' }))
  writeFileSync(join(imageOut, 'sizes.json'), JSON.stringify(python ? {
    python: { version: '3.13', files: [
      { path: 'bin/python/python.wasm', bytes: 1 }, { path: 'bin/python/python313.zip', bytes: 1 },
    ] },
  } : {}))
  writeImageProvenance(imageOut, { dshCommit: 'f'.repeat(40), sourceRoot: source })

  const workerEntry = join(bundle, 'worker-entry.js')
  const toolWorker = join(bundle, 'tool-worker-python.js')
  writeFileSync(workerEntry, 'worker entry bytes')
  writeFileSync(toolWorker, 'python worker bytes')
  writeFileSync(join(bundle, 'index.html'), 'page bytes')
  writeFileSync(join(bundle, 'boot.js'), 'boot bytes')
  writeFileSync(join(bundle, 'client.js'), 'client bytes')
  mkdirSync(join(bundle, 'lazy'))
  writeFileSync(join(bundle, 'lazy', 'chunk.tar.gz'), 'lazy bytes')
  for (const file of ['image.tar.gz', 'manifest.json', 'sizes.json']) {
    copyFileSync(join(imageOut, file), join(bundle, file))
  }
  createBundleProvenance({ imageOutput: imageOut, output: bundle, sourceRoot: source })
  return { root, source, imageOut, bundle, workerEntry, toolWorker }
}

test('bundle provenance records and checks every final bundle file', () => {
  const item = fixture(true)
  const provenance = join(item.bundle, 'phone-dsh-provenance.json')
  const record = JSON.parse(readFileSync(provenance, 'utf8'))
  assert.equal(record.python, true)
  assert.deepEqual(record.bundle_files.map(file => file.path), [
    'boot.js', 'client.js', 'image.tar.gz', 'index.html', 'lazy/chunk.tar.gz',
    'manifest.json', 'sizes.json', 'tool-worker-python.js', 'worker-entry.js',
  ])
  assert.equal(verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectPython: 'yes',
  }).python, true)
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectPython: 'no',
  }), /Python capability mismatch/)

  writeFileSync(join(item.bundle, 'boot.js'), 'tampered boot')
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source,
  }), /boot\.js/)
})

test('a pre-jq provenance record is valid only as a jq-less bundle', () => {
  const item = fixture(true)
  const provenance = join(item.bundle, 'phone-dsh-provenance.json')
  const record = JSON.parse(readFileSync(provenance, 'utf8'))
  delete record.jq
  writeFileSync(provenance, `${JSON.stringify(record, null, 2)}\n`)
  assert.equal(verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectJq: 'no',
  }).jq, false)
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectJq: 'yes',
  }), /jq capability mismatch/)
  // Advertising jq without the generic worker the toolbox spawns is the
  // artifact bug that made the first jq command 404.
  record.jq = true
  writeFileSync(provenance, `${JSON.stringify(record, null, 2)}\n`)
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectJq: 'yes',
  }), /requires the generic tool-worker\.js/)
})

test('bundle provenance rejects missing Python and changed source identity', () => {
  const item = fixture(false)
  const provenance = join(item.bundle, 'phone-dsh-provenance.json')
  assert.equal(JSON.parse(readFileSync(provenance, 'utf8')).python, false)
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectPython: 'yes',
  }), /Python capability mismatch/)
  writeFileSync(join(item.source, 'input.ts'), 'changed source identity')
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source, expectPython: 'no',
  }), /source hash/)
})

test('an external image path remains valid when it matches the recorded bundle image', () => {
  const item = fixture(true)
  const provenance = join(item.bundle, 'phone-dsh-provenance.json')
  rmSync(join(item.bundle, 'image.tar.gz'))
  assert.equal(verifyBundleProvenance({
    bundleRoot: item.bundle,
    imageOverride: join(item.imageOut, 'image.tar.gz'),
    provenance,
    sourceRoot: item.source,
    expectPython: 'yes',
  }).python, true)
})

test('Python detection requires real nonempty tar entries, not path strings in file bodies', () => {
  const item = fixture(false)
  assert.equal(JSON.parse(readFileSync(join(item.bundle, 'phone-dsh-provenance.json'), 'utf8')).python, false)
})

test('bundle provenance refuses Python metadata without its tar entries', () => {
  const item = fixture(false)
  writeFileSync(join(item.imageOut, 'sizes.json'), JSON.stringify({ python: { version: '3.13' } }))
  assert.throws(() => writeImageProvenance(item.imageOut, { dshCommit: 'f'.repeat(40), sourceRoot: item.source }), /metadata does not match/)
})

test('bundle verification rejects modified manifest and lazy bundle assets', () => {
  const item = fixture(true)
  const provenance = join(item.bundle, 'phone-dsh-provenance.json')
  writeFileSync(join(item.bundle, 'manifest.json'), JSON.stringify({ root: '/tampered' }))
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source,
  }), /manifest\.json/)
  copyFileSync(join(item.imageOut, 'manifest.json'), join(item.bundle, 'manifest.json'))
  writeFileSync(join(item.bundle, 'lazy', 'chunk.tar.gz'), 'tampered lazy chunk')
  assert.throws(() => verifyBundleProvenance({
    bundleRoot: item.bundle, provenance, sourceRoot: item.source,
  }), /lazy\/chunk\.tar\.gz/)
})
