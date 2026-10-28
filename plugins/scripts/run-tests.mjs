// SPDX-License-Identifier: MIT
/**
 * Portable `npm test` entry point for the plugins workspace.
 *
 * `node --test` itself is portable; two environment facts are not:
 *
 * - tests create their scratch trees under `os.tmpdir()`, and some runners
 *   expose `/tmp` as a volatile alias (or a path inside the checkout), which
 *   breaks tests that expect a real directory outside the repository;
 * - a few tests wait on promises resolved by production timers that are
 *   deliberately unref'ed, so a test worker can drain its event loop before
 *   the root test settles (`cancelledByParent`).
 *
 * This launcher creates one unique temporary root per run, outside every Git
 * checkout, exports `TMPDIR`/`TMP`/`TEMP` to the test workers, and preloads a
 * test-only keepalive (`scripts/test-preload.mjs`). It passes `--import`
 * instead of `NODE_OPTIONS`, so child processes a test spawns do not inherit
 * the keepalive.
 */
import { spawn } from 'node:child_process'
import {
  accessSync, constants, existsSync, globSync, mkdtempSync, realpathSync, rmSync, statSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptsDirectory = dirname(fileURLToPath(import.meta.url))
const pluginRoot = dirname(scriptsDirectory)
const preload = join(scriptsDirectory, 'test-preload.mjs')

/** Resolve a path when it exists, otherwise return it unchanged. */
function realpathOrSelf(path) {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** Whether `directory` is itself inside (or is) a Git checkout. */
function isInsideGitCheckout(directory) {
  let current = realpathSync(directory)
  for (;;) {
    if (existsSync(join(current, '.git'))) return true
    const parent = dirname(current)
    if (parent === current) return false
    current = parent
  }
}

/** Whether a writable directory exists at `directory`. */
function writableDirectory(directory) {
  try {
    if (!statSync(directory).isDirectory()) return false
    accessSync(directory, constants.W_OK | constants.X_OK)
    return true
  } catch {
    return false
  }
}

/** Keep glob results out of installed third-party test trees. */
export function excludeNodeModulesPaths(paths) {
  return paths.filter(path => !path.split(/[\\/]/u).includes('node_modules'))
}

/**
 * Pick a temporary base outside every Git checkout.
 *
 * An explicit `PDSH_TEST_TMPDIR` wins. On Linux, where the default is `/tmp`,
 * prefer `/var/tmp`: `/tmp` is often a Worker-visible alias that is not the
 * same filesystem the test process sees. The system default and `/var/tmp`
 * remain fallbacks for other platforms.
 * @returns {string} an existing writable directory.
 */
function chooseBase() {
  const candidates = []
  const explicit = process.env.PDSH_TEST_TMPDIR
  if (explicit !== undefined && explicit !== '') candidates.push(explicit)
  const system = tmpdir()
  if (process.platform === 'linux' && realpathOrSelf(system) === '/tmp') candidates.push('/var/tmp')
  candidates.push(system, '/var/tmp')
  for (const candidate of new Set(candidates)) {
    const absolute = resolve(candidate)
    if (!writableDirectory(absolute)) continue
    if (isInsideGitCheckout(absolute)) continue
    return absolute
  }
  throw new Error('run-tests: no writable temporary directory outside a Git checkout')
}

/**
 * Expand the package.json test patterns into a deterministic file list.
 * @param {string[]} patterns - glob patterns, relative to the plugins root.
 * @returns {string[]} absolute test file paths.
 */
function expandPatterns(patterns) {
  const files = []
  for (const pattern of patterns) {
    const matches = excludeNodeModulesPaths(globSync(pattern, { cwd: pluginRoot }).sort())
    if (matches.length === 0) throw new Error(`run-tests: pattern '${pattern}' matched no test files`)
    for (const match of matches) {
      const absolute = resolve(pluginRoot, match)
      if (!statSync(absolute).isFile()) throw new Error(`run-tests: '${match}' is not a file`)
      files.push(absolute)
    }
  }
  return [...new Set(files)]
}

function main(patterns) {
  if (patterns.length === 0) {
    process.stderr.write('run-tests: expected at least one test pattern\n')
    process.exitCode = 2
    return
  }

  let tempRoot
  let cleaned = false
  const cleanup = () => {
    if (cleaned) return
    cleaned = true
    if (tempRoot !== undefined) rmSync(tempRoot, { recursive: true, force: true })
  }
  try {
    tempRoot = mkdtempSync(join(chooseBase(), 'pdsh-node-test-'))
    const files = expandPatterns(patterns)
    const env = { ...process.env, TMPDIR: tempRoot, TMP: tempRoot, TEMP: tempRoot }
    const child = spawn(process.execPath, ['--test', '--import', preload, ...files], {
      cwd: pluginRoot,
      env,
      stdio: 'inherit',
    })
    const signals = ['SIGINT', 'SIGTERM', 'SIGHUP']
    let forwardedSignal = null
    const handlers = new Map(signals.map(signal => [signal, () => {
      forwardedSignal = signal
      if (!child.killed) child.kill(signal)
    }]))
    for (const [signal, handler] of handlers) process.on(signal, handler)
    const removeHandlers = () => {
      for (const [signal, handler] of handlers) process.removeListener(signal, handler)
    }
    let finished = false
    const settle = (finish) => {
      if (finished) return
      finished = true
      removeHandlers()
      cleanup()
      finish()
    }
    child.once('error', (error) => {
      settle(() => {
        process.stderr.write(`run-tests: failed to start ${process.execPath}: ${error.message}\n`)
        process.exitCode = 1
      })
    })
    child.once('close', (code, signal) => {
      settle(() => {
        // Prefer the signal the child died from, then one we forwarded: a
        // wrapper that sent SIGTERM must see the same termination even when
        // Node's test runner translates it to an exit code.
        const termination = signal ?? forwardedSignal
        if (termination !== null) {
          process.kill(process.pid, termination)
          return
        }
        process.exitCode = code ?? 1
      })
    })
  } catch (error) {
    cleanup()
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 1
  }
}

const invokedPath = process.argv[1]
if (invokedPath !== undefined
    && realpathOrSelf(resolve(invokedPath)) === realpathOrSelf(fileURLToPath(import.meta.url))) {
  main(process.argv.slice(2))
}
