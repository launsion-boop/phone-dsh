#!/usr/bin/env node
// SPDX-License-Identifier: MIT
/**
 * Bundle the WKWebView worker entry with esbuild.
 *
 *   PDSH_DSH_CHECKOUT=<pinned checkout> node worker-entry/build.mjs [--out <dir>] [--check]
 *
 * `@deepseek-ai/dsh-experimental-webworker-runtime/src/` specifiers resolve into
 * the pinned checkout; no DSH source is copied or patched. The browser aliases
 * come from the checkout's own `module-proxies.ts` table, the same table the
 * runtime's official worker build uses, so this never copies DSH definitions.
 * One specifier is redirected on top of that table: `sharp` (which the runtime
 * replaces with a notImplementedFail stub) resolves to this layer's Worker-side
 * raster shim, matching the static-module override `runtime-binding.ts` installs
 * for image-loaded code. The emitted bundle is checked for that shim's marker.
 * The checkout path is read from the environment (or the per-machine
 * `~/.config/phone-dsh/dsh-checkout` file) and is never written into the repository.
 *
 * Output: `<out>/worker-entry.js`, `<out>/tool-worker-python.js`,
 * `<out>/tool-worker.js`, `<out>/workflow-isolate.js` and
 * `<out>/web-boot.js` (+ source maps) plus `<out>/www/index.html`,
 * `<out>/www/boot.js`. Both tool workers must be served beside the entry: the
 * W7 runtime spawns the python one at
 * `new URL('./tool-worker-python.js', import.meta.url)`, and the generic
 * `WasiToolbox` (the jq engine) spawns `./tool-worker.js`. The workflow
 * isolate is spawned by the Worker-native workflow bridge at
 * `new URL('./workflow-isolate.js', location.href)`; it is a module Worker
 * with the QuickJS WASM realm inlined and no `node:` imports. `web-boot.js` is
 * the full DSH Web page's half: it
 * spawns the entry Worker and drives the runtime's `WorkerTunnel`;
 * `examples/probe-app/scripts/copy-bundle-assets.sh` stages it beside the
 * injected `web/index.html`. `--check` builds into a temporary directory,
 * verifies all five artifacts and removes it.
 *
 * The bundle root is `src/boot.ts`, which imports `src/jsc-compat.ts` before
 * the entry graph. That puts the JavaScriptCore compatibility prelude at the
 * top of `worker-entry.js`, so the Worker installs it before any DSH module
 * evaluates even when the bundle is served without the macOS smoke's own
 * prelude.
 */
import { cp, mkdir, mkdtemp, rm, stat } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import { SHARP_SHIM_MARKER } from './src/sharp-marker.ts'
import { QUICKJS_REALM_MARKER } from '../workflow-worker/src/quickjs-vm.ts'

const here = dirname(fileURLToPath(import.meta.url))
const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'
const RUNTIME_CLIENT = '@deepseek-ai/dsh-experimental-webworker-runtime/client'
const CLIENT_WEB_INJECTIONS = '@deepseek-ai/dsh-client-web/injections'
const RUNTIME_DIR = 'packages/experimental/webworker-runtime'
const CLIENT_WEB_DIR = 'packages/client/web'
const WORKFLOW_PTC_SRC = 'packages/workflow/workflow-ptc/src'
const WORKFLOW_ISOLATE_ENTRY = join(here, '..', 'workflow-worker', 'src', 'isolate-runner.ts')
const VM_SHIM_PATH = join(here, 'src', 'vm-shim.ts')
// The isolate's node:vm face is a real QuickJS/WASM realm, not the main
// Worker's `with`-scope shim. Only the isolate graph gets this mapping.
const QUICKJS_VM_PATH = join(here, '..', 'workflow-worker', 'src', 'quickjs-vm.ts')

const { values } = parseArgs({
  options: {
    out: { type: 'string', default: join(here, 'dist') },
    check: { type: 'boolean', default: false },
  },
})

function resolveCheckout() {
  const fromEnv = process.env.PDSH_DSH_CHECKOUT
  if (fromEnv !== undefined && fromEnv !== '') return fromEnv
  try {
    const path = join(process.env.HOME ?? '', '.config/phone-dsh/dsh-checkout')
    const line = readFileSync(path, 'utf8').trim()
    return line === '' ? undefined : line
  } catch {
    return undefined
  }
}

function fail(message) {
  console.error(`worker-entry build: ${message}`)
  process.exitCode = 1
}

const checkout = resolveCheckout()
if (checkout === undefined) {
  fail('PDSH_DSH_CHECKOUT is not set and ~/.config/phone-dsh/dsh-checkout has no path.')
  process.exit(1)
}

const runtimeDir = join(checkout, RUNTIME_DIR)
const runtimeSrc = join(runtimeDir, 'src')
/** Worker-side replacement for the runtime's notImplementedFail `sharp` stub. */
const SHARP_SHIM_PATH = join(here, 'src', 'sharp-shim.ts')
if (!existsSync(join(runtimeSrc, 'worker-host.ts'))) {
  fail(`PDSH_DSH_CHECKOUT does not look like the pinned checkout: ${checkout}`)
  fail(`expected ${join(runtimeSrc, 'worker-host.ts')} to exist.`)
  process.exit(1)
}

let proxies
let replacedPrefixes
try {
  // The checkout exports this table from its source; importing it avoids a copy.
  const table = await import(join(runtimeSrc, 'module-proxies.ts'))
  proxies = table.MODULE_PROXIES
  replacedPrefixes = table.MODULE_PROXY_PREFIXES
} catch (error) {
  fail(`cannot read the checkout's module-proxy table: ${error instanceof Error ? error.message : String(error)}`)
  fail('a Node runtime with TypeScript type stripping (>= 22.18) is required to build.')
  process.exit(1)
}

const requireFromRuntime = createRequire(join(runtimeDir, 'package.json'))
let shellParserEntry
try {
  const parserManifest = requireFromRuntime.resolve('@yarnpkg/parsers/package.json')
  shellParserEntry = join(dirname(parserManifest), 'lib/shell.js')
} catch {
  shellParserEntry = undefined
}

const out = values.check === true ? await mkdtemp(join(tmpdir(), 'pdsh-entry-check-')) : resolve(values.out)

/** Build a checkout resolver; `isolate` selects the QuickJS realm faces. */
function checkoutRuntimePlugin(options = {}) {
  return {
    name: 'pdsh-dsh-checkout-runtime',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        if (args.path.startsWith(RUNTIME_PREFIX)) {
          return { path: join(runtimeSrc, args.path.slice(RUNTIME_PREFIX.length)) }
        }
        // The full Web page imports the runtime's page-half package export. Map
        // it to the same pinned source the rest of this build reads, so
        // `web-boot.js` never depends on a partly materialized `lib/` tree.
        if (args.path === RUNTIME_CLIENT) return { path: join(runtimeSrc, 'client', 'index.ts') }
        if (args.path === CLIENT_WEB_INJECTIONS) {
          return { path: join(checkout, CLIENT_WEB_DIR, 'src', 'apply-injections.ts') }
        }
        // Layer override before the checkout's proxy table: statically bundled
        // importers must see the same shim the module table serves to the image.
        if (args.path === 'sharp') return { path: SHARP_SHIM_PATH }
        // The workflow isolate bundles the official execution/meta faces from
        // the verified checkout (the published package has no `src/`). The
        // isolate build resolves `node:vm` to the embedded QuickJS/WASM realm;
        // the main Worker build keeps the compile-only vm-shim.
        if (args.path === '@deepseek-ai/dsh-workflow-ptc/src/runtime.ts') {
          return { path: join(checkout, WORKFLOW_PTC_SRC, 'runtime.ts') }
        }
        if (args.path === '@deepseek-ai/dsh-workflow-ptc/src/meta.ts') {
          return { path: join(checkout, WORKFLOW_PTC_SRC, 'meta.ts') }
        }
        if (args.path === 'node:vm' || args.path === 'vm') {
          return { path: options.isolate === true ? QUICKJS_VM_PATH : VM_SHIM_PATH }
        }
        // The official workflow runtime imports only `assertObjectJsonSchema` and
        // `JsonSchemaError` from dsh-tools. Redirect that specifier to the
        // official source file so the isolate does not pull dsh-sandbox and its
        // top-level `node:fs`/`node:os` imports into a browser Worker.
        if (options.isolate === true && args.path === '@deepseek-ai/dsh-tools') {
          return { path: join(checkout, 'packages/core/tools/src/json-schema.ts') }
        }
        // Bundled DSH attribution code only needs `node:module` to read its own
        // package version. The isolate has no CommonJS resolver; answer that
        // metadata read and refuse every other module request.
        if (args.path === 'node:module' || args.path === 'module') {
          return { path: join(here, '..', 'workflow-worker', 'src', 'node-module-shim.ts') }
        }
        const exact = proxies[args.path]
        if (exact !== undefined) return { path: join(runtimeSrc, exact.replace(/^\.\//, '')) }
        for (const [prefix, replacement] of Object.entries(replacedPrefixes)) {
          if (args.path.startsWith(prefix)) {
            return { path: join(runtimeSrc, replacement.replace(/^\.\//, '')) }
          }
        }
        if (args.path === '@yarnpkg/parsers' && shellParserEntry !== undefined) {
          return { path: shellParserEntry }
        }
        return null
      })
    },
  }
}

try {
  const esbuild = await import('esbuild')
  await mkdir(out, { recursive: true })
  const built = await esbuild.build({
    // `boot.ts` imports the JavaScriptCore prelude before the entry, so the
    // emitted bundle installs it first. Keep this root, not `entry.ts`.
    entryPoints: [join(here, 'src', 'boot.ts')],
    outfile: join(out, 'worker-entry.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    sourcemap: true,
    logLevel: 'warning',
    plugins: [checkoutRuntimePlugin()],
  })
  if (built.errors.length > 0) throw new Error(built.errors.map(error => error.text).join('\n'))
  const artifact = await stat(join(out, 'worker-entry.js'))
  if (artifact.size === 0) throw new Error('esbuild wrote an empty worker-entry.js')
  // The shim is reachable only through runtime-binding.ts -> static-modules.ts.
  // A missing marker means the override was dropped or tree-shaken, which would
  // silently restore the runtime's notImplementedFail `sharp` stub.
  if (!readFileSync(join(out, 'worker-entry.js'), 'utf8').includes(SHARP_SHIM_MARKER)) {
    throw new Error(
      `the sharp Worker shim marker "${SHARP_SHIM_MARKER}" is missing from worker-entry.js: `
      + 'the static-module override is not reachable from the entry graph',
    )
  }
  // The W7 python runtime spawns its own tool worker with
  // `new Worker(new URL('./tool-worker-python.js', import.meta.url))`; the
  // deployment serves this file beside worker-entry.js, and the page's boot
  // then finds it without a second path convention.
  const toolWorker = await esbuild.build({
    entryPoints: [join(here, '..', 'wasi-toolbox', 'python', 'tool-worker-python.ts')],
    outfile: join(out, 'tool-worker-python.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    sourcemap: true,
    logLevel: 'warning',
    plugins: [checkoutRuntimePlugin()],
  })
  if (toolWorker.errors.length > 0) throw new Error(toolWorker.errors.map(error => error.text).join('\n'))
  const toolWorkerArtifact = await stat(join(out, 'tool-worker-python.js'))
  if (toolWorkerArtifact.size === 0) throw new Error('esbuild wrote an empty tool-worker-python.js')
  // The generic WASI tool worker serves the jq engine (and any future plain
  // preview1 program) through the same hot-instance/VFS proxy. It is a separate
  // bundle from the python worker because that worker requires a stdlib zip.
  const genericToolWorker = await esbuild.build({
    entryPoints: [join(here, '..', 'wasi-toolbox', 'src', 'tool-worker.ts')],
    outfile: join(out, 'tool-worker.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    sourcemap: true,
    logLevel: 'warning',
    plugins: [checkoutRuntimePlugin()],
  })
  if (genericToolWorker.errors.length > 0) throw new Error(genericToolWorker.errors.map(error => error.text).join('\n'))
  const genericArtifact = await stat(join(out, 'tool-worker.js'))
  if (genericArtifact.size === 0) throw new Error('esbuild wrote an empty tool-worker.js')
  // The workflow bridge loads this module as a Worker; it is a page-independent
  // bundle with the QuickJS realm inlined. IIFE-safe: it must run both as a
  // classic/module Web Worker and as a Node worker_threads file in the
  // image-boot harness.
  const isolate = await esbuild.build({
    entryPoints: [WORKFLOW_ISOLATE_ENTRY],
    outfile: join(out, 'workflow-isolate.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    sourcemap: true,
    logLevel: 'warning',
    loader: { '.wasm': 'binary' },
    metafile: true,
    nodePaths: [join(checkout, 'node_modules'), join(here, 'node_modules')],
    plugins: [checkoutRuntimePlugin({ isolate: true })],
  })
  if (isolate.errors.length > 0) throw new Error(isolate.errors.map(error => error.text).join('\n'))
  const isolateArtifact = await stat(join(out, 'workflow-isolate.js'))
  if (isolateArtifact.size === 0) throw new Error('esbuild wrote an empty workflow-isolate.js')
  // A browser module Worker cannot resolve `node:`; the isolate must bundle
  // every runtime face. Fail loudly instead of shipping a bundle that only
  // works in the Node worker_threads harness.
  const isolateOutput = Object.values(isolate.metafile?.outputs ?? {}).find(output => output.entryPoint !== undefined)
  const externalNode = (isolateOutput?.imports ?? []).filter(entry =>
    entry.external === true && entry.path.startsWith('node:'))
  if (externalNode.length > 0) {
    throw new Error(
      `workflow-isolate.js still imports unresolved Node built-ins: ${externalNode.map(entry => entry.path).join(', ')}`,
    )
  }
  const isolateSource = readFileSync(join(out, 'workflow-isolate.js'), 'utf8')
  if (!isolateSource.includes(QUICKJS_REALM_MARKER)) {
    throw new Error(
      `the QuickJS isolate realm marker "${QUICKJS_REALM_MARKER}" is missing from workflow-isolate.js: `
      + 'the workflow script would not run in a separate realm',
    )
  }
  const strayNodeImport = /(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*)["'](node:[^"']+)["']/u.exec(isolateSource)
  if (strayNodeImport !== null) {
    throw new Error(`workflow-isolate.js contains an unhandled ${strayNodeImport[1]} specifier`)
  }
  const webBoot = await esbuild.build({
    entryPoints: [join(here, 'src', 'web-boot.ts')],
    outfile: join(out, 'web-boot.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'es2022',
    sourcemap: true,
    logLevel: 'warning',
    plugins: [checkoutRuntimePlugin()],
  })
  if (webBoot.errors.length > 0) throw new Error(webBoot.errors.map(error => error.text).join('\n'))
  const webBootArtifact = await stat(join(out, 'web-boot.js'))
  if (webBootArtifact.size === 0) throw new Error('esbuild wrote an empty web-boot.js')
  if (values.check === true) {
    console.log(`worker-entry build check: ok (${artifact.size} bytes, python tool worker ${toolWorkerArtifact.size} bytes, generic tool worker ${genericArtifact.size} bytes, workflow isolate ${isolateArtifact.size} bytes, web boot ${webBootArtifact.size} bytes, ${SHARP_SHIM_MARKER})`)  } else {
    await cp(join(here, 'www'), join(out, 'www'), { recursive: true })
    const ratio = `${(artifact.size / 1024).toFixed(1)} KiB`
    console.log(`worker-entry build: wrote ${join(out, 'worker-entry.js')} (${artifact.size} bytes, ${ratio})`)
    console.log(`worker-entry build: wrote ${join(out, 'tool-worker-python.js')} (${toolWorkerArtifact.size} bytes)`)
    console.log(`worker-entry build: wrote ${join(out, 'tool-worker.js')} (${genericArtifact.size} bytes)`)
    console.log(`worker-entry build: wrote ${join(out, 'workflow-isolate.js')} (${isolateArtifact.size} bytes)`)
    console.log(`worker-entry build: wrote ${join(out, 'web-boot.js')} (${webBootArtifact.size} bytes)`)
    console.log(`worker-entry build: wrote ${join(out, 'www')}`)
  }
} catch (error) {
  fail(error instanceof Error ? error.message : String(error))
} finally {
  if (values.check === true) await rm(out, { recursive: true, force: true })
}
