#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Build the phone-style DSH bundle: one ESM file that boots a composed profile
// (dsh-base + a surface bundle + the phone patch) without a package tree on
// disk, without native addons, and without the require-builtin addon.
//
//   node bundle/build.mjs                       # both surfaces (headless + resident phone)
//   node bundle/build.mjs --surface headless    # one-shot desktop/headless bundle only
//   node bundle/build.mjs --surface phone       # resident phone surface bundle only
//   node bundle/build.mjs [--out dist] [--phone-patch profile/phone.cordis.patch.yml]
//                         [--extra-patch file.yml]... [--no-minify]
//
// Output:
//   <out>/dsh-phone.mjs               headless one-shot bundle (desktop simulation, `dsh` one-shot)
//   <out>/dsh-phone-surface.mjs       resident phone surface bundle (LocalDSHHost launches this one)
//   <out>/size-report[-phone-surface].md, <out>/meta[-phone-surface].json
//
// The two surfaces differ only in the patch layer applied between `dsh-base`
// and the phone profile: `@deepseek-ai/dsh-headless` (runs one task, exits) or
// `surface-phone` (binds the DSH remote/web API and stays resident).

import { mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'
import { gzipSync } from 'node:zlib'

// The Worker consumes just-bash's browser bundle through the byte-guarded
// terminal-state seam. Run the installer here as well as in the npm lifecycle
// hooks: `npm ci --ignore-scripts && npm run bundle` must not stage an
// unpatched engine whose terminal metadata is missing. The installer is
// idempotent and refuses a wrong version/hash.
await import('../shell-ext/tools/patch-just-bash.mjs')

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const require = createRequire(join(root, 'package.json'))

const { values: args } = parseArgs({
  options: {
    surface: { type: 'string', default: 'all' },
    out: { type: 'string', default: join(root, 'dist') },
    'phone-patch': { type: 'string', default: join(root, 'profile', 'phone.cordis.patch.yml') },
    'extra-patch': { type: 'string', multiple: true, default: [] },
    minify: { type: 'boolean', default: true },
    'no-minify': { type: 'boolean', default: false },
  },
})

const phoneSurfaceRoot = join(root, 'surface-phone')
const SURFACES = {
  headless: {
    package: '@deepseek-ai/dsh-headless',
    patch: () => require.resolve('@deepseek-ai/dsh-headless/cordis.patch.yml'),
    output: 'dsh-phone.mjs',
    report: 'size-report.md',
    meta: 'meta.json',
    modules: 'modules.generated.mjs',
    alias: {},
  },
  phone: {
    // The resident-surface layer is part of this repository, not an installed
    // package: the bundle aliases its package name to the source file.
    package: '@phone-dsh/dsh-surface-phone',
    patch: () => join(phoneSurfaceRoot, 'cordis.patch.yml'),
    output: 'dsh-phone-surface.mjs',
    report: 'size-report-phone-surface.md',
    meta: 'meta-phone-surface.json',
    modules: 'modules.phone-surface.generated.mjs',
    alias: { '@phone-dsh/dsh-surface-phone': join(phoneSurfaceRoot, 'src', 'index.js') },
  },
}
const requested = args.surface === 'all' ? Object.keys(SURFACES) : [args.surface]
for (const name of requested) {
  if (SURFACES[name] === undefined) {
    throw new Error(`unknown surface ${JSON.stringify(name)}; supported: ${['all', ...Object.keys(SURFACES)].join(', ')}`)
  }
}

const esbuild = await import(require.resolve('esbuild'))
const appBoot = await import(require.resolve('@deepseek-ai/dsh-app-boot'))
const dshVersion = JSON.parse(readFileSync(require.resolve('@deepseek-ai/dsh/package.json'), 'utf8')).version
const minify = args.minify && !args['no-minify']
const out = resolve(args.out)
mkdirSync(out, { recursive: true })

// Native or process-spawning packages the phone runtime cannot load. Each stub
// keeps the import shape and fails loudly when a call reaches it.
const stub = (file) => join(here, 'stubs', file)
const nativeAlias = {
  '@deepseek-ai/node-addon-system/flock': stub('flock.mjs'),
  'node-addon-require-builtin': stub('require-builtin.mjs'),
  'node-pty': stub('unavailable.mjs'),
  'sharp': stub('unavailable.mjs'),
  'koffi': stub('unavailable.mjs'),
  'execa': stub('unavailable.mjs'),
  '@deepseek-ai/libreoffice-kit': stub('unavailable.mjs'),
  '@vscode/ripgrep': stub('ripgrep.mjs'),
}

/** Compose the layers, generate the static plugin table, and bundle one surface. */
async function buildSurface(surfaceName) {
  const surface = SURFACES[surfaceName]
  const surfacePatch = surface.patch()
  const layers = [
    { label: 'base', file: require.resolve('@deepseek-ai/dsh-base/cordis.patch.yml') },
    { label: 'surface', file: surfacePatch },
    { label: 'phone', file: resolve(args['phone-patch']) },
    ...args['extra-patch'].map((file, index) => ({ label: `extra-${index}`, file: resolve(file) })),
  ]

  // Compose exactly as boot does, then collect every plugin name the tree may
  // import. A row disabled with a literal `true` is never imported; rows gated by
  // an expression stay in, because the bundle cannot evaluate them at build time.
  const composeWarnings = []
  const composed = appBoot.composeEntries(layers.map(layer => appBoot.loadOverlayPatches('dsh', layer.file)), message => composeWarnings.push(message))
  for (const message of composeWarnings) process.stderr.write(`build: ${message}\n`)
  // A skipped patch is a silent no-op at boot (e.g. a row that tried to swap a plugin name); refuse it here.
  if (composeWarnings.length > 0) throw new Error(`profile composition produced ${composeWarnings.length} skipped patch(es); fix the phone patch`)
  const names = new Set()
  const skipped = []
  const visit = (entry) => {
    if (entry.disabled === true) { skipped.push(entry.id ?? entry.name); return }
    if (typeof entry.name === 'string' && !entry.name.startsWith('cordis:')) names.add(entry.name)
    if (entry.group && Array.isArray(entry.config)) entry.config.forEach(visit)
  }
  composed.forEach(visit)
  // Plugins that other plugins mount by name at runtime (not as config rows).
  for (const name of ['@deepseek-ai/cordis-plugin-include', '@deepseek-ai/cordis-plugin-group']) names.add(name)

  // Strict Typert descriptors. `typert-loader` discovers them by resolving each
  // mounted package's package.json, which a single-file bundle does not ship;
  // without them the gateway falls back to reading method parameter names from
  // the (minified) class source and the wire fields stop matching the SDK.
  // Collect every composed package that exports `./typert` and let the entry
  // register the manifests before the tree mounts. Only the resident surface
  // serves the gateway, so the one-shot bundle keeps an empty list.
  const typertManifests = []
  if (surfaceName === 'phone') {
    const seen = new Set()
    for (const name of [...names].sort()) {
      const packageName = name.startsWith('@') ? name.split('/').slice(0, 2).join('/') : name.split('/')[0]
      if (seen.has(packageName)) continue
      seen.add(packageName)
      let manifestPath
      try {
        const manifest = JSON.parse(readFileSync(require.resolve(`${packageName}/package.json`), 'utf8'))
        const target = manifest.exports?.['./typert']
        const relative = typeof target === 'string' ? target : target?.default
        if (typeof relative !== 'string') continue
        manifestPath = `${packageName}/typert`
      } catch {
        continue
      }
      typertManifests.push({ packageName, manifestPath })
    }
  }

  const generated = join(out, surface.modules)
  const sorted = [...names].sort()
  writeFileSync(generated, [
    '// Generated by bundle/build.mjs. Static plugin table and strict Typert manifests.',
    ...typertManifests.map((entry, index) => `import { TYPERT as PDSH_TYPERT_${index} } from ${JSON.stringify(entry.manifestPath)}`),
    '',
    'export const MODULES = {',
    ...sorted.map(name => `  ${JSON.stringify(name)}: () => import(${JSON.stringify(name)}),`),
    '}',
    `export const TYPERT = [${typertManifests.map((entry, index) => `PDSH_TYPERT_${index}`).join(', ')}]`,
    `export const LAYERS = ${JSON.stringify(Object.fromEntries(layers.map(layer => [layer.label, readFileSync(layer.file, 'utf8')])))}`,
    `export const BUILD = ${JSON.stringify({ dshVersion, surface: surfaceName, layers: layers.map(l => l.label), builtAt: new Date().toISOString() })}`,
    '',
  ].join('\n'))

  const inlinedManifests = []
  const result = await esbuild.build({
    entryPoints: [join(here, 'entry.ts')],
    outfile: join(out, surface.output),
    bundle: true,
    platform: 'node',
    format: 'esm',
    target: 'node22',
    minify,
    keepNames: true,
    sourcemap: false,
    legalComments: 'none',
    metafile: true,
    logLevel: 'warning',
    alias: { ...nativeAlias, ...surface.alias },
    nodePaths: [join(root, 'node_modules')],
    define: {
      'process.env.PDSH_DSH_BUNDLED': '"1"',
    },
    // CommonJS dependencies inside an ESM bundle still call require() for builtins.
    banner: {
      js: "import { createRequire as __xlCreateRequire } from 'node:module'; const require = __xlCreateRequire(import.meta.url);",
    },
    plugins: [{
      name: 'generated-modules',
      setup(build) {
        build.onResolve({ filter: /^xl:modules$/ }, () => ({ path: generated }))
      },
    }, {
      // Packages read their own manifest at module init (`createRequire(import.meta.url)("../package.json")`,
      // e.g. dsh-llm's attribution headers). In one file there is no package tree, so inline name/version.
      name: 'inline-package-manifests',
      setup(build) {
        build.onLoad({ filter: /node_modules[\\/].*\.js$/ }, (load) => {
          const text = readFileSync(load.path, 'utf8')
          if (!text.includes('../package.json')) return undefined
          const pattern = /createRequire\w*\(\s*import\.meta\.url\s*\)\(\s*(["'])\.\.\/package\.json\1\s*\)/g
          if (!pattern.test(text)) return undefined
          const manifest = JSON.parse(readFileSync(join(dirname(load.path), '..', 'package.json'), 'utf8'))
          inlinedManifests.push(manifest.name)
          return { contents: text.replace(pattern, `(${JSON.stringify({ name: manifest.name, version: manifest.version })})`), loader: 'js' }
        })
      },
    }],
  })

  // Size report: total, gzip, and the heaviest packages by bundled bytes.
  const bundlePath = join(out, surface.output)
  const bundleBytes = statSync(bundlePath).size
  const gzipBytes = gzipSync(readFileSync(bundlePath)).length
  const byPackage = new Map()
  for (const [input, info] of Object.entries(result.metafile.outputs[relative(process.cwd(), bundlePath)]?.inputs ?? {})) {
    const match = /node_modules\/((?:@[^/]+\/)?[^/]+)/.exec(input)
    const key = match ? match[1] : input.includes('modules') ? '(generated plugin table + profile layers)' : `phone-dsh: ${input.replace(/^(\.\.\/)+/, '').split('/')[0]}`
    byPackage.set(key, (byPackage.get(key) ?? 0) + info.bytesInOutput)
  }
  const top = [...byPackage.entries()].sort((a, b) => b[1] - a[1])
  const kib = (n) => `${(n / 1024).toFixed(1)} KiB`
  const report = [
    '# dsh-phone bundle size report',
    '',
    `- DSH version: ${dshVersion}`,
    `- Surface: ${surfaceName}`,
    `- Plugin modules in the static table: ${sorted.length}`,
    `- Rows skipped (literally disabled): ${skipped.length}`,
    `- Bundle: ${kib(bundleBytes)} (${bundleBytes} bytes), gzip ${kib(gzipBytes)}, minify=${minify}`,
    `- Inlined package manifests: ${[...new Set(inlinedManifests)].sort().join(', ') || 'none'}`,
    '',
    '| Package | Bytes in bundle |',
    '|---|---|',
    ...top.slice(0, 40).map(([name, bytes]) => `| ${name} | ${kib(bytes)} |`),
    '',
  ]
  writeFileSync(join(out, surface.report), report.join('\n'))
  writeFileSync(join(out, surface.meta), JSON.stringify(result.metafile))
  process.stdout.write(`${report.slice(0, 9).join('\n')}\nwrote ${bundlePath}\n`)
  return bundlePath
}

for (const surfaceName of requested) await buildSurface(surfaceName)
