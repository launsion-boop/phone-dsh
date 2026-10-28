// SPDX-License-Identifier: MIT
/**
 * Measure the wasm brush module: size, instantiation and per-command latency.
 *
 * Usage:
 *
 *   node crates/pdsh-brush-wasm/harness/measure.mjs [--wasm FILE] [--runs N] [--json OUT]
 *
 * The numbers printed here are the ones quoted in `REPORT.md`; the script is
 * deterministic apart from timing noise.
 *
 * @module pdsh-brush-wasm/harness/measure
 */

import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { brotliCompressSync, constants as zlibConstants } from 'node:zlib'

import { createCommandTable } from './commands.mjs'
import { resetFixture } from './fixture.mjs'
import { loadBrush, resolveWasmPath } from './wasm.mjs'

/**
 * Parse the command line.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {{wasmPath: string, runs: number, json: string | undefined}} options.
 */
function parseArguments(argv) {
  const options = { wasmPath: resolveWasmPath(), runs: 200, json: undefined }
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--wasm') { options.wasmPath = argv[index + 1]; index += 1 }
    else if (argv[index] === '--runs') { options.runs = Number(argv[index + 1]); index += 1 }
    else if (argv[index] === '--json') { options.json = argv[index + 1]; index += 1 }
    else throw new Error(`unknown argument '${argv[index]}'`)
  }
  return options
}

/**
 * Time an async operation in milliseconds.
 *
 * @param {Function} operation - async operation.
 * @returns {Promise<number>} elapsed milliseconds.
 */
async function elapsed(operation) {
  const start = process.hrtime.bigint()
  await operation()
  return Number(process.hrtime.bigint() - start) / 1e6
}

/**
 * Percentile of a sorted numeric array.
 *
 * @param {number[]} sorted - ascending values.
 * @param {number} fraction - 0..1.
 * @returns {number} value.
 */
function percentile(sorted, fraction) {
  if (sorted.length === 0) return 0
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(fraction * sorted.length) - 1))
  return sorted[index]
}

const options = parseArguments(process.argv.slice(2))
const bytes = readFileSync(options.wasmPath)
const rawBytes = statSync(options.wasmPath).size
const brotliBytes = brotliCompressSync(bytes, {
  params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 11 },
}).length

const root = mkdtempSync(join(tmpdir(), 'pdsh-brush-measure-'))
resetFixture(root)
const table = createCommandTable({ root, mode: 'demo' })

// Compile measurements recompile the same bytes so the cost includes parsing.
const compileTimes = []
for (let index = 0; index < 5; index += 1) {
  compileTimes.push(await elapsed(() => WebAssembly.compile(bytes)))
}
const module = await WebAssembly.compile(bytes)

const instantiateTimes = []
let last
for (let index = 0; index < 20; index += 1) {
  let loaded
  instantiateTimes.push(await elapsed(async () => { loaded = await loadBrush({ root, commands: table, module }) }))
  last = loaded
}
const brush = last ?? await loadBrush({ root, commands: table, module })

// A fresh instance, first command.
const fresh = await loadBrush({ root, commands: table, module })
const firstRun = await elapsed(() => { fresh.run('echo hi') })
const initialMemory = fresh.exports.memory.buffer.byteLength

const warm = []
for (let index = 0; index < options.runs; index += 1) {
  warm.push(await elapsed(() => { fresh.run('echo hi') }))
}
warm.sort((left, right) => left - right)
const finalMemory = fresh.exports.memory.buffer.byteLength

const imports = [...new Set(brush.imports.map((entry) => entry.module))].sort()
const wasiImports = brush.imports.filter((entry) => entry.module === 'wasi_snapshot_preview1').length
const hostImports = brush.imports.filter((entry) => entry.module === 'xl').length

const summary = {
  wasm: options.wasmPath,
  rawBytes,
  brotliBytes,
  brotliRatio: Number((brotliBytes / rawBytes).toFixed(3)),
  compileMsAverage: Number((compileTimes.reduce((sum, value) => sum + value, 0) / compileTimes.length).toFixed(2)),
  instantiateMsAverage: Number((instantiateTimes.reduce((sum, value) => sum + value, 0) / instantiateTimes.length).toFixed(2)),
  firstRunMs: Number(firstRun.toFixed(2)),
  warmRuns: options.runs,
  warmMsP50: Number(percentile(warm, 0.5).toFixed(2)),
  warmMsP95: Number(percentile(warm, 0.95).toFixed(2)),
  memoryInitialBytes: initialMemory,
  memoryAfterRunsBytes: finalMemory,
  importModules: imports,
  wasiImports,
  hostImports,
  version: brush.version(),
}

console.log(JSON.stringify(summary, null, 2))
if (options.json !== undefined) {
  const { writeFileSync } = await import('node:fs')
  writeFileSync(options.json, `${JSON.stringify(summary, null, 2)}\n`)
}
rmSync(root, { recursive: true, force: true })
