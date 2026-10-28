// SPDX-License-Identifier: MIT
/**
 * Stable native-jq parity gate for the real WASI engine.
 *
 * The 52 commands below were run against Debian's native `jq-1.6` on the same
 * fixtures; the baked `stdout`/exit pairs are that oracle's output, not a
 * snapshot of this engine. The suite executes the built `jq.wasm` through the
 * production `WasiToolbox`, so an artifact is required (a missing artifact is
 * a skip with a reason, never a PASS via the 512-vector fallback golden).
 *
 * Error diagnostics are engine-specific (jaq text differs from jq's); the
 * parity table asserts the exit class and a stable substring, while the exact
 * documented deviations live in docs/p1/cap-primary-jq-engine-safety.md.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { discoverJqArtifact } from '../wasi-toolbox/jq/artifacts.ts'
import { workerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/message-endpoint.ts'
import { WasiToolbox } from '../wasi-toolbox/src/toolbox.ts'
import { MemoryVfsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import { createWorkerCommands } from '../shell-ext/src/commands.ts'
import { VfsFileSystem } from '../shell-ext/src/filesystem.ts'
import { WorkerShell } from '../shell-ext/src/shell.ts'

const artifact = discoverJqArtifact()

interface Case {
  readonly args: readonly string[]
  readonly files: readonly string[]
  readonly stdin: string | undefined
  readonly code: number
  readonly stdout: string
  readonly stderr: RegExp | undefined
}

/** Native jq 1.6 oracle: one `jq` invocation over the fixture files. */
const CASES: readonly Case[] = [
  { args: ["-n", "-c", "1,2"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "1\n2\n", stderr: undefined },
  { args: ["-c", "."], files: ["n4.json"], stdin: undefined, code: 0, stdout: "1\n2\n3\n4\n", stderr: undefined },
  { args: ["-c", "."], files: ["nd.json"], stdin: undefined, code: 0, stdout: "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n", stderr: undefined },
  { args: ["-c", "input_line_number"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "1\n2\n3\n4\n", stderr: undefined },
  { args: ["-c", "input_line_number"], files: ["n2.json"], stdin: undefined, code: 0, stdout: "1\n1\n", stderr: undefined },
  { args: ["-c", "input_line_number"], files: ["multi.json"], stdin: undefined, code: 0, stdout: "3\n6\n", stderr: undefined },
  { args: ["-c", "if . == 3 then input else . end"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "1\n2\n4\n", stderr: undefined },
  { args: ["-c", "select(. > 1) | inputs"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "3\n4\n", stderr: undefined },
  { args: ["-c", "first(inputs)"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "2\n4\n", stderr: undefined },
  { args: ["-c", "last(inputs)"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "4\n", stderr: undefined },
  { args: ["-c", "limit(2; inputs)"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "2\n3\n", stderr: undefined },
  { args: ["-n", "-c", "1, inputs, 2"], files: ["n3.json"], stdin: undefined, code: 0, stdout: "1\n1\n2\n3\n2\n", stderr: undefined },
  { args: ["-c", "reduce inputs as $x (0; .+$x)"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "9\n", stderr: undefined },
  { args: ["-c", "[foreach inputs as $x (0; .+$x; .)]"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "[2,5,9]\n", stderr: undefined },
  { args: ["-c", "label $out | 1, break $out"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "1\n1\n1\n1\n", stderr: undefined },
  { args: ["-c", "def f($x): $x + .; f(10)"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "11\n12\n13\n14\n", stderr: undefined },
  { args: ["-c", "input as $x | $x + ."], files: ["n4.json"], stdin: undefined, code: 0, stdout: "3\n7\n", stderr: undefined },
  { args: ["-n", "-c", "$ARGS", "--args", "a", "b"], files: [], stdin: undefined, code: 0, stdout: "{\"positional\":[\"a\",\"b\"],\"named\":{}}\n", stderr: undefined },
  { args: ["-n", "-c", "$ARGS", "--jsonargs", "1", "\"x\""], files: [], stdin: undefined, code: 0, stdout: "{\"positional\":[1,\"x\"],\"named\":{}}\n", stderr: undefined },
  { args: ["-n", "-c", "$__loc__"], files: [], stdin: undefined, code: 0, stdout: "{\"file\":\"<top-level>\",\"line\":1}\n", stderr: undefined },
  { args: ["-c", "\"\\(.)\""], files: ["n4.json"], stdin: undefined, code: 0, stdout: "\"1\"\n\"2\"\n\"3\"\n\"4\"\n", stderr: undefined },
  { args: ["-c", "tostring"], files: ["n4.json"], stdin: undefined, code: 0, stdout: "\"1\"\n\"2\"\n\"3\"\n\"4\"\n", stderr: undefined },
  { args: ["-c", "type"], files: ["nd.json"], stdin: undefined, code: 0, stdout: "\"object\"\n\"object\"\n\"object\"\n", stderr: undefined },
  { args: ["-c", "keys"], files: ["nd.json"], stdin: undefined, code: 0, stdout: "[\"a\"]\n[\"a\"]\n[\"a\"]\n", stderr: undefined },
  { args: ["-c", "length"], files: ["nd.json"], stdin: undefined, code: 0, stdout: "1\n1\n1\n", stderr: undefined },
  { args: ["-c", ".[]?"], files: ["nd.json"], stdin: undefined, code: 0, stdout: "1\n2\n3\n", stderr: undefined },
  { args: ["-s", "-c", "."], files: ["j1", "j2"], stdin: undefined, code: 0, stdout: "[1,2,3,4]\n", stderr: undefined },
  { args: ["-s", "-c", "add"], files: ["j1", "j2"], stdin: undefined, code: 0, stdout: "10\n", stderr: undefined },
  { args: ["-s", "-c", "input_line_number"], files: ["j1", "j2"], stdin: undefined, code: 0, stdout: "2\n", stderr: undefined },
  { args: ["-s", "-c", "[.[], input_line_number]"], files: ["j1", "j2"], stdin: undefined, code: 0, stdout: "[1,2,3,4,2]\n", stderr: undefined },
  { args: ["-R", "-c", "."], files: ["f1"], stdin: undefined, code: 0, stdout: "\"a\"\n\"b\"\n", stderr: undefined },
  { args: ["-R", "-c", "[., input_line_number]"], files: ["f1"], stdin: undefined, code: 0, stdout: "[\"a\",1]\n[\"b\",2]\n", stderr: undefined },
  { args: ["-R", "-c", "[., input_line_number]"], files: ["f1", "f2"], stdin: undefined, code: 0, stdout: "[\"a\",1]\n[\"b\",2]\n[\"c\",1]\n[\"d\",2]\n", stderr: undefined },
  { args: ["-R", "-c", "[., input_line_number]"], files: ["k1", "k2"], stdin: undefined, code: 0, stdout: "[\"a\",1]\n[\"bc\",1]\n[\"d\",2]\n", stderr: undefined },
  { args: ["-R", "-c", "[., input_line_number]"], files: ["n2.json"], stdin: undefined, code: 0, stdout: "[\"1\",1]\n[\"2\",1]\n", stderr: undefined },
  { args: ["-R", "-s", "-c", "."], files: ["f1", "f2"], stdin: undefined, code: 0, stdout: "\"a\\nb\\nc\\nd\\n\"\n", stderr: undefined },
  { args: ["-R", "-s", "-c", "input_line_number"], files: ["f1", "f2"], stdin: undefined, code: 0, stdout: "2\n", stderr: undefined },
  { args: ["-R", "-s", "-c", "input_line_number"], files: ["k1", "k2"], stdin: undefined, code: 0, stdout: "2\n", stderr: undefined },
  { args: ["-R", "-s", "-c", "split(\"\\n\")"], files: ["f1"], stdin: undefined, code: 0, stdout: "[\"a\",\"b\",\"\"]\n", stderr: undefined },
  { args: ["-R", "-c", "select(length > 0)"], files: [], stdin: "a\n\nb\n", code: 0, stdout: "\"a\"\n\"b\"\n", stderr: undefined },
  { args: ["-c", ".[]"], files: [], stdin: "[1,2,3]", code: 0, stdout: "1\n2\n3\n", stderr: undefined },
  { args: ["-c", "input_line_number"], files: [], stdin: "1\n2\n", code: 0, stdout: "1\n2\n", stderr: undefined },
  { args: ["-c", "inputs"], files: [], stdin: "1\n2\n3\n", code: 0, stdout: "2\n3\n", stderr: undefined },
  { args: ["-R", "-c", "input_line_number"], files: [], stdin: "a\nb", code: 0, stdout: "1\n1\n", stderr: undefined },
  { args: ["-n", "-c", "input"], files: ["empty.json"], stdin: undefined, code: 5, stdout: "", stderr: /break/u },
  { args: ["-c", "input"], files: ["n3.json"], stdin: undefined, code: 5, stdout: "2\n", stderr: /break/u },
  { args: ["-c", "."], files: ["missing.json"], stdin: undefined, code: 2, stdout: "", stderr: /Could not open file/u },
  { args: ["-c", "."], files: ["bad.json"], stdin: undefined, code: 4, stdout: "", stderr: /parse error/u },
  { args: ["-e", "-n", "false"], files: [], stdin: undefined, code: 1, stdout: "false\n", stderr: undefined },
  { args: ["-e", "-n", "empty"], files: [], stdin: undefined, code: 4, stdout: "", stderr: undefined },
  { args: ["-e", "-n", "null"], files: [], stdin: undefined, code: 1, stdout: "null\n", stderr: undefined },
  { args: ["-c", "input_line_number"], files: ["j1", "j2"], stdin: undefined, code: 0, stdout: "1\n2\n1\n2\n", stderr: undefined },
]

const FIXTURES: Readonly<Record<string, string>> = {
  'n4.json': '1\n2\n3\n4\n',
  'n3.json': '1\n2\n3\n',
  'n2.json': '1\n2',
  'nd.json': '{"a":1}\n{"a":2}\n{"a":3}\n',
  'multi.json': '{\n"a":1\n}\n{\n"a":2\n}\n',
  'empty.json': '',
  'bad.json': '{\n',
  'f1': 'a\nb\n',
  'f2': 'c\nd\n',
  'k1': 'a\nb',
  'k2': 'c\nd\n',
  'j1': '1\n2\n',
  'j2': '3\n4\n',
}

test('jq wasi: 52 native jq 1.6 command/expected pairs match the real engine', {
  skip: artifact.skipReason,
  timeout: 120_000,
}, async () => {
  if (artifact.artifact === undefined) return
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  for (const [name, contents] of Object.entries(FIXTURES)) backend.seedFile(`/dsh/workspace/${name}`, contents)
  const wasm = readFileSync(artifact.artifact.wasm)
  const toolbox = new WasiToolbox({
    commands: [{
      program: 'jq-wasi',
      module: { url: `image://${artifact.artifact.wasm}`, load: async () => wasm },
    }],
    backend,
    preopens: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
  })
  try {
    await toolbox.assertFileView()
    let index = 0
    for (const item of CASES) {
      index += 1
      const stdout: Uint8Array[] = []
      const stderr: Uint8Array[] = []
      const result = await toolbox.run({
        program: 'jq-wasi',
        argv: [...item.args, ...item.files],
        cwd: '/dsh/workspace',
        env: {},
        ...item.stdin === undefined ? {} : { stdin: new TextEncoder().encode(item.stdin) },
        onStdout: chunk => { stdout.push(Uint8Array.from(chunk)) },
        onStderr: chunk => { stderr.push(Uint8Array.from(chunk)) },
      })
      const decode = (chunks: readonly Uint8Array[]): string => {
        const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0)
        const joined = new Uint8Array(total)
        let offset = 0
        for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength }
        return new TextDecoder().decode(joined)
      }
      const out = decode(stdout)
      const err = decode(stderr)
      assert.equal(result.exitCode, item.code, `case ${index} ${item.args.join(' ')}: ${err}`)
      assert.equal(out, item.stdout, `case ${index} ${item.args.join(' ')}: stdout`)
      if (item.stderr === undefined) {
        assert.equal(err, '', `case ${index} ${item.args.join(' ')}: unexpected stderr: ${err}`)
      } else {
        assert.match(err, item.stderr, `case ${index} ${item.args.join(' ')}: stderr`)
      }
    }
    assert.equal(CASES.length, 52)
  } finally {
    await toolbox.dispose()
  }
})

test('jq wasi: -R trailing empty operands reset line and source like native jq 1.6', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  if (artifact.artifact === undefined) return
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedFile('/dsh/workspace/k1', 'a\nb')
  backend.seedFile('/dsh/workspace/empty.json', '')
  const wasm = readFileSync(artifact.artifact.wasm)
  const toolbox = new WasiToolbox({
    commands: [{ program: 'jq-wasi', module: { url: 'image://jq.wasm', load: async () => wasm } }],
    backend,
    preopens: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
  })
  const run = async (argv: readonly string[]): Promise<{ code: number; stdout: string; stderr: string }> => {
    const stdout: Uint8Array[] = []
    const stderr: Uint8Array[] = []
    const result = await toolbox.run({
      program: 'jq-wasi',
      argv: [...argv],
      cwd: '/dsh/workspace',
      env: {},
      onStdout: chunk => { stdout.push(Uint8Array.from(chunk)) },
      onStderr: chunk => { stderr.push(Uint8Array.from(chunk)) },
    })
    const decode = (chunks: readonly Uint8Array[]): string =>
      new TextDecoder().decode(Uint8Array.from(chunks.flatMap(chunk => [...chunk])))
    return { code: result.exitCode, stdout: decode(stdout), stderr: decode(stderr) }
  }
  try {
    // Native jq 1.6: `a\nb` + empty reports `["b",0]`, because opening the
    // next operand resets the raw line counter even when it has no bytes.
    const lines = await run(['-R', '-c', '[., input_line_number]', 'k1', 'empty.json'])
    assert.deepEqual(lines, { code: 0, stdout: '["a",1]\n["b",0]\n', stderr: '' })
    const error = await run([
      '-R', '-c', 'if input_line_number == 0 then error("zero") else . end', 'k1', 'empty.json',
    ])
    assert.equal(error.code, 5)
    assert.equal(error.stdout, '"a"\n')
    assert.match(error.stderr, /\(at empty\.json:0\): zero/u)
  } finally {
    await toolbox.dispose()
  }
})

test('jq wasi: raw EOF position matches native jq 1.6', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  if (artifact.artifact === undefined) return
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedFile('/dsh/workspace/raw-tail-space', 'a\n   ')
  backend.seedFile('/dsh/workspace/raw-terminated', 'a\nb\n')
  backend.seedFile('/dsh/workspace/raw-empty', '')
  backend.seedFile('/dsh/workspace/raw-unterminated', 'a\nb')
  backend.seedFile('/dsh/workspace/empty.json', '')
  const wasm = readFileSync(artifact.artifact.wasm)
  const toolbox = new WasiToolbox({
    commands: [{ program: 'jq-wasi', module: { url: 'image://jq.wasm', load: async () => wasm } }],
    backend,
    preopens: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
  })
  const run = async (argv: readonly string[]): Promise<{ code: number; stdout: string; stderr: string }> => {
    const stdout: Uint8Array[] = []
    const stderr: Uint8Array[] = []
    const result = await toolbox.run({
      program: 'jq-wasi',
      argv: [...argv],
      cwd: '/dsh/workspace',
      env: {},
      onStdout: chunk => { stdout.push(Uint8Array.from(chunk)) },
      onStderr: chunk => { stderr.push(Uint8Array.from(chunk)) },
    })
    const decode = (chunks: readonly Uint8Array[]): string =>
      new TextDecoder().decode(Uint8Array.from(chunks.flatMap(chunk => [...chunk])))
    return { code: result.exitCode, stdout: decode(stdout), stderr: decode(stderr) }
  }
  try {
    // Oracle: Debian jq 1.6 `-n -R -c 'inputs, error("boom")' <files>`.
    // Raw whitespace is data, so an unterminated final line (even a spaces
    // line) leaves the reader at `<unknown>`, while a newline-terminated final
    // operand names that file and its line count. A trailing empty operand
    // resets only when the preceding non-empty line was terminated; an
    // unreadable operand keeps its own `file:0` marker and still exits 2.
    const cases = [
      { files: ['raw-tail-space'], code: 5, stdout: '"a"\n"   "\n', at: '<unknown>' },
      { files: ['raw-terminated'], code: 5, stdout: '"a"\n"b"\n', at: 'raw-terminated:2' },
      { files: ['raw-empty'], code: 5, stdout: '', at: 'raw-empty:0' },
      { files: ['raw-unterminated', 'empty.json'], code: 5, stdout: '"a"\n"b"\n', at: '<unknown>' },
      { files: ['raw-terminated', 'empty.json'], code: 5, stdout: '"a"\n"b"\n', at: 'empty.json:0' },
      { files: ['raw-unterminated', 'missing.json'], code: 2, stdout: '"a"\n"b"\n', at: 'missing.json:0' },
    ] as const
    for (const item of cases) {
      const result = await run(['-n', '-R', '-c', 'inputs, error("boom")', ...item.files])
      assert.equal(result.code, item.code, `${item.files.join(' ')}: ${result.stderr}`)
      assert.equal(result.stdout, item.stdout, `${item.files.join(' ')}: stdout`)
      assert.ok(
        result.stderr.includes(`(at ${item.at}): boom`),
        `${item.files.join(' ')}: expected (at ${item.at}), got ${result.stderr}`,
      )
    }
  } finally {
    await toolbox.dispose()
  }
})

test('jq wasi: first(inputs) stays lazy while inputs/-s still open later operands', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  if (artifact.artifact === undefined) return
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  backend.seedFile('/dsh/workspace/raw1', 'a\n')
  backend.seedFile('/dsh/workspace/json2', '{}')
  const wasm = readFileSync(artifact.artifact.wasm)
  const toolbox = new WasiToolbox({
    commands: [{ program: 'jq-wasi', module: { url: 'image://jq.wasm', load: async () => wasm } }],
    backend,
    preopens: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
  })
  const run = async (
    argv: readonly string[],
    stdin?: string,
  ): Promise<{ code: number; stdout: string; stderr: string }> => {
    const stdout: Uint8Array[] = []
    const stderr: Uint8Array[] = []
    const result = await toolbox.run({
      program: 'jq-wasi',
      argv: [...argv],
      cwd: '/dsh/workspace',
      env: {},
      ...stdin === undefined ? {} : { stdin: new TextEncoder().encode(stdin) },
      onStdout: chunk => { stdout.push(Uint8Array.from(chunk)) },
      onStderr: chunk => { stderr.push(Uint8Array.from(chunk)) },
    })
    const decode = (chunks: readonly Uint8Array[]): string =>
      new TextDecoder().decode(Uint8Array.from(chunks.flatMap(chunk => [...chunk])))
    return { code: result.exitCode, stdout: decode(stdout), stderr: decode(stderr) }
  }
  try {
    // Native jq 1.6 and the 1.7.1 Apple build both return the first value and
    // exit 0 without opening the missing second operand. The raw line is
    // newline-terminated inside raw1; `{}` is a self-contained two-byte JSON
    // document that must not trigger a three-byte BOM peek.
    assert.deepEqual(
      await run(['-n', '-R', '-c', 'first(inputs)', 'raw1', 'missing.json']),
      { code: 0, stdout: '"a"\n', stderr: '' },
    )
    assert.deepEqual(
      await run(['-n', '-c', 'first(inputs)', 'json2', 'missing.json']),
      { code: 0, stdout: '{}\n', stderr: '' },
    )
    // `-n -r input` consumes exactly one raw line; repeated stdin operands
    // must not be opened just because they remain on the command line.
    assert.deepEqual(
      await run(['-n', '-R', '-r', 'input', '-', '-'], 'a\nb\n'),
      { code: 0, stdout: 'a\n', stderr: '' },
    )
    assert.deepEqual(
      await run(['-n', '-R', '-r', 'first(inputs)', '-', 'missing.json'], 'a\n'),
      { code: 0, stdout: 'a\n', stderr: '' },
    )

    // Negative controls: filters that really ask for every input, or a real
    // slurp, still open the later operand and must not swallow its error.
    const jsonInputs = await run(['-n', '-c', 'inputs', 'json2', 'missing.json'])
    assert.equal(jsonInputs.code, 2)
    assert.equal(jsonInputs.stdout, '{}\n')
    assert.match(jsonInputs.stderr, /Could not open file missing\.json/u)
    const rawInputs = await run(['-n', '-R', '-c', 'inputs', 'raw1', 'missing.json'])
    assert.equal(rawInputs.code, 2)
    assert.equal(rawInputs.stdout, '"a"\n')
    assert.match(rawInputs.stderr, /Could not open file missing\.json/u)
    const slurped = await run(['-s', '-c', '.', 'json2', 'missing.json'])
    assert.equal(slurped.code, 2)
    assert.equal(slurped.stdout, '[{}]\n')
    assert.match(slurped.stderr, /Could not open file missing\.json/u)
    const rawSlurped = await run(['-R', '-s', '-c', '.', 'raw1', 'missing.json'])
    assert.equal(rawSlurped.code, 2)
    assert.equal(rawSlurped.stdout, '"a\\n"\n')
    assert.match(rawSlurped.stderr, /Could not open file missing\.json/u)
  } finally {
    await toolbox.dispose()
  }
})

test('jq wasi: shell `jq --version` names the real jaq engine, not only jq-1.6', {
  skip: artifact.skipReason,
  timeout: 60_000,
}, async () => {
  if (artifact.artifact === undefined) return
  const backend = new MemoryVfsBackend()
  backend.seedDirectory('/dsh/workspace')
  const wasm = readFileSync(artifact.artifact.wasm)
  const toolbox = new WasiToolbox({
    commands: [{ program: 'jq-wasi', module: { url: 'image://jq.wasm', load: async () => wasm } }],
    backend,
    preopens: [{ guestPath: '/dsh/workspace', hostPath: '/dsh/workspace' }],
    crossOriginIsolated: true,
    spawnWorker: (): ToolWorkerTransport => workerTransport(
      new Worker(new URL('../wasi-toolbox/src/node-worker-harness.ts', import.meta.url)) as unknown as WorkerLike,
    ),
  })
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-version-'))
  try {
    mkdirSync(join(root, '/dsh/workspace'), { recursive: true })
    writeFileSync(join(root, 'unused'), '')
    const out: Uint8Array[] = []
    const direct = await toolbox.run({
      program: 'jq-wasi', argv: ['--version'], cwd: '/dsh/workspace', env: {},
      onStdout: chunk => { out.push(Uint8Array.from(chunk)) },
    })
    assert.equal(direct.exitCode, 0)
    const text = new TextDecoder().decode(Uint8Array.from(out.flatMap(chunk => [...chunk])))
    assert.match(text, /^jq-1\.6 /u)
    assert.match(text, /jaq-core 3\.1\.2/u)
    assert.match(text, /jaq-std 3\.0\.4/u)
    assert.match(text, /pdsh-jaq-wasm/u)

    // The production shell must surface that same identity through
    // `jq --version`; the GNU convention wrapper may not replace it with the
    // generic just-bash banner.
    const shell = new WorkerShell({
      fs: new VfsFileSystem({ root, workerPaths: true }),
      commands: createWorkerCommands({ git: false, curl: false, toolbox }),
    })
    const shellVersion = await shell.run(['bash', '-c', 'jq --version'], { cwd: '/dsh/workspace' })
    assert.equal(shellVersion.exitCode, 0, shellVersion.stderr)
    assert.equal(shellVersion.stdout, text)
    // A legal shell cwd outside every preopen must not turn the probe into the
    // `cannot map the shell cwd` failure; both `/` and `/dsh` must surface the
    // same real engine identity as the direct `jq-wasi --version`.
    const rootVersion = await shell.run(['bash', '-c', 'cd / && jq --version'], { cwd: '/dsh/workspace' })
    assert.equal(rootVersion.exitCode, 0, rootVersion.stderr)
    assert.equal(rootVersion.stdout, text)
    const dshVersion = await shell.run(['bash', '-c', 'jq --version'], { cwd: '/dsh' })
    assert.equal(dshVersion.exitCode, 0, dshVersion.stderr)
    assert.equal(dshVersion.stdout, text)
  } finally {
    await toolbox.dispose()
    rmSync(root, { recursive: true, force: true })
  }
})
