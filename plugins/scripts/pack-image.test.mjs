// SPDX-License-Identifier: MIT
// Image staging tests: the packer drops `src/**` from workspace packages, so
// every export face must be bundled into `lib/` and the rewritten manifest must
// point there with bare imports left external. A face named `client` must not
// land on the packer's PAGE_ASSETS path, where it would ship unlowered.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'
import vm from 'node:vm'
import { gunzipSync } from 'node:zlib'

import {
  AGENT_INSTRUCTIONS_PACKAGE,
  AGENT_INSTRUCTIONS_ROW,
  JQ_ENGINE_FILE, JQ_IMAGE_MOUNT, JQ_SIZES_FILE, JQ_WASM_FILE,
  PLUGIN_PACKAGES, PYTHON_COMPRESSION_FILE, PYTHON_IMAGE_MOUNT, PYTHON_MODULES_FILE, PYTHON_SIZES_FILE, PYTHON_STDLIB_FILE, PYTHON_WASM_FILE,
  assertInstructionSource, assertSharpReplacement, builtinExports, builtinImports, isImagePackage, packImage,
  probePythonModules, pythonModulesFromZipEntries, resolveJqSources, resolvePythonSources, stageJqArtifacts, stagePlugin,
  stagePythonArtifacts,
  stagedFacePath, stagedFaceTargets, zipEntryNames,
} from './pack-image.mjs'
import { readPin } from './dsh-checkout.mjs'
import { SHARP_SHIM_MARKER } from '../worker-entry/src/sharp-marker.ts'
import { JQ_SOURCE_ALGORITHM, jqSourceReport } from '../wasi-toolbox/jq/source-fingerprint.ts'

const encoder = new TextEncoder()

/**
 * Build a minimal stored ZIP (local headers + central directory + EOCD).
 * The CPython stdlib is `ZIP_STORED`, so this is the exact shape the module
 * probe reads.
 * @param {Record<string, string>} entries - name → text content.
 * @returns {Buffer} archive bytes.
 */
function storedZip(entries) {
  const locals = []
  const centrals = []
  let offset = 0
  const names = Object.keys(entries)
  for (const name of names) {
    const nameBytes = encoder.encode(name)
    const data = encoder.encode(entries[name])
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt16LE(0, 6)
    local.writeUInt16LE(0, 8)
    local.writeUInt16LE(0, 10)
    local.writeUInt16LE(0, 12)
    local.writeUInt32LE(0, 14)
    local.writeUInt32LE(data.byteLength, 18)
    local.writeUInt32LE(data.byteLength, 22)
    local.writeUInt16LE(nameBytes.byteLength, 26)
    local.writeUInt16LE(0, 28)
    locals.push(local, Buffer.from(nameBytes), Buffer.from(data))
    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(20, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0, 8)
    central.writeUInt16LE(0, 10)
    central.writeUInt16LE(0, 12)
    central.writeUInt16LE(0, 14)
    central.writeUInt32LE(0, 16)
    central.writeUInt32LE(data.byteLength, 20)
    central.writeUInt32LE(data.byteLength, 24)
    central.writeUInt16LE(nameBytes.byteLength, 28)
    central.writeUInt16LE(0, 30)
    central.writeUInt16LE(0, 32)
    central.writeUInt16LE(0, 34)
    central.writeUInt16LE(0, 36)
    central.writeUInt32LE(0, 38)
    central.writeUInt32LE(offset, 42)
    centrals.push(central, Buffer.from(nameBytes))
    offset += 30 + nameBytes.byteLength + data.byteLength
  }
  const centralBytes = Buffer.concat(centrals)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054b50, 0)
  eocd.writeUInt16LE(0, 4)
  eocd.writeUInt16LE(0, 6)
  eocd.writeUInt16LE(names.length, 8)
  eocd.writeUInt16LE(names.length, 10)
  eocd.writeUInt32LE(centralBytes.byteLength, 12)
  eocd.writeUInt32LE(offset, 16)
  eocd.writeUInt16LE(0, 20)
  return Buffer.concat([...locals, centralBytes, eocd])
}

const checkout = process.env.PDSH_DSH_CHECKOUT
const stageSkip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the real plug-in faces live in the pinned checkout'
  : false
const scratch = []

after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

test('stages every export face into lib/ and rewrites the manifest', async () => {
  const esbuild = await import('esbuild')
  const root = mkdtempSync(join(tmpdir(), 'pdsh-stage-test-'))
  scratch.push(root)
  const source = join(root, 'source')
  mkdirSync(join(source, 'src'), { recursive: true })
  writeFileSync(join(source, 'src', 'index.ts'), [
    "import { Context } from '@deepseek-ai/cordis'",
    "import { join } from 'node:path'",
    "export { extra } from './extra.ts'",
    'export const entry = join(Context.name, "index")',
    '',
  ].join('\n'))
  writeFileSync(join(source, 'src', 'extra.ts'), 'export const extra = 42\n')
  writeFileSync(join(source, 'src', 'client.ts'), 'export const client = "worker-side"\n')
  writeFileSync(join(source, 'data.json'), '{"ok":true}\n')
  writeFileSync(join(source, 'package.json'), `${JSON.stringify({
    name: '@scope/stage-test',
    version: '0.0.0',
    type: 'module',
    main: './src/index.ts',
    exports: {
      '.': './src/index.ts',
      './extra': './src/extra.ts',
      './client': './src/client.ts',
      './data.json': './data.json',
      './package.json': './package.json',
    },
    peerDependencies: { '@deepseek-ai/cordis': '*' },
  }, null, 2)}\n`)

  const staged = await stagePlugin({
    esbuild,
    package: { name: '@scope/stage-test', directory: source },
    output: join(root, 'staged'),
  })

  assert.equal(staged.manifest.main, './lib/index.js')
  assert.deepEqual(staged.manifest.exports, {
    '.': './lib/index.js',
    './extra': './lib/extra.js',
    './client': './lib/client-module.js',
    './data.json': './data.json',
    './package.json': './package.json',
  })
  assert.equal(staged.manifest.files, undefined)
  assert.ok(staged.requested.has('@deepseek-ai/cordis'))
  const built = readFileSync(join(root, 'staged', 'lib', 'index.js'), 'utf8')
  assert.match(built, /from "@deepseek-ai\/cordis"/)
  assert.match(built, /from "node:path"/)
  assert.match(built, /export \{/)
  assert.match(built, /extra/)
  assert.ok(!built.includes(root), 'debugger comments must not embed the staging path')
  assert.ok(readFileSync(join(root, 'staged', 'lib', 'client-module.js'), 'utf8').includes('worker-side'))
  assert.deepEqual(JSON.parse(readFileSync(join(root, 'staged', 'data.json'), 'utf8')), { ok: true })
  assert.equal(JSON.parse(readFileSync(join(root, 'staged', 'package.json'), 'utf8')).name, '@scope/stage-test')
  assert.equal(basename(staged.directory), 'staged')
})

test('a ./client face avoids the official packer PAGE_ASSETS path', () => {
  assert.equal(stagedFacePath('.'), 'lib/index.js')
  assert.equal(stagedFacePath('./client'), 'lib/client-module.js')
  assert.equal(stagedFacePath('./client.worker'), 'lib/client-module.worker.js')
  assert.equal(stagedFacePath('./extra'), 'lib/extra.js')
  // PAGE_ASSETS is `lib/client.js` and `lib/client.*.js`; the staged names must
  // not match either glob.
  const pageAsset = /^lib\/client(?:\.[^/]*)?\.js$/
  for (const key of ['./client', './client.worker']) {
    assert.equal(pageAsset.test(stagedFacePath(key)), false, `${key} must not stage onto a page asset`)
  }
  assert.equal(pageAsset.test('lib/client.js'), true)
  assert.equal(pageAsset.test('lib/client.worker.js'), true)
})

test('the real exec-bridge ./client face stages as a Worker module, not a page asset', { skip: stageSkip }, async () => {
  const esbuild = await import('esbuild')
  const plugin = PLUGIN_PACKAGES.find(entry => entry.name === '@phone-dsh/dsh-exec-bridge')
  assert.ok(plugin)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-stage-client-'))
  scratch.push(root)
  const staged = await stagePlugin({ esbuild, package: plugin, output: join(root, 'staged') })
  const target = staged.manifest.exports['./client']
  assert.equal(target, './lib/client-module.js')
  assert.doesNotMatch(target.replace(/^\.\//, ''), /^lib\/client(?:\.[^/]*)?\.js$/)
  assert.ok(stagedFaceTargets(staged.manifest).includes(target))

  // The staged body is ESM, which is exactly why the packer must lower it: a
  // page-asset classification would ship this `import`/`export` untransformed.
  const runtime = await import(pathToFileURL(join(checkout, 'packages/experimental/webworker-runtime/lib/index.js')).href)
  const source = readFileSync(join(root, 'staged', 'lib', 'client-module.js'), 'utf8')
  const lowering = runtime.lowerModuleSource({ filename: '/staged/lib/client-module.js', source })
  assert.equal(lowering.lowered, true)
  // The face itself may only request its shared chunks; node:http is reached
  // through the closure of staged files, every request of which must be a
  // chunk, a node: builtin or an image package.
  const requests = new Set()
  const visit = (relative) => {
    const body = readFileSync(join(root, 'staged', relative), 'utf8')
    for (const request of runtime.lowerModuleSource({ filename: `/staged/${relative}`, source: body }).moduleRequests) {
      if (requests.has(request)) continue
      requests.add(request)
      if (request.startsWith('./') || request.startsWith('../')) visit(join(relative, '..', request))
      else assert.ok(request.startsWith('node:') || isImagePackage(request), `${request} is not resolvable inside the image`)
    }
  }
  visit('lib/client-module.js')
  assert.ok(requests.has('node:http'))
})

test('a dsh.client face stages as a page asset and runs through the module-loader factory', async () => {
  const esbuild = await import('esbuild')
  const plugin = PLUGIN_PACKAGES.find(entry => entry.name === '@phone-dsh/dsh-phone-mcp')
  assert.ok(plugin)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-stage-page-client-'))
  scratch.push(root)
  const staged = await stagePlugin({ esbuild, package: plugin, output: join(root, 'staged') })
  assert.equal(staged.manifest.exports['./client'], './lib/client.js')
  assert.ok(readFileSync(join(root, 'staged', 'lib', 'client.js'), 'utf8').length > 0)

  // Execute the real artifact through the same registration facade the page
  // installs, with the module-table words served by a fake require. This proves
  // the serialized bundle exports the plugin and injects its CSS module.
  const styles = []
  const document = {
    head: { appendChild(node) { styles.push(node) } },
    querySelector() { return null },
    createElement() { return { dataset: {}, textContent: '' } },
  }
  const registrations = []
  const window = { __ModuleLoader__: { load(registration) { registrations.push(registration) } } }
  vm.runInNewContext(readFileSync(join(root, 'staged', 'lib', 'client.js'), 'utf8'),
                     { window, document, console })
  assert.equal(registrations.length, 1)
  assert.equal(registrations[0].id, plugin.name)
  const react = {
    createElement() { return {} },
    useCallback(fn) { return fn },
    useEffect() {},
    useMemo(fn) { return fn() },
    useRef(value) { return { current: value } },
    useState(value) { return [value, () => {}] },
    Fragment: {},
  }
  const required = []
  const exports = registrations[0].factory(specifier => {
    required.push(specifier)
    if (specifier === 'react') return react
    if (specifier === 'react/jsx-runtime') return { jsx() {}, jsxs() {}, Fragment: {} }
    if (specifier === '@deepseek-ai/dsh-client-ui-primitives') {
      return { Button() {}, Input() {}, Tag() {}, FileTypeIcon() {}, classifyFileType() { return 'text' } }
    }
    throw new Error(`unexpected module-table request: ${specifier}`)
  })
  assert.equal(typeof exports.apply, 'function')
  assert.ok(required.includes('react'), 'React is a module-table external, never bundled')
  assert.equal(styles.length, 1, 'the CSS module injects exactly one plugin-owned style')
  assert.equal(styles[0].dataset.plugin, plugin.name)
  assert.match(styles[0].textContent, /\.[0-9a-f]{8}_root\b/)
})

test('PLUGIN_PACKAGES is derived from the npm workspaces', () => {
  const names = PLUGIN_PACKAGES.map(plugin => plugin.name)
  for (const expected of [
    '@phone-dsh/dsh-exec-bridge',
    '@phone-dsh/dsh-subprocess-xl',
    '@phone-dsh/dsh-channel',
    '@phone-dsh/dsh-shell-ext',
    '@phone-dsh/dsh-wasi-toolbox',
    '@phone-dsh/dsh-surface-phone',
  ]) assert.ok(names.includes(expected), `${expected} must be staged into the image`)
  assert.ok(!names.includes('@phone-dsh/dsh-worker-entry'), 'the Worker assembly is the host side, not an image package')
  assert.equal(new Set(names).size, names.length)
})

test('the real feature-admin page client builds from its types source, not a literal wildcard', { skip: stageSkip }, async () => {
  const esbuild = await import('esbuild')
  const plugin = PLUGIN_PACKAGES.find(entry => entry.name === '@phone-dsh/dsh-feature-admin')
  assert.ok(plugin)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-stage-feature-admin-'))
  scratch.push(root)
  const staged = await stagePlugin({
    esbuild,
    package: plugin,
    output: join(root, 'staged'),
    checkout,
  })
  // The source package points `default` at the built page asset the DSH module
  // table serves and keeps its entry under `types`; staging must build that
  // source and must never copy a wildcard export target as a literal path.
  assert.equal(staged.manifest.exports['./client'], './lib/client.js')
  assert.deepEqual(staged.manifest.exports['.'], {
    types: './lib/index.js',
    default: './lib/index.js',
  })
  for (const key of Object.keys(staged.manifest.exports)) {
    assert.equal(key.includes('*'), false, `${key} is not a concrete image path`)
  }

  const registrations = []
  const window = { __ModuleLoader__: { load(registration) { registrations.push(registration) } } }
  vm.runInNewContext(readFileSync(join(root, 'staged', 'lib', 'client.js'), 'utf8'),
                     { window, console })
  assert.equal(registrations.length, 1)
  assert.equal(registrations[0].id, plugin.name)
  const react = {
    createElement() { return {} },
    useCallback(fn) { return fn },
    useEffect() {},
    useMemo(fn) { return fn() },
    useState(value) { return [value, () => {}] },
    useSyncExternalStore(_subscribe, getSnapshot) { return getSnapshot() },
  }
  const exports = registrations[0].factory(specifier => {
    if (specifier === 'react') return react
    throw new Error(`unexpected module-table request: ${specifier}`)
  })
  assert.equal(typeof exports.apply, 'function')
  assert.deepEqual([...exports.inject], ['slots', 'locale', 'connection', 'sessions'])
})

test('npm dependencies are bundled once, builtins get the node: prefix, and the manifest drops them', async () => {
  const esbuild = await import('esbuild')
  const root = mkdtempSync(join(tmpdir(), 'pdsh-stage-deps-'))
  scratch.push(root)
  const source = join(root, 'source')
  mkdirSync(join(source, 'src'), { recursive: true })
  mkdirSync(join(source, 'node_modules', 'fake-dep'), { recursive: true })
  writeFileSync(join(source, 'node_modules', 'fake-dep', 'package.json'), JSON.stringify({
    name: 'fake-dep', version: '1.0.0', type: 'module', main: './index.js',
  }))
  // fake-dep carries its own nested install of nested-dep, as npm does when
  // versions conflict; the nested package is bundled under its own name.
  mkdirSync(join(source, 'node_modules', 'fake-dep', 'node_modules', 'nested-dep'), { recursive: true })
  writeFileSync(join(source, 'node_modules', 'fake-dep', 'node_modules', 'nested-dep', 'package.json'), JSON.stringify({
    name: 'nested-dep', version: '0.1.0', type: 'module', main: './index.js',
  }))
  writeFileSync(join(source, 'node_modules', 'fake-dep', 'node_modules', 'nested-dep', 'index.js'), "export const nested = 'nested-dep-marker'\n")
  writeFileSync(join(source, 'node_modules', 'fake-dep', 'index.js'), [
    "import { join } from 'path'",
    "import { nested } from 'nested-dep'",
    "export const marker = join('bundled-dep', nested)",
    '',
  ].join('\n'))
  writeFileSync(join(source, 'src', 'a.ts'), "import { marker } from 'fake-dep'\nexport const a = `a:${marker}`\n")
  writeFileSync(join(source, 'src', 'b.ts'), [
    "import { marker } from 'fake-dep'",
    "import { Context } from '@deepseek-ai/cordis'",
    'export const b = `b:${marker}:${Context.name}`',
    '',
  ].join('\n'))
  writeFileSync(join(source, 'package.json'), `${JSON.stringify({
    name: '@scope/deps-test',
    version: '0.0.0',
    type: 'module',
    exports: { './a': './src/a.ts', './b': './src/b.ts' },
    dependencies: { 'fake-dep': '1.0.0', '@deepseek-ai/cordis': '*' },
  }, null, 2)}\n`)

  const staged = await stagePlugin({ esbuild, package: { name: '@scope/deps-test', directory: source }, output: join(root, 'staged') })
  assert.deepEqual(staged.manifest.dependencies, { '@deepseek-ai/cordis': '*' })
  assert.deepEqual([...staged.bundled].sort(), ['fake-dep', 'nested-dep'])
  assert.deepEqual([...staged.requested], ['@deepseek-ai/cordis'])
  assert.deepEqual([...staged.builtins], ['node:path'])

  const lib = join(root, 'staged', 'lib')
  const faces = ['a.js', 'b.js'].map(name => readFileSync(join(lib, name), 'utf8'))
  for (const face of faces) {
    assert.ok(!face.includes('bundled-dep'), 'the dependency body belongs in a shared chunk, not in each face')
    assert.ok(!/from\s*"fake-dep"/.test(face), 'no bare import of the bundled package may remain')
    assert.match(face, /from\s*"\.\/chunks\//)
  }
  const chunks = readdirSync(join(lib, 'chunks')).map(name => readFileSync(join(lib, 'chunks', name), 'utf8'))
  const carrying = chunks.filter(chunk => chunk.includes('bundled-dep'))
  assert.equal(carrying.length, 1, 'exactly one chunk carries the dependency')
  assert.match(carrying[0], /from\s*"node:path"/)
  assert.ok(!/from\s*"path"/.test(carrying[0]), 'bare builtin imports must be rewritten to node: form')
})

test('the real shell-ext stages with just-bash bundled and matches the third-party notice', async () => {
  const esbuild = await import('esbuild')
  const plugin = PLUGIN_PACKAGES.find(entry => entry.name === '@phone-dsh/dsh-shell-ext')
  assert.ok(plugin)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-stage-shell-'))
  scratch.push(root)
  const staged = await stagePlugin({ esbuild, package: plugin, output: join(root, 'staged') })

  assert.ok(staged.bundled.has('just-bash'))
  assert.ok(staged.bundled.has('diff'), 'just-bash imports its nested diff install; it ships in the image')
  for (const name of Object.keys(staged.manifest.dependencies ?? {})) {
    assert.ok(isImagePackage(name), `${name} would be unresolvable for the packer`)
  }
  assert.ok(!('just-bash' in (staged.manifest.dependencies ?? {})))

  // A host package may import a source-only DSH face (the published package
  // excludes `src/`); the real image passes the verified checkout. This fixture
  // exercises that bundling path without touching the shared reference tree.
  const sourceCheckout = join(root, 'checkout')
  mkdirSync(join(sourceCheckout, 'packages/boot/plugin-manager/src'), { recursive: true })
  // The checkout's own install is where a real build resolves `yaml`; this
  // fixture points at the plugin install instead of copying node_modules.
  symlinkSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'node_modules'),
              join(sourceCheckout, 'node_modules'), 'dir')
  writeFileSync(join(sourceCheckout, 'packages/boot/plugin-manager/src/patch.ts'), [
    "import { parseDocument } from 'yaml'",
    'export const flatten = rows => rows',
    'export async function writePluginEnabled() { return parseDocument("[]") }',
    '',
  ].join('\n'))
  // workflow-worker bundles the official meta/runtime source faces from the
  // verified checkout. The staging fixture must carry every face its staged
  // entry points reach, or the image packer sees a missing source.
  mkdirSync(join(sourceCheckout, 'packages/workflow/workflow-ptc/src'), { recursive: true })
  writeFileSync(join(sourceCheckout, 'packages/workflow/workflow-ptc/src/meta.ts'), [
    'export function validateMeta(value) { return value }',
    '',
  ].join('\n'))
  writeFileSync(join(sourceCheckout, 'packages/workflow/workflow-ptc/src/runtime.ts'), [
    'export class WorkflowExecution {',
    '  constructor(meta, body, args, limits, observer, children) {',
    '    this.meta = meta; this.body = body; this.args = args; this.limits = limits;',
    '    this.observer = observer; this.children = children',
    '  }',
    '  async drive() { return { value: null, stopReason: "completed", agentsStarted: 0 } }',
    '}',
    '',
  ].join('\n'))
  writeFileSync(join(sourceCheckout, 'packages/workflow/workflow-ptc/src/realm.ts'), [
    'export class MaterializeError extends Error {}',
    'export function renderThrown(error) { return String(error) }',
    'export function materializeFromRealm(value) { return value }',
    '',
  ].join('\n'))
  writeFileSync(join(sourceCheckout, 'packages/workflow/workflow-ptc/src/types.ts'), 'export {}\n')

  // plugins/THIRD_PARTY.md lists exactly the npm packages bundled into the
  // image across every staged package, not only shell-ext.
  const bundled = new Set(staged.bundled)
  for (const other of PLUGIN_PACKAGES) {
    if (other.name === plugin.name) continue
    const dir = mkdtempSync(join(tmpdir(), 'pdsh-stage-all-'))
    scratch.push(dir)
    for (const name of (await stagePlugin({ esbuild, package: other, output: dir, checkout: sourceCheckout })).bundled) bundled.add(name)
  }
  const notice = readFileSync(join(plugin.directory, '..', 'THIRD_PARTY.md'), 'utf8')
  const section = notice.split(/^## npm packages bundled into staged packages\s*$/m)[1]?.split(/^## /m)[0] ?? ''
  const listed = [...section.matchAll(/^\| `([^`]+)` \|/gm)].map(match => match[1]).sort()
  assert.deepEqual(listed, [...bundled].sort())

  // The staged faces are self-contained apart from the image packages: Node
  // can import the shell face once the one workspace dependency is reachable.
  const modules = join(root, 'staged', 'node_modules', '@phone-dsh')
  mkdirSync(modules, { recursive: true })
  symlinkSync(join(plugin.directory, '..', 'exec-bridge'), join(modules, 'dsh-exec-bridge'), 'dir')
  const shell = await import(pathToFileURL(join(root, 'staged', 'lib', 'shell.js')).href)
  assert.equal(typeof shell.WorkerShell, 'function')
  assert.equal(typeof shell.runShellCommand, 'function')
})

test('named builtin imports are collected per module and checked against the runtime declarations', { skip: stageSkip }, async () => {
  const members = builtinImports([
    'import { deflateSync, inflateSync as inflate } from "node:zlib";',
    'import * as fsAll from "node:fs";',
    'import pathDefault, { join } from "node:path";',
    'import { gunzipSync as O9 } from "node:zlib";',
  ].join('\n'))
  assert.deepEqual([...members.get('node:zlib')].sort(), ['deflateSync', 'gunzipSync', 'inflateSync'])
  assert.deepEqual([...members.get('node:fs')], ['*'])
  assert.deepEqual([...members.get('node:path')].sort(), ['default', 'join'])

  const runtime = await import(pathToFileURL(join(checkout, 'packages/experimental/webworker-runtime/lib/index.js')).href)
  const zlib = await builtinExports(checkout, runtime, 'node:zlib')
  assert.ok(zlib instanceof Set)
  // The pinned runtime's zlib proxy is zstd plus gzip stubs: no deflate at all.
  assert.ok(zlib.has('gunzipSync'))
  assert.ok(!zlib.has('deflateSync'))
  assert.ok(!zlib.has('inflateSync'))
  const fs = await builtinExports(checkout, runtime, 'node:fs')
  assert.ok(fs.has('readFileSync') && fs.has('promises'))
  assert.equal(await builtinExports(checkout, runtime, 'node:not-a-module'), null)
  const fsPromises = await builtinExports(checkout, runtime, 'node:fs/promises')
  assert.ok(fsPromises.has('appendFile') && fsPromises.has('rename') && fsPromises.has('writeFile'), 'multi-name const declarations are read in full')
})

// ---------------------------------------------------------------------------
// G2-FIX-8: the CPython-on-WASI artifacts must reach the packed image.
// Before the fix pack-image had no python rule at all, so the image never
// carried python.wasm/python313.zip and every python3 step exited 127 in the
// Worker. These tests use fixture bytes in a temporary directory; the real
// build products stay outside the repository.

/** Deterministic, non-repeating fixture bytes (content is asserted in the tar). */
function fixtureBytes(length, seed) {
  const bytes = Buffer.alloc(length)
  let value = seed
  for (let index = 0; index < length; index += 1) {
    value = (value * 1103515245 + 12345) & 0x7fffffff
    bytes[index] = value & 0xff
  }
  return bytes
}

function pythonFixtureDir(prefix) {
  const directory = mkdtempSync(join(tmpdir(), prefix))
  scratch.push(directory)
  return directory
}

/** sha256 hex of a byte buffer, matching what build.sh records. */
function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

/**
 * Write the source-bound `engine.json`/`sizes.json` pair a real `build.sh`
 * leaves beside `jq.wasm`.
 * @param {string} directory - artifact directory.
 * @param {Uint8Array} wasm - engine bytes.
 * @param {{ engine?: string, sourceFingerprint?: string, engineWasmSha?: string }} [overrides]
 */
function writeJqBuildReports(directory, wasm, overrides = {}) {
  const source = jqSourceReport()
  const sha = sha256Hex(wasm)
  const record = {
    algorithm: JQ_SOURCE_ALGORITHM,
    fingerprint: overrides.sourceFingerprint ?? source.fingerprint,
  }
  writeFileSync(join(directory, JQ_ENGINE_FILE), JSON.stringify({
    format: 2,
    engine: overrides.engine ?? 'jaq-core test',
    source: record,
    toolchain: 'rustc test; cargo test; target wasm32-wasip1',
    wasm: { bytes: wasm.byteLength, sha256: overrides.engineWasmSha ?? sha },
    probes: ['-n -c 1, 2'],
  }))
  writeFileSync(join(directory, JQ_SIZES_FILE), JSON.stringify({
    format: 2,
    engine: overrides.engine ?? 'jaq-core test',
    source: { ...record, files: source.files },
    jqWasm: { bytes: wasm.byteLength, sha256: sha },
    toolchain: 'rustc test; cargo test; target wasm32-wasip1',
  }))
}

/**
 * Write the two reports a real `build.sh` leaves beside the pair. `modules` is
 * the probe's answer, not the stdlib ZIP's entries: a fixture can therefore
 * carry zlib.py in the archive while the interpreter report omits zlib.
 * @param {string} directory - artifact directory.
 * @param {{ wasm: Uint8Array, stdlib: Uint8Array, modules?: string[], tarfileGzip?: boolean, zlibRuntime?: string }} options
 */
function writePythonBuildReports(directory, options) {
  const { wasm, stdlib } = options
  writeFileSync(join(directory, 'compression.json'), `${JSON.stringify({
    modules: options.modules ?? ['zlib', 'bz2', 'lzma'],
    tarfileGzip: options.tarfileGzip ?? true,
    zlib: '1.3.1',
    zlibRuntime: options.zlibRuntime ?? '1.3.1',
    pythonVersion: '3.13',
  }, null, 2)}\n`)
  writeFileSync(join(directory, 'sizes.json'), `${JSON.stringify({
    format: 1,
    pythonWasm: { bytes: wasm.byteLength, sha256: sha256Hex(wasm) },
    pythonStdlibZip: { bytes: stdlib.byteLength, sha256: sha256Hex(stdlib) },
  }, null, 2)}\n`)
}

test('python artifact resolution fails loud with the build.sh command when files are missing', () => {
  const directory = pythonFixtureDir('pdsh-python-missing-')
  assert.throws(
    () => resolvePythonSources({ python: directory, env: {} }),
    (error) => {
      const message = error instanceof Error ? error.message : String(error)
      assert.match(message, /python\.wasm/)
      assert.match(message, /python313\.zip/)
      assert.match(message, /wasi-toolbox\/python\/build\.sh/)
      return true
    },
  )

  // A half-supplied env pair is the same class of failure: no silent skip.
  const root = pythonFixtureDir('pdsh-python-env-')
  const wasm = join(root, PYTHON_WASM_FILE)
  writeFileSync(wasm, fixtureBytes(64, 7))
  assert.throws(
    () => resolvePythonSources({ env: { PDSH_PYTHON_STDLIB: join(root, PYTHON_STDLIB_FILE) } }),
    /PDSH_PYTHON_WASM/,
  )
  // PDSH_PYTHON_WASM alone defaults the stdlib to its build.sh sibling, and a
  // missing sibling is still loud rather than a partial image.
  assert.throws(
    () => resolvePythonSources({ env: { PDSH_PYTHON_WASM: wasm } }),
    /python313\.zip/,
  )
})

test('python artifact resolution reads a build.sh output directory or the env pair', () => {
  const root = pythonFixtureDir('pdsh-python-resolve-')
  const wasm = join(root, PYTHON_WASM_FILE)
  const stdlib = join(root, PYTHON_STDLIB_FILE)
  writeFileSync(wasm, fixtureBytes(128, 3))
  writeFileSync(stdlib, fixtureBytes(256, 5))

  const fromDirectory = resolvePythonSources({ python: root, env: {} })
  assert.deepEqual(fromDirectory, { wasm, stdlib, directory: root })

  const fromEnv = resolvePythonSources({ env: { PDSH_PYTHON_WASM: wasm, PDSH_PYTHON_STDLIB: stdlib } })
  assert.deepEqual(fromEnv, { wasm, stdlib, directory: root })

  assert.equal(resolvePythonSources({ env: {} }), undefined, 'no request means no python in the image')
})

test('the compression block comes from compression.json, never from stdlib ZIP entries', () => {
  const root = pythonFixtureDir('pdsh-python-compression-probe-')
  const artifacts = join(root, 'python')
  mkdirSync(artifacts, { recursive: true })
  const wasm = fixtureBytes(512, 13)
  // The archive still contains zlib.py while the interpreter probe reports
  // only bz2/lzma. The old packer inferred zlib=yes from this ZIP entry and
  // printed "linked" in AGENTS.md (E09 / G2-FIX-27 regression point).
  const stdlib = storedZip({
    'json/__init__.py': '',
    'zlib.py': '',
    'bz2.py': '',
    'lzma.py': '',
  })
  const wasmPath = join(artifacts, PYTHON_WASM_FILE)
  const stdlibPath = join(artifacts, PYTHON_STDLIB_FILE)
  writeFileSync(wasmPath, wasm)
  writeFileSync(stdlibPath, stdlib)
  writePythonBuildReports(artifacts, { wasm, stdlib, modules: ['bz2', 'lzma'] })

  const output = join(root, 'staged')
  const staged = stagePythonArtifacts({ wasm: wasmPath, stdlib: stdlibPath, directory: artifacts, output })
  // python_modules stays the ZIP fact (zlib.py is importable in principle)...
  assert.deepEqual(staged.probe.modules, ['bz2', 'json', 'lzma', 'zlib'])
  // ...and the compression capability is only the probe's answer.
  assert.deepEqual(staged.probe.compression, {
    modules: ['bz2', 'lzma'],
    tarfileGzip: true,
    zlibRuntime: '1.3.1',
  })
  const stagedProbe = JSON.parse(readFileSync(join(output, PYTHON_MODULES_FILE), 'utf8'))
  assert.deepEqual(stagedProbe.compression.modules, ['bz2', 'lzma'])
})

test('staging refuses a python pair without compression.json', () => {
  const root = pythonFixtureDir('pdsh-python-no-compression-')
  const wasm = join(root, PYTHON_WASM_FILE)
  const stdlib = join(root, PYTHON_STDLIB_FILE)
  const wasmBytes = fixtureBytes(64, 3)
  const stdlibBytes = storedZip({ 'json/__init__.py': '' })
  writeFileSync(wasm, wasmBytes)
  writeFileSync(stdlib, stdlibBytes)
  assert.throws(
    () => stagePythonArtifacts({ wasm, stdlib, directory: root, output: join(root, 'staged') }),
    (error) => {
      const message = error instanceof Error ? error.message : String(error)
      assert.match(message, /compression\.json/)
      assert.match(message, /wasi-toolbox\/python\/build\.sh/)
      return true
    },
  )
})

test('staging refuses a compression report whose sizes.json describes other bytes', () => {
  const root = pythonFixtureDir('pdsh-python-sha-mismatch-')
  const wasm = join(root, PYTHON_WASM_FILE)
  const stdlib = join(root, PYTHON_STDLIB_FILE)
  const wasmBytes = fixtureBytes(64, 3)
  const stdlibBytes = storedZip({ 'json/__init__.py': '' })
  writeFileSync(wasm, wasmBytes)
  writeFileSync(stdlib, stdlibBytes)
  writePythonBuildReports(root, { wasm: wasmBytes, stdlib: stdlibBytes })
  // Same filenames, different interpreter: the report still claims the old
  // sha256, so this is a stale report on a foreign pair and must not be packed.
  writeFileSync(wasm, fixtureBytes(64, 4))
  assert.throws(
    () => stagePythonArtifacts({ wasm, stdlib, directory: root, output: join(root, 'staged') }),
    (error) => {
      const message = error instanceof Error ? error.message : String(error)
      assert.match(message, /python\.wasm has sha256/)
      assert.match(message, /sizes\.json records/)
      assert.match(message, /wasi-toolbox\/python\/build\.sh/)
      return true
    },
  )
})

test('staging refuses a malformed compression report', () => {
  const root = pythonFixtureDir('pdsh-python-bad-report-')
  const wasm = join(root, PYTHON_WASM_FILE)
  const stdlib = join(root, PYTHON_STDLIB_FILE)
  const wasmBytes = fixtureBytes(64, 3)
  const stdlibBytes = storedZip({ 'json/__init__.py': '' })
  writeFileSync(wasm, wasmBytes)
  writeFileSync(stdlib, stdlibBytes)
  writePythonBuildReports(root, { wasm: wasmBytes, stdlib: stdlibBytes })
  writeFileSync(join(root, 'compression.json'), `${JSON.stringify({ modules: 'zlib', tarfileGzip: true })}\n`)
  assert.throws(
    () => stagePythonArtifacts({ wasm, stdlib, directory: root, output: join(root, 'staged') }),
    /modules\[\] as an array of strings/,
  )
})

test('the packed image carries python.wasm and python313.zip at the documented path', { skip: stageSkip, timeout: 180_000 }, async () => {
  const root = pythonFixtureDir('pdsh-python-image-')
  const artifacts = join(root, 'python')
  mkdirSync(artifacts, { recursive: true })
  const wasm = fixtureBytes(2048, 11)
  const stdlib = storedZip({
    'json/__init__.py': '',
    'json/decoder.py': '',
    're.py': 'import sys\n',
    'zlib.py': '',
    '__pycache__/ignored.py': '',
    'README.txt': '',
  })
  writeFileSync(join(artifacts, PYTHON_WASM_FILE), wasm)
  writeFileSync(join(artifacts, PYTHON_STDLIB_FILE), stdlib)
  writePythonBuildReports(artifacts, { wasm, stdlib })
  // The packer reads the pair plus the two reports build.sh leaves beside it;
  // it must never write into (or delete from) that source directory.
  const expectedInputs = [PYTHON_STDLIB_FILE, PYTHON_WASM_FILE, PYTHON_COMPRESSION_FILE, PYTHON_SIZES_FILE].sort()
  const inputFiles = readdirSync(artifacts).sort()
  assert.deepEqual(inputFiles, expectedInputs, 'the fixture must carry the pair and both build reports')
  const inputBytes = new Map(inputFiles.map(name => [name, readFileSync(join(artifacts, name))]))
  const compressionReport = JSON.parse(readFileSync(join(artifacts, PYTHON_COMPRESSION_FILE), 'utf8'))
  const sizesReport = JSON.parse(readFileSync(join(artifacts, PYTHON_SIZES_FILE), 'utf8'))
  // The compression capability is bound to this exact pair by sizes.json.
  assert.equal(sizesReport.pythonWasm.sha256, sha256Hex(wasm))
  assert.equal(sizesReport.pythonStdlibZip.sha256, sha256Hex(stdlib))
  assert.deepEqual(compressionReport.modules, ['zlib', 'bz2', 'lzma'])

  const out = join(root, 'out')
  const result = await packImage({ out, python: artifacts, env: {} })
  const sizes = JSON.parse(readFileSync(join(out, 'sizes.json'), 'utf8'))

  assert.equal(result.python.mount, PYTHON_IMAGE_MOUNT)
  assert.equal(sizes.python.mount, PYTHON_IMAGE_MOUNT)
  assert.deepEqual(sizes.python.files, [
    { path: `${PYTHON_IMAGE_MOUNT}/${PYTHON_WASM_FILE}`, bytes: wasm.byteLength },
    { path: `${PYTHON_IMAGE_MOUNT}/${PYTHON_STDLIB_FILE}`, bytes: stdlib.byteLength },
  ])
  // The build-time probe is the manifest's python_modules source of truth.
  assert.deepEqual(sizes.python.modules, ['json', 're', 'zlib'])
  assert.equal(sizes.python.modules_path, `${PYTHON_IMAGE_MOUNT}/${PYTHON_MODULES_FILE}`)

  // The bytes are really inside the packed tar, not only in the report: the
  // ustar header carries the image path and the stored body is the fixture.
  const tar = gunzipSync(readFileSync(join(out, 'image.tar.gz')))
  for (const [name, bytes] of [[PYTHON_WASM_FILE, wasm], [PYTHON_STDLIB_FILE, stdlib]]) {
    assert.ok(tar.includes(Buffer.from(`${PYTHON_IMAGE_MOUNT}/${name}`)), `${name} has no tar entry`)
    assert.ok(tar.includes(bytes), `${name} bytes are not in the packed tar`)
  }

  // The runtime mounts image entries under /dsh; that is exactly the path the
  // Worker boot reads, so prove the mapping with the checkout's own loader.
  const runtime = await import(pathToFileURL(join(checkout, 'packages/experimental/webworker-runtime/lib/index.js')).href)
  const mounted = runtime.loadVfsImage(tar, '/dsh')
  assert.deepEqual(Buffer.from(mounted.readFileSync(`/dsh/${PYTHON_IMAGE_MOUNT}/${PYTHON_WASM_FILE}`)), wasm)
  assert.deepEqual(Buffer.from(mounted.readFileSync(`/dsh/${PYTHON_IMAGE_MOUNT}/${PYTHON_STDLIB_FILE}`)), stdlib)
  const probe = JSON.parse(Buffer.from(mounted.readFileSync(`/dsh/${PYTHON_IMAGE_MOUNT}/${PYTHON_MODULES_FILE}`)).toString('utf8'))
  assert.deepEqual(probe.modules, ['json', 're', 'zlib'])
  // The compression block is the build report, bound to these bytes; it is
  // never inferred from the ZIP entries (which also contain zlib.py here).
  const expectedCompression = {
    modules: [...compressionReport.modules].sort(),
    tarfileGzip: compressionReport.tarfileGzip,
    ...compressionReport.zlibRuntime === undefined ? {} : { zlibRuntime: compressionReport.zlibRuntime },
  }
  assert.deepEqual(probe.compression, expectedCompression)
  assert.deepEqual(sizes.python.compression, probe.compression)

  // Artifact bytes never enter the repository: the staged copy lived in the
  // packer's temporary staging directory, which packImage removes.
  assert.equal(dirname(result.output), root)
  assert.deepEqual(readdirSync(artifacts).sort(), inputFiles, 'packImage must not write into the source artifact directory')
  for (const [name, bytes] of inputBytes) {
    assert.deepEqual(readFileSync(join(artifacts, name)), bytes, `${name} changed during packing`)
  }
})

test('the python module probe reads the produced stdlib, not a hand-written list', () => {
  const zip = storedZip({
    'json/__init__.py': '',
    'json/decoder.py': '',
    're.py': '',
    'zlib.py': '',
    'tarfile.py': '',
    'bz2.py': '',
    'lzma.py': '',
    '__pycache__/junk.py': '',
    'not-a-module.py': '',
    'docs/readme.txt': '',
  })
  assert.deepEqual(
    zipEntryNames(zip).filter(name => name.endsWith('.py')).sort(),
    ['__pycache__/junk.py', 'bz2.py', 'json/__init__.py', 'json/decoder.py', 'lzma.py', 'not-a-module.py', 're.py', 'tarfile.py', 'zlib.py'],
  )
  assert.deepEqual(pythonModulesFromZipEntries(zipEntryNames(zip)), ['bz2', 'json', 'lzma', 're', 'tarfile', 'zlib'])
  assert.deepEqual(probePythonModules(zip), ['bz2', 'json', 'lzma', 're', 'tarfile', 'zlib'])
})

test('the image refuses a roster or profile without the instruction loader', () => {
  const roster = [AGENT_INSTRUCTIONS_PACKAGE]
  const rows = [{ id: AGENT_INSTRUCTIONS_ROW, name: AGENT_INSTRUCTIONS_PACKAGE }]
  assert.deepEqual(assertInstructionSource(roster, rows), {
    package: AGENT_INSTRUCTIONS_PACKAGE,
    row: AGENT_INSTRUCTIONS_ROW,
  })
  // Nested insert and group composition are searched like the loader does.
  assert.doesNotThrow(() => assertInstructionSource(roster, [{ insert: [{ id: AGENT_INSTRUCTIONS_ROW }] }]))
  assert.doesNotThrow(() => assertInstructionSource(roster, [{ group: true, config: [{ id: AGENT_INSTRUCTIONS_ROW }] }]))
  // Dropping the package, dropping the row, or disabling it breaks the fix.
  assert.throws(() => assertInstructionSource([], rows), /missing from the roster/)
  assert.throws(() => assertInstructionSource(roster, []), /composes no agent-instructions row/)
  assert.throws(
    () => assertInstructionSource(roster, [{ id: AGENT_INSTRUCTIONS_ROW, disabled: true }]),
    /disabled in the phone profile/,
  )
  assert.throws(
    () => assertInstructionSource(roster, [{ id: AGENT_INSTRUCTIONS_ROW, disabled: { js: 'process.env.X' } }]),
    /disabled in the phone profile/,
  )
})

test('the packed image records no python section when the artifacts are not requested', { skip: stageSkip, timeout: 180_000 }, async () => {
  const root = pythonFixtureDir('pdsh-python-none-')
  const out = join(root, 'out')
  const result = await packImage({ out, env: {} })
  assert.equal(result.python, undefined)
  const sizes = JSON.parse(readFileSync(join(out, 'sizes.json'), 'utf8'))
  assert.equal(sizes.python, undefined, 'sizes.json must not claim python the image does not carry')
  // G2-FIX-60: the image record names the Worker-side sharp replacement, and
  // the Worker bundle check that ran beside packing proves the shim is in it.
  assert.equal(sizes.sharp_shim.marker, SHARP_SHIM_MARKER)
  assert.equal(sizes.sharp_shim.runtime_proxy, './node/external_packages/sharp.ts')
  assert.match(sizes.sharp_shim.worker_bundle, new RegExp(SHARP_SHIM_MARKER.replaceAll('/', '\\/')))
  assert.equal(result.sharp.specifier, 'sharp')
})

test('explicit --without-python behavior ignores configured artifacts and records the omission', { skip: stageSkip, timeout: 180_000 }, async () => {
  const root = pythonFixtureDir('pdsh-python-explicit-off-')
  const out = join(root, 'out')
  const result = await packImage({
    out,
    withoutPython: true,
    env: { PDSH_PYTHON_WASM: join(root, 'must-not-be-read.wasm') },
  })
  assert.equal(result.python, undefined)
  assert.equal(result.provenance.python, false)
  const sizes = JSON.parse(readFileSync(join(out, 'sizes.json'), 'utf8'))
  assert.equal(sizes.python, undefined)
  const provenance = JSON.parse(readFileSync(join(out, 'phone-dsh-provenance.json'), 'utf8'))
  assert.equal(provenance.python, false)
})

test('the sharp replacement seam check fails loud when the runtime stops replacing it', () => {
  const facts = assertSharpReplacement({
    REPLACED_EXTERNAL_PACKAGES: ['sharp', 'ws'],
    MODULE_PROXIES: { sharp: './node/external_packages/sharp.ts' },
  })
  assert.deepEqual(facts, {
    specifier: 'sharp',
    runtime_proxy: './node/external_packages/sharp.ts',
    shim: 'worker-entry/src/sharp-shim.ts',
    marker: SHARP_SHIM_MARKER,
  })
  assert.throws(
    () => assertSharpReplacement({ REPLACED_EXTERNAL_PACKAGES: ['ws'], MODULE_PROXIES: { sharp: './x.ts' } }),
    /REPLACED_EXTERNAL_PACKAGES/,
  )
  assert.throws(
    () => assertSharpReplacement({ REPLACED_EXTERNAL_PACKAGES: ['sharp'], MODULE_PROXIES: {} }),
    /MODULE_PROXIES/,
  )
})

test('the pack-image CLI takes --python and fails loud before packing when it is empty', { skip: stageSkip, timeout: 60_000 }, () => {
  const root = pythonFixtureDir('pdsh-python-cli-')
  const empty = join(root, 'empty')
  mkdirSync(empty, { recursive: true })
  const script = join(dirname(fileURLToPath(import.meta.url)), 'pack-image.mjs')
  const result = spawnSync(process.execPath, [script, '--out', join(root, 'out'), '--python', empty], {
    encoding: 'utf8',
    timeout: 50_000,
  })
  assert.equal(result.status, 1, `${result.stdout ?? ''}\n${result.stderr ?? ''}`)
  assert.match(result.stderr, /--python/)
  assert.match(result.stderr, /wasi-toolbox\/python\/build\.sh/)
})


test('jq staging verifies the build report and refuses other bytes', () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-pack-'))
  scratch.push(root)
  const wasm = Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])
  writeFileSync(join(root, JQ_WASM_FILE), wasm)
  writeJqBuildReports(root, wasm)
  const sources = resolveJqSources({ jq: root })
  assert.equal(sources.wasm, join(root, JQ_WASM_FILE))
  const staged = stageJqArtifacts({ ...sources, output: join(root, 'stage') })
  assert.equal(staged.engine, 'jaq-core test')
  assert.equal(readFileSync(join(root, 'stage', JQ_WASM_FILE)).byteLength, wasm.byteLength)
  assert.ok(readFileSync(join(root, 'stage', JQ_ENGINE_FILE), 'utf8').includes('jaq-core test'))

  writeFileSync(join(root, JQ_WASM_FILE), Buffer.concat([wasm, Buffer.from([0])]))
  assert.throws(() => stageJqArtifacts({ ...sources, output: join(root, 'stage2') }), /describes other bytes/u)
})

test('jq staging requires a non-empty matching engine identity', () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-engine-identity-'))
  scratch.push(root)
  const wasm = Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])
  writeFileSync(join(root, JQ_WASM_FILE), wasm)
  const mutateReport = (name, update) => {
    const path = join(root, name)
    const report = JSON.parse(readFileSync(path, 'utf8'))
    update(report)
    writeFileSync(path, `${JSON.stringify(report, null, 2)}\n`)
  }
  const attempt = output => stageJqArtifacts({
    ...resolveJqSources({ jq: root }),
    output: join(root, output),
  })

  // 1. engine.json lost the identity entirely.
  writeJqBuildReports(root, wasm)
  mutateReport(JQ_ENGINE_FILE, report => { delete report.engine })
  assert.throws(() => attempt('missing-engine'), /must record a non-empty engine identity/u)

  // 2. Both reports carry only whitespace instead of a real identity.
  writeJqBuildReports(root, wasm)
  mutateReport(JQ_ENGINE_FILE, report => { report.engine = '   ' })
  mutateReport(JQ_SIZES_FILE, report => { report.engine = '   ' })
  assert.throws(() => attempt('blank-engine'), /must record a non-empty engine identity/u)

  // 3. sizes.json lost the identity that binds its digest to the engine.
  writeJqBuildReports(root, wasm)
  mutateReport(JQ_SIZES_FILE, report => { delete report.engine })
  assert.throws(() => attempt('missing-sizes-engine'), /must record a non-empty engine identity/u)

  // 4. Both are non-empty but name different engines.
  writeJqBuildReports(root, wasm)
  mutateReport(JQ_SIZES_FILE, report => { report.engine = 'jaq-core other' })
  assert.throws(() => attempt('mismatched-engine'), /name different engines/u)
})

test('jq staging refuses a source change, a swapped report and a replaced wasm', () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-source-bound-'))
  scratch.push(root)
  const wasm = Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])

  // 1. Source changed after the artifact was built: the report fingerprint no
  //    longer names this checkout, so the packer must rebuild rather than
  //    re-label old bytes with the new source hash.
  writeFileSync(join(root, JQ_WASM_FILE), wasm)
  writeJqBuildReports(root, wasm, { sourceFingerprint: '0'.repeat(64) })
  assert.throws(
    () => resolveJqSources({ jq: root }) && stageJqArtifacts({ ...resolveJqSources({ jq: root }), output: join(root, 'stale') }),
    /does not name this checkout's jq source|source/u,
  )

  // 2. Reports swapped between two builds: engine.json describes other bytes
  //    even though sizes.json still matches the wasm on disk.
  writeJqBuildReports(root, wasm, { engineWasmSha: '1'.repeat(64) })
  assert.throws(
    () => stageJqArtifacts({ ...resolveJqSources({ jq: root }), output: join(root, 'swapped') }),
    /engine\.json does not describe|sha256 mismatch/u,
  )

  // 3. Wasm replaced after both reports were written.
  writeJqBuildReports(root, wasm)
  writeFileSync(join(root, JQ_WASM_FILE), Buffer.concat([wasm, Buffer.from([1])]))
  assert.throws(
    () => stageJqArtifacts({ ...resolveJqSources({ jq: root }), output: join(root, 'replaced') }),
    /describes other bytes|sha256/u,
  )
})

test('jq enablement is explicit and names the build command when incomplete', () => {
  assert.equal(resolveJqSources({ env: {} }), undefined)
  const root = mkdtempSync(join(tmpdir(), 'pdsh-jq-missing-'))
  scratch.push(root)
  assert.throws(
    () => resolveJqSources({ jq: root }),
    /wasi-toolbox\/jq\/build\.sh/u,
  )
})

test('the jq image mount is the path the boot wiring reads', () => {
  assert.equal(JQ_IMAGE_MOUNT, 'bin/jq')
  assert.equal(JQ_WASM_FILE, 'jq.wasm')
})

test('a controlled checkout override must supply both SHA and version', async () => {
  const out = mkdtempSync(join(tmpdir(), 'pdsh-override-pair-'))
  scratch.push(out)
  await assert.rejects(
    packImage({ out, checkout: checkout ?? '.', checkoutSha: readPin().commit }),
    /--checkout-sha and --checkout-version must be supplied together/,
  )
})

test('a controlled checkout override still verifies the explicit SHA', { skip: stageSkip, timeout: 60_000 }, async () => {
  const pin = readPin()
  const out = mkdtempSync(join(tmpdir(), 'pdsh-override-sha-'))
  scratch.push(out)
  await assert.rejects(
    packImage({ out, checkout, checkoutSha: '0'.repeat(40), checkoutVersion: pin.version }),
    /HEAD is .*but dsh-pin\.json pins/,
  )
})
