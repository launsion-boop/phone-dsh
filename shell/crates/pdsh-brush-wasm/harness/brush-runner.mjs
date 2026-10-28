// SPDX-License-Identifier: MIT
/**
 * Corpus runner adapter for `tools/shell-corpus/coverage.mjs`.
 *
 * Usage:
 *
 *   node tools/shell-corpus/coverage.mjs \
 *     --runner brush-wasm \
 *     --runner-module shell/crates/pdsh-brush-wasm/harness/brush-runner.mjs \
 *     --out <dir>
 *
 * Environment:
 *
 * - `PDSH_BRUSH_MODE=demo|stub` (default `demo`): `demo` runs the real host
 *   command subset; `stub` advertises every program the corpus names and
 *   succeeds without output, which measures shell-language acceptance.
 * - `PDSH_BRUSH_WASM=<path>`: release wasm to load.
 * - `PDSH_BRUSH_CORPUS=<path>`: corpus used to discover program names in stub
 *   mode (defaults to the committed public corpus).
 *
 * @module pdsh-brush-wasm/harness/brush-runner
 */

import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { collectProgramNames, createCommandTable } from './commands.mjs'
import { resetFixture } from './fixture.mjs'
import { loadBrush } from './wasm.mjs'

/** Default public corpus, resolved from this file. */
export const DEFAULT_CORPUS = fileURLToPath(
  new URL('../../../../plugins/tools/shell-corpus/corpus/public.jsonl', import.meta.url),
)

/**
 * Read a corpus JSONL file and return its command strings.
 *
 * @param {string} path - corpus path.
 * @returns {string[]} command lines.
 */
export function readCorpus(path) {
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter((line) => line.trim() !== '')
    .map((line) => JSON.parse(line))
    .map((entry) => entry.cmd)
    .filter((command) => typeof command === 'string')
}

/**
 * Turn a brush diagnostic into the structured hint the classifier accepts.
 *
 * @param {string} command - the command line.
 * @param {string} stderr - runner diagnostics.
 * @returns {{missingProgram?: string, syntaxConstruct?: string}} hints.
 */
export function classifyFailure(command, stderr) {
  const missing = /command not found: ([\w.+-]+)/.exec(stderr)
    ?? /failed to execute command '([^']+)'/.exec(stderr)
    ?? /no host command table: ([\w.+-]+) is not available/.exec(stderr)
  if (missing !== null) return { missingProgram: missing[1] }
  if (/failed to duplicate open file/.test(stderr) && /[<>]/.test(command)) {
    return { syntaxConstruct: 'redirection' }
  }
  return {}
}

/** A runner that drives the wasm shell for one corpus command at a time. */
export class BrushWasmRunner {
  /**
   * @param {object} [options] - runner options.
   * @param {string} [options.wasmPath] - wasm file.
   * @param {'demo'|'stub'} [options.mode] - host command mode.
   * @param {string} [options.corpusPath] - corpus used for stub-mode names.
   * @param {NodeJS.ProcessEnv} [options.env] - environment overrides.
   */
  constructor(options = {}) {
    this.name = 'brush-wasm'
    this.options = options
    this.mode = options.mode ?? process.env.PDSH_BRUSH_MODE ?? 'demo'
    this.corpusPath = options.corpusPath ?? process.env.PDSH_BRUSH_CORPUS ?? DEFAULT_CORPUS
    this.root = undefined
    this.brush = undefined
  }

  /** Create the fixture, command table and wasm instance once. */
  async start() {
    if (this.brush !== undefined) return
    this.root = mkdtempSync(join(tmpdir(), 'pdsh-brush-corpus-'))
    resetFixture(this.root)
    const extraNames = this.mode === 'stub' ? collectProgramNames(readCorpus(this.corpusPath)) : []
    this.table = createCommandTable({ root: this.root, mode: this.mode, extraNames })
    this.brush = await loadBrush({
      root: this.root,
      commands: this.table,
      wasmPath: this.options.wasmPath ?? process.env.PDSH_BRUSH_WASM,
    })
  }

  /**
   * Run one corpus command from a fresh fixture.
   *
   * @param {string} command - shell command.
   * @returns {Promise<object>} outcome with the classifier hints.
   */
  async run(command) {
    await this.start()
    resetFixture(this.root)
    this.brush.reset()
    const outcome = this.brush.run(command)
    if (outcome.error !== '') throw new Error(outcome.error)
    return {
      exitCode: outcome.exitCode,
      stdout: outcome.stdout,
      stderr: outcome.stderr,
      ...classifyFailure(command, outcome.stderr),
    }
  }

  /** Release the fixture directory. */
  async close() {
    if (this.root !== undefined) rmSync(this.root, { recursive: true, force: true })
    this.root = undefined
    this.brush = undefined
  }
}

/**
 * Factory used by the coverage tool.
 *
 * @param {{checkout?: string, env?: NodeJS.ProcessEnv}} options - tool options.
 * @returns {BrushWasmRunner} runner.
 */
export function createRunner(options = {}) {
  return new BrushWasmRunner({ env: options.env })
}
