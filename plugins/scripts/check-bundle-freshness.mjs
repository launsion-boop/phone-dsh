#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Staleness gate for the worker bundle the App actually boots.
 *
 * The worker payload is **three separately built artifacts** plus the image
 * (see `docs/receipts/android-port-2026-10-31.md` §"部署管线的两个坑"):
 *
 *   | artifact                                    | producer                                   |
 *   |---------------------------------------------|--------------------------------------------|
 *   | `Bundle/worker/worker-entry.js` (+ siblings) | `plugins/worker-entry/build.mjs --out <dir>` |
 *   | `Bundle/worker/image.tar.gz`                 | `plugins/scripts/pack-image.mjs --out <dir>` |
 *   | `Bundle/worker/tool-worker-python.js`        | `plugins/worker-entry/build.mjs --out <dir>` |
 *
 * A source edit that is not followed by a rebuild leaves the App running the
 * previous bytes while every test is green. That has already produced four
 * incidents in this tree (a capability manifest advertising nineteen phone
 * tools the host never implemented, two `python3`/`jq` lanes, and one
 * `shell-timeout` over-report), each found by hand. This gate turns "did you
 * rebuild after editing?" into a machine check:
 *
 * - every artifact present in `examples/probe-app/Bundle/worker/` must be at
 *   least as new as the newest source file that feeds it;
 * - a stale artifact prints the artifact time, the newest source **file** and
 *   the exact rebuild command, and the process exits 1;
 * - an absent artifact is SKIP, not FAIL: the bundle directory is gitignored
 *   (~65 MB built from the pinned DSH checkout), so a clean checkout has
 *   nothing to compare — that is not evidence of staleness.
 *
 * The five artifacts one `build.mjs` run emits are one build unit, so they
 * share one source set: rebuilding any of them with the documented command
 * refreshes all of them. `image.tar.gz` has its own producer
 * (`pack-image.mjs`), which excludes the workspace `worker-entry` package, so
 * it is compared against the plugin sources minus that package.
 *
 * Tests and documentation are not sources of an artifact: editing a `*.test.*`
 * or `*.md` file must not turn the gate red.
 *
 * Usage:
 *   node plugins/scripts/check-bundle-freshness.mjs [--root <repo>] [--json]
 * @module @phone-dsh/dsh-plugins/scripts/check-bundle-freshness
 */
import { readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

/** Repository root this module ships in. */
const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..')

/** Directory the App boots from (gitignored build input). */
export const BUNDLE_DIR = 'examples/probe-app/Bundle/worker'

/** The bundle artifacts and the command that rebuilds each one. */
export const BUILD_COMMANDS = Object.freeze({
  'worker-entry.js': 'node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker',
  'tool-worker-python.js': 'node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker',
  'tool-worker.js': 'node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker',
  'workflow-isolate.js': 'node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker',
  'web-boot.js': 'node plugins/worker-entry/build.mjs --out examples/probe-app/Bundle/worker',
  'image.tar.gz': 'node plugins/scripts/pack-image.mjs --out examples/probe-app/Bundle/worker',
})

/** Every artifact this gate compares, in a stable order. */
export const ARTIFACTS = Object.freeze(Object.keys(BUILD_COMMANDS))

/**
 * Source roots that are not `plugins/<package>/src`.
 *
 * `plugins/*\/src` is discovered at run time so a new plugin package is covered
 * without editing this list; these are the faces that live outside it.
 */
export const EXTRA_SOURCE_ROOTS = Object.freeze([
  'plugins/shell-ext/tools',
  'plugins/worker-entry/www',
  'plugins/wasi-toolbox/python',
  'plugins/wasi-toolbox/jq',
  'plugins/wasi-toolbox/git',
  'plugins/workflow-worker/src',
  'plugins/profile',
])

/** Directory names that never carry an artifact's source. */
const IGNORED_DIRECTORIES = new Set([
  '.build', '.cache', '.git', '.turbo', '__pycache__', 'build', 'dist', 'node_modules', 'target',
])

/** File suffixes that do not change an artifact (tests, docs, source maps). */
const IGNORED_FILE = /(?:\.test\.[cm]?[jt]s|\.spec\.[cm]?[jt]s|\.md|\.map)$/u

/**
 * Every source root that feeds the bundle, sorted.
 * @param root - repository root.
 * @returns repository-relative directory paths (existing ones only).
 */
export function sourceRoots(root = REPO_ROOT) {
  const roots = new Set(EXTRA_SOURCE_ROOTS)
  let packages
  try {
    packages = readdirSync(join(root, 'plugins'), { withFileTypes: true })
  } catch {
    return []
  }
  for (const entry of packages) {
    if (!entry.isDirectory()) continue
    const candidate = `plugins/${entry.name}/src`
    try {
      if (statSync(join(root, candidate)).isDirectory()) roots.add(candidate)
    } catch {
      // A package without a `src/` face (tests, scripts) contributes nothing.
    }
  }
  return [...roots]
    .filter(relative => {
      try {
        return statSync(join(root, relative)).isDirectory()
      } catch {
        return false
      }
    })
    .sort()
}

/**
 * The newest file under one directory tree.
 * @param directory - absolute directory to walk.
 * @param root - repository root, used to render a relative path.
 * @returns the newest `{path, mtimeMs}`, or undefined for an empty tree.
 */
export function newestFile(directory, root) {
  let newest
  const walk = (absolute) => {
    let entries
    try {
      entries = readdirSync(absolute, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (!IGNORED_DIRECTORIES.has(entry.name)) walk(join(absolute, entry.name))
        continue
      }
      if (!entry.isFile() || IGNORED_FILE.test(entry.name)) continue
      const absolutePath = join(absolute, entry.name)
      let mtimeMs
      try {
        mtimeMs = statSync(absolutePath).mtimeMs
      } catch {
        continue
      }
      if (newest === undefined || mtimeMs > newest.mtimeMs) {
        newest = { path: absolutePath.slice(root.length + 1).split('\\').join('/'), mtimeMs }
      }
    }
  }
  walk(directory)
  return newest
}

/**
 * The newest source file across every root that feeds the bundle.
 * @param root - repository root.
 * @param roots - source roots to scan (defaults to {@link sourceRoots}).
 * @returns the newest `{path, mtimeMs}`, or undefined when nothing exists.
 */
export function newestSource(root = REPO_ROOT, roots = sourceRoots(root)) {
  let newest
  for (const relative of roots) {
    const candidate = newestFile(join(root, relative), root)
    if (candidate !== undefined && (newest === undefined || candidate.mtimeMs > newest.mtimeMs)) {
      newest = candidate
    }
  }
  return newest
}

/**
 * Source roots that feed one artifact.
 *
 * The five files `build.mjs` emits share one set: one command rebuilds all of
 * them, so a wider set only means "run that command". The image has a different
 * producer (`pack-image.mjs`) and it deliberately excludes the workspace
 * `worker-entry` package (`WORKSPACE_EXCLUDES` in pack-image), so a
 * `plugins/worker-entry/**` edit must not demand a 25 MB image repack.
 * @param artifact - artifact file name.
 * @param roots - every source root.
 * @returns the roots this artifact is built from.
 */
function rootsFor(artifact, roots) {
  if (artifact !== 'image.tar.gz') return roots
  return roots.filter(relative => !relative.startsWith('plugins/worker-entry/'))
}

/**
 * Compare every artifact against the newest source file.
 * @param root - repository root.
 * @param artifacts - artifact names to check (defaults to {@link ARTIFACTS}).
 * @returns one result per artifact, in the requested order.
 */
export function checkBundleFreshness(root = REPO_ROOT, artifacts = ARTIFACTS) {
  const roots = sourceRoots(root)
  return artifacts.map(artifact => {
    const source = newestSource(root, rootsFor(artifact, roots))
    const path = join(root, BUNDLE_DIR, artifact)
    let mtimeMs
    try {
      mtimeMs = statSync(path).mtimeMs
    } catch {
      return { artifact, status: 'absent' }
    }
    if (source === undefined) return { artifact, status: 'fresh', artifactMtimeMs: mtimeMs }
    return mtimeMs < source.mtimeMs
      ? { artifact, status: 'stale', artifactMtimeMs: mtimeMs, source }
      : { artifact, status: 'fresh', artifactMtimeMs: mtimeMs, source }
  })
}

/** Render one result as its one-line PASS/FAIL/SKIP record. */
export function formatResult(result) {
  const stamp = ms => new Date(ms).toISOString()
  if (result.status === 'absent') {
    return `SKIP bundle-freshness ${result.artifact} (absent: ${BUNDLE_DIR} is a gitignored build input)`
  }
  const comparison = `${stamp(result.artifactMtimeMs)} >= ${stamp(result.source.mtimeMs)} ${result.source.path}`
  if (result.status === 'fresh') return `PASS bundle-freshness ${result.artifact} (${comparison})`
  return `FAIL bundle-freshness ${result.artifact}: artifact ${stamp(result.artifactMtimeMs)} is older than `
    + `${result.source.path} ${stamp(result.source.mtimeMs)} — rebuild: ${BUILD_COMMANDS[result.artifact]}`
}

function main() {
  const { values } = parseArgs({
    options: {
      root: { type: 'string', default: REPO_ROOT },
      json: { type: 'boolean', default: false },
      help: { type: 'boolean', short: 'h', default: false },
    },
  })
  if (values.help) {
    process.stdout.write('usage: node plugins/scripts/check-bundle-freshness.mjs [--root <repo>] [--json]\n')
    return 0
  }
  const root = resolve(values.root)
  const results = checkBundleFreshness(root)
  if (values.json) {
    process.stdout.write(`${JSON.stringify({ root, results }, undefined, 2)}\n`)
  } else {
    for (const result of results) process.stdout.write(`${formatResult(result)}\n`)
    const count = status => results.filter(result => result.status === status).length
    process.stdout.write(
      `bundle-freshness: ${String(count('fresh'))} fresh, ${String(count('stale'))} stale, `
      + `${String(count('absent'))} absent\n`,
    )
  }
  return results.some(result => result.status === 'stale') ? 1 : 0
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main()
}
