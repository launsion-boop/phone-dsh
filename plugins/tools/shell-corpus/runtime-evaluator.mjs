// SPDX-License-Identifier: MIT
/**
 * Child-process evaluator for the `runtime-js` corpus runner.
 *
 * It imports the pinned DSH runtime's shell interpreter and `MemoryVfs`
 * straight from the checkout, gives every command a fresh scratch filesystem
 * seeded with a small demo workspace, and answers NDJSON jobs on stdin:
 *
 *   stdin:  {"id": 1, "cmd": "ls -la"}
 *   stdout: {"id": 1, "exitCode": 0, "stdout": "...", "stderr": ""}
 *
 * The parent supplies the checkout path with `--checkout`; this file never
 * contains a machine-specific path.
 *
 * @module tools/shell-corpus/runtime-evaluator
 */

import { createInterface } from 'node:readline'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

/** Maximum bytes of one stream returned to the parent. */
const MAX_STREAM_BYTES = 65_536

/** Directory fixture created before every command. */
const DIRECTORIES = [
  '/dsh/workspace/src',
  '/dsh/workspace/docs',
  '/dsh/workspace/data',
  '/dsh/workspace/scripts',
  '/dsh/workspace/empty',
  '/dsh/home',
  '/dsh/tmp',
]

/** File fixture created before every command. */
const FILES = new Map([
  ['/dsh/workspace/README.md', '# Demo workspace\n\nA tiny project used by the shell corpus.\n\nSee docs/guide.md for usage.\n'],
  ['/dsh/workspace/package.json', '{\n  "name": "demo",\n  "version": "1.0.0",\n  "scripts": {\n    "build": "tsc",\n    "test": "node --test"\n  }\n}\n'],
  ['/dsh/workspace/docs/guide.md', '# Guide\n\nRun the tests with npm test, then read the output.\n'],
  ['/dsh/workspace/src/index.ts', "import { answer } from './util.ts'\n\nexport function add(left: number, right: number): number {\n  return left + right + answer\n}\n"],
  ['/dsh/workspace/src/util.ts', 'export const answer = 42\n'],
  ['/dsh/workspace/scripts/build.sh', '#!/bin/sh\necho build\n'],
  ['/dsh/workspace/data/numbers.txt', '3\n1\n2\n'],
  ['/dsh/workspace/data/words.txt', 'apple\nbanana\napple\n'],
  ['/dsh/workspace/data/people.csv', 'name,role\nalice,dev\nbob,ops\n'],
  ['/dsh/workspace/.gitignore', 'node_modules/\ndist/\n'],
  ['/dsh/home/notes.txt', 'Remember the milk\n'],
])

/**
 * Parse the evaluator command line.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {string} the checkout directory.
 */
function parseArguments(argv) {
  let checkout
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--checkout') {
      checkout = argv[index + 1]
      index += 1
    }
  }
  if (checkout === undefined || checkout === '') {
    throw new Error('usage: runtime-evaluator.mjs --checkout DIR')
  }
  return resolve(checkout)
}

/**
 * Import the two runtime modules this evaluator drives.
 *
 * @param {string} checkout - checkout root.
 * @returns {Promise<{runShellCommand: Function, MemoryVfs: Function, setActiveVfs: Function}>} runtime API.
 */
async function loadRuntime(checkout) {
  const source = pathToFileURL(resolve(checkout, 'packages', 'experimental', 'webworker-runtime', 'src'))
  let interpreter
  let memory
  let active
  try {
    interpreter = await import(`${source.href}/shell/interpret.ts`)
    memory = await import(`${source.href}/storage/memory.ts`)
    active = await import(`${source.href}/storage/active.ts`)
  } catch (error) {
    throw new Error(
      `cannot import the DSH runtime shell from ${checkout}: ${error instanceof Error ? error.message : String(error)}`,
    )
  }
  if (typeof interpreter.runShellCommand !== 'function'
    || typeof memory.MemoryVfs !== 'function'
    || typeof active.setActiveVfs !== 'function') {
    throw new Error(`the DSH runtime at ${checkout} does not export runShellCommand, MemoryVfs and setActiveVfs`)
  }
  return {
    runShellCommand: interpreter.runShellCommand,
    MemoryVfs: memory.MemoryVfs,
    setActiveVfs: active.setActiveVfs,
  }
}

/**
 * Build a fresh scratch VFS with the demo workspace.
 *
 * @param {Function} MemoryVfs - runtime VFS class.
 * @returns {object} the new VFS.
 */
function createScratchVfs(MemoryVfs) {
  const vfs = new MemoryVfs()
  for (const directory of DIRECTORIES) vfs.mkdirSync(directory, { recursive: true })
  for (const [path, text] of FILES) vfs.writeFileSync(path, text)
  return vfs
}

/** Cap one returned stream so a runaway command cannot fill the report. */
function cap(text) {
  return text.length > MAX_STREAM_BYTES ? text.slice(0, MAX_STREAM_BYTES) : text
}

/**
 * Run one job against a fresh scratch VFS.
 *
 * @param {{id: number, cmd: string, cwd?: string}} job - one command.
 * @param {Awaited<ReturnType<typeof loadRuntime>>} runtime - runtime API.
 * @returns {Promise<object>} one result line.
 */
async function runJob(job, runtime) {
  const cwd = typeof job.cwd === 'string' && job.cwd !== '' ? job.cwd : '/dsh/workspace'
  const vfs = createScratchVfs(runtime.MemoryVfs)
  runtime.setActiveVfs(vfs)
  try {
    const outcome = await runtime.runShellCommand(job.cmd, {
      cwd,
      env: {
        HOME: '/dsh/home',
        PATH: '/usr/bin:/bin',
        PWD: cwd,
        LANG: 'C.UTF-8',
        LC_ALL: 'C.UTF-8',
        TERM: 'dumb',
        NO_COLOR: '1',
      },
    })
    return {
      id: job.id,
      exitCode: Number.isFinite(outcome.exitCode) ? outcome.exitCode : 1,
      stdout: cap(typeof outcome.stdout === 'string' ? outcome.stdout : ''),
      stderr: cap(typeof outcome.stderr === 'string' ? outcome.stderr : ''),
    }
  } catch (error) {
    return { id: job.id, error: error instanceof Error ? error.message : String(error) }
  }
}

/** CLI entry point. */
async function main() {
  const checkout = parseArguments(process.argv.slice(2))
  const runtime = await loadRuntime(checkout)
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity })
  for await (const line of lines) {
    const text = line.trim()
    if (text === '') continue
    let job
    try {
      job = JSON.parse(text)
    } catch {
      continue
    }
    if (job === null || typeof job !== 'object' || typeof job.cmd !== 'string') continue
    const result = await runJob({ id: job.id, cmd: job.cmd, cwd: job.cwd }, runtime)
    process.stdout.write(`${JSON.stringify(result)}\n`)
  }
}

main().catch((error) => {
  process.stderr.write(`runtime-evaluator: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`)
  process.exitCode = 2
})
