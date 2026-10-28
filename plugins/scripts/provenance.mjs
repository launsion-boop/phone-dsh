// SPDX-License-Identifier: MIT
import { createHash } from 'node:crypto'
import { existsSync, lstatSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gunzipSync } from 'node:zlib'

export const PHONE_SOURCE_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const PROVENANCE_FILE = 'phone-dsh-provenance.json'

function hashBytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

export function sha256File(path) {
  return hashBytes(readFileSync(path))
}

/** Hash the source files that build the Worker and image, independent of mtimes. */
export function phoneSourceHash(root = PHONE_SOURCE_ROOT) {
  const hash = createHash('sha256')
  const ignored = new Set(['.git', 'node_modules', 'dist', '.build', 'DerivedData', 'coverage'])
  const walk = directory => {
    for (const name of readdirSync(directory).sort()) {
      if (ignored.has(name)) continue
      const path = join(directory, name)
      const info = lstatSync(path)
      if (info.isSymbolicLink()) throw new Error(`phone source contains a symbolic link: ${path}`)
      if (info.isDirectory()) walk(path)
      else if (info.isFile()) {
        hash.update(relative(root, path).replaceAll('\\', '/'))
        hash.update('\0')
        hash.update(readFileSync(path))
        hash.update('\0')
      }
    }
  }
  walk(root)
  return hash.digest('hex')
}

export function readPin(root = PHONE_SOURCE_ROOT) {
  return JSON.parse(readFileSync(join(root, 'dsh-pin.json'), 'utf8'))
}

export function pythonPresent(imageOutput) {
  const sizes = JSON.parse(readFileSync(join(imageOutput, 'sizes.json'), 'utf8'))
  JSON.parse(readFileSync(join(imageOutput, 'manifest.json'), 'utf8'))
  const tar = gunzipSync(readFileSync(join(imageOutput, 'image.tar.gz')))
  const pythonFiles = sizes.python?.files ?? []
  const wasmPath = 'bin/python/python.wasm'
  const stdlibPath = 'bin/python/python313.zip'
  const manifestFiles = new Map(pythonFiles.map(file => [file.path, file.bytes]))
  const entries = readTarEntries(tar)
  const hasWasm = entries.has(wasmPath) && entries.get(wasmPath) > 0
  const hasStdlib = entries.has(stdlibPath) && entries.get(stdlibPath) > 0
  const hasPythonManifest = manifestFiles.has(wasmPath) && manifestFiles.has(stdlibPath)
    && manifestFiles.get(wasmPath) > 0 && manifestFiles.get(stdlibPath) > 0
  const metadataClaimsPython = Boolean(sizes.python)
  if (metadataClaimsPython !== hasPythonManifest
      || metadataClaimsPython !== (hasWasm && hasStdlib)
      || hasWasm !== hasStdlib) {
    throw new Error('python capability metadata does not match image contents')
  }
  return Boolean(sizes.python)
}

/**
 * Whether the image really carries the jq engine, checked against both the
 * packer metadata and the image's own tar entries. A metadata-only claim is a
 * broken artifact, not a capability.
 * @param imageOutput - pack-image output directory.
 * @returns True only when `jq.wasm` and its engine report are present.
 */
export function jqPresent(imageOutput) {
  const sizes = JSON.parse(readFileSync(join(imageOutput, 'sizes.json'), 'utf8'))
  const tar = gunzipSync(readFileSync(join(imageOutput, 'image.tar.gz')))
  const wasmPath = 'bin/jq/jq.wasm'
  const enginePath = 'bin/jq/engine.json'
  const metadata = new Map((sizes.jq?.files ?? []).map(file => [file.path, file.bytes]))
  const entries = readTarEntries(tar)
  const hasWasm = entries.has(wasmPath) && entries.get(wasmPath) > 0
  const hasEngine = entries.has(enginePath) && entries.get(enginePath) > 0
  const metadataClaimsJq = Boolean(sizes.jq)
  if (metadataClaimsJq !== (hasWasm && hasEngine)
      || !metadata.has(wasmPath) && metadataClaimsJq
      || hasWasm !== hasEngine) {
    throw new Error('jq capability metadata does not match image contents')
  }
  return Boolean(sizes.jq)
}

/** Parse regular-file names and sizes from the ustar image without extracting it. */
function readTarEntries(tar) {
  const entries = new Map()
  for (let offset = 0; offset + 512 <= tar.byteLength; ) {
    const header = tar.subarray(offset, offset + 512)
    if (header.every(byte => byte === 0)) break
    const text = (start, length) => header.subarray(start, start + length).toString('utf8').replace(/\0.*$/s, '')
    const name = text(0, 100)
    const prefix = text(345, 155)
    const path = prefix === '' ? name : `${prefix}/${name}`
    const sizeText = text(124, 12).trim().replace(/\0/g, '')
    const size = sizeText === '' ? 0 : Number.parseInt(sizeText, 8)
    const type = header[156]
    if (!Number.isFinite(size) || size < 0 || offset + 512 + size > tar.byteLength) {
      throw new Error('image tar has an invalid entry size')
    }
    if (path !== '' && (type === 0 || type === 48)) entries.set(path, size)
    offset += 512 + Math.ceil(size / 512) * 512
  }
  return entries
}

function bundleFiles(root) {
  const files = []
  const walk = directory => {
    for (const name of readdirSync(directory).sort()) {
      const path = join(directory, name)
      const info = lstatSync(path)
      if (info.isSymbolicLink()) throw new Error(`bundle contains a symbolic link: ${path}`)
      if (info.isDirectory()) walk(path)
      else if (info.isFile()) {
        const assetPath = relative(root, path).replaceAll('\\', '/')
        if (assetPath === PROVENANCE_FILE || assetPath === 'probe-bundle.json' || name === '.gitkeep') continue
        files.push({ path: assetPath, sha256: sha256File(path) })
      }
    }
  }
  walk(root)
  return files
}

export function writeImageProvenance(imageOutput, { dshCommit, sourceRoot = PHONE_SOURCE_ROOT } = {}) {
  const imagePath = join(imageOutput, 'image.tar.gz')
  const record = {
    schema: 1,
    phone_source_sha256: phoneSourceHash(sourceRoot),
    dsh_commit: dshCommit,
    image_sha256: sha256File(imagePath),
    python: pythonPresent(imageOutput),
    jq: jqPresent(imageOutput),
  }
  writeFileSync(join(imageOutput, PROVENANCE_FILE), `${JSON.stringify(record, null, 2)}\n`)
  return record
}

export function createBundleProvenance({ imageOutput, output, sourceRoot = PHONE_SOURCE_ROOT }) {
  const imageRecord = JSON.parse(readFileSync(join(imageOutput, PROVENANCE_FILE), 'utf8'))
  const pin = readPin(sourceRoot)
  if (imageRecord.dsh_commit !== pin.commit) throw new Error('image provenance DSH commit does not match the phone-dsh pin')
  const bundleImage = join(output, 'image.tar.gz')
  if (!existsSync(bundleImage) || sha256File(bundleImage) !== imageRecord.image_sha256) {
    throw new Error('bundle image bytes do not match the packer provenance')
  }
  const record = {
    ...imageRecord,
    bundle_files: bundleFiles(output),
  }
  writeFileSync(join(output, PROVENANCE_FILE), `${JSON.stringify(record, null, 2)}\n`)
  return record
}

export function verifyBundleProvenance({ bundleRoot, imageOverride, provenance, sourceRoot = PHONE_SOURCE_ROOT, expectPython = 'any', expectJq = 'any' }) {
  if (!existsSync(provenance)) throw new Error(`missing provenance file: ${provenance}`)
  const record = JSON.parse(readFileSync(provenance, 'utf8'))
  if (record.schema !== 1) throw new Error('unsupported provenance schema')
  // Bundles produced before the jq engine existed have no `jq` field. They
  // are legitimately jq-less, so `--jq no` must accept them; only an explicit
  // true may advertise the capability.
  const jq = record.jq ?? false
  const pin = readPin(sourceRoot)
  const sourceHash = phoneSourceHash(sourceRoot)
  if (record.phone_source_sha256 !== sourceHash) throw new Error('phone-dsh source hash does not match this checkout')
  if (record.dsh_commit !== pin.commit) throw new Error('DSH commit does not match plugins/dsh-pin.json')
  if (!Array.isArray(record.bundle_files) || record.bundle_files.length === 0) {
    throw new Error('provenance bundle_files list is missing or empty')
  }
  const expected = new Map(record.bundle_files.map(file => [file.path, file.sha256]))
  if (expected.size !== record.bundle_files.length) throw new Error('provenance bundle_files contains duplicate paths')
  const actual = new Map(bundleFiles(bundleRoot).map(file => [file.path, file.sha256]))
  if (imageOverride) {
    if (!existsSync(imageOverride)) throw new Error(`missing external image: ${imageOverride}`)
    if (!expected.has('image.tar.gz') || expected.get('image.tar.gz') !== sha256File(imageOverride)) {
      throw new Error('external image does not match the bundle image digest')
    }
    if (actual.has('image.tar.gz') && actual.get('image.tar.gz') !== expected.get('image.tar.gz')) {
      throw new Error('bundle image bytes do not match the provenance digest')
    }
    actual.set('image.tar.gz', sha256File(imageOverride))
  }
  for (const [path, digest] of expected) {
    if (path.startsWith('/') || path.split('/').includes('..')) throw new Error(`invalid bundle path in provenance: ${path}`)
    if (actual.get(path) !== digest) throw new Error(`bundle file ${path} is missing or its bytes changed`)
  }
  for (const path of actual.keys()) {
    if (!expected.has(path)) throw new Error(`unrecorded bundle file: ${path}`)
  }
  // The jq toolbox always spawns `./tool-worker.js` beside the entry. An image
  // that stages jq.wasm but whose bundle lacks that file advertises a
  // capability whose first invocation is a nested-Worker 404.
  if (jq && !actual.has('tool-worker.js')) {
    throw new Error('jq capability requires the generic tool-worker.js beside worker-entry.js')
  }
  if (expectPython !== 'any' && record.python !== (expectPython === 'yes')) {
    throw new Error(`Python capability mismatch: expected ${expectPython}, provenance says ${String(record.python)}`)
  }
  if (expectJq !== 'any' && jq !== (expectJq === 'yes')) {
    throw new Error(`jq capability mismatch: expected ${expectJq}, provenance says ${String(jq)}`)
  }
  return { ...record, jq }
}
