#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Prove that a produced CPython wasm32-wasi interpreter has its compression
 * standard library before it is published.
 *
 * The script runs `python.wasm` under Node's WASI host with the stdlib zip
 * mounted read-only at `/usr/local/lib/python313.zip` and a writable `/tmp`,
 * executes the probe programs from `compression-probe.ts`, and checks three
 * things independently:
 *
 *   1. `import zlib, bz2, lzma` succeeds and the modules roundtrip their data;
 *   2. `tarfile.open(name, "w:gz")` writes a real gzip stream and reads the
 *      member back with the same bytes;
 *   3. the archive the guest wrote is a valid gzip stream on the host too
 *      (checked with Node's own `zlib`), so the VFS bytes are inspected
 *      outside the interpreter that produced them.
 *
 * `build.sh` runs this against every artifact it produces and refuses to write
 * `sizes.json` for a runtime that fails any check. `build.sh --check` runs it
 * against an existing artifact, so a stale pre-fix build fails loudly instead
 * of being packed into an image.
 *
 * Usage:
 *   node verify-compression.mjs --wasm FILE --stdlib FILE [--report FILE]
 *
 * Exit codes: 0 = every capability present, 1 = probe failed, 2 = usage error.
 * @module @phone-dsh/dsh-wasi-toolbox/python/verify-compression
 */
import {
  closeSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, openSync,
  readFileSync, rmSync, writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import process from 'node:process'
import { gunzipSync } from 'node:zlib'
import { WASI } from 'node:wasi'
import {
  COMPRESSION_PROBE_ARCHIVE,
  COMPRESSION_PROBE_MODULES,
  COMPRESSION_PROBE_PAYLOAD_BYTES,
  COMPRESSION_PROBE_PROGRAM,
  compressionProbeProblems,
  parseCompressionReport,
  parseTarfileReport,
} from './compression-probe.ts'

const USAGE = 'usage: node verify-compression.mjs --wasm FILE --stdlib FILE [--report FILE]'

function usageError(message) {
  process.stderr.write(`compression probe: ${message}\n${USAGE}\n`)
  process.exit(2)
}

function parseArgs(argv) {
  const options = { wasm: undefined, stdlib: undefined, report: undefined }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--wasm' || argument === '--stdlib' || argument === '--report') {
      const value = argv[index + 1]
      if (value === undefined || value === '') usageError(`${argument} needs a file`)
      options[argument.slice(2)] = value
      index += 1
      continue
    }
    if (argument === '--help' || argument === '-h') {
      process.stdout.write(`${USAGE}\n`)
      process.exit(0)
    }
    usageError(`unknown argument: ${argument}`)
  }
  if (options.wasm === undefined) usageError('--wasm is required')
  if (options.stdlib === undefined) usageError('--stdlib is required')
  for (const name of ['wasm', 'stdlib']) {
    const value = options[name]
    if (!existsSync(value)) usageError(`${name} file not found: ${value}`)
  }
  return options
}

function fail(lines) {
  for (const line of lines) process.stderr.write(`compression probe: ${line}\n`)
  const remainder = lines.slice(1).join(' ')
  process.stderr.write(
    `compression probe: FAILED: the runtime does not provide zlib, bz2, lzma and tarfile w:gz (${remainder})\n`,
  )
  process.exit(1)
}

const options = parseArgs(process.argv.slice(2))
const work = mkdtempSync(join(tmpdir(), 'pdsh-python-compression-'))
const libDir = join(work, 'usr', 'local', 'lib')
const tmpDir = join(work, 'tmp')
mkdirSync(libDir, { recursive: true })
mkdirSync(tmpDir, { recursive: true })
// The guest sees exactly the layout runtime.ts mounts: the stdlib zip under
// /usr/local/lib and the volatile tmp root at /tmp.
copyFileSync(options.stdlib, join(libDir, 'python313.zip'))
const stdoutPath = join(work, 'stdout.txt')
const stderrPath = join(work, 'stderr.txt')
const stdinFd = openSync('/dev/null', 'r')
const stdoutFd = openSync(stdoutPath, 'w')
const stderrFd = openSync(stderrPath, 'w')

let exitCode
try {
  const wasi = new WASI({
    version: 'preview1',
    args: ['python3', '-c', COMPRESSION_PROBE_PROGRAM],
    env: {
      PYTHONHOME: '/usr/local',
      PYTHONPATH: '/usr/local/lib/python313.zip',
      PYTHONDONTWRITEBYTECODE: '1',
      PYTHONNOUSERSITE: '1',
    },
    preopens: { '/usr/local/lib': libDir, '/tmp': tmpDir },
    stdin: stdinFd,
    stdout: stdoutFd,
    stderr: stderrFd,
    returnOnExit: true,
  })
  const module = await WebAssembly.compile(readFileSync(options.wasm))
  const instance = await WebAssembly.instantiate(module, wasi.getImportObject())
  exitCode = wasi.start(instance)
} catch (error) {
  closeSync(stdinFd)
  closeSync(stdoutFd)
  closeSync(stderrFd)
  fail([error instanceof Error ? error.message : String(error)])
} finally {
  try { closeSync(stdinFd) } catch { /* already closed */ }
  try { closeSync(stdoutFd) } catch { /* already closed */ }
  try { closeSync(stderrFd) } catch { /* already closed */ }
}

const stdout = readFileSync(stdoutPath, 'utf8')
const stderr = readFileSync(stderrPath, 'utf8')
const problems = compressionProbeProblems(stdout)
if (exitCode !== 0) {
  problems.unshift(`python3 exited ${exitCode}`)
}
if (problems.length > 0) {
  const output = stderr.trim()
  fail([...problems, ...(output === '' ? [] : output.split('\n').slice(-8))])
}

// Host-side verification: the archive the guest wrote must be a real gzip
// stream whose uncompressed tar bytes contain both the member name and the
// exact payload. Node's zlib is unrelated to CPython's built-in zlib, so this
// is an independent check of the bytes the VFS produced.
const archivePath = join(tmpDir, COMPRESSION_PROBE_ARCHIVE.replace(/^\/tmp\//, ''))
let archiveBytes
try {
  archiveBytes = readFileSync(archivePath)
} catch {
  fail([`tarfile w:gz left no archive at the guest path ${COMPRESSION_PROBE_ARCHIVE}`])
}
let tarBytes
try {
  tarBytes = gunzipSync(archiveBytes)
} catch (error) {
  fail([`the guest archive is not a gzip stream: ${error instanceof Error ? error.message : String(error)}`])
}
if (!tarBytes.includes(Buffer.from('probe.txt'))) {
  fail(['the guest archive does not contain the probe.txt member'])
}
if (!tarBytes.includes(Buffer.from(COMPRESSION_PROBE_PAYLOAD_BYTES))) {
  fail(['the guest archive does not contain the probe payload'])
}

const report = parseCompressionReport(stdout)
const tarfile = parseTarfileReport(stdout)
if (report === undefined || tarfile === undefined) {
  fail(['the probe markers disappeared after validation'])
}
const summary = {
  modules: [...COMPRESSION_PROBE_MODULES],
  tarfileGzip: true,
  zlib: report.zlib,
  zlibRuntime: report.zlibRuntime,
  pythonVersion: report.pythonVersion,
  tarfileBytes: tarfile.bytes,
  archiveBytes: archiveBytes.byteLength,
}
if (options.report !== undefined) {
  writeFileSync(options.report, `${JSON.stringify(summary, null, 2)}\n`)
}
process.stdout.write(
  `compression probe: zlib ${report.zlib} (runtime ${report.zlibRuntime}), bz2 ok, lzma ok, `
  + `tarfile w:gz roundtrip ${tarfile.bytes} bytes, host gunzip ${archiveBytes.byteLength} bytes\n`,
)
rmSync(work, { recursive: true, force: true })
