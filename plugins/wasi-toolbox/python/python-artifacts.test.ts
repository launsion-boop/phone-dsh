// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { writeFileSync } from 'node:fs'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  PYTHON_STDLIB_FILE,
  PYTHON_WASM_FILE,
  artifactPairIn,
  discoverPythonArtifacts,
  ensurePythonArtifacts,
} from './python-artifacts.ts'

async function artifactDirectory(): Promise<string> {
  return mkdtemp(join(tmpdir(), 'pdsh-python-artifacts-'))
}

async function writePair(directory: string, wasm = 'wasm', stdlib = 'zip'): Promise<void> {
  await writeFile(join(directory, PYTHON_WASM_FILE), wasm)
  await writeFile(join(directory, PYTHON_STDLIB_FILE), stdlib)
}

function sha256(contents: string): string {
  return createHash('sha256').update(contents).digest('hex')
}

async function writeBuildReports(directory: string, wasm: string, stdlib: string, options: {
  modules?: readonly string[]
  tarfileGzip?: boolean
  wasmSha?: string
  stdlibSha?: string
} = {}): Promise<void> {
  await writeFile(join(directory, 'sizes.json'), JSON.stringify({
    pythonWasm: { sha256: options.wasmSha ?? sha256(wasm) },
    pythonStdlibZip: { sha256: options.stdlibSha ?? sha256(stdlib) },
  }))
  await writeFile(join(directory, 'compression.json'), JSON.stringify({
    modules: options.modules ?? ['zlib', 'bz2', 'lzma'],
    tarfileGzip: options.tarfileGzip ?? true,
  }))
}

test('python artifacts: an explicit PDSH_PYTHON_WASM wins and derives the stdlib sibling', () => {
  const discovery = discoverPythonArtifacts({
    env: { PDSH_PYTHON_WASM: '/artifacts/python.wasm' },
    probe: () => assert.fail('an explicit pair must not be probed during discovery'),
  })
  assert.deepEqual(discovery.pair, {
    wasm: '/artifacts/python.wasm',
    stdlib: join('/artifacts', PYTHON_STDLIB_FILE),
  })
})

test('python artifacts: PDSH_PYTHON_STDLIB selects a stdlib outside the wasm directory', () => {
  const discovery = discoverPythonArtifacts({
    env: {
      PDSH_PYTHON_WASM: '/a/python.wasm',
      PDSH_PYTHON_STDLIB: '/b/python313.zip',
    },
  })
  assert.deepEqual(discovery.pair, { wasm: '/a/python.wasm', stdlib: '/b/python313.zip' })
})

test('python artifacts: an explicit PDSH_PYTHON_ARTIFACTS directory is returned without probing', () => {
  const discovery = discoverPythonArtifacts({
    env: { PDSH_PYTHON_ARTIFACTS: '/explicit/artifacts' },
    probe: () => assert.fail('an explicit directory must not be probed during discovery'),
  })
  assert.deepEqual(discovery.pair, artifactPairIn('/explicit/artifacts'))
  assert.equal(discovery.skipReason, undefined)
})

test('python artifacts: no default artifact skips with the build command', () => {
  const discovery = discoverPythonArtifacts({
    env: {},
    defaultDirectory: join(tmpdir(), 'pdsh-python-artifacts-absent-entirely'),
    probe: () => assert.fail('an absent default pair must not be probed'),
  })
  assert.equal(discovery.pair, undefined)
  assert.match(discovery.skipReason ?? '', /no built python\.wasm/)
  assert.match(discovery.skipReason ?? '', /build\.sh --out/)
})

test('python artifacts: a half-present default artifact is skipped as incomplete', async () => {
  const directory = await artifactDirectory()
  try {
    await writeFile(join(directory, PYTHON_WASM_FILE), 'wasm')
    const discovery = discoverPythonArtifacts({
      env: {},
      defaultDirectory: directory,
      probe: () => assert.fail('an incomplete default pair must not be probed'),
    })
    assert.equal(discovery.pair, undefined)
    assert.match(discovery.skipReason ?? '', /incomplete artifact/)
    assert.match(discovery.skipReason ?? '', /python313\.zip/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: a default pair without compression.json is skipped as a pre-fix build', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    // A pre-fix build wrote sizes.json but never compression.json, because the
    // compression probe did not exist. That leftover is ambient state, not a
    // current-build regression, and must not fail every npm test.
    await writeFile(join(directory, 'sizes.json'), JSON.stringify({
      pythonWasm: { sha256: sha256('wasm') },
      pythonStdlibZip: { sha256: sha256('zip') },
    }))
    const discovery = discoverPythonArtifacts({
      env: {},
      defaultDirectory: directory,
      probe: () => assert.fail('an unverified legacy pair must not be executed'),
    })
    assert.equal(discovery.pair, undefined)
    assert.equal(discovery.failure, undefined)
    assert.match(discovery.skipReason ?? '', /no compression\.json/)
    assert.match(discovery.skipReason ?? '', /build\.sh --out/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: a stamped default artifact that passes the probe is returned as verified', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    await writeBuildReports(directory, 'wasm', 'zip')
    const probed: string[] = []
    const discovery = discoverPythonArtifacts({
      env: {},
      defaultDirectory: directory,
      probe: pair => {
        probed.push(pair.stdlib)
        return { ok: true, output: 'compression probe: zlib 1.3.1, bz2 ok, lzma ok' }
      },
    })
    assert.equal(discovery.failure, undefined)
    assert.equal(discovery.probeVerified, true)
    assert.deepEqual(discovery.pair, artifactPairIn(directory))
    assert.deepEqual(probed, [join(directory, PYTHON_STDLIB_FILE)])
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: a stamped artifact whose probe fails fails the suite instead of skipping', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    await writeBuildReports(directory, 'wasm', 'zip')
    const discovery = discoverPythonArtifacts({
      env: {},
      defaultDirectory: directory,
      probe: () => ({ ok: false, output: 'compression probe: FAILED: no module named zlib' }),
    })
    assert.equal(discovery.pair, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.match(discovery.failure ?? '', /probe failed/)
    assert.match(discovery.failure ?? '', /no module named zlib/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: a stamped artifact with mismatched report hashes fails the suite', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    await writeBuildReports(directory, 'wasm', 'zip', { wasmSha: sha256('some other wasm') })
    const discovery = discoverPythonArtifacts({
      env: {},
      defaultDirectory: directory,
      probe: () => assert.fail('an inconsistent stamped pair must not be executed'),
    })
    assert.equal(discovery.pair, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.match(discovery.failure ?? '', /python\.wasm sha256 is/)
    assert.match(discovery.failure ?? '', /sizes\.json records/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: a compression report that omits a module fails the suite', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    await writeBuildReports(directory, 'wasm', 'zip', { modules: ['zlib', 'lzma'] })
    const discovery = discoverPythonArtifacts({
      env: {},
      defaultDirectory: directory,
      probe: () => assert.fail('an inconsistent stamped pair must not be executed'),
    })
    assert.equal(discovery.pair, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.match(discovery.failure ?? '', /missing bz2/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

/** Publish a verified-looking pair synchronously, as build.sh --check does. */
function publishVerifiedPair(directory: string, wasm = 'wasm', stdlib = 'zip'): void {
  writeFileSync(join(directory, PYTHON_WASM_FILE), wasm)
  writeFileSync(join(directory, PYTHON_STDLIB_FILE), stdlib)
  writeFileSync(join(directory, 'sizes.json'), JSON.stringify({
    pythonWasm: { sha256: sha256(wasm) },
    pythonStdlibZip: { sha256: sha256(stdlib) },
  }))
  writeFileSync(join(directory, 'compression.json'), JSON.stringify({
    modules: ['zlib', 'bz2', 'lzma'],
    tarfileGzip: true,
  }))
}

test('python artifacts: ensure rebuilds an absent default pair instead of skipping', async () => {
  const directory = await artifactDirectory()
  try {
    let builds = 0
    const discovery = ensurePythonArtifacts({
      env: {},
      defaultDirectory: directory,
      build: () => {
        builds += 1
        publishVerifiedPair(directory)
        return { ok: true, output: 'python build: done' }
      },
      probe: () => ({ ok: true, output: 'compression probe: zlib ok' }),
    })
    assert.equal(builds, 1)
    assert.equal(discovery.failure, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.equal(discovery.probeVerified, true)
    assert.match(discovery.provisioned ?? '', /no built python\.wasm/)
    assert.deepEqual(discovery.pair, artifactPairIn(directory))
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: ensure replaces a pre-fix pair instead of skipping it', async () => {
  const directory = await artifactDirectory()
  try {
    // A pre-fix build: the pair exists but has no compression.json, the exact
    // ambient state that used to make the four compression tests skip.
    await writePair(directory)
    await writeFile(join(directory, 'sizes.json'), JSON.stringify({
      pythonWasm: { sha256: sha256('wasm') },
      pythonStdlibZip: { sha256: sha256('zip') },
    }))
    let builds = 0
    const discovery = ensurePythonArtifacts({
      env: {},
      defaultDirectory: directory,
      build: () => {
        builds += 1
        publishVerifiedPair(directory)
        return { ok: true, output: 'python build: rebuilt' }
      },
      probe: () => ({ ok: true, output: 'compression probe: zlib ok' }),
    })
    assert.equal(builds, 1)
    assert.equal(discovery.failure, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.equal(discovery.probeVerified, true)
    assert.match(discovery.provisioned ?? '', /no compression\.json/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: ensure fails the suite when the build cannot produce a pair', async () => {
  const directory = await artifactDirectory()
  try {
    const discovery = ensurePythonArtifacts({
      env: {},
      defaultDirectory: directory,
      build: () => ({ ok: false, output: 'python build: ModuleNotFoundError: No module named zlib' }),
      probe: () => assert.fail('a failed build is not probed'),
    })
    assert.equal(discovery.pair, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.match(discovery.failure ?? '', /did not produce one/)
    assert.match(discovery.failure ?? '', /ModuleNotFoundError/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: ensure fails when --check exits 0 but the pair stays unverified', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    const discovery = ensurePythonArtifacts({
      env: {},
      defaultDirectory: directory,
      build: () => ({ ok: true, output: 'python build: pretend success' }),
      probe: () => ({ ok: true, output: 'compression probe: ok' }),
    })
    assert.equal(discovery.pair, undefined)
    assert.match(discovery.failure ?? '', /still not verified/)
    assert.match(discovery.failure ?? '', /no compression\.json/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test('python artifacts: an explicit selection never triggers a build', () => {
  const discovery = ensurePythonArtifacts({
    env: { PDSH_PYTHON_WASM: '/artifacts/python.wasm' },
    build: () => assert.fail('an explicit pair must not be built over'),
    probe: () => assert.fail('an explicit pair is not probed during selection'),
  })
  assert.deepEqual(discovery.pair, {
    wasm: '/artifacts/python.wasm',
    stdlib: join('/artifacts', PYTHON_STDLIB_FILE),
  })
})

test('python artifacts: a stamped pair whose probe fails is a failure, not a rebuild', async () => {
  const directory = await artifactDirectory()
  try {
    await writePair(directory)
    await writeBuildReports(directory, 'wasm', 'zip')
    const discovery = ensurePythonArtifacts({
      env: {},
      defaultDirectory: directory,
      build: () => assert.fail('a stamped regression must not be rebuilt away'),
      probe: () => ({ ok: false, output: 'compression probe: FAILED: no module named zlib' }),
    })
    assert.equal(discovery.pair, undefined)
    assert.equal(discovery.skipReason, undefined)
    assert.match(discovery.failure ?? '', /probe failed/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})
