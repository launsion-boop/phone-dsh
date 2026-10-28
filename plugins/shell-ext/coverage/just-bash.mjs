// SPDX-License-Identifier: MIT
/**
 * `just-bash` runner for `tools/shell-corpus/coverage.mjs`.
 *
 * Every corpus command gets the same fresh demo workspace as the `runtime-js`
 * evaluator has (a command may create or remove files, but never depends on a
 * previous command). The shell is the real `plugins/shell-ext` Worker
 * shell over `VfsFileSystem` rooted at a temporary directory.
 *
 * Programs the corpus names but the Worker does not implement are registered as
 * the explicit coverage stubs of `shell-ext/src/corpus.ts`; each one says on
 * stderr that it did not run. This is the same measurement the brush spike made
 * in `PDSH_BRUSH_MODE=stub`: shell-language and command-table coverage, not a
 * claim that `npm install` or `git clone` works in the Worker. `README.md`
 * records the gap list.
 * @module @phone-dsh/dsh-shell-ext/coverage/just-bash
 */

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { getCommandNames } from 'just-bash/browser'
import {
  VfsFileSystem,
  createCorpusStub,
  createCurlCommand,
  createWhichCommand,
  runShellCommand,
} from '../src/index.ts'

/** Directory fixture created before every command (matches runtime-evaluator.mjs). */
const DIRECTORIES = [
  '/dsh/workspace/src',
  '/dsh/workspace/docs',
  '/dsh/workspace/data',
  '/dsh/workspace/scripts',
  '/dsh/workspace/empty',
  '/dsh/home',
  '/dsh/tmp',
]

/** File fixture created before every command (matches runtime-evaluator.mjs). */
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

/** Environment the runtime evaluator uses, plus the shell defence variables. */
const ENVIRONMENT = {
  HOME: '/dsh/home',
  PATH: '/usr/bin:/bin',
  PWD: '/dsh/workspace',
  LANG: 'C.UTF-8',
  LC_ALL: 'C.UTF-8',
  TERM: 'dumb',
  NO_COLOR: '1',
  PDSH_VFS_ROOT: '',
}

/** Command names just-bash implements inside its built-in table. */
const JUST_BASH_COMMANDS = new Set(getCommandNames())

/** Shell syntax words that are not commands. */
const SHELL_KEYWORDS = new Set([
  'if', 'then', 'elif', 'else', 'fi', 'for', 'in', 'do', 'done', 'while', 'until',
  'case', 'esac', 'function', 'select', 'time', '!', '{', '}', '(', ')', '[[', ']]',
])

/** Builtins the interpreter handles itself even though `getCommandNames()` omits them. */
const SHELL_BUILTINS = new Set([
  'cd', 'export', 'unset', 'set', 'shift', 'test', '[', 'source', '.', 'eval', 'exec',
  'command', 'builtin', 'declare', 'local', 'readonly', 'return', 'break', 'continue',
  'trap', 'wait', 'jobs', 'getopts', 'read', 'mapfile', 'pushd', 'popd', 'dirs',
  'shopt', 'umask', 'type', 'hash', 'help', 'kill', 'history', 'alias', 'unalias',
])

/**
 * Programs just-bash's browser bundle cannot instantiate, even though the
 * registry names them (python/JS/tar/yq/sqlite are Node-only chunks).
 */
const FORCED_STUBS = new Set(['python3', 'python', 'node', 'js-exec', 'tar', 'yq', 'sqlite3'])

/**
 * Seed one fresh demo workspace under `root`.
 * @param {string} root - temporary real directory mapped to virtual `/`.
 */
export function seedWorkspace(root) {
  for (const directory of DIRECTORIES) mkdirSync(join(root, directory), { recursive: true })
  for (const [path, content] of FILES) writeFileSync(join(root, path), content)
}

/**
 * Extract the command words of one shell line.
 *
 * This is a recogniser for the corpus's conventional commands, not a shell
 * parser: it tracks quoting and heredoc bodies so text inside `"..."` or a
 * here-doc is not mistaken for a program. Command substitutions are skipped;
 * the corpus uses them only around known builtins.
 * @param {string} command - the command line.
 * @returns {string[]} program names in command position.
 */
export function commandPrograms(command) {
  const programs = []
  let heredoc = undefined
  const lines = command.split('\n')
  for (const rawLine of lines) {
    if (heredoc !== undefined) {
      if (rawLine.replace(/^\t+/, '').trim() === heredoc) heredoc = undefined
      continue
    }
    const match = /<<-?\s*(['"]?)([A-Za-z_][\w.-]*)\1/.exec(rawLine)
    if (match !== null) {
      heredoc = match[2]
      // Only the part before the operator is a command line.
      const before = rawLine.slice(0, match.index)
      for (const name of linePrograms(before)) programs.push(name)
      continue
    }
    for (const name of linePrograms(rawLine)) programs.push(name)
  }
  return programs
}

/**
 * Split one physical line on shell separators and read each command's first word.
 * @param {string} line - one line without a heredoc body.
 * @returns {string[]} program names.
 */
function linePrograms(line) {
  const programs = []
  // Blank quoted text first so `echo "a;b"` is one command.
  let masked = ''
  let quote
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index]
    if (quote !== undefined) {
      if (character === quote) quote = undefined
      masked += ' '
      continue
    }
    if (character === "'" || character === '"') {
      quote = character
      masked += ' '
      continue
    }
    masked += character
  }
  for (const segment of masked.split(/&&|\|\||[;|&\n]/)) {
    let text = segment.trim()
    if (text === '') continue
    for (;;) {
      const stripped = text.replace(/^(?:\(+|\{+|!+)\s*/, '')
      if (stripped === text) break
      text = stripped
    }
    // A function definition is not a command invocation.
    if (/^[A-Za-z_]\w*\s*\(\s*\)/.test(text)) continue
    // Leading variable assignments (`FOO=bar cmd`, or a bare `FOO=bar`).
    for (;;) {
      const assignment = /^[A-Za-z_]\w*=(?:[^\s]*)(?:\s+|$)/.exec(text)
      if (assignment === null) break
      text = text.slice(assignment[0].length)
    }
    if (text === '') continue
    const word = /^([A-Za-z0-9_./+:@-]+)/.exec(text)?.[1]
    if (word === undefined) continue
    if (SHELL_KEYWORDS.has(word)) continue
    programs.push(word)
  }
  return programs
}

/** Fake `/v1/http` upstream: every URL answers 200 with a short deterministic body. */
async function offlineFetch(_input, init) {
  const target = new Headers(init?.headers).get('X-PDSH-Target-URL') ?? 'http://127.0.0.1/'
  const url = new URL(target)
  const head = new Headers(init?.headers).get('X-PDSH-Target-Method') === 'HEAD'
  return new Response(head ? null : `pdsh-corpus: ${url.hostname}${url.pathname}\n`, {
    status: 200,
    headers: { 'content-type': 'text/plain', 'x-corpus': 'offline' },
  })
}

/** The runner object the coverage tool consumes. */
export class JustBashRunner {
  /** @param {{timeoutMs?: number, maxOutputBytes?: number}} [options] */
  constructor(options = {}) {
    this.name = 'just-bash'
    this.timeoutMs = options.timeoutMs ?? 10_000
    this.maxOutputBytes = options.maxOutputBytes ?? 65_536
    // `host` registers the explicit corpus stubs (the W5 coverage gate);
    // `real` measures only what the Worker would actually run.
    this.mode = options.env?.PDSH_SHELL_CORPUS_MODE ?? process.env.PDSH_SHELL_CORPUS_MODE ?? 'host'
    this.temporary = []
  }

  /** No shared process: every command constructs one shell instance. */
  async start() {}

  /**
   * Run one corpus command in a fresh workspace.
   * @param {string} command - shell command line.
   * @returns {Promise<{exitCode: number, stdout: string, stderr: string, missingProgram?: string}>} outcome.
   */
  async run(command) {
    const root = mkdtempSync(join(tmpdir(), 'pdsh-just-bash-'))
    this.temporary.push(root)
    try {
      seedWorkspace(root)
      const detected = new Set(commandPrograms(command))
      const stubs = []
      if (this.mode !== 'real') {
        for (const program of detected) {
          if (program === 'curl' || program === 'which') continue
          if (FORCED_STUBS.has(program) || (!JUST_BASH_COMMANDS.has(program) && !SHELL_BUILTINS.has(program))) {
            stubs.push(program)
          }
        }
      }
      const commands = [
        createCurlCommand({ fetch: offlineFetch, origin: 'http://127.0.0.1:1', token: 'corpus-runner' }),
        ...stubs.map(program => createCorpusStub(program)),
      ]
      commands.push(createWhichCommand([...JUST_BASH_COMMANDS, ...SHELL_BUILTINS, ...stubs, 'curl', 'which']))
      const result = await runShellCommand(
        ['bash', '-c', command],
        {
          cwd: '/dsh/workspace',
          env: ENVIRONMENT,
          timeoutMs: this.timeoutMs,
          maxOutputBytes: this.maxOutputBytes,
        },
        { fs: new VfsFileSystem({ root }), commands },
      )
      return {
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
        ...result.missingProgram === undefined ? {} : { missingProgram: result.missingProgram },
      }
    } catch (error) {
      return { error: error instanceof Error ? error.message : String(error) }
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }

  /** Remove any directory a failed cleanup left behind. */
  async close() {
    for (const root of this.temporary.splice(0)) rmSync(root, { recursive: true, force: true })
  }
}

/**
 * Factory used by `coverage.mjs` (`createRunner` or default export).
 * @param {{env?: NodeJS.ProcessEnv}} [options] - runner options from the tool.
 * @returns {JustBashRunner} the runner.
 */
export function createRunner(options = {}) {
  return new JustBashRunner({ env: options.env })
}

export default createRunner
