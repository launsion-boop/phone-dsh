// SPDX-License-Identifier: MIT
/**
 * Golden-vector gate for the Worker shell command surface.
 *
 * Coverage (`coverage.mjs`) answers "did the runner exit 0?". That is not the
 * same question as "did the command print what GNU/POSIX prints?" — a
 * built-in that echoes a literal `%y`, fabricates a path, or silently omits a
 * command also exits 0. The G2-A01/G2-A05 defects were exactly this class, so
 * the W5 tooling needs a second gate that compares **stdout bytes and exit
 * status** against a committed expectation.
 *
 * A vector is one JSON object per line. Two spellings are accepted and
 * normalised to the same shape: the compact contract form
 *
 * ```json
 * {"name":"paths/realpath-normalizes","category":"files",
 *  "cmd":"realpath notes/../t.txt","fixture":{"t.txt":"x\n"},
 *  "expect":{"stdout":"/dsh/workspace/t.txt\n","stderrPrefix":"","exit":0}}
 * ```
 *
 * and the original field form (`script`, `files`, top-level `stdout`,
 * `stderrIncludes`, `exitCode`). Optional fields: `stdin`, `directories`,
 * `stderr` (exact), `stderrIncludes`/`expect.stderrPrefix`, `env`,
 * `filesAfter` (relative path -> exact content), `cwd` (default
 * `/dsh/workspace`), `host` (deterministic `/v1/http` host for curl vectors),
 * `stdoutMatches` (a second regex assertion on stdout) and
 * `expectedDeviation` (a recorded upstream gap; audited by `contract.mjs`).
 * Every vector runs in a fresh temporary VFS through the real `WorkerShell`
 * and the production `createWorkerCommands` table, so a gap in the command
 * table fails here instead of inside a scenario.
 *
 * Usage:
 *   node tools/shell-corpus/golden.mjs [--golden FILE] [--quiet]
 *   node --test tools/shell-corpus          # runs golden.test.mjs
 *
 * Exit status: 0 when every vector passes, 1 when one differs, 2 on a bad
 * vector file.
 * @module tools/shell-corpus/golden
 */

import { mkdirSync, mkdtempSync, readFileSync, rmSync, stat, writeFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { VfsFileSystem } from '../../shell-ext/src/filesystem.ts'
import { WorkerShell } from '../../shell-ext/src/shell.ts'
import { createWorkerCommands } from '../../shell-ext/src/commands.ts'

/** Committed vector file, resolved next to this module. */
export const DEFAULT_GOLDEN = fileURLToPath(new URL('./golden/worker-shell.jsonl', import.meta.url))

/** Default working directory of every vector. */
export const GOLDEN_CWD = '/dsh/workspace'

/** Fields a vector may carry (both the compact and the original spelling). */
const VECTOR_KEYS = new Set([
  'name', 'category', 'script', 'cmd', 'files', 'fixture', 'directories', 'cwd', 'env',
  'stdin', 'stdout', 'stderr', 'stderrIncludes', 'exitCode', 'filesAfter', 'filesAbsent', 'stdoutMatches',
  'expect', 'host', 'expectedDeviation',
])

/** Fields `expect` may carry. */
const EXPECT_KEYS = new Set(['stdout', 'stderr', 'stderrPrefix', 'exit', 'exitCode'])

/** Fields `host` may carry. */
const HOST_KEYS = new Set(['curl', 'gzip'])

/** Deterministic `/v1/http` host shapes a curl vector can request. */
const CURL_HOST_MODES = new Set(['ok', 'deny', 'unreachable', 'status'])

/** Fields `expectedDeviation` may carry. */
const DEVIATION_KEYS = new Set(['upstreamGap', 'note'])

/** A malformed golden file. */
export class GoldenFormatError extends Error {
  /** 1-based line number of the offending record. */
  line

  /**
   * @param line - 1-based line number.
   * @param message - what is wrong.
   */
  constructor(line, message) {
    super(`golden vector line ${String(line)}: ${message}`)
    this.name = 'GoldenFormatError'
    this.line = line
  }
}

/** Validate a plain string map (`files`, `fixture`, `filesAfter`). */
function stringMap(value, line, field) {
  if (value === undefined) return undefined
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new GoldenFormatError(line, `'${field}' must be an object`)
  }
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry !== 'string') throw new GoldenFormatError(line, `'${field}.${key}' must be a string`)
  }
  return value
}

/**
 * Normalise one parsed record to the canonical vector shape.
 *
 * The compact contract form (`cmd`/`fixture`/`expect`) and the original
 * field form (`script`/`files`/`stdout`/`exitCode`) describe the same vector;
 * mixing the two spellings for one field is rejected so a typo cannot silently
 * win over the other side.
 *
 * @param {object} record - parsed JSON object.
 * @param {number} line - 1-based line number.
 * @returns {object} canonical vector.
 * @throws GoldenFormatError for an unknown field or a missing/mistyped one.
 */
export function normalizeVector(record, line) {
  for (const key of Object.keys(record)) {
    if (!VECTOR_KEYS.has(key)) throw new GoldenFormatError(line, `unknown field '${key}'`)
  }
  if (typeof record.name !== 'string' || record.name === '') throw new GoldenFormatError(line, "missing 'name'")
  const script = record.cmd ?? record.script
  if (typeof script !== 'string' || script === '') throw new GoldenFormatError(line, "missing 'cmd'/'script'")
  if (record.cmd !== undefined && record.script !== undefined) {
    throw new GoldenFormatError(line, "use either 'cmd' or 'script', not both")
  }
  if (record.fixture !== undefined && record.files !== undefined) {
    throw new GoldenFormatError(line, "use either 'fixture' or 'files', not both")
  }
  const files = stringMap(record.fixture ?? record.files, line, record.fixture === undefined ? 'files' : 'fixture')
  const expect = record.expect
  if (expect !== undefined && (expect === null || typeof expect !== 'object' || Array.isArray(expect))) {
    throw new GoldenFormatError(line, "'expect' must be an object")
  }
  for (const key of Object.keys(expect ?? {})) {
    if (!EXPECT_KEYS.has(key)) throw new GoldenFormatError(line, `unknown expect field '${key}'`)
  }
  for (const [inner, outer] of [['stdout', 'stdout'], ['exit', 'exitCode'], ['exitCode', 'exitCode'], ['stderrPrefix', 'stderrIncludes'], ['stderr', 'stderr']]) {
    if (expect?.[inner] !== undefined && record[outer] !== undefined) {
      throw new GoldenFormatError(line, `use either 'expect.${inner}' or '${outer}', not both`)
    }
  }
  const stdout = expect?.stdout ?? record.stdout
  if (stdout !== undefined && typeof stdout !== 'string') throw new GoldenFormatError(line, "'stdout' must be a string")
  if (stdout === undefined && record.stdoutMatches === undefined) {
    throw new GoldenFormatError(line, "missing exact 'stdout' (or a 'stdoutMatches' pattern)")
  }
  const exitCode = expect?.exit ?? expect?.exitCode ?? record.exitCode
  if (!Number.isInteger(exitCode)) throw new GoldenFormatError(line, "missing integer 'exit'/'exitCode'")
  const stderrIncludes = expect?.stderrPrefix ?? record.stderrIncludes
  if (stderrIncludes !== undefined && typeof stderrIncludes !== 'string') {
    throw new GoldenFormatError(line, "'stderrPrefix' must be a string")
  }
  const stderr = expect?.stderr ?? record.stderr
  if (stderr !== undefined && typeof stderr !== 'string') throw new GoldenFormatError(line, "'stderr' must be a string")
  if (record.stdin !== undefined && typeof record.stdin !== 'string') throw new GoldenFormatError(line, "'stdin' must be a string")
  if (record.directories !== undefined && !Array.isArray(record.directories)) {
    throw new GoldenFormatError(line, "'directories' must be an array")
  }
  if (record.cwd !== undefined && (typeof record.cwd !== 'string' || !record.cwd.startsWith('/'))) {
    throw new GoldenFormatError(line, "'cwd' must be absolute")
  }
  if (record.stdoutMatches !== undefined) {
    try {
      void new RegExp(record.stdoutMatches, 'u')
    } catch (error) {
      throw new GoldenFormatError(line, `invalid 'stdoutMatches' (${error instanceof Error ? error.message : String(error)})`)
    }
  }
  const filesAfter = stringMap(record.filesAfter, line, 'filesAfter')
  if (record.filesAbsent !== undefined) {
    if (!Array.isArray(record.filesAbsent) || record.filesAbsent.some(entry => typeof entry !== 'string')) {
      throw new GoldenFormatError(line, "'filesAbsent' must be an array of strings")
    }
  }
  const host = record.host
  if (host !== undefined) {
    if (host === null || typeof host !== 'object' || Array.isArray(host)) throw new GoldenFormatError(line, "'host' must be an object")
    for (const key of Object.keys(host)) {
      if (!HOST_KEYS.has(key)) throw new GoldenFormatError(line, `unknown host field '${key}'`)
    }
    const curl = host.curl
    if (curl !== undefined) {
      if (typeof curl !== 'string' || !CURL_HOST_MODES.has(curl)) {
        throw new GoldenFormatError(line, `host.curl must be one of ${[...CURL_HOST_MODES].join('/')}`)
      }
    }
    if (host.gzip !== undefined && host.gzip !== 'unavailable') {
      throw new GoldenFormatError(line, "host.gzip must be 'unavailable' when present")
    }
  }
  const expectedDeviation = record.expectedDeviation
  if (expectedDeviation !== undefined) {
    if (expectedDeviation === null || typeof expectedDeviation !== 'object' || Array.isArray(expectedDeviation)) {
      throw new GoldenFormatError(line, "'expectedDeviation' must be an object")
    }
    for (const key of Object.keys(expectedDeviation)) {
      if (!DEVIATION_KEYS.has(key)) throw new GoldenFormatError(line, `unknown expectedDeviation field '${key}'`)
    }
    if (typeof expectedDeviation.upstreamGap !== 'string' || expectedDeviation.upstreamGap === '') {
      throw new GoldenFormatError(line, "'expectedDeviation.upstreamGap' must be a non-empty string")
    }
  }
  return {
    name: record.name,
    category: record.category ?? 'uncategorized',
    script,
    ...files === undefined ? {} : { files },
    ...record.stdin === undefined ? {} : { stdin: record.stdin },
    ...record.directories === undefined ? {} : { directories: record.directories },
    ...record.cwd === undefined ? {} : { cwd: record.cwd },
    ...record.env === undefined ? {} : { env: record.env },
    ...stdout === undefined ? {} : { stdout },
    ...stderr === undefined ? {} : { stderr },
    ...stderrIncludes === undefined ? {} : { stderrIncludes },
    exitCode,
    ...filesAfter === undefined ? {} : { filesAfter },
    ...record.filesAbsent === undefined ? {} : { filesAbsent: record.filesAbsent },
    ...record.stdoutMatches === undefined ? {} : { stdoutMatches: record.stdoutMatches },
    ...host === undefined ? {} : { host },
    ...expectedDeviation === undefined ? {} : { expectedDeviation },
  }
}

/**
 * Parse and validate a golden JSONL document.
 *
 * @param {string} text - file contents.
 * @returns {object[]} validated vectors.
 * @throws GoldenFormatError for a blank, malformed or incomplete record.
 */
export function parseGolden(text) {
  const vectors = []
  const seen = new Set()
  const lines = text.split(/\r?\n/)
  for (const [index, raw] of lines.entries()) {
    if (raw.trim() === '') continue
    let record
    try {
      record = JSON.parse(raw)
    } catch (error) {
      throw new GoldenFormatError(index + 1, `not JSON (${error instanceof Error ? error.message : String(error)})`)
    }
    if (record === null || typeof record !== 'object' || Array.isArray(record)) {
      throw new GoldenFormatError(index + 1, 'a vector must be a JSON object')
    }
    const vector = normalizeVector(record, index + 1)
    if (seen.has(vector.name)) throw new GoldenFormatError(index + 1, `duplicate vector name '${vector.name}'`)
    seen.add(vector.name)
    vectors.push(vector)
  }
  if (vectors.length === 0) throw new GoldenFormatError(1, 'the file has no vectors')
  return vectors
}

/** Create the absolute directory of one workspace-relative file. */
function ensureParent(root, relative) {
  mkdirSync(dirname(join(root, GOLDEN_CWD, relative)), { recursive: true })
}

/**
 * Build the deterministic `/v1/http` host a curl vector asks for.
 *
 * The host is a `fetch` double, never a socket: `deny` answers the 403 the
 * real loopback route uses for an origin outside its allow-list, `unreachable`
 * throws the transport error a dead route produces, `status` answers one fixed
 * status for `--fail` vectors, and `ok` is a 200 with a known body.
 * @param {string} mode - one of `ok`, `deny`, `unreachable`, `status`.
 * @returns {typeof fetch} the double.
 */
export function goldenHostFetch(mode) {
  return async (input, init) => {
    const headers = new Headers(init?.headers)
    const target = headers.get('x-pdsh-target-url') ?? String(input)
    const method = (headers.get('x-pdsh-target-method') ?? 'GET').toUpperCase()
    if (mode === 'unreachable') throw new TypeError('fetch failed: connect ECONNREFUSED 127.0.0.1:9')
    if (mode === 'deny') return new Response('forbidden by host allow-list\n', { status: 403 })
    if (mode === 'status') return new Response('missing\n', { status: 404, statusText: 'Not Found' })
    if (method === 'POST') return new Response('posted to the /v1/http route\n', { status: 200 })
    void target
    return new Response('hello from /v1/http\n', { status: 200, headers: { 'content-type': 'text/plain' } })
  }
}

/**
 * Build one Worker shell over a fresh temporary VFS seeded with the vector.
 *
 * The production command table is used with the network/toolbox-dependent
 * programs disabled by default, so the gate is hermetic: an accelerator, a
 * real `curl` upstream or the WASI toolbox is not needed to answer a POSIX
 * command. A vector that carries a `host.curl` mode installs the matching
 * deterministic fetch double, so the shim's failure semantics are exercised
 * without a socket.
 *
 * @param {object} vector - a validated vector.
 * @returns {{shell: WorkerShell, root: string}} the shell and its temp root.
 */
export function createGoldenShell(vector) {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-golden-'))
  for (const directory of ['/dsh/workspace', '/dsh/home', '/dsh/tmp', ...vector.directories ?? []]) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  for (const [relative, content] of Object.entries(vector.files ?? {})) {
    ensureParent(root, relative)
    writeFileSync(join(root, GOLDEN_CWD, relative), content)
  }
  const curlMode = vector.host?.curl
  const curl = curlMode === undefined
    ? false
    : {
        fetch: goldenHostFetch(curlMode),
        origin: 'http://127.0.0.1:9',
        token: 'golden-token',
      }
  const gzip = vector.host?.gzip === 'unavailable'
    ? { zlib: null, compressionStream: null, decompressionStream: null }
    : undefined
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root, workerPaths: true }),
    commands: createWorkerCommands({ git: false, toolbox: false, curl, ...gzip === undefined ? {} : { gzip } }),
  })
  return { shell, root }
}

/**
 * Run one vector and compare its observable result.
 *
 * @param {object} vector - a validated vector.
 * @returns {Promise<object>} `{name, pass, expected, actual, filesAfter}`.
 */
export async function runGoldenVector(vector) {
  const { shell, root } = createGoldenShell(vector)
  try {
    const result = await shell.run(['bash', '-c', vector.script], {
      cwd: vector.cwd ?? GOLDEN_CWD,
      env: vector.env ?? {},
      stdin: vector.stdin ?? '',
      timeoutMs: 30_000,
    })
    const problems = []
    if (vector.stdout !== undefined && result.stdout !== vector.stdout) {
      problems.push({ field: 'stdout', expected: vector.stdout, actual: result.stdout })
    }
    if (result.exitCode !== vector.exitCode) {
      problems.push({ field: 'exitCode', expected: vector.exitCode, actual: result.exitCode })
    }
    if (vector.stderr !== undefined && result.stderr !== vector.stderr) {
      problems.push({ field: 'stderr', expected: vector.stderr, actual: result.stderr })
    }
    if (vector.stderrIncludes !== undefined && !result.stderr.includes(vector.stderrIncludes)) {
      problems.push({ field: 'stderr', expected: `contains ${vector.stderrIncludes}`, actual: result.stderr })
    }
    if (vector.stdoutMatches !== undefined) {
      const pattern = new RegExp(vector.stdoutMatches, 'u')
      if (!pattern.test(result.stdout)) {
        problems.push({ field: 'stdoutMatches', expected: vector.stdoutMatches, actual: result.stdout })
      }
    }
    const filesAfter = []
    for (const relative of vector.filesAbsent ?? []) {
      let present = true
      try {
        await stat(join(root, GOLDEN_CWD, relative))
      } catch {
        present = false
      }
      if (present) problems.push({ field: `filesAbsent:${relative}`, expected: 'absent', actual: 'present' })
    }
    for (const [relative, expected] of Object.entries(vector.filesAfter ?? {})) {
      let actual
      try {
        actual = await readFile(join(root, GOLDEN_CWD, relative), 'utf8')
      } catch (error) {
        actual = `<missing: ${error instanceof Error ? error.message : String(error)}>`
      }
      filesAfter.push({ relative, expected, actual, pass: actual === expected })
      if (actual !== expected) problems.push({ field: `filesAfter:${relative}`, expected, actual })
    }
    return {
      name: vector.name,
      category: vector.category ?? 'uncategorized',
      pass: problems.length === 0,
      problems,
      expected: { stdout: vector.stdout, exitCode: vector.exitCode },
      actual: { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode },
      filesAfter,
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

/**
 * Run every vector.
 *
 * @param {object[]} vectors - output of {@link parseGolden}.
 * @returns {Promise<{total: number, passed: number, failed: number, results: object[]}>} summary.
 */
export async function runGoldenVectors(vectors) {
  const results = []
  for (const vector of vectors) results.push(await runGoldenVector(vector))
  const passed = results.filter(result => result.pass).length
  return { total: results.length, passed, failed: results.length - passed, results }
}

/** Print one concise result line. */
function describe(result) {
  const details = result.problems
    .map(problem => `${problem.field}: expected ${JSON.stringify(problem.expected)}, got ${JSON.stringify(problem.actual)}`)
    .join('; ')
  return `${result.pass ? 'ok  ' : 'FAIL'} ${result.name}${result.pass ? '' : ` — ${details}`}`
}

/**
 * CLI entry point.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {Promise<number>} process exit status.
 */
export async function main(argv) {
  let file = DEFAULT_GOLDEN
  let quiet = false
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      process.stdout.write('usage: node tools/shell-corpus/golden.mjs [--golden FILE] [--quiet]\n')
      return 0
    }
    if (argument === '--quiet') {
      quiet = true
      continue
    }
    if (argument === '--golden') {
      const value = argv[index + 1]
      if (value === undefined) {
        process.stderr.write('golden: --golden needs a file\n')
        return 2
      }
      file = value
      index += 1
      continue
    }
    process.stderr.write(`golden: unknown argument '${argument}'\n`)
    return 2
  }
  let vectors
  try {
    const path = isAbsolute(file) ? file : resolve(file)
    vectors = parseGolden(readFileSync(path, 'utf8'))
  } catch (error) {
    process.stderr.write(`golden: ${error instanceof Error ? error.message : String(error)}\n`)
    return 2
  }
  const summary = await runGoldenVectors(vectors)
  if (!quiet) {
    for (const result of summary.results) process.stdout.write(`${describe(result)}\n`)
  }
  process.stdout.write(`golden: ${String(summary.passed)}/${String(summary.total)} vectors passed\n`)
  return summary.failed === 0 ? 0 : 1
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href

if (invokedDirectly) {
  main(process.argv.slice(2)).then((status) => {
    process.exitCode = status
  }).catch((error) => {
    process.stderr.write(`golden: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`)
    process.exitCode = 2
  })
}
