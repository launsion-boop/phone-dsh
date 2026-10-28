// SPDX-License-Identifier: MIT
/**
 * Pack-time compatibility for Cordis fibers whose `dispose()` returns `void`.
 *
 * Cordis declares `Fiber.dispose` as `() => Promise<void>`, but its effect
 * wrapper returns `undefined` when the fiber was already disposed (the wrapper
 * short-circuits after the first call). Two pinned DSH listeners call
 * `fiber.dispose().catch(...)` from `agent/disposed`, where the Agent scope may
 * already have disposed the fiber, so JavaScriptCore (and Node) raises
 * "Cannot read properties of undefined (reading 'catch')".
 *
 * The phone image therefore rewrites exactly those two built call sites while
 * staging the pinned packages: the disposer still runs immediately, `this`
 * stays the fiber, and a rejected cleanup still reaches the same listener.
 * `Promise.resolve` only normalises the return value; it adds no policy.
 *
 * The rewrite is deliberately not a global replacement. Each entry names one
 * package and one file, and the staging step fails loudly when the anchor or
 * the call statement is absent or duplicated. The transformed hashes and the
 * pinned commit/version are recorded in `sizes.json` by `pack-image.mjs`; the
 * DSH checkout is never modified.
 * @module @phone-dsh/dsh-plugins/scripts/dispose-compat
 */
import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/**
 * One built call site and the exact statement it must contain.
 * @typedef {object} DisposeCompatSite
 * @property {string} file - package-relative built file.
 * @property {string} callSite - human-readable listener that owns the call.
 * @property {string} anchor - unique enclosing declaration, checked before the call.
 * @property {string} statement - exact call statement to normalise.
 * @property {string} replacement - same statement with a Promise return.
 */

/**
 * One pinned package that needs the call-site rewrite.
 * @typedef {object} DisposeCompatPackage
 * @property {string} package - package name in the pinned checkout.
 * @property {readonly DisposeCompatSite[]} sites - exact sites in that package.
 */

/** The pinned packages and the two `agent/disposed` cleanup listeners. */
export const DISPOSE_COMPAT_PACKAGES = Object.freeze([
  Object.freeze({
    package: '@deepseek-ai/dsh-tool-subagent',
    sites: Object.freeze([
      Object.freeze({
        file: 'lib/index.js',
        callSite: 'tool-subagent: agent/disposed removeScoped',
        anchor: 'const removeScoped = (candidate) => {',
        statement: 'fiber.dispose().catch((error) => {',
        replacement: 'Promise.resolve(fiber.dispose()).catch((error) => {',
      }),
    ]),
  }),
  Object.freeze({
    package: '@deepseek-ai/dsh-file-reference-local',
    sites: Object.freeze([
      Object.freeze({
        file: 'lib/index.js',
        callSite: 'file-reference-local: agent/disposed disposePrompt',
        anchor: 'const disposePrompt = (agent) => {',
        statement: 'const task = fiber.dispose().catch((error) => {',
        replacement: 'const task = Promise.resolve(fiber.dispose()).catch((error) => {',
      }),
    ]),
  }),
])

/** Count non-overlapping literal occurrences. */
function count(source, needle) {
  return source.split(needle).length - 1
}

/** SHA-256 of one staged text file, encoded as lowercase hex. */
function sha256(text) {
  return createHash('sha256').update(text).digest('hex')
}

/**
 * Resolve one declared dependency the way the packer's `materialize` does.
 *
 * The official packer resolves a dependency of a workspace package from that
 * workspace's directory (a direct workspace hit wins, then Node walks up
 * `node_modules`). A package staged under `tmpdir()` has no ancestors that
 * answer that walk, so the staged tree must carry the same links the pinned
 * install has.
 *
 * @param {string} name - dependency package name.
 * @param {string} source - pinned package directory the dependency is declared in.
 * @param {ReadonlyMap<string, string>} workspaces - package name to pinned directory.
 * @returns {string | undefined} real package directory, or undefined when the
 *   pinned install cannot resolve it (the packer then reports it under `missing`).
 */
function resolveDependency(name, source, workspaces) {
  const workspace = workspaces.get(name)
  if (workspace !== undefined && existsSync(join(workspace, 'package.json'))) {
    return realpathSync(workspace)
  }
  let directory = source
  for (;;) {
    const candidate = join(directory, 'node_modules', name)
    if (existsSync(join(candidate, 'package.json'))) return realpathSync(candidate)
    const parent = dirname(directory)
    if (parent === directory) return undefined
    directory = parent
  }
}

/**
 * Add a `node_modules` resolution view to one staged package.
 *
 * Only the pairs the packer materializes are linked: `dependencies` and, for a
 * workspace package, `peerDependencies` (the same two fields `materialize`
 * follows). The links live under the staged `node_modules`, which the packer's
 * collector skips, so they change resolution without changing image contents.
 * A dependency the pinned install cannot resolve is left for the packer's own
 * `missing` report rather than guessed at.
 *
 * @param {object} options - dependency view inputs.
 * @param {object} options.manifest - parsed pinned package.json.
 * @param {string} options.source - pinned package directory.
 * @param {string} options.output - staged package directory.
 * @param {ReadonlyMap<string, string>} options.workspaces - package name to pinned directory.
 * @returns {{resolved: string[], unresolved: string[]}} names linked and names the install cannot answer.
 */
function stageDependencyView({ manifest, source, output, workspaces }) {
  const names = new Set()
  for (const field of ['dependencies', 'peerDependencies']) {
    const dependencies = manifest[field]
    if (typeof dependencies !== 'object' || dependencies === null) continue
    for (const name of Object.keys(dependencies)) names.add(name)
  }
  const resolved = []
  const unresolved = []
  for (const name of [...names].sort()) {
    const target = resolveDependency(name, source, workspaces)
    if (target === undefined) {
      unresolved.push(name)
      continue
    }
    const link = join(output, 'node_modules', name)
    mkdirSync(dirname(link), { recursive: true })
    rmSync(link, { recursive: true, force: true })
    symlinkSync(target, link, 'dir')
    resolved.push(name)
  }
  return { resolved, unresolved }
}

/**
 * Rewrite one exact built call site, or fail if the pinned source drifted.
 *
 * @param {string} source - built JavaScript file contents.
 * @param {DisposeCompatSite} site - exact site to rewrite.
 * @param {string} packageName - package name used in the error message.
 * @returns {{source: string, replacements: 1, sourceSha256: string, transformedSha256: string}} rewritten text and hashes.
 * @throws {Error} when the anchor or statement is missing or duplicated.
 */
export function rewriteDisposeSite(source, site, packageName) {
  const label = `${packageName}/${site.file} (${site.callSite})`
  const anchors = count(source, site.anchor)
  if (anchors !== 1) {
    throw new Error(
      `pack-image: dispose compatibility expected exactly one ${JSON.stringify(site.anchor)} in ${label}, found ${anchors}; `
      + 'the pinned DSH build drifted, so refuse to transform it',
    )
  }
  const statements = count(source, site.statement)
  if (statements !== 1) {
    throw new Error(
      `pack-image: dispose compatibility expected exactly one ${JSON.stringify(site.statement)} in ${label}, found ${statements}; `
      + 'the pinned DSH build drifted, so refuse to transform it',
    )
  }
  if (source.indexOf(site.anchor) > source.indexOf(site.statement)) {
    throw new Error(`pack-image: dispose compatibility anchor follows the call site in ${label}; refuse to guess`)
  }
  const rewritten = source.replace(site.statement, site.replacement)
  return {
    source: rewritten,
    replacements: 1,
    sourceSha256: sha256(source),
    transformedSha256: sha256(rewritten),
  }
}

/**
 * Copy the published faces of one pinned package and rewrite its call sites.
 *
 * Only `package.json`, `lib/`, and `locale/` are staged; the packer's workspace
 * view excludes sources and tests anyway, and the manifest stays byte-identical.
 *
 * @param {object} options - staging inputs.
 * @param {DisposeCompatPackage} options.package - package to stage.
 * @param {string} options.source - pinned package directory.
 * @param {string} options.output - staging directory for this package.
 * @param {string} options.commit - pinned DSH commit recorded in the facts.
 * @param {string} options.version - pinned DSH version recorded in the facts.
 * @param {ReadonlyMap<string, string>} [options.workspaces] - every pinned workspace, used for dependency links.
 * @returns {{directory: string, facts: object[], dependencies: {resolved: string[], unresolved: string[]}}} staged directory, facts and dependency view.
 */
export function stageDisposeCompatPackage({ package: spec, source, output, commit, version, workspaces = new Map() }) {
  const manifest = join(source, 'package.json')
  if (!existsSync(manifest)) {
    throw new Error(`pack-image: dispose compatibility target ${spec.package} has no package.json at ${source}`)
  }
  mkdirSync(output, { recursive: true })
  cpSync(manifest, join(output, 'package.json'))
  const packageJson = JSON.parse(readFileSync(manifest, 'utf8'))
  for (const directory of ['lib', 'locale']) {
    const from = join(source, directory)
    if (existsSync(from)) cpSync(from, join(output, directory), { recursive: true })
  }
  if (!existsSync(join(output, 'lib'))) {
    throw new Error(
      `pack-image: dispose compatibility target ${spec.package} has no built lib/ in ${source}; `
      + 'build the pinned checkout with `pnpm build` before packing',
    )
  }
  const facts = []
  // The staged package lives under tmpdir(), where the pinned install's
  // ancestor node_modules are absent. Mirror the resolution view materialize
  // expects before the packer walks the dependency closure.
  const dependencies = stageDependencyView({ manifest: packageJson, source, output, workspaces })
  for (const site of spec.sites) {
    const file = join(output, site.file)
    if (!existsSync(file)) {
      throw new Error(
        `pack-image: dispose compatibility target ${spec.package}/${site.file} is missing from the built package; `
        + 'build the pinned checkout with `pnpm build` before packing',
      )
    }
    const result = rewriteDisposeSite(readFileSync(file, 'utf8'), site, spec.package)
    writeFileSync(file, result.source)
    facts.push({
      package: spec.package,
      file: site.file,
      call_site: site.callSite,
      anchor: site.anchor,
      statement: site.statement,
      replacement: site.replacement,
      replacements: result.replacements,
      source_sha256: result.sourceSha256,
      transformed_sha256: result.transformedSha256,
      dsh_commit: commit,
      dsh_version: version,
    })
  }
  return { directory: output, facts, dependencies }
}

/**
 * Stage every compatibility package so the packer resolves the rewritten build.
 *
 * @param {object} options - staging inputs.
 * @param {ReadonlyMap<string, string>} options.workspaces - package name to pinned directory.
 * @param {string} options.output - staging root for all compatibility packages.
 * @param {string} options.commit - pinned DSH commit recorded in the facts.
 * @param {string} options.version - pinned DSH version recorded in the facts.
 * @returns {{workspaces: Map<string, string>, packages: string[], facts: object[]}} staged inputs and facts.
 */
export function stageDisposeCompat({ workspaces, output, commit, version }) {
  const staged = new Map()
  const facts = []
  for (const spec of DISPOSE_COMPAT_PACKAGES) {
    const source = workspaces.get(spec.package)
    if (source === undefined) {
      throw new Error(`pack-image: dispose compatibility target ${spec.package} is not a workspace in the pinned checkout`)
    }
    const directory = join(output, spec.package.replace(/^@/u, '').replaceAll('/', '__'))
    const result = stageDisposeCompatPackage({ package: spec, source, output: directory, commit, version, workspaces })
    staged.set(spec.package, result.directory)
    facts.push(...result.facts)
  }
  return {
    workspaces: staged,
    packages: DISPOSE_COMPAT_PACKAGES.map(spec => spec.package),
    facts,
  }
}
