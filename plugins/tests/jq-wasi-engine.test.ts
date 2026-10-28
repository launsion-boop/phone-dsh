// SPDX-License-Identifier: MIT
/**
 * End-to-end regression for the real jq engine.
 *
 * These tests execute the produced `jq.wasm` through the Worker's actual
 * `WasiToolbox` (generic tool worker, VFS proxy, hot instance) and assert the
 * output/status a native jq 1.6 produces for the input-family shapes the old
 * token shim had to refuse. They are separate from the 512-vector golden gate
 * on purpose: the golden vectors continue to pin the fail-loud shim that an
 * image without the artifact keeps, while this file proves the artifact-backed
 * path really implements the capability.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { fileURLToPath } from 'node:url'
import { discoverJqArtifact } from '../wasi-toolbox/jq/artifacts.ts'
import { workerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/message-endpoint.ts'
import { WasiToolbox } from '../wasi-toolbox/src/toolbox.ts'
import { MemoryVfsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import { setWorkerToolbox } from '../wasi-toolbox/src/toolbox.ts'
import { createWorkerCommands } from '../shell-ext/src/commands.ts'
import { VfsFileSystem } from '../shell-ext/src/filesystem.ts'
import { WorkerShell } from '../shell-ext/src/shell.ts'
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { buildCapabilityManifest } from '../worker-entry/src/capabilities.ts'
import { installJqToolbox, JQ_ENGINE_IMAGE_PATH, JQ_WASM_IMAGE_PATH } from '../worker-entry/src/jq-toolbox.ts'
import type { WorkerEntryVfs } from '../worker-entry/src/entry.ts'

const artifact = discoverJqArtifact()

interface EngineFixture {
  readonly toolbox: WasiToolbox
  readonly backend: MemoryVfsBackend
  readonly close: () => Promise<void>
}

async function engine(files: Readonly<Record<string, string>> = {}): Promise<EngineFixture> {
  if (artifact.artifact === undefined) throw new Error(artifact.skipReason ?? 'no jq artifact')
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/tmp')
  for (const [name, text] of Object.entries(files)) backend.seedFile(`/dsh/workspace/${name}`, text)
  const wasm = readFileSync(artifact.artifact.wasm)
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'jq-wasi',
      aliases: ['jaq'],
      module: { url: `image://${artifact.artifact.wasm}`, load: async () => wasm },
    }],
    backend,
    preopens: [
      { guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' },
      { guestPath: '/dsh/home', hostPath: '/dsh/home' },
      { guestPath: '/dsh/tmp', hostPath: '/dsh/tmp' },
    ],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
  })
  await toolbox.assertFileView()
  return {
    toolbox,
    backend,
    close: async () => { await toolbox.dispose() },
  }
}

interface Outcome {
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

async function jq(setup: EngineFixture, args: readonly string[], stdin: string | Uint8Array = ''): Promise<Outcome> {
  const out: Uint8Array[] = []
  const err: Uint8Array[] = []
  const result = await setup.toolbox.run({
    program: 'jq-wasi',
    argv: [...args],
    cwd: '/dsh/workspace',
    env: {},
    stdin: typeof stdin === 'string' ? new TextEncoder().encode(stdin) : stdin,
    onStdout: chunk => { out.push(Uint8Array.from(chunk)) },
    onStderr: chunk => { err.push(Uint8Array.from(chunk)) },
  })
  const decode = (chunks: readonly Uint8Array[]): string => {
    const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
    const joined = new Uint8Array(total)
    let offset = 0
    for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength }
    return new TextDecoder().decode(joined)
  }
  return { code: result.exitCode, stdout: decode(out), stderr: decode(err) }
}

test('jq wasi: artifact is present and was built by the pinned engine', { skip: artifact.skipReason }, () => {
  assert.ok(artifact.artifact !== undefined)
  const report = JSON.parse(readFileSync(artifact.artifact.engine, 'utf8')) as { engine?: unknown; probes?: unknown }
  assert.match(String(report.engine), /jaq-core/u)
  assert.ok(Array.isArray(report.probes) && report.probes.length >= 4)
})

test('jq wasi: lazy conditionals, functions, reduce/foreach and break match jq 1.6', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  const setup = await engine({
    'n4.json': '1\n2\n3\n4\n',
    'n3.json': '1\n2\n3\n',
  })
  try {
    assert.deepEqual(await jq(setup, ['-c', 'if . == 3 then input else . end', 'n4.json']),
      { code: 0, stdout: '1\n2\n4\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'select(. > 1) | inputs', 'n4.json']),
      { code: 0, stdout: '3\n4\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'first(inputs)', 'n4.json']),
      { code: 0, stdout: '2\n4\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-n', '-c', '1, inputs, 2', 'n3.json']),
      { code: 0, stdout: '1\n1\n2\n3\n2\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'reduce inputs as $x (0; .+$x)', 'n4.json']),
      { code: 0, stdout: '9\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', '[foreach inputs as $x (0; .+$x; .)]', 'n4.json']),
      { code: 0, stdout: '[2,5,9]\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'label $out | 1, break $out', 'n4.json']),
      { code: 0, stdout: '1\n1\n1\n1\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'def f($x): $x + .; f(10)', 'n4.json']),
      { code: 0, stdout: '11\n12\n13\n14\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'input as $x | $x + .', 'n4.json']),
      { code: 0, stdout: '3\n7\n', stderr: '' })
  } finally {
    await setup.close()
  }
})

test('jq wasi: EOF break, line number and input families keep native status', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  const setup = await engine({
    'n3.json': '1\n2\n3\n',
    'n2.json': '1\n2',
    'multi.json': '{\n"a":1\n}\n{\n"a":2\n}\n',
    'k1': 'a\nb',
    'empty.json': '',
    'bad.json': '1\n{invalid\n',
  })
  try {
    const broke = await jq(setup, ['-c', 'input', 'n3.json'])
    assert.equal(broke.code, 5)
    assert.equal(broke.stdout, '2\n')
    assert.match(broke.stderr, /jq: error \(at n3\.json:3\): break/u)
    const empty = await jq(setup, ['-n', '-c', 'input', 'empty.json'])
    assert.equal(empty.code, 5)
    assert.match(empty.stderr, /\(at empty\.json:0\): break/u)
    assert.deepEqual(await jq(setup, ['-c', 'input_line_number', 'n3.json']),
      { code: 0, stdout: '1\n2\n3\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'input_line_number', 'n2.json']),
      { code: 0, stdout: '1\n1\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-c', 'input_line_number', 'multi.json']),
      { code: 0, stdout: '3\n6\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-R', '-c', '[., input_line_number]', 'k1', 'empty.json']),
      { code: 0, stdout: '["a",1]\n["b",0]\n', stderr: '' })
    const trailing = await jq(setup, [
      '-R', '-c', 'if input_line_number == 0 then error("zero") else . end', 'k1', 'empty.json',
    ])
    assert.equal(trailing.code, 5)
    assert.equal(trailing.stdout, '"a"\n')
    assert.match(trailing.stderr, /\(at empty\.json:0\): zero/u)
    assert.deepEqual(await jq(setup, ['-n', '-c', '"\\(inputs)"', 'n3.json']),
      { code: 0, stdout: '"1"\n"2"\n"3"\n', stderr: '' })
    // EOF is jq's real "break" error value, not an internal sentinel. `catch`
    // sees the same string native jq exposes.
    const caughtBreak = await jq(setup, ['-n', '-c', 'try input catch .', 'empty.json'])
    assert.deepEqual(caughtBreak, { code: 0, stdout: '"break"\n', stderr: '' })
    // A parse error is an ordinary catchable error value too; it must not leak
    // a marker into the catch or the diagnostic.
    const caughtParse = await jq(setup, ['-n', '-c', 'try (input,input) catch .', 'bad.json'])
    assert.equal(caughtParse.code, 0)
    assert.match(caughtParse.stdout, /^1\n"/u)
    assert.doesNotMatch(caughtParse.stdout, /__pdsh_jq_/u)
    assert.equal(caughtParse.stderr, '')
    // An unreadable operand is not catchable: native jq reports it and exits 2
    // even when `input` itself ends in a caught break.
    const missing = await jq(setup, ['-n', '-c', 'try input catch .', 'missing.json'])
    assert.equal(missing.code, 2)
    assert.equal(missing.stdout, '"break"\n')
    assert.match(missing.stderr, /Could not open file missing\.json/u)
  } finally {
    await setup.close()
  }
})

test('jq wasi: raw operands reset line numbers and raw slurp uses the last source', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  const setup = await engine({
    'r1': 'a\nb\n',
    'r2': 'c\nd\n',
    'r3': 'a\nb\nc\n',
  })
  try {
    assert.deepEqual(await jq(setup, ['-R', 'input_line_number', 'r1', 'r2']),
      { code: 0, stdout: '1\n2\n1\n2\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-R', '-s', 'input_line_number', 'r1']),
      { code: 0, stdout: '2\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-R', '-s', 'input_line_number', 'r3', 'r2']),
      { code: 0, stdout: '2\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-R', '-s', '.', 'r1', 'r2']),
      { code: 0, stdout: '"a\\nb\\nc\\nd\\n"\n', stderr: '' })
  } finally {
    await setup.close()
  }
})

test('jq wasi: -s stays lazy under -n and preserves empty-result/open-error order', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  const setup = await engine({ 'one.json': '1\n' })
  try {
    assert.deepEqual(await jq(setup, ['-n', '-s', '.', 'missing.json']),
      { code: 0, stdout: 'null\n', stderr: '' })
    const slurped = await jq(setup, ['-s', '.', 'missing.json'])
    assert.equal(slurped.code, 2)
    assert.equal(slurped.stdout, '[]\n')
    assert.match(slurped.stderr, /Could not open file missing\.json/u)
    const constant = await jq(setup, ['-s', '1', 'missing.json'])
    assert.equal(constant.code, 2)
    assert.equal(constant.stdout, '1\n')
    assert.match(constant.stderr, /Could not open file missing\.json/u)
    const existing = await jq(setup, ['-s', '.', 'one.json', 'missing.json'])
    assert.equal(existing.code, 2)
    assert.equal(existing.stdout, '[\n  1\n]\n')
    assert.match(existing.stderr, /Could not open file missing\.json/u)
  } finally {
    await setup.close()
  }
})

test('jq wasi: $ARGS, $__loc__ and invalid UTF-8 are real engine paths', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  const setup = await engine({ 'one.json': '1\n' })
  try {
    assert.deepEqual(await jq(setup, ['-n', '-c', '$ARGS', '--args', 'a', 'b']),
      { code: 0, stdout: '{"positional":["a","b"],"named":{}}\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-n', '-c', '$__loc__']),
      { code: 0, stdout: '{"file":"<top-level>","line":1}\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-n', '-c', '1,\n$__loc__']),
      { code: 0, stdout: '1\n{"file":"<top-level>","line":2}\n', stderr: '' })
    assert.deepEqual(await jq(setup, ['-n', '-c', 'def f:\n  $__loc__;\n[f, f]']),
      { code: 0, stdout: '[{"file":"<top-level>","line":2},{"file":"<top-level>","line":2}]\n', stderr: '' })
    const invalid = await jq(setup, ['-c', '.'], new Uint8Array([0x22, 0xff, 0xfe, 0x22, 0x0a]))
    assert.equal(invalid.code, 0)
    assert.equal(invalid.stdout, '"��"\n')
  } finally {
    await setup.close()
  }
})

test('jq wasi: boot wiring publishes the engine and the shell jq routes to it', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  const setup = await engine({ 'n4.json': '1\n2\n3\n4\n' })
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-shell-'))
  try {
    setWorkerToolbox(setup.toolbox)
    mkdirSync(join(root, '/dsh/workspace'), { recursive: true })
    writeFileSync(join(root, '/dsh/workspace/n4.json'), '1\n2\n3\n4\n')
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox: setup.toolbox }),
    })
    const result = await shell.run(['bash', '-c', "jq -c 'if . == 3 then input else . end' n4.json"], {
      cwd: '/dsh/workspace',
    })
    assert.equal(result.exitCode, 0, result.stderr)
    assert.equal(result.stdout, '1\n2\n4\n')
    const manifest = buildCapabilityManifest({
      commands: ['jq', 'jq-wasi', 'python3'],
      python: { available: false },
      jq: { available: true, program: 'jq-wasi', engine: 'jaq-core 3.1.2 + jaq-std 3.0.4 + jaq-json 2.0.3' },
    })
    assert.equal(manifest.json.jq?.available, true)
    assert.deepEqual(manifest.json.jq?.input_family, ['input', 'inputs', 'input_line_number'])
    assert.match(manifest.markdown, /jq: real `jaq-core/u)
    const absent = buildCapabilityManifest({ commands: ['jq'], python: { available: false } })
    assert.equal(absent.json.jq, undefined)
    assert.doesNotMatch(absent.markdown, /jq: real/u)
  } finally {
    setWorkerToolbox(undefined)
    await setup.close()
    rmSync(root, { recursive: true, force: true })
  }
})

test('jq wasi: infinite stdout is stopped by the stream cap and the engine is reusable', {
  skip: artifact.skipReason,
  timeout: 30_000,
}, async () => {
  const setup = await engine()
  try {
    const kept: Uint8Array[] = []
    const stderr: Uint8Array[] = []
    const result = await setup.toolbox.run({
      program: 'jq-wasi',
      argv: ['-n', '-c', 'while(true; .+1)'],
      cwd: '/dsh/workspace',
      env: {},
      maxStdoutBytes: 1024,
      maxStderrBytes: 1024,
      onStdout: chunk => { kept.push(Uint8Array.from(chunk)) },
      onStderr: chunk => { stderr.push(Uint8Array.from(chunk)) },
    })
    assert.equal(result.failureCode, 'E_OUTPUT_LIMIT')
    assert.equal(result.stdoutTruncated, true)
    assert.ok(result.stdoutBytes > 1024, `the produced counter must exceed the cap, got ${result.stdoutBytes}`)
    assert.equal(result.stderrBytes, 0, 'the host cap diagnostic is not a guest stderr byte')
    const keptBytes = kept.reduce((sum, chunk) => sum + chunk.byteLength, 0)
    assert.equal(keptBytes, 1024, 'the host keeps exactly the capped prefix, not the whole infinite stream')
    assert.match(new TextDecoder().decode(stderr[0]), /exceeded the 1024-byte stream cap[\s\S]*E_OUTPUT_LIMIT/u)

    // The stopped worker was dropped, not left wedged in an infinite loop.
    const next = await setup.toolbox.run({
      program: 'jq-wasi', argv: ['-n', '-c', '1+1'], cwd: '/dsh/workspace', env: {},
    })
    assert.equal(next.exitCode, 0)
  } finally {
    await setup.close()
  }
})

test('jq wasi: an oversized stderr is stopped by its own cap with E_OUTPUT_LIMIT', {
  skip: artifact.skipReason,
  timeout: 30_000,
}, async () => {
  const setup = await engine()
  try {
    const result = await setup.toolbox.run({
      program: 'jq-wasi',
      argv: ['-n', '-c', '"x" * 2000 | error(.)'],
      cwd: '/dsh/workspace',
      env: {},
      maxStdoutBytes: 1024,
      maxStderrBytes: 1024,
    })
    assert.equal(result.failureCode, 'E_OUTPUT_LIMIT')
    assert.equal(result.stderrTruncated, true)
    assert.ok(result.stderrBytes > 1024, `produced stderr must exceed the cap, got ${result.stderrBytes}`)
    assert.equal(result.stdoutBytes, 0, 'the host cap diagnostic is not a guest stdout byte')
    const next = await setup.toolbox.run({
      program: 'jq-wasi', argv: ['-n', '-c', '3+3'], cwd: '/dsh/workspace', env: {},
    })
    assert.equal(next.exitCode, 0)
  } finally {
    await setup.close()
  }
})

test('jq wasi: AbortSignal terminates a WASM CPU loop after it starts and the next run succeeds', {
  skip: artifact.skipReason,
  timeout: 30_000,
}, async () => {
  const setup = await engine()
  try {
    // A fixed cold-start delay cannot prove cancellation: on a slow harness the
    // abort lands before the exec is posted, so the pre-dispatch cancellation
    // path returns `cancelled` without ever entering the WASM loop. Wait for a
    // marker the running filter itself writes, then abort the executing
    // dispatch. The watchdog only turns a missing marker into a clear failure;
    // a passing run never depends on a wall-clock guess.
    const marker = 'wasm-loop-started'
    const controller = new AbortController()
    let printed = ''
    let markerSeen = false
    const started = Date.now()
    const watchdog = setTimeout(() => {
      controller.abort(new Error('the engine did not write its start marker within 20 s'))
    }, 20_000)
    const running = setup.toolbox.run({
      program: 'jq-wasi',
      argv: ['-n', '-c', `"${marker}", (while(true; .+1) | empty)`],
      cwd: '/dsh/workspace',
      env: {},
      signal: controller.signal,
      onStdout: chunk => {
        printed += new TextDecoder().decode(chunk)
        if (!markerSeen && printed.includes(marker)) {
          markerSeen = true
          controller.abort(new Error('test cancel after the engine started'))
        }
      },
    })
    try {
      const result = await running
      const elapsed = Date.now() - started
      assert.equal(markerSeen, true, 'the running filter wrote its start marker before the abort')
      assert.match(printed, /wasm-loop-started/u)
      assert.equal(result.cancelled, true)
      // The executing-dispatch stop path carries E_JOB_CANCEL; the old
      // pre-dispatch cancellation result had no failureCode and zero bytes.
      assert.equal(result.failureCode, 'E_JOB_CANCEL', 'the abort stopped an executing dispatch, not the pre-exec path')
      assert.ok(result.stdoutBytes > 0, `the stopped dispatch ran the engine and counted its marker, got ${result.stdoutBytes} bytes`)
      assert.ok(elapsed < 10_000, `the abort settled in ${elapsed} ms`)
    } finally {
      clearTimeout(watchdog)
    }
    const next = await setup.toolbox.run({
      program: 'jq-wasi', argv: ['-n', '-c', '2+2'], cwd: '/dsh/workspace', env: {},
    })
    assert.equal(next.exitCode, 0)
  } finally {
    await setup.close()
  }
})

test('jq wasi: a shell-limited infinite generator reports the cap, not a truncated pass', {
  skip: artifact.skipReason,
  timeout: 30_000,
}, async () => {
  const setup = await engine()
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-cap-'))
  try {
    mkdirSync(join(root, '/dsh/workspace'), { recursive: true })
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox: setup.toolbox }),
    })
    const result = await shell.run(['bash', '-c', "jq -n -c 'while(true; .+1)'"], {
      cwd: '/dsh/workspace',
      maxOutputBytes: 1024,
      timeoutMs: 10_000,
    })
    assert.equal(result.exitCode, 1, result.stderr)
    assert.match(result.stderr, /E_OUTPUT_LIMIT|output truncated/u)
    assert.ok(result.stdout.length < 20_000, `bounded display output, got ${result.stdout.length} chars`)
    const next = await shell.run(['bash', '-c', "jq -n -c '1+1'"], { cwd: '/dsh/workspace' })
    assert.equal(next.exitCode, 0, next.stderr)
    assert.equal(next.stdout, '2\n')
  } finally {
    await setup.close()
    rmSync(root, { recursive: true, force: true })
  }
})

test('jq wasi: direct jq-wasi/jaq shell commands use the same output ceiling', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  const setup = await engine()
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-direct-cap-'))
  try {
    mkdirSync(join(root, '/dsh/workspace'), { recursive: true })
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox: setup.toolbox }),
    })
    for (const name of ['jq-wasi', 'jaq']) {
      const result = await shell.run(['bash', '-c', `${name} -n -c 'while(true; .+1)'`], {
        cwd: '/dsh/workspace',
        maxOutputBytes: 1024,
        timeoutMs: 10_000,
      })
      assert.equal(result.exitCode, 1, `${name}: ${result.stderr}`)
      assert.match(result.stderr, /E_OUTPUT_LIMIT/u, name)
      assert.ok(result.stdout.length < 20_000, `${name}: bounded display output, got ${result.stdout.length} chars`)
      const next = await shell.run(['bash', '-c', `${name} -n -c '1+1'`], { cwd: '/dsh/workspace' })
      assert.equal(next.exitCode, 0, `${name} after cap: ${next.stderr}`)
      assert.equal(next.stdout, '2\n', name)
    }
  } finally {
    await setup.close()
    rmSync(root, { recursive: true, force: true })
  }
})

test('jq wasi: an explicit toolbox or toolbox:false never dispatches through the global slot', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  // The defect: a Worker shell assembled around another VFS with
  // `toolbox:false` (or its own fork toolbox) still ran jq through whichever
  // toolbox happened to be globally published.
  const setup = await engine({ 'data.json': '{"value":"FORK"}\n' })
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-isolation-'))
  try {
    mkdirSync(join(root, '/dsh/workspace'), { recursive: true })
    writeFileSync(join(root, '/dsh/workspace/data.json'), '{"value":"FORK"}\n')
    let globalDispatches = 0
    const live: string[] = []
    const globalFake = {
      list: () => [{ program: 'jq-wasi', aliases: ['jaq'] }],
      has: (program: string) => program === 'jq-wasi',
      preopenTable: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
      run: async (request: { onStdout?: (chunk: Uint8Array) => void; onStderr?: (chunk: Uint8Array) => void }) => {
        globalDispatches += 1
        const chunk = new TextEncoder().encode('LIVE\n')
        live.push('LIVE')
        request.onStdout?.(chunk)
        return {
          program: 'jq-wasi', exitCode: 0, cancelled: false, memoryExceeded: false,
          memoryPeakBytes: 0, stdoutBytes: chunk.byteLength, stderrBytes: 0,
        }
      },
    }
    setWorkerToolbox(globalFake as never)

    const shellFor = (toolbox: typeof setup.toolbox | false | undefined): WorkerShell => new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox }),
    })

    // Explicit `false` means this table has no WASI engine. The built-in
    // reading the fork VFS must answer FORK, never the global LIVE.
    const disabled = await shellFor(false).run(['bash', '-c', 'jq .value data.json'], { cwd: '/dsh/workspace' })
    assert.equal(disabled.exitCode, 0, disabled.stderr)
    assert.equal(disabled.stdout, '"FORK"\n')
    assert.equal(globalDispatches, 0, 'toolbox:false must not reach the global toolbox')
    assert.deepEqual(live, [], 'the global fake produced no output')

    // A concrete fork toolbox is the only engine this table may use.
    const own = await shellFor(setup.toolbox).run(['bash', '-c', 'jq .value data.json'], { cwd: '/dsh/workspace' })
    assert.equal(own.exitCode, 0, own.stderr)
    assert.equal(own.stdout, '"FORK"\n')
    assert.equal(globalDispatches, 0, 'an explicit toolbox must not fall back to the global slot')
    assert.deepEqual(live, [], 'the global fake saw no dispatch and no write side effect')

    // The normal no-argument path still resolves the current global toolbox.
    const defaulted = await shellFor(undefined).run(['bash', '-c', 'jq .value data.json'], { cwd: '/dsh/workspace' })
    assert.equal(defaulted.stdout, 'LIVE\n')
    assert.equal(globalDispatches, 1)
  } finally {
    setWorkerToolbox(undefined)
    await setup.close()
    rmSync(root, { recursive: true, force: true })
  }
})

test('jq wasi: the boot installer reads the image artifact and registers the program', { skip: artifact.skipReason, timeout: 60_000 }, async () => {
  if (artifact.artifact === undefined) return
  const files = new Map<string, Uint8Array>([
    [JQ_WASM_IMAGE_PATH, readFileSync(artifact.artifact.wasm)],
    [JQ_ENGINE_IMAGE_PATH, readFileSync(artifact.artifact.engine)],
  ])
  const vfs = {
    files,
    readFileSync(path: string): Uint8Array {
      const bytes = files.get(path)
      if (bytes === undefined) throw Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT' })
      return bytes
    },
    subscribe: () => () => {},
    flush: async () => {},
  } as unknown as WorkerEntryVfs
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/tmp')
  let spawned = 0
  const wiring = await installJqToolbox({
    vfs,
    backend,
    log: () => {},
    spawnWorker: (): ToolWorkerTransport => {
      spawned += 1
      return workerTransport(
        new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
      )
    },
  })
  try {
    assert.ok(wiring !== undefined)
    assert.equal(wiring.toolbox.has('jq-wasi'), true)
    assert.match(wiring.probe?.engine ?? '', /jaq-core/u)
    const out: Uint8Array[] = []
    const result = await wiring.toolbox.run({
      program: 'jq-wasi',
      argv: ['-n', '-c', '1+1'],
      cwd: '/dsh/workspace',
      env: {},
      onStdout: chunk => { out.push(Uint8Array.from(chunk)) },
    })
    assert.equal(result.exitCode, 0)
    assert.equal(new TextDecoder().decode(out[0]), '2\n')
    assert.equal(spawned, 1, 'the first run must start the generic tool worker')
  } finally {
    await wiring?.toolbox.dispose()
  }
})

test('jq wasi: boot refuses wasm/report mismatches and a report without source binding', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  if (artifact.artifact === undefined) return
  const vfsFor = (wasm: Uint8Array, engine: Uint8Array): WorkerEntryVfs => {
    const files = new Map<string, Uint8Array>([
      [JQ_WASM_IMAGE_PATH, wasm],
      [JQ_ENGINE_IMAGE_PATH, engine],
    ])
    return {
      files,
      readFileSync(path: string): Uint8Array {
        const bytes = files.get(path)
        if (bytes === undefined) throw Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT' })
        return bytes
      },
      subscribe: () => () => {},
      flush: async () => {},
    } as unknown as WorkerEntryVfs
  }
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedDirectory('/dsh/home')
  backend.seedDirectory('/dsh/tmp')
  const wasm = Uint8Array.from(readFileSync(artifact.artifact.wasm))
  const engineBytes = readFileSync(artifact.artifact.engine)
  assert.ok(wasm.byteLength > 0)
  wasm[wasm.byteLength - 1] = wasm[wasm.byteLength - 1]! ^ 0xff
  await assert.rejects(
    installJqToolbox({ vfs: vfsFor(wasm, engineBytes), backend, log: () => {} }),
    /sha256/u,
    'a changed wasm must not be advertised against the old hash',
  )

  const report = JSON.parse(new TextDecoder().decode(engineBytes)) as Record<string, unknown>
  delete report['source']
  await assert.rejects(
    installJqToolbox({
      vfs: vfsFor(readFileSync(artifact.artifact.wasm), new TextEncoder().encode(JSON.stringify(report))),
      backend,
      log: () => {},
    }),
    /source fingerprint/u,
    'an artifact without a source binding must not boot',
  )
})

test('jq build: --check rejects a changed source fingerprint and a swapped engine report', {
  skip: artifact.skipReason,
}, () => {
  if (artifact.artifact === undefined) return
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-jq-stale-'))
  const buildScript = fileURLToPath(new URL('../wasi-toolbox/jq/build.sh', import.meta.url))
  try {
    for (const name of ['jq.wasm', 'engine.json', 'sizes.json']) {
      copyFileSync(join(artifact.artifact.directory, name), join(directory, name))
    }
    const sizesPath = join(directory, 'sizes.json')
    const enginePath = join(directory, 'engine.json')
    const originalSizes = JSON.parse(readFileSync(sizesPath, 'utf8')) as {
      source: { fingerprint: string }
      [key: string]: unknown
    }
    const originalEngine = readFileSync(enginePath, 'utf8')

    // Source changed after the artifact was built: the old bytes must not be
    // relabelled with the new source hash; --check refuses and asks to rebuild.
    const staleSizes = { ...originalSizes, source: { ...originalSizes.source, fingerprint: '0'.repeat(64) } }
    writeFileSync(sizesPath, JSON.stringify(staleSizes))
    const stale = spawnSync('bash', [buildScript, '--out', directory, '--check'], { encoding: 'utf8' })
    assert.notEqual(stale.status, 0, 'a source mismatch must not verify')
    assert.match(`${stale.stdout}${stale.stderr}`, /source fingerprint/u)

    // Reports swapped between builds: engine.json names other wasm bytes.
    writeFileSync(sizesPath, JSON.stringify(originalSizes))
    const swapped = JSON.parse(originalEngine) as { wasm: { sha256: string } }
    swapped.wasm.sha256 = '1'.repeat(64)
    writeFileSync(enginePath, JSON.stringify(swapped))
    const swappedRun = spawnSync('bash', [buildScript, '--out', directory, '--check'], { encoding: 'utf8' })
    assert.notEqual(swappedRun.status, 0, 'a swapped engine report must not verify')
    assert.match(`${swappedRun.stdout}${swappedRun.stderr}`, /engine\.json does not describe/u)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('jq wasi: an image without the artifact stays on the shim and advertises nothing', async () => {
  const vfs = {
    readFileSync(): Uint8Array { throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' }) },
    subscribe: () => () => {},
    flush: async () => {},
  } as unknown as WorkerEntryVfs
  const logs: string[] = []
  const wiring = await installJqToolbox({ vfs, backend: new MemoryVfsBackend(), log: message => logs.push(message) })
  assert.equal(wiring, undefined)
  assert.match(logs.join('\n'), /jq stays on the fail-loud shim/u)
})
