#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Capability probe for the built jq WASI executable.
 *
 * A file named `jq.wasm` is not evidence that the Worker has a jq. This probe
 * instantiates the artifact through Node's WASI preview1 host and executes the
 * input-family paths the Worker depends on, so a stale or broken artifact
 * fails at build/pack time instead of at the first model command.
 *
 * Usage: node verify.mjs --wasm <jq.wasm> [--report <file>]
 */
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WASI } from 'node:wasi'

const args = process.argv.slice(2)
function value(name, fallback) {
  const index = args.indexOf(name)
  return index === -1 ? fallback : args[index + 1]
}
const wasmPath = value('--wasm')
if (wasmPath === undefined) {
  console.error('verify-jq: --wasm <jq.wasm> is required')
  process.exit(2)
}
const sourceFingerprint = value('--source-fingerprint', '')
const toolchain = value('--toolchain', '')
const reportPath = value('--report')
if (reportPath !== undefined && !/^[0-9a-f]{64}$/u.test(sourceFingerprint)) {
  console.error('verify-jq: --report needs --source-fingerprint <sha256> (the artifact must be source-bound)')
  process.exit(2)
}

const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-verify-'))
const workspace = join(root, 'workspace')
mkdirSync(workspace, { recursive: true })
writeFileSync(join(workspace, 'n4.json'), '1\n2\n3\n4\n')
writeFileSync(join(workspace, 'n3.json'), '1\n2\n3\n')

/** Run one guest invocation and capture stdout/stderr/exit. */
async function run(guestArgs, stdin = '') {
  const wasi = new WASI({
    version: 'preview1',
    args: ['jq', ...guestArgs],
    env: {},
    preopens: { '/dsh/workspace': workspace },
    returnOnExit: true,
  })
  const module = await WebAssembly.compile(readFileSync(wasmPath))
  const instance = await WebAssembly.instantiate(module, wasi.getImportObject())
  const code = wasi.start(instance)
  return code
}

const checks = [
  { args: ['-n', '-c', '1, 2'], exit: 0 },
  { args: ['-c', 'if . == 3 then input else . end', '/dsh/workspace/n4.json'], exit: 0 },
  { args: ['-n', '-c', '[inputs]', '/dsh/workspace/n3.json'], exit: 0 },
  { args: ['-c', 'reduce inputs as $x (0; .+$x)', '/dsh/workspace/n4.json'], exit: 0 },
  { args: ['-n', '-c', '$__loc__.line'], exit: 0 },
]
let failed = 0
for (const check of checks) {
  try {
    const code = await run(check.args)
    if (code !== check.exit) {
      console.error(`verify-jq: ${JSON.stringify(check.args)} exited ${code}, expected ${check.exit}`)
      failed += 1
    }
  } catch (error) {
    console.error(`verify-jq: ${JSON.stringify(check.args)} trapped: ${error instanceof Error ? error.message : String(error)}`)
    failed += 1
  }
}
rmSync(root, { recursive: true, force: true })
if (failed !== 0) process.exit(1)
const bytes = readFileSync(wasmPath)
const report = {
  format: 2,
  engine: 'jaq-core 3.1.2 + jaq-std 3.0.4 + jaq-json 2.0.3',
  source: { algorithm: 'pdsh-jq-source-v1', fingerprint: sourceFingerprint },
  toolchain,
  wasm: { bytes: bytes.byteLength, sha256: (await import('node:crypto')).createHash('sha256').update(bytes).digest('hex') },
  probes: checks.map(check => check.args.join(' ')),
}
if (reportPath !== undefined) writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`)
console.log(`verify-jq: ${checks.length}/${checks.length} probes passed (${bytes.byteLength} bytes)`)
