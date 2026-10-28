// SPDX-License-Identifier: MIT
/**
 * Pluggable shell runners for the corpus coverage tool.
 *
 * Every runner has the same shape:
 *
 *   {
 *     name: string,
 *     async run(command: string, context?: object): Promise<{
 *       exitCode: number, stdout: string, stderr: string, error?: unknown,
 *       syntaxConstruct?: string, missingProgram?: string
 *     }>,
 *     async start?(): Promise<void>,
 *     async close?(): Promise<void>
 *   }
 *
 * `runtime-js` is built in: it drives the pinned runtime's own shell
 * interpreter inside a child Node process (the interpreter uses TypeScript
 * syntax that needs `--experimental-transform-types` on current Node) and
 * gives every command a fresh scratch `MemoryVfs`. Additional runners are
 * loaded from a module so W5-SHELL can add `just-bash` without touching this
 * tool. The conventional locations are next to this file:
 *
 *   plugins/shell-ext/coverage/<name>.mjs
 *   plugins/shell-ext/<name>-runner.mjs
 *
 * or an explicit path/specifier through `--runner-module` /
 * `PDSH_SHELL_RUNNER_MODULE`. The module exports `createRunner(options)` (or a
 * default function/object with a `run` method).
 *
 * @module tools/shell-corpus/runners
 */

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, isAbsolute, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { requireRuntimeSources, resolveDshCheckout } from './checkout.mjs'

/** Version of the runner interface documented above. */
export const RUNNER_INTERFACE_VERSION = 1

const TOOL_DIRECTORY = dirname(fileURLToPath(import.meta.url))

/**
 * Runner that drives the pinned DSH webworker-runtime shell in Node.
 *
 * The DSH sources are imported from the checkout at run time; nothing is
 * copied into this repository and no checkout path is stored here.
 */
export class RuntimeJsRunner {
  /** @param {{checkout?: string, evaluatorPath?: string, env?: NodeJS.ProcessEnv}} [options] */
  constructor(options = {}) {
    this.name = 'runtime-js'
    this.options = options
    this.child = undefined
    this.lines = undefined
    this.pending = new Map()
    this.sequence = 0
    this.diagnostics = ''
    this.exitPromise = undefined
    this.exitInfo = undefined
  }

  /** Spawn the evaluator child once. */
  async start() {
    if (this.child !== undefined) return
    const checkout = this.options.checkout || resolveDshCheckout()
    requireRuntimeSources(checkout)
    const evaluator = this.options.evaluatorPath
      ?? fileURLToPath(new URL('./runtime-evaluator.mjs', import.meta.url))
    const flags = ['--no-warnings']
    if (process.allowedNodeEnvironmentFlags.has('--experimental-transform-types')) {
      flags.push('--experimental-transform-types')
    }
    const child = spawn(process.execPath, [...flags, evaluator, '--checkout', checkout], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ...this.options.env },
    })
    this.child = child
    this.diagnostics = ''
    this.exitInfo = undefined
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => {
      this.diagnostics = (this.diagnostics + chunk).slice(-16_384)
    })
    this.lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
    this.lines.on('line', (line) => this.handleLine(line))
    this.exitPromise = new Promise((settle) => {
      const stopped = (reason) => {
        this.exitInfo = reason
        const detail = this.diagnostics.trim()
        const failure = new Error(`runtime-js evaluator stopped (${reason})${detail === '' ? '' : `: ${detail}`}`)
        for (const pending of this.pending.values()) pending.reject(failure)
        this.pending.clear()
        settle()
      }
      child.on('error', (error) => stopped(error.message))
      child.on('exit', (code, signal) => stopped(signal === null ? `exit ${String(code)}` : `signal ${signal}`))
    })
    // A child that dies before its first read must not turn a write error into
    // an unhandled event.
    child.stdin.on('error', () => {})
  }

  /** Route one NDJSON result line to the waiting command. */
  handleLine(line) {
    const text = line.trim()
    if (text === '') return
    let message
    try {
      message = JSON.parse(text)
    } catch {
      this.diagnostics = `${this.diagnostics}${text}\n`.slice(-16_384)
      return
    }
    const pending = this.pending.get(message.id)
    if (pending === undefined) return
    this.pending.delete(message.id)
    if (message.error !== undefined) {
      pending.reject(new Error(String(message.error)))
      return
    }
    pending.resolve({
      exitCode: Number.isFinite(message.exitCode) ? message.exitCode : 1,
      stdout: typeof message.stdout === 'string' ? message.stdout : '',
      stderr: typeof message.stderr === 'string' ? message.stderr : '',
    })
  }

  /**
   * Run one command in the evaluator.
   *
   * @param {string} command - the command line.
   * @returns {Promise<{exitCode: number, stdout: string, stderr: string}>} outcome.
   */
  async run(command) {
    await this.start()
    if (this.exitInfo !== undefined) throw new Error(`runtime-js evaluator is not running (${this.exitInfo})`)
    const id = ++this.sequence
    const promise = new Promise((resolvePromise, rejectPromise) => {
      this.pending.set(id, { resolve: resolvePromise, reject: rejectPromise })
    })
    this.child.stdin.write(`${JSON.stringify({ id, cmd: command })}\n`)
    return await promise
  }

  /** Stop the evaluator child. */
  async close() {
    if (this.child === undefined) return
    const child = this.child
    this.lines?.close()
    child.stdin.end()
    const timeout = new Promise((settle) => setTimeout(settle, 2000).unref())
    await Promise.race([this.exitPromise, timeout])
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
    this.child = undefined
    this.lines = undefined
    this.exitPromise = undefined
    this.exitInfo = undefined
  }
}

/**
 * Import an external runner module.
 *
 * @param {string} name - runner name from `--runner`.
 * @param {{runnerModule?: string, checkout?: string}} options - resolution options.
 * @returns {Promise<object>} the validated runner.
 */
async function loadExternalRunner(name, options) {
  const candidates = []
  if (typeof options.runnerModule === 'string' && options.runnerModule !== '') {
    candidates.push(options.runnerModule)
  }
  if (typeof process.env.PDSH_SHELL_RUNNER_MODULE === 'string' && process.env.PDSH_SHELL_RUNNER_MODULE !== '') {
    candidates.push(process.env.PDSH_SHELL_RUNNER_MODULE)
  }
  candidates.push(resolve(TOOL_DIRECTORY, '..', '..', 'shell-ext', 'coverage', `${name}.mjs`))
  candidates.push(resolve(TOOL_DIRECTORY, '..', '..', 'shell-ext', `${name}-runner.mjs`))

  let lastError
  for (const candidate of candidates) {
    const looksLikePath = candidate.startsWith('.') || isAbsolute(candidate) || candidate.endsWith('.mjs')
    if (looksLikePath && !existsSync(resolve(candidate))) continue
    let module
    try {
      module = await import(looksLikePath ? pathToFileURL(resolve(candidate)).href : candidate)
    } catch (error) {
      lastError = error
      continue
    }
    const factory = module.createRunner ?? module.default
    let runner
    try {
      runner = typeof factory === 'function'
        ? await factory({ checkout: options.checkout, env: process.env })
        : factory
    } catch (error) {
      throw new Error(`runner module for '${name}' failed to start: ${error instanceof Error ? error.message : String(error)}`)
    }
    if (runner === null || typeof runner !== 'object' || typeof runner.run !== 'function') {
      throw new Error(`runner module '${candidate}' does not export createRunner() or a runner with run()`)
    }
    runner.name ??= name
    return runner
  }
  const detail = lastError instanceof Error ? ` (${lastError.message})` : ''
  throw new Error(
    `unknown runner '${name}'${detail}; pass --runner-module or put a runner at one of: ${candidates.join(', ')}`,
  )
}

/**
 * Create a runner by name.
 *
 * @param {string} name - `runtime-js` or an external runner name.
 * @param {{checkout?: string, runnerModule?: string, env?: NodeJS.ProcessEnv}} [options] - runner options.
 * @returns {Promise<{name: string, run: Function, start?: Function, close?: Function}>} the runner.
 */
export async function createRunner(name, options = {}) {
  if (name === 'runtime-js') return new RuntimeJsRunner(options)
  return await loadExternalRunner(name, options)
}

/**
 * Load the corpus JSONL, keeping one record per line.
 *
 * @param {string} text - corpus JSONL text.
 * @returns {{cmd: string, category?: string, origin?: string}[]} parsed commands.
 * @throws {Error} on a malformed or command-less line.
 */
export function parseCorpus(text) {
  const entries = []
  const lines = text.split(/\r?\n/)
  for (const [index, rawLine] of lines.entries()) {
    const line = rawLine.replace(/^\uFEFF/, '').trim()
    if (line === '') continue
    let record
    try {
      record = JSON.parse(line)
    } catch (error) {
      throw new Error(`corpus line ${String(index + 1)} is not JSON: ${error instanceof Error ? error.message : String(error)}`)
    }
    if (record === null || typeof record !== 'object' || typeof record.cmd !== 'string' || record.cmd.trim() === '') {
      throw new Error(`corpus line ${String(index + 1)} has no command string`)
    }
    entries.push({
      cmd: record.cmd,
      category: typeof record.category === 'string' ? record.category : 'uncategorized',
      origin: typeof record.origin === 'string' ? record.origin : undefined,
    })
  }
  return entries
}
