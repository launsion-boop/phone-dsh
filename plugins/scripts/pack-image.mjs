#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Pack the Worker-runtime VFS image for the phone profile.
 *
 * DSH ships no "phone" image: the official CLI packer packs one of DSH's
 * shipped profiles from the workspace as published. This wrapper drives the
 * checkout's own packer library (never a copy) with the repository layer the
 * phone needs:
 *
 *   1. Stage each phone-dsh plugin package: bundle every source export face
 *      into `lib/<face>.js` and rewrite `main`/`exports` to point there. The
 *      packer's workspace exclude drops `src/**` and `dist/**`, and these
 *      packages publish TypeScript sources from `src/`.
 *   2. Compose the roster from the 0.2.1 base bundle's rows, the workspace
 *      plugin packages, the surface rows carried by the worker profile patch, the
 *      Worker assembly's image entry seeds, and every `@deepseek-ai/*` import
 *      the staged plugins request.
 *   3. Load the worker profile patch with DSH's own `loadOverlayPatches`, so
 *      `!!js` expressions keep the in-memory representation the loader expects,
 *      and pass it as the packer's `homePatch` (`home/cordis.patch.yml`).
 *   4. Pack, assert the image is complete, and write the runtime artifacts.
 *   5. Assert the Worker-side `sharp` replacement is still wired: the pinned
 *      runtime must keep replacing the native package, and the Worker entry
 *      bundle must carry this layer's shim (G2-FIX-60). The facts are recorded
 *      in `sizes.json`.
 *
 * Usage:
 *   PDSH_DSH_CHECKOUT=<checkout> node scripts/pack-image.mjs --out <dir>
 * @module @phone-dsh/dsh-plugins/scripts/pack-image
 */
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { gunzipSync } from 'node:zlib'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { builtinModules, createRequire } from 'node:module'
import { parseArgs } from 'node:util'
import { writeImageProvenance } from './provenance.mjs'
import { pathToFileURL, fileURLToPath } from 'node:url'

import { verifyCheckout, readPin } from './dsh-checkout.mjs'
import { stageDisposeCompat } from './dispose-compat.mjs'
import { SHARP_MODULE_SPECIFIER, SHARP_SHIM_MARKER, SHARP_SHIM_MODULE } from '../worker-entry/src/sharp-marker.ts'
import { JQ_SOURCE_ALGORITHM, jqSourceReport } from '../wasi-toolbox/jq/source-fingerprint.ts'
// The image bundles just-bash through shell-ext. Apply the byte-guarded
// terminal-state seam even when this script is invoked directly (the CI stage
// does), not only through the npm lifecycle hooks.
import '../shell-ext/tools/patch-just-bash.mjs'

/** Directory of this script (`plugins/scripts`). */
const HERE = dirname(fileURLToPath(import.meta.url))
/** Repository-side DSH plugin root (`plugins`). */
const PLUGIN_ROOT = resolve(HERE, '..')
/** The worker profile layer applied as the image's home patch. */
export const WORKER_PROFILE_PATCH = join(PLUGIN_ROOT, 'profile', 'phone.worker.cordis.patch.yml')

/** Shipped DSH profile template the Worker host boots (`--host ... --no-open`). */
export const IMAGE_PROFILE = 'web'

/**
 * Image directory the CPython-on-WASI artifacts are staged under, relative to
 * the image root: the Worker reads them at `/dsh/bin/python/{python.wasm,
 * python313.zip}` (the same `bin/` convention as the runtime's `/dsh/bin/rg`).
 * `worker-entry/src/python-toolbox.ts` mirrors these two names.
 */
export const PYTHON_IMAGE_MOUNT = 'bin/python'
/** Interpreter artifact file name (CPython's wasm32-wasi build). */
export const PYTHON_WASM_FILE = 'python.wasm'
/** Zipped standard library file name. */
export const PYTHON_STDLIB_FILE = 'python313.zip'
/**
 * Build-time probe the packer writes beside the artifact pair. The Worker reads
 * it at `/dsh/bin/python/modules.json` and copies the list into the boot
 * capability manifest; `worker-entry/src/python-toolbox.ts` mirrors the name.
 */
export const PYTHON_MODULES_FILE = 'modules.json'
/**
 * Build report the real interpreter probe writes (a successful
 * `verify-compression.mjs` run: module roundtrips, `tarfile w:gz` and the zlib
 * runtime version). It is the only source of the compression capability.
 */
export const PYTHON_COMPRESSION_FILE = 'compression.json'
/**
 * Build report `build.sh` writes beside the pair: the measured sha256 of both
 * files. The packer refuses a pair whose bytes do not match it, so a stale
 * `compression.json` can never be staged onto a different interpreter.
 */
export const PYTHON_SIZES_FILE = 'sizes.json'
/** Python version line the probe records (the pinned wasm32-wasi build). */
export const PYTHON_VERSION = '3.13'
/** Command that produces the pair; every loud python failure points at it. */
export const PYTHON_BUILD_COMMAND = 'bash plugins/wasi-toolbox/python/build.sh --out <dir>'

/**
 * Image directory the jq WASI engine is staged under. The Worker reads it at
 * `/dsh/bin/jq/jq.wasm`; `worker-entry/src/jq-toolbox.ts` mirrors these names.
 */
export const JQ_IMAGE_MOUNT = 'bin/jq'
/** jq-compatible WASI executable file name. */
export const JQ_WASM_FILE = 'jq.wasm'
/** Build report the engine probe writes beside the executable. */
export const JQ_ENGINE_FILE = 'engine.json'
/** Size/digest report `build.sh` writes; binds engine.json to the bytes. */
export const JQ_SIZES_FILE = 'sizes.json'
/** Command that produces the engine; every loud jq failure points at it. */
export const JQ_BUILD_COMMAND = 'bash plugins/wasi-toolbox/jq/build.sh --out <dir>'

/**
 * Repository packages packed from staged workspaces (see `workspaceDirs`). The
 * order follows package.json so logs and assertions read the same on every run.
 */
// Every workspace package under plugins except the Worker assembly itself is staged into the image: the Cordis rows
// (exec-bridge, subprocess-xl, llm-bridge, tool-journal, lifecycle-gate, surface-phone) and the shared libraries they import
// inside the Worker (channel, shell-ext, wasi-toolbox, ...). Derived from package.json so a new workspace is never forgotten.
/**
 * Bare imports a staged bundle may keep. Everything else a workspace package
 * imports (its npm dependencies, such as shell-ext's just-bash) is bundled into
 * the staged `lib/` file: the packer resolves roster packages from the pinned
 * DSH checkout only, so an npm package that lives in this repository's
 * node_modules would otherwise be reported as unresolved.
 */
const IMAGE_SCOPES = Object.freeze(['@deepseek-ai/', '@phone-dsh/'])
export const BUNDLE_EXTERNAL = Object.freeze(['node:*', ...IMAGE_SCOPES.map(scope => `${scope}*`)])

/**
 * Module-table specifiers every browser client bundle receives from the page
 * shell rather than bundling. Mirrors the pinned checkout's `PLATFORM_MODULES`;
 * keep this list explicit so a second React or a duplicate shared singleton can
 * never be inlined into a phone client face.
 */
const CLIENT_PLATFORM_EXTERNALS = Object.freeze([
  'react',
  'react/jsx-runtime',
  'react-dom',
  'react-dom/client',
  '@deepseek-ai/cordis',
  'zod',
  '@tanstack/react-virtual',
  '@deepseek-ai/dsh-client-store',
  '@deepseek-ai/dsh-client-ui-slots',
  '@deepseek-ai/dsh-client-ui-primitives',
  '@deepseek-ai/dsh-client-ui-dockkit',
])

/**
 * Browser-safe `@deepseek-ai/*` wire layers with no shared runtime identity.
 * The pinned checkout's client build inlines the same family instead of
 * requesting a module-table row; only these may be bundled into a phone client.
 */
const CLIENT_INLINE_SAFE = /^@deepseek-ai\/dsh-util-workspace-path(?:\/|$)/

/**
 * DSH source faces a phone host package imports directly because the published
 * package excludes `src/`. The pinned checkout supplies the source; bundling it
 * here is what keeps the phone package's `@deepseek-ai/*` imports resolvable in
 * the Worker image without copying DSH code into this repository.
 */
const CHECKOUT_SOURCE_FACES = Object.freeze({
  '@deepseek-ai/dsh-plugin-manager/src/patch.ts': 'packages/boot/plugin-manager/src/patch.ts',
  // The Worker workflow bridge reuses the official workflow execution and meta
  // validation instead of copying their semantics. The published package
  // excludes `src/`, so these faces come from the same verified checkout.
  '@deepseek-ai/dsh-workflow-ptc/src/runtime.ts': 'packages/workflow/workflow-ptc/src/runtime.ts',
  '@deepseek-ai/dsh-workflow-ptc/src/meta.ts': 'packages/workflow/workflow-ptc/src/meta.ts',
})

/**
 * Whether a bare specifier names a package the image carries as its own
 * package (a DSH package from the checkout or a staged workspace package).
 * @param specifier - bare import specifier or package name.
 * @returns True for the two image scopes.
 */
export function isImagePackage(specifier) {
  return IMAGE_SCOPES.some(scope => specifier.startsWith(scope))
}

/**
 * Names a runtime builtin proxy exports, read from the runtime's type
 * declarations (`lib/types/.../implemented/<module>.d.ts`, which the compiled
 * `worker.js` bundle does not expose per module). A stub that throws
 * notImplementedFail still counts as exported; an absent name does not.
 * @param checkout - pinned checkout directory.
 * @param runtime - the runtime module namespace (`MODULE_PROXIES`).
 * @param moduleName - `node:` specifier.
 * @returns The exported names, or null when the runtime has no declaration file for the proxy.
 */
export async function builtinExports(checkout, runtime, moduleName) {
  const target = runtime.MODULE_PROXIES?.[moduleName]
  if (typeof target !== 'string') return null
  const declaration = join(checkout, 'packages/experimental/webworker-runtime/lib/types', target.replace(/^\.\//, '').replace(/\.ts$/, '.d.ts'))
  if (!existsSync(declaration)) return null
  // The declaration file is TypeScript (multi-name `export declare const a: T, b: T`
  // spans lines), so it is read through the compiler's parser, not a regex.
  const ts = (await import('typescript')).default
  const file = ts.createSourceFile(declaration, readFileSync(declaration, 'utf8'), ts.ScriptTarget.Latest, false, ts.ScriptKind.TS)
  const names = new Set()
  const bindingNames = (name) => {
    if (ts.isIdentifier(name)) names.add(name.text)
    else for (const element of name.elements) if (!ts.isOmittedExpression(element)) bindingNames(element.name)
  }
  for (const statement of file.statements) {
    if (ts.isExportAssignment(statement)) {
      names.add('default')
      continue
    }
    if (ts.isExportDeclaration(statement)) {
      if (statement.exportClause && ts.isNamedExports(statement.exportClause)) {
        for (const element of statement.exportClause.elements) names.add(element.name.text)
      } else {
        return null // `export * from` cannot be resolved here; do not guess
      }
      continue
    }
    const modifiers = ts.canHaveModifiers(statement) ? (ts.getModifiers(statement) ?? []) : []
    if (!modifiers.some(m => m.kind === ts.SyntaxKind.ExportKeyword)) continue
    if (modifiers.some(m => m.kind === ts.SyntaxKind.DefaultKeyword)) names.add('default')
    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) bindingNames(declaration.name)
    } else if (statement.name && ts.isIdentifier(statement.name)) {
      names.add(statement.name.text)
    }
  }
  return names
}

/**
 * Named imports of node: builtins in one staged JavaScript file.
 * @param source - staged file text.
 * @returns Map of `node:` specifier to the imported member names (`*` for a namespace import).
 */
export function builtinImports(source) {
  const members = new Map()
  const add = (moduleName, name) => {
    if (!members.has(moduleName)) members.set(moduleName, new Set())
    members.get(moduleName).add(name)
  }
  for (const match of source.matchAll(/import\s*(\*\s*as\s+[\w$]+|[\w$]+)?\s*,?\s*(\{[^}]*\})?\s*from\s*["'](node:[^"']+)["']/g)) {
    const [, head, named, moduleName] = match
    if (head?.startsWith('*')) add(moduleName, '*')
    else if (head) add(moduleName, 'default')
    if (named) {
      for (const part of named.slice(1, -1).split(',')) {
        const name = part.trim().split(/\s+as\s+/)[0]
        if (name) add(moduleName, name === 'default' ? 'default' : name)
      }
    }
  }
  return members
}

const NODE_BUILTINS = new Set(builtinModules.filter(name => !name.startsWith('_')))
/**
 * esbuild plugin: a bare Node builtin import (`fs`) inside a bundled npm package
 * becomes its `node:` form, the only spelling the Worker runtime's module
 * proxies provide.
 */
const nodeBuiltinPrefix = {
  name: 'pdsh-node-builtin-prefix',
  setup(build) {
    build.onResolve({ filter: /^[a-z_]+(?:\/[a-z_]+)?$/ }, args => (
      NODE_BUILTINS.has(args.path) ? { path: `node:${args.path}`, external: true } : undefined
    ))
  },
}

const WORKSPACE_EXCLUDES = new Set(['worker-entry'])
const workspaceDirs = (() => {
  const root = JSON.parse(readFileSync(join(PLUGIN_ROOT, 'package.json'), 'utf8'))
  const dirs = new Set([...(root.workspaces ?? []), 'surface-phone'])
  return [...dirs].filter(d => !WORKSPACE_EXCLUDES.has(d) && existsSync(join(PLUGIN_ROOT, d, 'package.json')))
})()
export const PLUGIN_PACKAGES = Object.freeze(workspaceDirs.map(d => ({
  name: JSON.parse(readFileSync(join(PLUGIN_ROOT, d, 'package.json'), 'utf8')).name,
  directory: join(PLUGIN_ROOT, d),
})))

/**
 * Packages the Worker assembly imports by literal specifier, and the Cordis
 * boot plugins `dsh-app-boot` imports. They are roots of the image even when no
 * roster row names them; keep in step with `worker-host.ts` and the packer's
 * `IMAGE_ENTRY_SEEDS`.
 */
export const RUNTIME_ROOTS = Object.freeze([
  '@deepseek-ai/dsh-app-boot',
  '@deepseek-ai/dsh-cmdline',
  '@deepseek-ai/dsh-launch-environment',
  '@deepseek-ai/cordis',
  '@deepseek-ai/cordis-plugin-include',
  '@deepseek-ai/cordis-plugin-group',
  '@deepseek-ai/cordis-plugin-loader',
])

const CODE_TARGET = /\.(?:[cm]?[jt]s)$/

/**
 * Package name of a module specifier.
 * @param specifier - possibly a subpath.
 * @returns The package name.
 */
export function packageNameOf(specifier) {
  const [first = specifier, second = ''] = specifier.split('/')
  return first.startsWith('@') ? `${first}/${second}` : first
}

/**
 * Read one JSON file.
 * @param file - absolute path.
 * @returns Parsed object.
 */
function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'))
}

/**
 * Resolve the CPython-on-WASI artifact pair the image should carry.
 *
 * The artifacts are build products (`wasi-toolbox/python/build.sh`) and are
 * never committed, so the image build asks for them explicitly: `--python
 * <dir>` (the build.sh output directory) or the `PDSH_PYTHON_WASM` /
 * `PDSH_PYTHON_STDLIB` pair of file paths. `PDSH_PYTHON_STDLIB` defaults to the
 * `python313.zip` sibling of `PDSH_PYTHON_WASM`, matching the runtime tests.
 *
 * Resolution is all-or-nothing: when the caller asks for python, a missing or
 * empty file is a loud failure naming the build command, never a silently
 * thinner image whose every `python3` step would exit 127.
 * @param options - `--python` directory and the environment to read.
 * @param options.python - directory passed as `--python <dir>`, if any.
 * @param options.env - environment (defaults to `process.env`).
 * @returns `{ wasm, stdlib, directory }` absolute paths, or undefined when
 *   python is not requested.
 */
export function resolvePythonSources({ python, env = process.env } = {}) {
  let wasm
  let stdlib
  let source
  if (python !== undefined) {
    if (typeof python !== 'string' || python === '') {
      throw new Error('pack-image: --python needs a directory (the wasi-toolbox/python/build.sh output)')
    }
    const directory = resolve(python)
    wasm = join(directory, PYTHON_WASM_FILE)
    stdlib = join(directory, PYTHON_STDLIB_FILE)
    source = `--python ${python}`
  } else {
    const wasmEnv = typeof env.PDSH_PYTHON_WASM === 'string' ? env.PDSH_PYTHON_WASM.trim() : ''
    const stdlibEnv = typeof env.PDSH_PYTHON_STDLIB === 'string' ? env.PDSH_PYTHON_STDLIB.trim() : ''
    if (wasmEnv === '' && stdlibEnv === '') return undefined
    if (wasmEnv === '') {
      throw new Error(
        'pack-image: PDSH_PYTHON_STDLIB is set but PDSH_PYTHON_WASM is not; '
        + `set both to ${PYTHON_BUILD_COMMAND} output files, or pass --python <dir>`,
      )
    }
    wasm = resolve(wasmEnv)
    stdlib = stdlibEnv === '' ? join(dirname(wasm), PYTHON_STDLIB_FILE) : resolve(stdlibEnv)
    source = 'PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB'
  }
  const missing = []
  for (const [name, file] of [[PYTHON_WASM_FILE, wasm], [PYTHON_STDLIB_FILE, stdlib]]) {
    if (!existsSync(file)) {
      missing.push(`${name} (${file}) is missing`)
      continue
    }
    if (statSync(file).size === 0) missing.push(`${name} (${file}) is empty`)
  }
  if (missing.length > 0) {
    throw new Error([
      `pack-image: the python artifacts are enabled (${source}) but cannot be staged:`,
      ...missing.map(entry => `  ${entry}`),
      'build them first:',
      `  ${PYTHON_BUILD_COMMAND}`,
      'then repack with --python <that output directory> (or complete PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB).',
    ].join('\n'))
  }
  return { wasm, stdlib, directory: dirname(wasm) }
}

/**
 * Resolve the jq WASI artifact the image should carry.
 *
 * The engine is a build product (`wasi-toolbox/jq/build.sh`) and is never
 * committed. It is enabled by `--jq <dir>` or `PDSH_JQ_ARTIFACTS`; an explicit
 * request is all-or-nothing so an image never silently advertises a `jq` whose
 * engine is absent.
 * @param options - `--jq` directory and the environment to read.
 * @param options.jq - directory passed as `--jq <dir>`, if any.
 * @param options.env - environment (defaults to `process.env`).
 * @returns `{ wasm, engine, sizes, directory }` absolute paths, or undefined.
 */
export function resolveJqSources({ jq, env = process.env } = {}) {
  let directory
  let source
  if (jq !== undefined) {
    if (typeof jq !== 'string' || jq === '') {
      throw new Error('pack-image: --jq needs a directory (the wasi-toolbox/jq/build.sh output)')
    }
    directory = resolve(jq)
    source = `--jq ${jq}`
  } else {
    const fromEnv = typeof env.PDSH_JQ_ARTIFACTS === 'string' ? env.PDSH_JQ_ARTIFACTS.trim() : ''
    if (fromEnv === '') return undefined
    directory = resolve(fromEnv)
    source = 'PDSH_JQ_ARTIFACTS'
  }
  const wasm = join(directory, JQ_WASM_FILE)
  const engine = join(directory, JQ_ENGINE_FILE)
  const sizes = join(directory, JQ_SIZES_FILE)
  const missing = []
  for (const [name, file] of [[JQ_WASM_FILE, wasm], [JQ_ENGINE_FILE, engine], [JQ_SIZES_FILE, sizes]]) {
    if (!existsSync(file)) {
      missing.push(`${name} (${file}) is missing`)
      continue
    }
    if (statSync(file).size === 0) missing.push(`${name} (${file}) is empty`)
  }
  if (missing.length > 0) {
    throw new Error([
      `pack-image: the jq engine is enabled (${source}) but cannot be staged:`,
      ...missing.map(entry => `  ${entry}`),
      'build it first:',
      `  ${JQ_BUILD_COMMAND}`,
      'then repack with --jq <that output directory> (or set PDSH_JQ_ARTIFACTS).',
    ].join('\n'))
  }
  return { wasm, engine, sizes, directory }
}

/**
 * Read and verify the engine build reports before staging.
 *
 * `engine.json` is the capability probe's own record and `sizes.json` binds
 * its sha256 to the executable. Both must describe the bytes on disk, name
 * the current checkout's source fingerprint, and carry the same non-empty
 * engine identity; a stale/incomplete report (or a report swapped between
 * builds) is a loud pack failure rather than a false capability claim.
 * @param options - resolved sources.
 * @returns The engine identity and the recorded digest.
 */
export function readJqBuildReports({ wasm, engine, sizes }) {
  let engineReport
  let sizesReport
  try {
    engineReport = recordOf(JSON.parse(readFileSync(engine, 'utf8')))
    sizesReport = recordOf(JSON.parse(readFileSync(sizes, 'utf8')))
  } catch (error) {
    throw new Error(
      `pack-image: the jq build reports are not valid JSON (${error instanceof Error ? error.message : String(error)}); `
      + `rebuild the engine with ${JQ_BUILD_COMMAND}`,
      { cause: error },
    )
  }
  if (engineReport === undefined || sizesReport === undefined) {
    throw new Error(`pack-image: the jq build reports must be JSON objects; rebuild with ${JQ_BUILD_COMMAND}`)
  }
  const source = jqSourceReport()
  for (const [label, report] of [[sizes, sizesReport], [engine, engineReport]]) {
    const record = recordOf(report.source)
    if (record?.algorithm !== JQ_SOURCE_ALGORITHM || record.fingerprint !== source.fingerprint) {
      throw new Error(
        `pack-image: ${label} does not name this checkout's jq source (${source.fingerprint}); `
        + `the artifact is stale, rebuild it with ${JQ_BUILD_COMMAND}`,
      )
    }
  }
  const actual = sha256File(wasm)
  const bytes = statSync(wasm).size
  const recorded = recordOf(sizesReport.jqWasm)?.sha256
  if (typeof recorded !== 'string') {
    throw new Error(`pack-image: ${sizes} must record jqWasm.sha256; rebuild the engine with ${JQ_BUILD_COMMAND}`)
  }
  if (recorded !== actual) {
    throw new Error(
      `pack-image: ${wasm} has sha256 ${actual}, but ${sizes} records ${recorded}; `
      + `the report describes other bytes, rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  const recordedBytes = recordOf(sizesReport.jqWasm)?.bytes
  if (typeof recordedBytes === 'number' && recordedBytes !== bytes) {
    throw new Error(
      `pack-image: ${wasm} has ${String(bytes)} bytes, but ${sizes} records ${String(recordedBytes)}; `
      + `the report describes other bytes, rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  const engineWasm = recordOf(engineReport.wasm)
  if (typeof engineWasm?.sha256 !== 'string' || engineWasm.sha256 !== actual) {
    throw new Error(
      `pack-image: ${engine} does not describe ${wasm} (sha256 mismatch); rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  if (typeof engineWasm.bytes === 'number' && engineWasm.bytes !== bytes) {
    throw new Error(
      `pack-image: ${engine} records ${String(engineWasm.bytes)} wasm bytes, but ${wasm} has ${String(bytes)}; `
      + `rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  const engineName = engineReport.engine
  const sizesEngine = sizesReport.engine
  if (typeof engineName !== 'string' || engineName.trim() === '') {
    throw new Error(
      `pack-image: ${engine} must record a non-empty engine identity; rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  if (typeof sizesEngine !== 'string' || sizesEngine.trim() === '') {
    throw new Error(
      `pack-image: ${sizes} must record a non-empty engine identity; rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  if (sizesEngine !== engineName) {
    throw new Error(
      `pack-image: ${sizes} and ${engine} name different engines; rebuild with ${JQ_BUILD_COMMAND}`,
    )
  }
  return { engine: engineName, sha256: recorded }
}

/**
 * Stage the verified jq executable and its probe beside Python in the image.
 * @param options - resolved sources and the staging directory.
 * @returns The staged directory, the file facts, and the engine identity.
 */
export function stageJqArtifacts({ wasm, engine, sizes, output }) {
  const reports = readJqBuildReports({ wasm, engine, sizes })
  const bytes = readFileSync(wasm)
  if (bytes.byteLength < 8 || bytes[0] !== 0 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
    throw new Error(`pack-image: ${wasm} is not a WebAssembly module; rebuild with ${JQ_BUILD_COMMAND}`)
  }
  mkdirSync(output, { recursive: true })
  writeFileSync(join(output, JQ_WASM_FILE), bytes)
  writeFileSync(join(output, JQ_ENGINE_FILE), readFileSync(engine))
  return {
    directory: output,
    engine: reports.engine,
    files: [
      { name: JQ_WASM_FILE, bytes: bytes.byteLength },
      { name: JQ_ENGINE_FILE, bytes: statSync(engine).size },
    ],
  }
}

/** sha256 hex of one file, read once. */
function sha256File(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

/** One JSON object, or undefined when the value is not an object. */
function recordOf(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value
    : undefined
}

/**
 * Read the two build reports `build.sh` writes beside the pair and bind them to
 * the exact bytes being staged.
 *
 * `compression.json` is the real interpreter probe (`verify-compression.mjs`):
 * it imported and roundtripped each compression module and wrote a real
 * `tarfile` gzip archive. `sizes.json` records the sha256 of the pair that
 * probe ran against. Neither file is inferred from the stdlib ZIP entry names:
 * a `zlib.py` in the archive proves the wrapper is packed, not that the native
 * zlib extension is linked into `python.wasm`.
 *
 * A missing or malformed report, or a digest that does not match the files on
 * disk, is a stale/foreign artifact. The packer refuses it (naming the build
 * command) instead of staging a report that describes other bytes.
 * @param directory - the `build.sh --out` directory.
 * @param wasm - resolved `python.wasm`.
 * @param stdlib - resolved `python313.zip`.
 * @returns The verified compression capability and the recorded sizes.
 */
export function readPythonBuildReports({ directory, wasm, stdlib }) {
  const compressionPath = join(directory, PYTHON_COMPRESSION_FILE)
  const sizesPath = join(directory, PYTHON_SIZES_FILE)
  const missing = []
  if (!existsSync(compressionPath)) missing.push(PYTHON_COMPRESSION_FILE)
  if (!existsSync(sizesPath)) missing.push(PYTHON_SIZES_FILE)
  if (missing.length > 0) {
    throw new Error(
      `pack-image: the python artifacts in ${directory} have no ${missing.join(' or ')}; `
      + `the compression capability must come from a real interpreter probe. Rebuild the pair with `
      + `${PYTHON_BUILD_COMMAND} and pass that directory to --python.`,
    )
  }
  let compressionReport
  let sizesReport
  try {
    compressionReport = recordOf(JSON.parse(readFileSync(compressionPath, 'utf8')))
    sizesReport = recordOf(JSON.parse(readFileSync(sizesPath, 'utf8')))
  } catch (error) {
    throw new Error(
      `pack-image: the python build reports in ${directory} are not valid JSON `
      + `(${error instanceof Error ? error.message : String(error)}); rebuild the pair with ${PYTHON_BUILD_COMMAND}`,
      { cause: error },
    )
  }
  if (compressionReport === undefined || sizesReport === undefined) {
    throw new Error(
      `pack-image: ${PYTHON_COMPRESSION_FILE} and ${PYTHON_SIZES_FILE} in ${directory} must be JSON objects; `
      + `rebuild the pair with ${PYTHON_BUILD_COMMAND}`,
    )
  }
  const modules = compressionReport.modules
  if (!Array.isArray(modules) || modules.some(name => typeof name !== 'string')) {
    throw new Error(
      `pack-image: ${compressionPath} must carry modules[] as an array of strings; `
      + `the compression capability comes from the build probe, rebuild with ${PYTHON_BUILD_COMMAND}`,
    )
  }
  if (typeof compressionReport.tarfileGzip !== 'boolean') {
    throw new Error(
      `pack-image: ${compressionPath} must carry tarfileGzip as a boolean; `
      + `rebuild the pair with ${PYTHON_BUILD_COMMAND}`,
    )
  }
  if (compressionReport.zlibRuntime !== undefined && typeof compressionReport.zlibRuntime !== 'string') {
    throw new Error(
      `pack-image: ${compressionPath} zlibRuntime must be a string when present; `
      + `rebuild the pair with ${PYTHON_BUILD_COMMAND}`,
    )
  }
  const recordedWasm = recordOf(sizesReport.pythonWasm)?.sha256
  const recordedStdlib = recordOf(sizesReport.pythonStdlibZip)?.sha256
  if (typeof recordedWasm !== 'string' || typeof recordedStdlib !== 'string') {
    throw new Error(
      `pack-image: ${sizesPath} must record pythonWasm.sha256 and pythonStdlibZip.sha256; `
      + `rebuild the pair with ${PYTHON_BUILD_COMMAND}`,
    )
  }
  const actualWasm = sha256File(wasm)
  if (recordedWasm !== actualWasm) {
    throw new Error(
      `pack-image: ${wasm} has sha256 ${actualWasm}, but ${sizesPath} records ${recordedWasm}; `
      + `the compression report describes other bytes. Rebuild the pair with ${PYTHON_BUILD_COMMAND}.`,
    )
  }
  const actualStdlib = sha256File(stdlib)
  if (recordedStdlib !== actualStdlib) {
    throw new Error(
      `pack-image: ${stdlib} has sha256 ${actualStdlib}, but ${sizesPath} records ${recordedStdlib}; `
      + `the compression report describes other bytes. Rebuild the pair with ${PYTHON_BUILD_COMMAND}.`,
    )
  }
  return {
    compression: {
      modules: [...modules].sort(),
      tarfileGzip: compressionReport.tarfileGzip,
      ...compressionReport.zlibRuntime === undefined ? {} : { zlibRuntime: compressionReport.zlibRuntime },
    },
    sizes: {
      pythonWasm: { sha256: recordedWasm },
      pythonStdlibZip: { sha256: recordedStdlib },
    },
  }
}

/**
 * Copy the resolved artifact pair into one staging directory so the packer can
 * mount exactly the pair (no build leftovers) at {@link PYTHON_IMAGE_MOUNT},
 * plus the build-time importable-module probe the capability manifest quotes.
 *
 * The module list comes from the stdlib ZIP entry names (a fact about what
 * `zipimport` can offer). The compression capability comes from the build
 * report, bound to the same bytes by `sizes.json` (see
 * {@link readPythonBuildReports}); the packer never guesses it from the ZIP.
 * @param options - resolved sources and the staging directory.
 * @returns The staged directory, the pair facts `sizes.json` records, and the probe.
 */
export function stagePythonArtifacts({ wasm, stdlib, directory = dirname(wasm), output }) {
  const reports = readPythonBuildReports({ directory, wasm, stdlib })
  mkdirSync(output, { recursive: true })
  const files = []
  for (const [name, source] of [[PYTHON_WASM_FILE, wasm], [PYTHON_STDLIB_FILE, stdlib]]) {
    const bytes = readFileSync(source)
    if (bytes.byteLength === 0) {
      throw new Error(`pack-image: ${source} is empty; rebuild it with ${PYTHON_BUILD_COMMAND}`)
    }
    writeFileSync(join(output, name), bytes)
    files.push({ name, bytes: bytes.byteLength })
  }
  const modules = probePythonModules(readFileSync(stdlib))
  if (modules.length === 0) {
    throw new Error(
      `pack-image: ${stdlib} lists no importable top-level module; `
      + `rebuild the pair with ${PYTHON_BUILD_COMMAND}`,
    )
  }
  const probe = {
    python: PYTHON_VERSION,
    source: PYTHON_STDLIB_FILE,
    modules,
    compression: reports.compression,
  }
  writeFileSync(join(output, PYTHON_MODULES_FILE), `${JSON.stringify(probe, null, 2)}\n`)
  return { directory: output, files, probe }
}

const ZIP_EOCD_SIGNATURE = 0x06054b50
const ZIP_CENTRAL_SIGNATURE = 0x02014b50
const ZIP_LOCAL_NAME_LENGTH_OFFSET = 28

function readU16LE(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8)
}

function readU32LE(bytes, offset) {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0
}

/**
 * List the entries of one ZIP archive from its central directory.
 *
 * The CPython build writes the stdlib with `ZIP_STORED` entries, so the
 * directory is the cheapest complete listing and needs no decompressor. This
 * is a build-time probe of the produced artifact, not a general ZIP library:
 * ZIP64 archives are refused loudly rather than misread.
 * @param {Uint8Array} bytes - the archive bytes.
 * @returns {string[]} entry names in directory order.
 */
export function zipEntryNames(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength < 22) {
    throw new Error('pack-image: the python stdlib is not a ZIP archive')
  }
  const minimum = Math.max(0, bytes.byteLength - 22 - 0xffff)
  let eocd = -1
  for (let offset = bytes.byteLength - 22; offset >= minimum; offset -= 1) {
    if (readU32LE(bytes, offset) !== ZIP_EOCD_SIGNATURE) continue
    if (offset + 22 + readU16LE(bytes, offset + 20) !== bytes.byteLength) continue
    eocd = offset
    break
  }
  if (eocd < 0) throw new Error('pack-image: the python stdlib ZIP has no end-of-central-directory record')
  if (readU16LE(bytes, eocd + 10) === 0xffff || readU32LE(bytes, eocd + 16) === 0xffffffff) {
    throw new Error('pack-image: ZIP64 python stdlib archives are not supported by the module probe')
  }
  const entries = readU16LE(bytes, eocd + 10)
  let at = readU32LE(bytes, eocd + 16)
  const names = []
  for (let index = 0; index < entries; index += 1) {
    if (at + 46 > bytes.byteLength || readU32LE(bytes, at) !== ZIP_CENTRAL_SIGNATURE) {
      throw new Error(`pack-image: the python stdlib ZIP central directory is corrupt at entry ${String(index)}`)
    }
    const nameLength = readU16LE(bytes, at + ZIP_LOCAL_NAME_LENGTH_OFFSET)
    const extraLength = readU16LE(bytes, at + 30)
    const commentLength = readU16LE(bytes, at + 32)
    const nameStart = at + 46
    const nameEnd = nameStart + nameLength
    if (nameEnd > bytes.byteLength) throw new Error('pack-image: the python stdlib ZIP entry name is out of bounds')
    names.push(new TextDecoder().decode(bytes.subarray(nameStart, nameEnd)))
    at = nameEnd + extraLength + commentLength
  }
  return names
}

const PYTHON_MODULE_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/u

/**
 * Derive the top-level modules `zipimport` can serve from stdlib entry names.
 *
 * A top-level `name.py` is a module; a directory is a package only when it
 * carries `__init__.py`. `__pycache__` and non-Python entries are not
 * importable names. The result is sorted so the manifest is byte-stable.
 * @param {readonly string[]} entries - ZIP entry names.
 * @returns {string[]} importable top-level module names, sorted.
 */
export function pythonModulesFromZipEntries(entries) {
  const modules = new Set()
  for (const entry of entries) {
    if (!entry.endsWith('.py')) continue
    const parts = entry.split('/')
    if (parts.some(part => part === '' || part === '__pycache__')) continue
    if (parts.length === 1) {
      const name = parts[0].slice(0, -'.py'.length)
      if (PYTHON_MODULE_NAME.test(name)) modules.add(name)
      continue
    }
    if (parts[parts.length - 1] === '__init__.py' && PYTHON_MODULE_NAME.test(parts[0])) {
      modules.add(parts[0])
    }
  }
  return [...modules].sort()
}

/**
 * Probe one produced `python313.zip` for the modules a guest can import.
 * @param {Uint8Array} stdlibBytes - the archived standard library.
 * @returns {string[]} sorted importable top-level module names.
 */
export function probePythonModules(stdlibBytes) {
  return pythonModulesFromZipEntries(zipEntryNames(stdlibBytes))
}

/**
 * File name for one package export face.
 * @param key - export key (`.`, `./client`).
 * @returns `index`, `client`, ...
 */
function faceName(key) {
  return key === '.' ? 'index' : key.replace(/^\.\//, '').replaceAll('/', '-')
}

/**
 * Package-relative image path for one export face's bundled body.
 *
 * The official packer classifies `lib/client.js` and `lib/client.*.js` as
 * PAGE_ASSETS: browser bundles served to the page's own module system, which
 * intentionally skip the Worker lowering transform. Our `./client` face is not
 * a page asset — it is the Worker-importable exec transport (W1) — so staging
 * it under that name would ship ESM the Worker loader cannot evaluate. Naming
 * the staged body `lib/client-module.js` keeps it below `lib/` while staying
 * out of the page-asset glob; the package's `exports` entry carries the new
 * path, so importers are unaffected.
 * @param key - export key (`.`, `./client`).
 * @returns Staged path relative to the package root.
 */
export function stagedFacePath(key) {
  const name = faceName(key)
  return /^client(?:\.[^/]*)?$/.test(name)
    ? `lib/${name.replace(/^client/, 'client-module')}.js`
    : `lib/${name}.js`
}

/**
 * Check the seam that carries the Worker-side `sharp` replacement.
 *
 * The image deliberately omits the native `sharp` package because the runtime
 * lists it in `REPLACED_EXTERNAL_PACKAGES` and serves a stub from
 * `MODULE_PROXIES`. Our layer replaces that stub in the Worker's static-module
 * table, so both facts must still hold in the pinned checkout; otherwise the
 * shim would be unreachable and every image decode would regress to
 * notImplementedFail. This is a contract check, not a compatibility shim.
 * @param runtime - the checkout's webworker-runtime namespace.
 * @returns The recorded replacement facts.
 * @throws {Error} when the runtime no longer replaces `sharp`.
 */
export function assertSharpReplacement(runtime) {
  const replaced = Array.isArray(runtime?.REPLACED_EXTERNAL_PACKAGES) ? runtime.REPLACED_EXTERNAL_PACKAGES : []
  if (!replaced.includes(SHARP_MODULE_SPECIFIER)) {
    throw new Error(
      `pack-image: the pinned runtime no longer lists "${SHARP_MODULE_SPECIFIER}" in REPLACED_EXTERNAL_PACKAGES; `
      + 'the Worker-side sharp shim would be unreachable and image reads would regress to notImplementedFail',
    )
  }
  const proxy = runtime?.MODULE_PROXIES?.[SHARP_MODULE_SPECIFIER]
  if (typeof proxy !== 'string' || proxy === '') {
    throw new Error(
      `pack-image: the pinned runtime has no MODULE_PROXIES entry for "${SHARP_MODULE_SPECIFIER}"; `
      + 'the module-replacement seam the Worker shim overrides is gone',
    )
  }
  return {
    specifier: SHARP_MODULE_SPECIFIER,
    runtime_proxy: proxy,
    shim: SHARP_SHIM_MODULE,
    marker: SHARP_SHIM_MARKER,
  }
}

/**
 * Build the Worker entry bundle in check mode and prove it carries the shim.
 *
 * `worker-entry/build.mjs` already fails when the shim marker is absent; this
 * wrapper turns that failure into an image-build failure, so a phone image can
 * never be packed beside a Worker bundle whose `require('sharp')` would still
 * reach the runtime's notImplementedFail stub.
 * @param checkout - verified checkout directory.
 * @returns The check's one-line summary.
 */
export function verifyWorkerBundleShim(checkout) {
  const buildScript = join(PLUGIN_ROOT, 'worker-entry', 'build.mjs')
  if (!existsSync(buildScript)) throw new Error(`pack-image: the Worker entry build script is missing at ${SHARP_SHIM_MODULE}`)
  const result = spawnSync(process.execPath, [buildScript, '--check'], {
    cwd: PLUGIN_ROOT,
    encoding: 'utf8',
    timeout: 120_000,
    env: { ...process.env, PDSH_DSH_CHECKOUT: checkout },
  })
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`.trim()
  if (result.status !== 0) {
    throw new Error(`pack-image: the Worker entry bundle does not carry the sharp shim: ${output === '' ? `exit ${String(result.status)}` : output}`)
  }
  if (!output.includes(SHARP_SHIM_MARKER)) {
    throw new Error(`pack-image: the Worker entry bundle check did not report the sharp shim marker ${SHARP_SHIM_MARKER}`)
  }
  return output.split('\n').at(-1) ?? ''
}

/**
 * Import the checkout's own packer, app-boot, and runtime build products.
 * @param checkout - verified checkout directory.
 * @returns The three module namespaces.
 */
async function importCheckout(checkout) {
  const packer = await import(pathToFileURL(join(checkout, 'packages/experimental/webworker-packer/lib/index.js')).href)
  const appBoot = await import(pathToFileURL(join(checkout, 'packages/boot/app-boot/lib/index.js')).href)
  // The runtime's lowering oracle lets the wrapper reject an export face the
  // packer left as ESM (the PAGE_ASSETS failure mode) instead of shipping it.
  const runtime = await import(pathToFileURL(join(checkout, 'packages/experimental/webworker-runtime/lib/index.js')).href)
  return { packer, appBoot, runtime }
}

/**
 * Resolve esbuild from this repository's existing development dependencies.
 * @returns The esbuild module namespace.
 */
async function importEsbuild() {
  return await import('esbuild')
}

/** TypeScript source file an export condition may name. */
const PAGE_CLIENT_SOURCE = /\.(?:[cm]?ts|tsx)$/
/** Type declaration file; never a page-client entry to build. */
const TYPE_DECLARATION = /\.d\.[cm]?ts$/

/**
 * A package declares a browser bundle (`dsh.client.platform === 'web'`) and
 * exports its entry as `./client`. Such a face belongs to the page's module
 * system, never to the Worker lowering pass.
 *
 * A source-only phone package exports `./client` as its `.ts` entry. The
 * official DSH client packages instead point `default` at the built
 * `lib/client.js` the page module table serves and keep the TypeScript entry
 * under `types`; the staged manifest always names `./lib/client.js`, so the
 * bundle is built from the source condition in that form. Both resolve the
 * same page asset; neither ships a literal wildcard path into the image.
 * @param manifest - package manifest.
 * @returns the client source target, or undefined when the package has no page face.
 */
export function pageClientTarget(manifest) {
  const declaration = manifest?.dsh?.client
  if (declaration === undefined || declaration === null || declaration.platform !== 'web') return undefined
  const client = manifest.exports?.['./client']
  const targets = typeof client === 'string'
    ? [client]
    : client !== null && typeof client === 'object'
      ? [client.default, client.types].filter(target => typeof target === 'string')
      : []
  if (targets.length === 0) {
    throw new Error(`${manifest.name ?? 'package'}: dsh.client is declared but exports["./client"] has no string target`)
  }
  for (const target of targets) {
    if (PAGE_CLIENT_SOURCE.test(target) && !TYPE_DECLARATION.test(target)) return target
  }
  return targets[0]
}

/**
 * Module-table specifiers one page client keeps as a `require` call.
 * @param manifest - package manifest with `dsh.client`.
 * @returns exact package names and their subpath patterns.
 */
function clientExternals(manifest) {
  const declaration = manifest.dsh?.client ?? {}
  const names = new Set([
    ...CLIENT_PLATFORM_EXTERNALS,
    ...optionalStringArray(manifest.name, 'dsh.client.inject', declaration.inject),
    ...optionalStringArray(manifest.name, 'dsh.client.external', declaration.external),
  ])
  const patterns = []
  for (const name of names) {
    patterns.push(name, `${name}/*`)
  }
  return { names, patterns }
}

/** Read one manifest list of strings without inventing entries. */
function optionalStringArray(subject, field, value) {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.some(entry => typeof entry !== 'string')) {
    throw new Error(`${subject}: ${field} must be a string array`)
  }
  return value
}

/** True when a specifier is one of the requested module-table packages. */
function isRequestedSpecifier(specifier, names) {
  if (names.has(specifier)) return true
  for (const name of names) {
    if (specifier.startsWith(`${name}/`)) return true
  }
  return false
}

/**
 * esbuild plugin for a page client face: requested module-table rows stay
 * external, browser-safe wire layers inline, and every other cross-plugin value
 * import is refused instead of silently creating a second runtime instance.
 * @param names - requested package names.
 * @param packageName - package name for diagnostics.
 * @returns the esbuild plugin.
 */
function clientPurityPlugin(names, packageName) {
  return {
    name: 'pdsh-client-purity',
    setup(build) {
      build.onResolve({ filter: /^@deepseek-ai\// }, args => {
        if (isRequestedSpecifier(args.path, names)) return { path: args.path, external: true }
        if (CLIENT_INLINE_SAFE.test(args.path)) return undefined
        throw new Error(
          `pack-image: ${packageName} client imports ${args.path}, which is neither a module-table row `
          + 'nor an inline-safe wire layer; declare it in dsh.client and keep the shared instance',
        )
      })
    },
  }
}

/**
 * esbuild plugin that turns a `.module.css` import into the DSH client's
 * class-map plus one plugin-owned style element. The page asset carries its own
 * stylesheet bytes; no separate CSS route is needed.
 * @param packageName - package name used for the stable class prefix.
 * @returns the esbuild plugin.
 */
function clientCssModulesPlugin(packageName) {
  const namespace = 'pdsh-client-css-module'
  return {
    name: 'pdsh-client-css-modules',
    setup(build) {
      build.onResolve({ filter: /\.module\.css$/ }, args => {
        const base = args.importer === '' ? process.cwd() : dirname(args.importer)
        return { path: resolve(base, args.path), namespace }
      })
      build.onLoad({ filter: /.*/, namespace }, args => {
        const css = readFileSync(args.path, 'utf8')
        const prefix = createHash('sha256').update(`${packageName}\0${args.path}`).digest('hex').slice(0, 8)
        const classMap = {}
        const renamed = css.replace(/(^|[\s,{>+~:(])\.(-?[_a-zA-Z][\w-]*)/g, (match, lead, name) => {
          classMap[name] = `${prefix}_${name}`
          return `${lead}.${classMap[name]}`
        })
        const relative = args.path.slice(resolve(pluginRootForCss(args.path)).length).replace(/^\/+/, '')
        const tagId = `${packageName}/${relative}`
        const contents = [
          `const css = ${JSON.stringify(renamed)};`,
          `const tagId = ${JSON.stringify(tagId)};`,
          `if (typeof document !== 'undefined' && document.querySelector(${JSON.stringify(`style[data-plugin-css="${tagId}"]`)}) === null) {`,
          '  const tag = document.createElement(\'style\');',
          `  tag.dataset.plugin = ${JSON.stringify(packageName)};`,
          '  tag.dataset.pluginCss = tagId;',
          '  tag.textContent = css;',
          '  document.head.appendChild(tag);',
          '}',
          `export default ${JSON.stringify(classMap)};`,
          '',
        ].join('\n')
        return { contents, loader: 'js', resolveDir: dirname(args.path) }
      })
    },
  }
}

/** Best-effort package root for the CSS module's tag id (the package directory). */
function pluginRootForCss(file) {
  const marker = `${join('node_modules', '')}`
  const index = file.lastIndexOf(marker)
  return index < 0 ? dirname(file) : dirname(file.slice(0, index))
}

/**
 * Bundle one page client face in the format the DSH module table consumes:
 * `window.__ModuleLoader__.load({ id, factory })`, with React and the requested
 * module rows resolved through the injected `require`. This is the same
 * artifact contract the pinned checkout's client build emits; the body is never
 * sent through the Worker lowering pass.
 * @param options - build inputs.
 * @param options.esbuild - esbuild module.
 * @param options.manifest - source package manifest.
 * @param options.entry - package-relative client source.
 * @param options.directory - source package directory.
 * @param options.output - staging directory.
 */
async function buildPageClient({ esbuild, manifest, entry, directory, output }) {
  const { names, patterns } = clientExternals(manifest)
  const outfile = join(output, 'lib', 'client.js')
  const built = await esbuild.build({
    entryPoints: [join(directory, entry)],
    outfile,
    bundle: true,
    format: 'cjs',
    platform: 'browser',
    target: 'es2022',
    jsx: 'automatic',
    jsxImportSource: 'react',
    external: patterns,
    banner: {
      js: `window.__ModuleLoader__.load({ id: ${JSON.stringify(manifest.name)}, factory: (require) => {\n`
        + 'var module = { exports: {} }; var exports = module.exports;',
    },
    footer: { js: 'return module.exports; } });' },
    plugins: [clientPurityPlugin(names, manifest.name), clientCssModulesPlugin(manifest.name)],
    absWorkingDir: directory,
    sourcemap: false,
    legalComments: 'none',
    logLevel: 'silent',
    metafile: true,
  })
  const artifact = statSync(outfile)
  if (artifact.size === 0) throw new Error(`pack-image: ${manifest.name} client bundle is empty`)
  const bundled = new Set()
  for (const input of Object.keys(built.metafile.inputs)) {
    const segments = [...input.matchAll(/node_modules\/((?:@[^/]+\/)?[^/]+)/g)]
    if (segments.length > 0) bundled.add(segments[segments.length - 1][1])
  }
  return { path: './lib/client.js', bundled }
}

/**
 * esbuild plugin that resolves a DSH source face from the verified checkout.
 * The published package has no `src/`, so a phone host package that imports
 * the official writer must bundle it from the same pinned tree.
 * @param checkout - verified checkout directory, or undefined for tests.
 * @returns the esbuild plugin.
 */
function checkoutSourcePlugin(checkout) {
  return {
    name: 'pdsh-checkout-source',
    setup(build) {
      build.onResolve({ filter: /^@deepseek-ai\/dsh-[^/]+\/src\/[^/]+\.ts$/ }, (args) => {
        const face = CHECKOUT_SOURCE_FACES[args.path]
        if (face === undefined) return undefined
        if (checkout === undefined || checkout === '') {
          throw new Error(`pack-image: the pinned checkout is required to bundle ${args.path}`)
        }
        return { path: join(checkout, face) }
      })
      // The Worker is a WebKit/browser-like runtime: the Node build of `yaml`
      // imports `node:process`, which the runtime does not proxy. Its browser
      // build is the same parser without that module edge.
      build.onResolve({ filter: /^yaml$/ }, () => {
        try {
          const manifest = createRequire(join(PLUGIN_ROOT, 'package.json')).resolve('yaml/package.json')
          return { path: join(dirname(manifest), 'browser/index.js') }
        } catch {
          return undefined
        }
      })
    },
  }
}

/**
 * Bundle and stage one plugin package so the packer's workspace view can ship
 * it without source or dist trees.
 * @param options - staging inputs.
 * @param options.esbuild - esbuild module.
 * @param options.package - repository package name and directory.
 * @param options.output - empty staging directory.
 * @param options.checkout - verified checkout directory for source-only DSH faces.
 * @returns Staged manifest, staged directory, the external image packages the
 * bundles still import (`requested`) and the npm packages bundled into them
 * (`bundled`, for the third-party notice) and the node: builtins they request
 * (`builtins`, checked against the runtime's module proxies).
 */
export async function stagePlugin({ esbuild, package: plugin, output, checkout }) {
  const source = readJson(join(plugin.directory, 'package.json'))
  const staged = structuredClone(source)
  const requested = new Set()
  const bundled = new Set()
  const builtins = new Set()
  const clientSource = pageClientTarget(source)
  /** `node:` specifier → member names the staged files import (`*` for a namespace import). */
  const builtinMembers = new Map()
  mkdirSync(join(output, 'lib'), { recursive: true })

  /** Code faces to bundle: staged path relative to the package root → source file. */
  const faces = new Map()

  /**
   * Rewrite one export target: a data file is copied as it is, a code face is
   * recorded for the single Worker bundling pass below. A page client face is
   * named `lib/client.js` (the packer's PAGE_ASSETS path) and built separately.
   * @param key - owning export key.
   * @param target - export target value.
   * @returns Rewritten target value.
   */
  const rewriteTarget = (key, target) => {
    if (key === './client' && clientSource !== undefined) return './lib/client.js'
    if (typeof target === 'string') {
      if (!CODE_TARGET.test(target)) {
        const sourceFile = join(plugin.directory, target)
        const stagedFile = join(output, target)
        mkdirSync(dirname(stagedFile), { recursive: true })
        writeFileSync(stagedFile, readFileSync(sourceFile))
        return target
      }
      const relative = stagedFacePath(key)
      faces.set(relative, join(plugin.directory, target))
      return `./${relative}`
    }
    if (Array.isArray(target)) return target.map(value => rewriteTarget(key, value))
    if (target !== null && typeof target === 'object') {
      return Object.fromEntries(Object.entries(target).map(([condition, value]) => [condition, rewriteTarget(key, value)]))
    }
    return target
  }

  if (staged.exports !== undefined) {
    staged.exports = Object.fromEntries(Object.entries(staged.exports).map(([key, target]) => [key, rewriteTarget(key, target)]))
  }
  if (typeof staged.main === 'string' && CODE_TARGET.test(staged.main)) {
    if (!staged.exports?.['.']) faces.set('lib/index.js', join(plugin.directory, staged.main))
    staged.main = './lib/index.js'
  }

  if (faces.size > 0) {
    // One build for every face: the package's npm dependencies are bundled in
    // (the packer resolves packages from the pinned checkout only) and modules
    // shared by several faces land once, in lib/chunks, imported by relative
    // path; only node: builtins and the two image scopes stay bare.
    const built = await esbuild.build({
      entryPoints: [...faces].map(([relative, file]) => ({ in: file, out: relative.replace(/\.js$/, '') })),
      outdir: output,
      bundle: true,
      splitting: true,
      chunkNames: 'lib/chunks/[name]-[hash]',
      format: 'esm',
      platform: 'node',
      target: 'node22',
      external: [...BUNDLE_EXTERNAL],
      plugins: [nodeBuiltinPrefix, checkoutSourcePlugin(checkout)],
      // Relative debugger comments keep the staged bytes independent of the
      // temporary staging path.
      absWorkingDir: plugin.directory,
      sourcemap: false,
      legalComments: 'none',
      logLevel: 'silent',
      metafile: true,
    })
    // The bundles' remaining bare imports are exactly the packages the image
    // must carry; anything else would be unresolvable inside the Worker.
    for (const input of Object.keys(built.metafile.inputs)) {
      // The innermost node_modules segment names the package: a nested install
      // (node_modules/just-bash/node_modules/diff) is `diff`, not `just-bash`.
      const segments = [...input.matchAll(/node_modules\/((?:@[^/]+\/)?[^/]+)/g)]
      if (segments.length > 0) bundled.add(segments[segments.length - 1][1])
    }
    for (const file of Object.keys(built.metafile.outputs)) {
      if (!/\.js$/.test(file)) continue
      for (const [moduleName, names] of builtinImports(readFileSync(join(plugin.directory, file), 'utf8'))) {
        if (!builtinMembers.has(moduleName)) builtinMembers.set(moduleName, new Set())
        for (const name of names) builtinMembers.get(moduleName).add(name)
      }
    }
    for (const info of Object.values(built.metafile.outputs)) {
      for (const imported of info.imports) {
        if (!imported.external) continue
        if (imported.path.startsWith('node:')) {
          builtins.add(imported.path)
          continue
        }
        if (!isImagePackage(imported.path)) {
          throw new Error(`pack-image: ${plugin.name} still imports ${imported.path} after bundling; the Worker image has no copy of it`)
        }
        requested.add(packageNameOf(imported.path))
      }
    }
  }

  if (clientSource !== undefined) {
    const client = await buildPageClient({
      esbuild,
      manifest: source,
      entry: clientSource,
      directory: plugin.directory,
      output,
    })
    // `@deepseek-ai/*` inlined wire layers are DSH packages from the pinned
    // checkout, not npm third-party entries for the notice table.
    for (const name of client.bundled) if (!isImagePackage(name)) bundled.add(name)
  }

  // A bundled npm package is no longer a dependency of the staged manifest;
  // left in place, the packer would look for it in the checkout and fail.
  for (const field of ['dependencies', 'peerDependencies', 'optionalDependencies']) {
    if (staged[field] === undefined) continue
    const kept = Object.fromEntries(Object.entries(staged[field]).filter(([name]) => isImagePackage(name)))
    if (Object.keys(kept).length > 0) staged[field] = kept
    else delete staged[field]
  }
  if (clientSource !== undefined && staged.peerDependencies !== undefined) {
    // A page client's `@deepseek-ai/dsh-client-*` peers are module-table rows
    // the browser loads; they are not Worker runtime faces. Keeping them on the
    // staged manifest would make the image packer walk a client-only package as
    // a Worker root and fail on its browser dependencies.
    const kept = Object.fromEntries(Object.entries(staged.peerDependencies)
      .filter(([name]) => !name.startsWith('@deepseek-ai/dsh-client-')))
    if (Object.keys(kept).length > 0) staged.peerDependencies = kept
    else delete staged.peerDependencies
  }
  // The staged tree is exactly what we wrote; a publish allowlist from the
  // source package could only hide it again.
  delete staged.files
  delete staged.scripts
  writeFileSync(join(output, 'package.json'), `${JSON.stringify(staged, null, 2)}\n`)
  return { directory: output, manifest: staged, requested, bundled, builtins, builtinMembers }
}

/**
 * Preset declarations the shipped Web app adds after its own patch. The phone
 * image deliberately does not materialize `dsh-web-app`, so the packer applies
 * these files explicitly; the agent-preset registry then lists a real roster
 * instead of an empty one. The same order is the Web bundle's own order.
 */
export const AGENT_PRESET_PATCH_FILES = Object.freeze([
  'packages/bundle/web-app/presets/standard.patch.yml',
  'packages/bundle/web-app/presets/ptc.patch.yml',
  'packages/bundle/web-app/presets/minimal.patch.yml',
  'packages/bundle/web-app/presets/cordis.patch.yml',
])

/**
 * Load the worker profile patch through DSH's own loader, preserving `!!js`
 * expression values exactly as a profile boot would read them. When the
 * verified checkout is supplied, append the shipped Web-app agent-preset
 * declarations so the image's feature-admin roster is the official one.
 * @param appBoot - checkout app-boot module.
 * @param file - patch file.
 * @param checkout - verified checkout directory; required by the image build.
 * @returns Loader patch rows.
 */
export function loadWorkerHomePatch(appBoot, file = WORKER_PROFILE_PATCH, checkout) {
  const rows = appBoot.loadOverlayPatches('pdsh-pack-image', file)
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error(`worker profile patch ${file} produced no rows`)
  }
  if (checkout !== undefined && checkout !== '') {
    for (const preset of AGENT_PRESET_PATCH_FILES) {
      const presetFile = join(checkout, preset)
      if (!existsSync(presetFile)) {
        throw new Error(`pack-image: the checkout has no agent-preset patch ${presetFile}`)
      }
      const presetRows = appBoot.loadOverlayPatches('pdsh-pack-image', presetFile)
      if (!Array.isArray(presetRows) || presetRows.length === 0) {
        throw new Error(`pack-image: agent-preset patch ${presetFile} produced no rows`)
      }
      rows.push(...presetRows)
    }
  }
  return rows
}

/**
 * Collect every package name a set of loader rows requests, including nested
 * insert lists and group row lists.
 * @param collectModuleNames - checkout packer helper.
 * @param rows - loader rows.
 * @returns Package names.
 */
export function rosterNames(collectModuleNames, rows) {
  const names = new Set()
  collectModuleNames(rows, names)
  return names
}

/**
 * Package names a preset declaration's `config.plugins` list requests.
 *
 * DSH's packer collector recurses `insert` lists and group `config` arrays but
 * stops at a plain object, while an `@deepseek-ai/dsh-agent-preset` row carries
 * its plugin rows under `config.plugins`. The official Web app relies on its
 * bundle roster to carry those packages; the phone image applies the preset
 * files itself, so it must collect the same names explicitly or the registry
 * resolves a missing package at boot.
 * @param collectModuleNames - checkout packer helper.
 * @param rows - loader rows.
 * @returns package names from every preset `config.plugins` list.
 */
export function presetRosterNames(collectModuleNames, rows) {
  const names = new Set()
  const visitRows = list => {
    if (!Array.isArray(list)) return
    for (const row of list) {
      if (row === null || typeof row !== 'object') continue
      const config = row.config
      if (config !== null && typeof config === 'object' && !Array.isArray(config)
          && Array.isArray(config.plugins)) {
        collectModuleNames(config.plugins, names)
      }
      visitRows(row.insert)
    }
  }
  visitRows(rows)
  return names
}

/**
 * Find one inserted/top-level row by id.
 * @param rows - loader rows.
 * @param id - row id.
 * @returns The row, if present.
 */
export function findRow(rows, id) {
  for (const row of rows) {
    if (row?.id === id) return row
    const nested = Array.isArray(row?.insert) ? findRow(row.insert, id) : undefined
    if (nested !== undefined) return nested
    if (row?.group === true && Array.isArray(row?.config)) {
      const grouped = findRow(row.config, id)
      if (grouped !== undefined) return grouped
    }
  }
  return undefined
}

/** Dual-face package whose node half composes the browser boot graph. */
export const CLIENT_MODULES_PACKAGE = '@deepseek-ai/dsh-client-modules'
/** Loader row id of the module-system host half. */
export const CLIENT_MODULES_ROW = 'modules'
/** Official browser transport package. */
export const CONNECTION_PACKAGE = '@deepseek-ai/dsh-client-connection'
/**
 * Loader row id of the browser transport row. It is not the global
 * `connection` id: app-boot requires that id to be active, while this row's
 * host half must stay pending because phone-surface owns `ctx.connection`.
 */
export const CONNECTION_ROW = 'connection-browser'
/** The only host row allowed to provide `ctx.connection` and `/api`. */
export const PHONE_SURFACE_ROW = 'phone-surface'
/** Credential/account rows that must stay disabled on the phone path. */
export const DISABLED_ACCOUNT_ROWS = Object.freeze(['credentials', 'authorization', 'deepseek-account'])

/**
 * Whether a loader row is disabled. A conditional `!!js` expression is opaque
 * at pack time; treating it as disabled keeps every structural assertion on
 * rows whose state is actually known.
 * @param row - loader row.
 * @returns true when the row cannot run unconditionally.
 */
export function rowDisabled(row) {
  return row?.disabled !== undefined && row?.disabled !== false
}

/**
 * Flatten loader rows, walking `insert` lists and nested group row lists.
 * @param rows - loader rows.
 * @returns every row in declaration order.
 */
export function flattenRows(rows) {
  const flat = []
  const visit = (list) => {
    if (!Array.isArray(list)) return
    for (const row of list) {
      if (row === null || typeof row !== 'object') continue
      flat.push(row)
      if (Array.isArray(row.insert)) visit(row.insert)
      if (row.group === true && Array.isArray(row.config)) visit(row.config)
    }
  }
  visit(rows)
  return flat
}

/**
 * Compose the base roster and the home patch the way the Loader applies a
 * patch layer: same-id rows replace base rows, `insert` rows append.
 * @param baseRows - `dsh-base` patch rows.
 * @param homePatch - image home patch rows.
 * @returns one flat row list.
 */
export function composeProfileRows(baseRows, homePatch) {
  const rows = flattenRows(baseRows).filter(row => !Array.isArray(row.insert))
  const positions = new Map(rows.map((row, index) => [row.id, index]))
  for (const row of flattenRows(homePatch)) {
    if (Array.isArray(row.insert) || typeof row.id !== 'string') continue
    const at = positions.get(row.id)
    if (at === undefined) {
      positions.set(row.id, rows.length)
      rows.push(row)
    } else {
      rows[at] = row
    }
  }
  return rows
}

/**
 * Resolve a package's browser bundle from its `dsh.client` declaration.
 * The modules host half reads `exports["./client"]`'s string form or its
 * `default` condition; this mirrors that rule so the assertion cannot accept a
 * different (for example Node-only) file than the browser actually loads.
 * @param manifest - package manifest.
 * @param packageName - package name used in errors.
 * @returns package-relative client target, or undefined when not a Web client.
 * @throws {Error} when the declaration is malformed.
 */
export function clientExportTarget(manifest, packageName) {
  const declaration = manifest?.dsh?.client
  if (declaration === undefined || declaration === null) return undefined
  if (declaration.platform !== 'web') return undefined
  const client = manifest.exports?.['./client']
  if (typeof client === 'string') return client
  if (client !== null && typeof client === 'object' && typeof client.default === 'string') return client.default
  throw new Error(`pack-image: ${packageName} declares dsh.client but exports no usable "./client" bundle`)
}

/**
 * Assert every enabled `dsh.client` row's browser bundle is actually in the
 * packed image and still classified as a PAGE_ASSET (browser bundle, not a
 * Worker-lowered face).
 * @param options - image inputs.
 * @param options.rows - composed loader rows.
 * @param options.files - packed image file map.
 * @param options.pageBundles - image paths the packer classified as page assets.
 * @returns one fact per client row.
 * @throws {Error} when a bundle is absent, empty, Node-only, or lowered.
 */
export function assertClientBundleFiles({ rows, files, pageBundles }) {
  const decoder = new TextDecoder()
  const facts = []
  for (const row of rows) {
    if (rowDisabled(row) || typeof row.name !== 'string' || row.name.startsWith('.') || row.name.startsWith('cordis:')) continue
    const packageName = packageNameOf(row.name)
    if (!packageName.startsWith('@deepseek-ai/') && !packageName.startsWith('@phone-dsh/')) continue
    const manifestPath = `node_modules/${packageName}/package.json`
    const manifestBytes = files[manifestPath]
    if (manifestBytes === undefined) {
      throw new Error(`pack-image: row ${String(row.id)} names ${packageName}, but ${manifestPath} is missing from the image`)
    }
    let manifest
    try {
      manifest = JSON.parse(decoder.decode(manifestBytes))
    } catch (reason) {
      throw new Error(`pack-image: cannot read ${manifestPath}: ${reason instanceof Error ? reason.message : String(reason)}`)
    }
    const target = clientExportTarget(manifest, packageName)
    if (target === undefined) continue
    if (/\/client\.node\.[cm]?js$/.test(target)) {
      throw new Error(`pack-image: ${packageName} resolves its browser client to Node bundle ${target}`)
    }
    const imagePath = exportImagePath(packageName, target)
    const bytes = files[imagePath]
    if (bytes === undefined || bytes.byteLength === 0) {
      throw new Error(`pack-image: ${packageName}'s dsh.client bundle ${imagePath} is missing or empty in the image`)
    }
    if (!pageBundles.has(imagePath)) {
      throw new Error(
        `pack-image: ${packageName}'s dsh.client bundle ${imagePath} is not a page asset; `
        + 'the browser would receive a Worker-lowered body',
      )
    }
    facts.push({ id: row.id, package: packageName, path: imagePath, bytes: bytes.byteLength })
  }
  if (!facts.some(fact => fact.package === CLIENT_MODULES_PACKAGE)) {
    throw new Error(`pack-image: the browser roster has no ${CLIENT_MODULES_PACKAGE} row; window.__DSH_BOOT__ cannot be composed`)
  }
  return facts
}

/**
 * Assert the phone connection contract: the official connection row is present
 * for its browser bundle only, its host half cannot activate, and the account
 * rows stay disabled so `phone-surface` remains the one `ctx.connection` and
 * `/api` owner.
 * @param rows - composed loader rows.
 * @returns the facts recorded in `sizes.json`.
 * @throws {Error} when the connection host half could activate or an account
 * row is enabled.
 */
export function assertConnectionContract(rows) {
  const requiredHostRow = findRow(rows, 'connection')
  if (requiredHostRow !== undefined && !rowDisabled(requiredHostRow)) {
    throw new Error(
      'pack-image: an enabled row uses the global "connection" id, which app-boot requires to activate; '
      + 'the browser-only transport row must use connection-browser so its host half can stay pending',
    )
  }
  const connection = findRow(rows, CONNECTION_ROW)
  if (connection === undefined) throw new Error(`pack-image: no ${CONNECTION_ROW} row; the browser has no transport bundle`)
  if (rowDisabled(connection)) throw new Error('pack-image: the connection-browser row is disabled; its browser bundle would not load')
  if (connection.name !== CONNECTION_PACKAGE) {
    throw new Error(`pack-image: row ${CONNECTION_ROW} must name ${CONNECTION_PACKAGE}`)
  }
  const injected = Array.isArray(connection.inject) ? connection.inject : []
  if (!injected.includes('webStartup')) {
    throw new Error(
      'pack-image: the connection row must inject webStartup; without that gate its host half '
      + 'could start and register a second /api beside phone-surface',
    )
  }
  for (const row of flattenRows(rows)) {
    const name = typeof row.name === 'string' ? row.name : ''
    if (row.id === 'web-startup' || name === '@deepseek-ai/dsh-web-app' || name === '@deepseek-ai/dsh-web-app/startup') {
      if (!rowDisabled(row)) {
        throw new Error('pack-image: a web-app startup row would provide webStartup and activate the connection host half')
      }
    }
  }
  for (const id of DISABLED_ACCOUNT_ROWS) {
    const row = findRow(rows, id)
    if (row === undefined) throw new Error(`pack-image: the ${id} row is missing; its disabled state cannot be verified`)
    if (!rowDisabled(row)) throw new Error(`pack-image: the ${id} row must stay disabled on the phone path`)
  }
  const accountController = findRow(rows, 'account-controller')
  if (accountController !== undefined && !rowDisabled(accountController)) {
    throw new Error('pack-image: account-controller must stay disabled while deepseek-account is disabled')
  }
  const surface = findRow(rows, PHONE_SURFACE_ROW)
  if (surface === undefined || rowDisabled(surface)) {
    throw new Error(`pack-image: ${PHONE_SURFACE_ROW} must be the enabled host ctx.connection and /api carrier`)
  }
  return {
    row: CONNECTION_ROW,
    package: CONNECTION_PACKAGE,
    host: 'pending',
    pending_services: [...injected, ...(injected.includes('credentials') ? [] : ['credentials'])],
    phone_surface: PHONE_SURFACE_ROW,
    disabled: [...DISABLED_ACCOUNT_ROWS],
  }
}

/**
 * Compose the real `window.__DSH_BOOT__` graph from the packed image bytes.
 *
 * The assertion uses DSH's own client-modules node half (from the verified
 * checkout) and a temporary filesystem holding only the image's package
 * manifests and browser bundles. It therefore proves the exact bytes the image
 * ships are enough for the module system to compose the boot graph, not merely
 * that a row name appears in the profile.
 * @param options - graph inputs.
 * @param options.checkout - verified checkout directory.
 * @param options.clientFacts - output of {@link assertClientBundleFiles}.
 * @param options.files - packed image file map.
 * @returns boot graph facts.
 */
export async function assertBootGraph({ checkout, clientFacts, files }) {
  const modulesManifest = join(checkout, 'packages/client/modules/package.json')
  let modulesEntry
  let cordisEntry
  try {
    const requireFromModules = createRequire(modulesManifest)
    modulesEntry = requireFromModules.resolve(CLIENT_MODULES_PACKAGE)
    cordisEntry = requireFromModules.resolve('@deepseek-ai/cordis')
  } catch (reason) {
    throw new Error(
      'pack-image: cannot load the checkout\'s client-modules node half; build packages/client/modules '
      + `(pnpm build) before packing: ${reason instanceof Error ? reason.message : String(reason)}`,
    )
  }
  const { ClientModuleRegistry, bootInjections } = await import(pathToFileURL(modulesEntry).href)
  const { Context } = await import(pathToFileURL(cordisEntry).href)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-boot-graph-'))
  try {
    const packages = new Map()
    for (const fact of clientFacts) {
      if (packages.has(fact.package)) continue
      packages.set(fact.package, fact)
      const manifestPath = `node_modules/${fact.package}/package.json`
      const manifest = files[manifestPath]
      if (manifest === undefined) throw new Error(`pack-image: ${manifestPath} disappeared before boot composition`)
      writeTreeFile(root, manifestPath, manifest)
      const bundle = files[fact.path]
      if (bundle === undefined) throw new Error(`pack-image: ${fact.path} disappeared before boot composition`)
      writeTreeFile(root, fact.path, bundle)
    }
    const ctx = new Context()
    ctx.baseUrl = `${pathToFileURL(root).href}/`
    const entries = [...packages.values()].map(fact => ({
      options: { name: fact.package },
      fiber: {},
      disabled: false,
      parent: { tree: { ctx: { baseUrl: ctx.baseUrl } } },
    }))
    ctx.provide('loader', {
      *entries() {
        yield* entries
      },
    })
    ctx.provide('webServer', {
      port: 0,
      register: () => () => {},
      tapIndex: () => () => {},
    })
    const service = new ClientModuleRegistry(ctx)
    const graph = service.graph()
    const boot = bootInjections(graph).find(injection => injection.kind === 'global' && injection.name === '__DSH_BOOT__')
    if (boot === undefined) throw new Error('pack-image: the modules host half produced no __DSH_BOOT__ injection')
    const composed = new Set(graph.entries.map(entry => entry.id))
    const missing = [...packages.keys()].filter(name => !composed.has(name))
    if (missing.length > 0) {
      throw new Error(`pack-image: window.__DSH_BOOT__ is missing client rows: ${missing.join(', ')}`)
    }
    await ctx.fiber.dispose()
    return {
      entries: [...composed],
      batches: graph.batches.length,
      __DSH_BOOT__: true,
      release: graph.release,
    }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

/**
 * Write one image-relative file under a temporary root.
 * @param root - temporary directory.
 * @param relative - `/`-separated image path.
 * @param bytes - file body.
 */
function writeTreeFile(root, relative, bytes) {
  const target = join(root, ...relative.split('/'))
  mkdirSync(dirname(target), { recursive: true })
  writeFileSync(target, bytes)
}

/**
 * The upstream package that injects `$DSH_HOME/AGENTS.md` into a request.
 *
 * The G2-ENG-05 fix relies on this unmodified row: the Worker writes the
 * environment summary to `$DSH_HOME/AGENTS.md` before the first request, and
 * the loader turns it into the model's baseline instructions. A profile or
 * roster change that silently drops or disables the row would leave the files
 * unread, so the image build fails instead of shipping an unread manifest.
 */
export const AGENT_INSTRUCTIONS_PACKAGE = '@deepseek-ai/dsh-agent-instructions'
/** Row id the base bundle uses for the instruction loader. */
export const AGENT_INSTRUCTIONS_ROW = 'agent-instructions'

/**
 * Assert the capability manifest has a reader in the packed image.
 *
 * The roster must carry `@deepseek-ai/dsh-agent-instructions` and a composed
 * row with id `agent-instructions` must not be disabled. A conditional
 * `disabled: !!js ...` expression cannot be audited at pack time (the value is
 * an opaque expression object), so it is rejected too: the row has to be
 * unconditionally enabled on the phone profile.
 * @param roster - every package name the image packs.
 * @param rows - composed base and home-patch rows.
 * @throws {Error} When the loader is missing or disabled.
 */
export function assertInstructionSource(roster, rows) {
  if (!roster.includes(AGENT_INSTRUCTIONS_PACKAGE)) {
    throw new Error(
      `pack-image: ${AGENT_INSTRUCTIONS_PACKAGE} is missing from the roster; `
      + 'the Worker writes /dsh/home/AGENTS.md but no row would inject it',
    )
  }
  let enabled = false
  const visit = (list) => {
    for (const row of list) {
      if (row?.id === AGENT_INSTRUCTIONS_ROW) {
        if (row.disabled !== undefined && row.disabled !== false) {
          throw new Error(
            `pack-image: the ${AGENT_INSTRUCTIONS_ROW} row is disabled in the phone profile; `
            + 'that row is the only reader of /dsh/home/AGENTS.md',
          )
        }
        enabled = true
      }
      if (Array.isArray(row?.insert)) visit(row.insert)
      if (row?.group === true && Array.isArray(row?.config)) visit(row.config)
    }
  }
  visit(rows)
  if (!enabled) {
    throw new Error(
      `pack-image: the phone profile composes no ${AGENT_INSTRUCTIONS_ROW} row; `
      + 'the Worker capability manifest would never reach the model',
    )
  }
  return { package: AGENT_INSTRUCTIONS_PACKAGE, row: AGENT_INSTRUCTIONS_ROW }
}

/**
 * Path an export face occupies in the image.
 * @param packageName - package name.
 * @param target - export target string.
 * @returns Image path.
 */
function exportImagePath(packageName, target) {
  return `node_modules/${packageName}/${target.replace(/^\.\//, '')}`
}

/**
 * Every target a staged manifest promises, from `exports` and `main`.
 * @param manifest - staged package manifest.
 * @returns String targets in declaration order.
 */
export function stagedFaceTargets(manifest) {
  const targets = new Set()
  for (const target of Object.values(manifest.exports ?? {})) {
    for (const value of flattenTargets(target)) targets.add(value)
  }
  if (typeof manifest.main === 'string') targets.add(manifest.main)
  return [...targets]
}

/**
 * Assert one packed export face passed the Worker lowering transform.
 *
 * The official packer leaves PAGE_ASSETS (`lib/client.js`, `lib/client.*.js`)
 * as ESM page bundles. A plugin face that lands on such a path would ship
 * without the transform and fail in the Worker loader, so the wrapper rejects
 * it here instead of only at W1. The runtime's own `lowerModuleSource` is the
 * oracle: an already-lowered body rejects a second lowering with its
 * "already lowered" error, while a still-ESM body lowers successfully.
 * @param options - check inputs.
 * @param options.runtime - checkout runtime module.
 * @param options.packageName - plugin package name.
 * @param options.target - staged export target.
 * @param options.imagePath - image path the target occupies.
 * @param options.files - packed image files.
 * @param options.pageBundles - image paths the packer classified as page assets.
 * @throws {Error} When the face is a page asset, unlowered, or cannot be checked.
 */
function assertPackedFaceLowered({ runtime, packageName, target, imagePath, files, pageBundles }) {
  const bytes = files[imagePath]
  if (bytes === undefined) {
    throw new Error(`pack-image: export ${target} of ${packageName} is missing from the image (${imagePath})`)
  }
  if (pageBundles.has(imagePath)) {
    throw new Error(
      `pack-image: export ${target} of ${packageName} resolves to ${imagePath}, which the official packer `
      + 'classifies as a PAGE_ASSET and ships without the Worker lowering transform; '
      + 'stage the face under a non-page image path',
    )
  }
  if (!/\.[cm]?js$/.test(imagePath)) return
  const source = new TextDecoder().decode(bytes)
  let lowering
  try {
    lowering = runtime.lowerModuleSource({ filename: `/${imagePath}`, source })
  } catch (reason) {
    // The expected case: the packer already lowered this body, and lowering it
    // twice is an error by contract.
    if (reason instanceof Error && reason.message.includes('already lowered')) return
    throw new Error(
      `pack-image: cannot verify the lowering contract of ${packageName} export ${target}: `
      + `${reason instanceof Error ? reason.message : String(reason)}`,
      { cause: reason },
    )
  }
  if (lowering.lowered) {
    throw new Error(
      `pack-image: export ${target} of ${packageName} was packed without the Worker lowering transform (${imagePath})`,
    )
  }
}

/**
 * Pack the image and write every artifact.
 * @param options - packaging inputs.
 * @param options.out - output directory.
 * @param options.checkout - pinned checkout directory.
 * @param options.checkoutSha - explicit expected HEAD for a controlled checkout
 *   override; must be supplied with `checkoutVersion`.
 * @param options.checkoutVersion - explicit expected installation version for
 *   the same controlled override.
 * @param options.pin - pin document.
 * @param options.python - `--python <dir>`: stage the `build.sh` artifact pair.
 * @param options.jq - `--jq <dir>`: stage the jq WASI engine.
 * @param options.env - environment for `PDSH_PYTHON_*`/`PDSH_JQ_ARTIFACTS`.
 * @returns Facts about the written image.
 */
export async function packImage({
  out,
  checkout = process.env.PDSH_DSH_CHECKOUT,
  checkoutSha,
  checkoutVersion,
  pin = readPin(),
  python,
  withoutPython = false,
  jq,
  withoutJq = false,
  env = process.env,
} = {}) {
  if (typeof out !== 'string' || out === '') throw new Error('pack-image: --out <dir> is required')
  if ((checkoutSha === undefined) !== (checkoutVersion === undefined)) {
    throw new Error('pack-image: --checkout-sha and --checkout-version must be supplied together')
  }
  if (checkoutSha !== undefined && !/^[0-9a-f]{40}$/.test(checkoutSha)) {
    throw new Error('pack-image: --checkout-sha must be a full 40-character lowercase commit')
  }
  // A controlled override changes the expected pin, never skips verification:
  // the checkout must still be clean, built, and at exactly this commit and
  // version. The canonical dsh-pin.json values stay in sizes.json beside the
  // actual HEAD, so a release can audit the difference.
  const expectedPin = checkoutSha === undefined
    ? pin
    : { ...pin, commit: checkoutSha, version: checkoutVersion }
  const verified = verifyCheckout({ checkout, pin: expectedPin })
  if (verified.version === undefined) {
    throw new Error('pack-image: the checkout names no apps/cli version; a version check is required')
  }
  const checkoutDir = verified.checkout
  const { packer, appBoot, runtime } = await importCheckout(checkoutDir)
  // Fail before the slow packing pass if the seam the shim rides on drifted.
  const sharpReplacement = assertSharpReplacement(runtime)
  const esbuild = await importEsbuild()
  const output = resolve(out)
  mkdirSync(output, { recursive: true })
  // Resolve before the (slow) staging pass so a missing pair fails at once.
  if (python !== undefined && withoutPython) throw new Error('pack-image: --python and --without-python cannot be used together')
  if (jq !== undefined && withoutJq) throw new Error('pack-image: --jq and --without-jq cannot be used together')
  const pythonSources = withoutPython ? undefined : resolvePythonSources({ python, env })
  const jqSources = withoutJq ? undefined : resolveJqSources({ jq, env })

  const stageRoot = mkdtempSync(join(tmpdir(), 'pdsh-dsh-stage-'))
  try {
    const workspaces = new Map(packer.indexWorkspacePackages(checkoutDir))
    // Two pinned DSH cleanup listeners call `.catch` on a Cordis fiber disposer
    // that is typed Promise but returns void once the owning scope already
    // disposed the fiber. Stage only those built packages with the exact call
    // sites normalised; stageDisposeCompat throws when the pin drifts.
    const disposeCompat = stageDisposeCompat({
      workspaces,
      output: join(stageRoot, 'dispose-compat'),
      commit: verified.head,
      version: verified.version,
    })
    for (const [name, directory] of disposeCompat.workspaces) workspaces.set(name, directory)
    const stagedManifests = new Map()
    const pluginRequests = new Set()
    for (const plugin of PLUGIN_PACKAGES) {
      const staged = await stagePlugin({
        esbuild,
        package: plugin,
        output: join(stageRoot, plugin.name.replace(/^@/, '').replaceAll('/', '__')),
        checkout: checkoutDir,
      })
      workspaces.set(plugin.name, staged.directory)
      stagedManifests.set(plugin.name, staged.manifest)
      for (const name of staged.requested) pluginRequests.add(name)
      // Every node: builtin the staged bundles request must have a module proxy
      // in the Worker runtime, or the face fails at load time on the phone.
      const proxied = new Set(Object.keys(runtime.MODULE_PROXIES ?? {}))
      const proxyPrefixes = Object.keys(runtime.MODULE_PROXY_PREFIXES ?? {})
      for (const name of staged.builtins) {
        if (proxied.has(name) || proxyPrefixes.some(prefix => name.startsWith(prefix))) continue
        throw new Error(`pack-image: ${plugin.name} imports ${name}, which the Worker runtime does not proxy`)
      }
      // ...and every named member must exist on that proxy (a git codec importing
      // deflateSync from a zstd-only node:zlib fails at the first object read).
      for (const [moduleName, names] of staged.builtinMembers) {
        if (names.has('*')) continue
        const exported = await builtinExports(checkoutDir, runtime, moduleName)
        if (exported === null) continue
        const missing = [...names].filter(name => !exported.has(name))
        if (missing.length > 0) {
          throw new Error(`pack-image: ${plugin.name} imports ${missing.join(', ')} from ${moduleName}, which the Worker runtime's proxy does not export`)
        }
      }
    }

    const homePatch = loadWorkerHomePatch(appBoot, WORKER_PROFILE_PATCH, checkoutDir)
    // PLATFORM_ENTRY_CONFIG requires the active JSONL Session store to stay
    // plaintext: the Worker carries no Zstandard codec for its own writes.
    const persistence = findRow(homePatch, 'session-persistence-journaled')
    if (persistence?.config?.compression !== 'none') {
      throw new Error(
        'pack-image: home patch must mount an active session-persistence row with compression: none '
        + '(the Worker image has no Zstandard writer)',
      )
    }

    const baseDirectory = workspaces.get('@deepseek-ai/dsh-base')
    if (baseDirectory === undefined) throw new Error('pack-image: the checkout has no @deepseek-ai/dsh-base bundle')
    const baseRows = appBoot.loadOverlayPatches('pdsh-pack-image', join(baseDirectory, 'cordis.patch.yml'))

    const names = new Set(PLUGIN_PACKAGES.map(plugin => plugin.name))
    names.add('@deepseek-ai/dsh-base')
    for (const name of rosterNames(packer.collectModuleNames, baseRows)) names.add(name)
    for (const name of rosterNames(packer.collectModuleNames, homePatch)) names.add(name)
    for (const name of presetRosterNames(packer.collectModuleNames, homePatch)) names.add(name)
    for (const name of RUNTIME_ROOTS) names.add(name)
    for (const name of pluginRequests) names.add(name)
    for (const name of disposeCompat.packages) {
      if (!names.has(name)) {
        throw new Error(`pack-image: dispose compatibility target ${name} is not in the profile roster`)
      }
    }

    // G2-ENG-05: the Worker writes /dsh/home/AGENTS.md, but the unmodified
    // upstream `agent-instructions` row is what injects it. Refuse a roster or
    // profile that dropped or disabled that reader.
    assertInstructionSource([...names], [...baseRows, ...homePatch])

    // The packer treats every workspace entry as a Worker root and publishes
    // only its declared faces. That is exactly right for roster packages, but
    // a client-only platform package reached through a phone package's peer
    // edge (for example `@deepseek-ai/dsh-client-ui-primitives`) must stay a
    // page-module dependency, not become a lowered Worker root whose npm deps
    // the image does not carry. Keep workspace treatment for the roster; let
    // the packer take every other dependency from the checkout install.
    const packWorkspaces = new Map(
      [...workspaces].filter(([name]) => names.has(name)),
    )
    if (!packWorkspaces.has('@deepseek-ai/dsh-base')) {
      throw new Error('pack-image: the roster has no @deepseek-ai/dsh-base workspace')
    }

    // The python artifacts are opaque build products: stage exactly the pair
    // and mount it through the packer's data-tree option, so no build log or
    // sizes.json accidentally enters the image. The same staging pass derives
    // the importable-module probe the boot capability manifest quotes.
    const pythonStaged = pythonSources === undefined
      ? undefined
      : stagePythonArtifacts({ ...pythonSources, output: join(stageRoot, 'python') })
    const jqStaged = jqSources === undefined
      ? undefined
      : stageJqArtifacts({ ...jqSources, output: join(stageRoot, 'jq') })
    const configTrees = [
      ...pythonStaged === undefined ? [] : [{ mount: PYTHON_IMAGE_MOUNT, directory: pythonStaged.directory }],
      ...jqStaged === undefined ? [] : [{ mount: JQ_IMAGE_MOUNT, directory: jqStaged.directory }],
    ]

    const result = packer.packVfsImage({
      profile: IMAGE_PROFILE,
      roster: [...names].sort(),
      installation: packer.installationManifest(checkoutDir),
      workspaces: packWorkspaces,
      resolveFrom: checkoutDir,
      homePatch,
      ...configTrees.length === 0 ? {} : { configTrees },
    })

    if (result.missing.length > 0) {
      throw new Error(`pack-image: the image is incomplete; unresolved packages:\n  ${result.missing.join('\n  ')}`)
    }
    for (const fact of disposeCompat.facts) {
      if (result.files[`node_modules/${fact.package}/${fact.file}`] === undefined) {
        throw new Error(`pack-image: dispose compatibility target ${fact.package}/${fact.file} did not reach the image`)
      }
    }
    const pageBundles = new Set(result.pageBundles)
    for (const plugin of PLUGIN_PACKAGES) {
      const count = result.packages.get(plugin.name) ?? 0
      if (count <= 1) throw new Error(`pack-image: ${plugin.name} contributed ${count} file(s), expected more than one`)
      if (result.files[`node_modules/${plugin.name}/package.json`] === undefined) {
        throw new Error(`pack-image: ${plugin.name}/package.json is missing from the image`)
      }
      const manifest = stagedManifests.get(plugin.name)
      const browserClient = clientExportTarget(manifest, plugin.name)
      for (const value of stagedFaceTargets(manifest)) {
        // The page client is the one face the official packer must leave as a
        // PAGE_ASSET; assertClientBundleFiles below checks it and its boot row.
        if (value === browserClient) continue
        const imagePath = exportImagePath(plugin.name, value)
        assertPackedFaceLowered({
          runtime,
          packageName: plugin.name,
          target: value,
          imagePath,
          files: result.files,
          pageBundles,
        })
      }
    }
    // Browser client roster: every enabled dsh.client row must have its real
    // browser bundle in the image, and DSH's own module-system node half must
    // compose window.__DSH_BOOT__ from those exact bytes. The connection row is
    // browser-only: its host half is gated on a service this image never
    // provides, so phone-surface stays the one ctx.connection and /api owner.
    const composedRows = composeProfileRows(baseRows, homePatch)
    const clientFacts = assertClientBundleFiles({
      rows: composedRows,
      files: result.files,
      pageBundles,
    })
    const connectionContract = assertConnectionContract(composedRows)
    const bootGraph = await assertBootGraph({
      checkout: checkoutDir,
      clientFacts,
      files: result.files,
    })
    const clientRoster = {
      row: CLIENT_MODULES_ROW,
      package: CLIENT_MODULES_PACKAGE,
      rows: clientFacts,
      boot: bootGraph,
      connection: connectionContract,
    }
    const homePatchPath = 'home/cordis.patch.yml'
    if (result.files[homePatchPath] === undefined) {
      throw new Error(`pack-image: ${homePatchPath} is missing from the image`)
    }
    // The image omits the native package; the Worker bundle must carry the
    // shim that replaces it in the module table.
    const workerBundleCheck = verifyWorkerBundleShim(checkoutDir)

    const python = pythonStaged === undefined
      ? undefined
      : {
          mount: PYTHON_IMAGE_MOUNT,
          files: pythonStaged.files.map(file => ({
            path: `${PYTHON_IMAGE_MOUNT}/${file.name}`,
            bytes: file.bytes,
          })),
          // The boot capability manifest quotes this list; keep it visible in
          // sizes.json so a release can audit what the model was told.
          modules: pythonStaged.probe.modules,
          modules_path: `${PYTHON_IMAGE_MOUNT}/${PYTHON_MODULES_FILE}`,
          // The compression capability is the build report, bound to the bytes
          // by sizes.json; repeat it here so a release can audit the exact
          // answer the model was given without unpacking modules.json.
          compression: pythonStaged.probe.compression,
          version: pythonStaged.probe.python,
        }
    for (const entry of python?.files ?? []) {
      const bytes = result.files[entry.path]
      if (bytes === undefined) {
        throw new Error(`pack-image: the python artifact ${entry.path} did not reach the image`)
      }
      if (bytes.byteLength !== entry.bytes) {
        throw new Error(
          `pack-image: the image's ${entry.path} is ${bytes.byteLength} B, expected ${entry.bytes} B`,
        )
      }
    }
    if (python !== undefined) {
      const modulesBytes = result.files[python.modules_path]
      if (modulesBytes === undefined) {
        throw new Error(`pack-image: the python module probe ${python.modules_path} did not reach the image`)
      }
      const probe = JSON.parse(new TextDecoder().decode(modulesBytes))
      if (JSON.stringify(probe.modules) !== JSON.stringify(python.modules)) {
        throw new Error('pack-image: the staged python module probe changed inside the image')
      }
      if (JSON.stringify(probe.compression) !== JSON.stringify(python.compression)) {
        throw new Error('pack-image: the staged python compression report changed inside the image')
      }
    }

    const jq = jqStaged === undefined
      ? undefined
      : {
          mount: JQ_IMAGE_MOUNT,
          engine: jqStaged.engine,
          files: jqStaged.files.map(file => ({
            path: `${JQ_IMAGE_MOUNT}/${file.name}`,
            bytes: file.bytes,
          })),
        }
    for (const entry of jq?.files ?? []) {
      const bytes = result.files[entry.path]
      if (bytes === undefined) throw new Error(`pack-image: the jq artifact ${entry.path} did not reach the image`)
      if (bytes.byteLength !== entry.bytes) {
        throw new Error(`pack-image: the image's ${entry.path} is ${bytes.byteLength} B, expected ${entry.bytes} B`)
      }
    }

    writeFileSync(join(output, 'image.tar.gz'), result.image)
    for (const archive of result.lazyArchives) {
      const target = join(output, archive.name)
      mkdirSync(dirname(target), { recursive: true })
      writeFileSync(target, archive.image)
    }
    const manifestBytes = result.files['config/vfs-manifest.json']
    if (manifestBytes === undefined) throw new Error('pack-image: the image has no config/vfs-manifest.json')
    writeFileSync(join(output, 'manifest.json'), manifestBytes)
    const runtimeDirectory = workspaces.get('@deepseek-ai/dsh-experimental-webworker-runtime')
      ?? join(checkoutDir, 'packages/experimental/webworker-runtime')
    for (const file of ['worker.js', 'client.js']) {
      const bytes = readFileSync(join(runtimeDirectory, 'lib', file))
      if (bytes.byteLength === 0) throw new Error(`pack-image: runtime ${file} is empty`)
      writeFileSync(join(output, file), bytes)
    }

    const sizes = {
      raw_bytes: gunzipSync(result.image).byteLength,
      gzip_bytes: result.image.byteLength,
      lazy: result.lazyArchives.map(archive => ({ name: archive.name, bytes: archive.image.byteLength })),
      files: Object.keys(result.files).length,
      ...python === undefined ? {} : { python },
      ...jq === undefined ? {} : { jq },
      client_roster: clientRoster,
      built_at: new Date().toISOString(),
      // The verified checkout is the artifact's source of truth. The pin
      // fields stay beside it so a controlled checkout override can never be
      // mistaken for the repository pin.
      dsh_commit: verified.head,
      dsh_pin_commit: pin.commit,
      dsh_pin_version: pin.version,
      dsh_expected_commit: expectedPin.commit,
      dsh_expected_version: expectedPin.version,
      dsh_checkout_overridden: expectedPin.commit !== pin.commit || expectedPin.version !== pin.version,
      dsh_checkout: verified.checkout,
      dsh_version: verified.version,
      sharp_shim: { ...sharpReplacement, worker_bundle: workerBundleCheck },
      dispose_compat: {
        site_count: disposeCompat.facts.length,
        sites: disposeCompat.facts,
      },
    }
    writeFileSync(join(output, 'sizes.json'), `${JSON.stringify(sizes, null, 2)}\n`)
    const provenance = writeImageProvenance(output, { dshCommit: pin.commit })

    return {
      output,
      sizes,
      provenance,
      python,
      jq,
      clientRoster,
      packages: Object.fromEntries(PLUGIN_PACKAGES.map(plugin => [plugin.name, result.packages.get(plugin.name) ?? 0])),
      files: sizes.files,
      lazy: result.lazyArchives.length,
      homePatch: homePatchPath,
      checkout: checkoutDir,
      sharp: { ...sharpReplacement, worker_bundle: workerBundleCheck },
    }
  } finally {
    rmSync(stageRoot, { recursive: true, force: true })
  }
}

/**
 * Flatten string leaves of a conditional export target.
 * @param target - export target object/array.
 * @returns String targets.
 */
function flattenTargets(target) {
  if (typeof target === 'string') return [target]
  if (Array.isArray(target)) return target.flatMap(flattenTargets)
  if (target !== null && typeof target === 'object') return Object.values(target).flatMap(flattenTargets)
  return []
}

/** Whether this file is the process entry point. */
function invokedByCli() {
  const entry = process.argv[1]
  if (entry === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(entry))
  } catch {
    return false
  }
}

async function main() {
  let parsed
  try {
    parsed = parseArgs({
      allowPositionals: false,
      options: {
        out: { type: 'string' },
        python: { type: 'string' },
        'without-python': { type: 'boolean', default: false },
        jq: { type: 'string' },
        'without-jq': { type: 'boolean', default: false },
        checkout: { type: 'string' },
        'checkout-sha': { type: 'string' },
        'checkout-version': { type: 'string' },
      },
    })
  } catch (reason) {
    process.stderr.write(`pack-image: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    process.exitCode = 2
    return
  }
  try {
    const out = parsed.values.out
    if (typeof out !== 'string' || out === '') {
      process.stderr.write(
        'usage: node scripts/pack-image.mjs --out <dir> [--checkout <pinned build>]'
        + ' [--checkout-sha <40-hex> --checkout-version <version>] [--python <build.sh output dir> | --without-python]'
        + ' [--jq <dir> | --without-jq]\n'
        + '  the checkout path also comes from PDSH_DSH_CHECKOUT; either way it is verified'
        + ' (HEAD, clean tree, built artifacts, installation version) and the actual HEAD is recorded in sizes.json\n'
        + '  --checkout-sha/--checkout-version form a controlled pair: both are required, the checkout must match them,'
        + ' and the canonical dsh-pin.json values remain recorded beside the actual ones\n'
        + `  python is enabled by PDSH_PYTHON_WASM/PDSH_PYTHON_STDLIB; produce it with:\n  ${PYTHON_BUILD_COMMAND}\n`
        + `  jq is enabled by PDSH_JQ_ARTIFACTS; produce it with:\n  ${JQ_BUILD_COMMAND}\n`,
      )
      process.exitCode = 2
      return
    }
    const python = parsed.values.python
    const jq = parsed.values.jq
    const checkout = parsed.values.checkout ?? process.env.PDSH_DSH_CHECKOUT
    const checkoutSha = parsed.values['checkout-sha']
    const checkoutVersion = parsed.values['checkout-version']
    const result = await packImage({
      out,
      checkout,
      ...checkoutSha === undefined ? {} : { checkoutSha },
      ...checkoutVersion === undefined ? {} : { checkoutVersion },
      ...python === undefined ? {} : { python },
      withoutPython: parsed.values['without-python'],
      ...jq === undefined ? {} : { jq },
      withoutJq: parsed.values['without-jq'],
    })
    process.stdout.write([
      `pack-image: OK (${result.sizes.dsh_version} ${result.sizes.dsh_commit.slice(0, 12)})`,
      `  checkout: ${result.sizes.dsh_checkout}`,
      `  pin:      ${result.sizes.dsh_pin_commit}`,
      ...result.sizes.dsh_checkout_overridden
        ? [`  override: expected ${result.sizes.dsh_expected_version} ${result.sizes.dsh_expected_commit}, actual ${result.sizes.dsh_commit}`]
        : [],
      `  output:   ${result.output}`,
      `  files:    ${result.files}`,
      `  raw:      ${result.sizes.raw_bytes} B`,
      `  gzip:     ${result.sizes.gzip_bytes} B`,
      `  lazy:     ${result.lazy}`,
      `  clients:  ${result.clientRoster.rows.length} browser bundle(s), __DSH_BOOT__ ${result.clientRoster.boot.entries.length} row(s), connection host ${result.clientRoster.connection.host}`,
      ...(result.python === undefined
        ? ['  python:   not staged (image carries no python3; pass --python <dir> to include it)']
        : [`  python:   ${result.python.files.map(file => `${file.path} (${file.bytes} B)`).join(', ')}`]),
      ...(result.jq === undefined
        ? ['  jq:       not staged (image keeps the fail-loud jq shim; pass --jq <dir> or set PDSH_JQ_ARTIFACTS)']
        : [`  jq:       ${result.jq.files.map(file => `${file.path} (${file.bytes} B)`).join(', ')}`]),
      `  sharp:    shim ${result.sharp.shim} replaces runtime proxy ${result.sharp.runtime_proxy}`,
      ...Object.entries(result.packages).map(([name, count]) => `  plugin:   ${name} (${count} files)`),
      '',
    ].join('\n'))
  } catch (reason) {
    process.stderr.write(`pack-image: ${reason instanceof Error ? reason.message : String(reason)}\n`)
    process.exitCode = 1
  }
}

if (invokedByCli()) await main()
