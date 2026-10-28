// SPDX-License-Identifier: MIT
/**
 * Regression tests for the iOS probe asset staging steps (G2-FIX-54).
 *
 * The W7 python runtime spawns `tool-worker-python.js` beside
 * `worker-entry.js` inside the Worker; the probe app can only run `python3`
 * when that file is copied into the app bundle. `copy-bundle-assets.sh` and
 * `sim_prepare_worker_assets` (the shared simulator staging step) were both
 * missing it, so every scenario python step hung on a 404 nested Worker while
 * the asset build itself looked successful. These tests drive the real shell
 * scripts in a throwaway example tree and fail when either step drops the
 * artifact instead of special-casing the probe app.
 * The same harness also covers the complete DSH Web page: a prebuilt
 * `<www>/web` must reach `Bundle/worker/web`, not be replaced by the flat
 * Worker files.
 */
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cp, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(HERE, '..', '..')
const EXAMPLE = join(REPO_ROOT, 'examples', 'probe-app')
const COPY_ASSETS = join(EXAMPLE, 'scripts', 'copy-bundle-assets.sh')
const SIM_COMMON = join(EXAMPLE, 'scripts', 'sim-common.sh')
const CHECKOUT_SCRIPT = join(REPO_ROOT, 'plugins', 'scripts', 'dsh-checkout.mjs')
// Run the real shell scripts with a specific bash (for example the macOS
// /bin/bash 3.2 build): PDSH_PROBE_STAGING_SHELL=/phone-peers/tools/bash32.
const STAGING_SHELL = process.env.PDSH_PROBE_STAGING_SHELL ?? 'bash'
const WEB_COMMIT = 'a'.repeat(40)
const WEB_VERSION = '0.2.1-rc.2'
const CHECKOUT_BUILDS = [
  'packages/experimental/webworker-runtime/lib/worker.js',
  'packages/experimental/webworker-runtime/lib/client.js',
  'packages/experimental/webworker-runtime/lib/index.js',
  'packages/experimental/webworker-packer/lib/index.js',
  'packages/experimental/webworker-packer/lib/bin.js',
  'packages/boot/app-boot/lib/index.js',
  'packages/client/modules/lib/index.js',
]

/** Runs bash and asserts a zero exit, returning stdout+stderr. */
function bash(script: string, args: readonly string[]): string {
  const result = spawnSync(STAGING_SHELL, ['-c', script, 'probe-staging-test', ...args], {
    encoding: 'utf8',
    env: { ...process.env, HOME: process.env.HOME ?? tmpdir() },
  })
  assert.equal(result.status, 0, `bash failed (${result.status}):\n${result.stdout}\n${result.stderr}`)
  return `${result.stdout}${result.stderr}`
}

function sha(data: string | Buffer): string {
  return createHash('sha256').update(data).digest('hex')
}

/** Writes the real web-build.json build-web-dist.sh emits. */
async function writeWebBuild(
  web: string,
  options: { readonly commit?: string; readonly version?: string } = {},
): Promise<void> {
  const commit = options.commit ?? WEB_COMMIT
  const version = options.version ?? WEB_VERSION
  const index = join(web, 'index.html')
  const html = await readFile(index, 'utf8')
  const entry = /(?:src|href)="\.\/(assets\/[^"]+)"/i.exec(html)?.[1]
  assert.ok(entry, 'example Web index has a relative asset entry')
  const entrySha = sha(await readFile(join(web, entry)))
  await writeFile(join(web, 'web-build.json'), `${JSON.stringify({
    source: 'apps/web/dist',
    package: '@deepseek-ai/dsh-web-frontend',
    version,
    dsh_version: version,
    commit,
    dsh_pin_commit: WEB_COMMIT,
    dsh_pin_version: WEB_VERSION,
    dsh_checkout_overridden: commit !== WEB_COMMIT || version !== WEB_VERSION,
    command: 'test build',
    entry,
    entry_sha256: entrySha,
    index: 'index.html',
    index_sha256: sha(html),
    vite_base: './',
    generated_at: '2026-10-27T00:00:00.000Z',
  }, null, 2)}\n`)
}

/** Creates the temporary example tree the scripts write into. */
async function exampleTree(options: { readonly web?: boolean } = {}): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), 'pdsh-probe-staging-'))
  const example = join(root, 'examples', 'probe-app')
  const web = join(example, 'Bundle', 'worker', 'web')
  await mkdir(join(example, 'scripts'), { recursive: true })
  await mkdir(join(example, 'Bundle', 'worker'), { recursive: true })
  await writeFile(join(example, 'Bundle', 'worker', '.gitkeep'), '')
  if (options.web !== false) {
    await mkdir(join(web, 'assets'), { recursive: true })
    await writeFile(join(web, 'index.html'), [
      '<!doctype html>',
      '<script>globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()</script>',
      '<script type="module" src="./web-boot.js"></script>',
      '<script type="module" crossorigin src="./assets/index-test.js"></script>',
      '',
    ].join('\n'))
    await writeFile(join(web, 'assets', 'index-test.js'), 'console.log("web")\n')
    await writeWebBuild(web)
  }
  await cp(COPY_ASSETS, join(example, 'scripts', 'copy-bundle-assets.sh'))
  return root
}

/** Writes the build outputs the copy script consumes. */
async function workerOutputs(
  root: string,
  options: {
    readonly toolWorker?: boolean
    readonly commit?: string
    readonly version?: string
  } = {},
): Promise<{ workerOut: string; imageOut: string }> {
  const commit = options.commit ?? WEB_COMMIT
  const version = options.version ?? WEB_VERSION
  const workerOut = join(root, 'worker-entry')
  const imageOut = join(root, 'image')
  await mkdir(join(workerOut, 'www'), { recursive: true })
  await mkdir(join(imageOut, 'lazy'), { recursive: true })
  await writeFile(join(workerOut, 'worker-entry.js'), 'console.log("entry")\n')
  await writeFile(join(workerOut, 'web-boot.js'), 'console.log("web boot")\n')
  if (options.toolWorker !== false) {
    await writeFile(join(workerOut, 'tool-worker-python.js'), 'console.log("tool worker")\n')
    await writeFile(join(workerOut, 'tool-worker.js'), 'console.log("generic tool worker")\n')
  }
  await writeFile(join(workerOut, 'workflow-isolate.js'), 'console.log("workflow isolate")\n')
  await writeFile(join(workerOut, 'www', 'index.html'), '<!doctype html>\n')
  await writeFile(join(workerOut, 'www', 'boot.js'), 'export {}\n')
  await writeFile(join(imageOut, 'image.tar.gz'), 'image\n')
  await writeFile(join(imageOut, 'sizes.json'), `${JSON.stringify({
    raw_bytes: 1,
    files: 1,
    dsh_commit: commit,
    dsh_version: version,
    dsh_pin_commit: WEB_COMMIT,
    dsh_pin_version: WEB_VERSION,
    dsh_expected_commit: commit,
    dsh_expected_version: version,
    dsh_checkout_overridden: commit !== WEB_COMMIT || version !== WEB_VERSION,
    dsh_checkout: '/tmp/fake-dsh-checkout',
  }, null, 2)}\n`)
  return { workerOut, imageOut }
}

/** Writes the flat prebuilt bundle shape `sim_prepare_worker_assets` reuses. */
async function prebuiltBundle(
  root: string,
  options: { readonly toolWorker?: boolean } = {},
): Promise<string> {
  const bundle = join(root, 'prebuilt')
  await mkdir(bundle, { recursive: true })
  await writeFile(join(bundle, 'worker-entry.js'), 'console.log("entry")\n')
  await writeFile(join(bundle, 'web-boot.js'), 'console.log("web boot")\n')
  if (options.toolWorker !== false) {
    await writeFile(join(bundle, 'tool-worker-python.js'), 'console.log("tool worker")\n')
    await writeFile(join(bundle, 'tool-worker.js'), 'console.log("generic tool worker")\n')
  }
  await writeFile(join(bundle, 'workflow-isolate.js'), 'console.log("workflow isolate")\n')
  await writeFile(join(bundle, 'index.html'), '<!doctype html>\n')
  await writeFile(join(bundle, 'boot.js'), 'export {}\n')
  await writeFile(join(bundle, 'image.tar.gz'), 'image\n')
  await writeFile(join(bundle, 'sizes.json'), `${JSON.stringify({
    raw_bytes: 1,
    files: 1,
    dsh_commit: WEB_COMMIT,
    dsh_version: WEB_VERSION,
    dsh_pin_commit: WEB_COMMIT,
    dsh_pin_version: WEB_VERSION,
    dsh_expected_commit: WEB_COMMIT,
    dsh_expected_version: WEB_VERSION,
    dsh_checkout_overridden: false,
    dsh_checkout: '/tmp/fake-dsh-checkout',
  }, null, 2)}\n`)
  return bundle
}

/** Installs the real checkout verifier and a canonical pin beside it. */
async function installVerifier(root: string): Promise<void> {
  const plugins = join(root, 'plugins')
  await mkdir(join(plugins, 'scripts'), { recursive: true })
  await mkdir(join(plugins, 'node_modules'), { recursive: true })
  await cp(CHECKOUT_SCRIPT, join(plugins, 'scripts', 'dsh-checkout.mjs'))
  await writeFile(join(plugins, 'dsh-pin.json'), `${JSON.stringify({
    repo: 'https://example.invalid/deepseek-harness',
    commit: WEB_COMMIT,
    version: WEB_VERSION,
  }, null, 2)}\n`)
}

/** Creates a real clean/built git checkout with the given installation version. */
async function gitCheckout(root: string, version = WEB_VERSION): Promise<string> {
  const checkout = join(root, 'checkout')
  await mkdir(join(checkout, 'apps', 'cli'), { recursive: true })
  execFileSync('git', ['init', '-q', checkout])
  execFileSync('git', ['-C', checkout, 'config', 'user.email', 'worker@example.invalid'])
  execFileSync('git', ['-C', checkout, 'config', 'user.name', 'worker'])
  await writeFile(
    join(checkout, 'apps', 'cli', 'package.json'),
    `${JSON.stringify({ name: '@deepseek-ai/dsh', version })}\n`,
  )
  for (const file of CHECKOUT_BUILDS) {
    await mkdir(dirname(join(checkout, file)), { recursive: true })
    await writeFile(join(checkout, file), '// built\n')
  }
  execFileSync('git', ['-C', checkout, 'add', '-A'])
  execFileSync('git', ['-C', checkout, 'commit', '-q', '-m', 'checkout'])
  return checkout
}

test('copy-bundle-assets stages the python tool worker beside the entry', async () => {
  const root = await exampleTree()
  try {
    const { workerOut, imageOut } = await workerOutputs(root)
    bash('bash "$1" --worker-out "$2" --image-out "$3"', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut,
      imageOut,
    ])
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    const toolWorker = await readFile(join(dest, 'tool-worker-python.js'), 'utf8')
    assert.equal(toolWorker, 'console.log("tool worker")\n')
    const genericWorker = await readFile(join(dest, 'tool-worker.js'), 'utf8')
    assert.equal(genericWorker, 'console.log("generic tool worker")\n',
      'the default bundle carries the generic worker the jq toolbox spawns')
    const entry = await readFile(join(dest, 'worker-entry.js'), 'utf8')
    assert.match(entry, /Symbol\.dispose/, 'the entry keeps the JavaScriptCore prelude')
    const webBoot = await readFile(join(dest, 'web', 'web-boot.js'), 'utf8')
    assert.equal(webBoot, 'console.log("web boot")\n')
    assert.ok(existsSync(join(dest, 'web', 'index.html')))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets stages a real Web dist and records same-source metadata', async () => {
  const root = await exampleTree()
  try {
    const { workerOut, imageOut } = await workerOutputs(root)
    const raw = join(root, 'raw-web')
    await mkdir(join(raw, 'assets'), { recursive: true })
    await writeFile(join(raw, 'index.html'), [
      '<!doctype html>',
      '<script>globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()</script>',
      '<script type="module" src="./web-boot.js"></script>',
      '<script type="module" crossorigin src="./assets/index-raw.js"></script>',
      '',
    ].join('\n'))
    await writeFile(join(raw, 'assets', 'index-raw.js'), 'console.log("raw")\n')
    await writeWebBuild(raw)
    bash('bash "$1" --worker-out "$2" --image-out "$3" --web-dist "$4" --force', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut,
      imageOut,
      raw,
    ])
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    const record = JSON.parse(await readFile(join(dest, 'web', 'web-build.json'), 'utf8'))
    assert.equal(record.entry, 'assets/index-raw.js')
    assert.match(record.entry_sha256, /^[0-9a-f]{64}$/)
    assert.equal(record.commit, WEB_COMMIT)
    assert.equal(record.dsh_version, WEB_VERSION)
    const probe = JSON.parse(await readFile(join(dest, 'probe-bundle.json'), 'utf8'))
    assert.equal(probe.web.record, 'web/web-build.json')
    assert.equal(probe.web.commit, WEB_COMMIT)
    assert.equal(probe.web.dsh_version, WEB_VERSION)
    assert.equal(probe.image.record, 'sizes.json')
    assert.equal(probe.image.commit, WEB_COMMIT)
    assert.equal(probe.image.dsh_version, WEB_VERSION)
    assert.equal(probe.image.checkout, '/tmp/fake-dsh-checkout')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets forwards the Web build pair to pack-image', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pdsh-probe-forward-'))
  try {
    const example = join(root, 'examples', 'probe-app')
    const web = join(example, 'Bundle', 'worker', 'web')
    const plugins = join(root, 'plugins')
    const checkout = join(root, 'checkout')
    const marker = join(root, 'pack-args.json')
    await mkdir(join(example, 'scripts'), { recursive: true })
    await mkdir(join(web, 'assets'), { recursive: true })
    await mkdir(join(plugins, 'worker-entry'), { recursive: true })
    await mkdir(join(plugins, 'scripts'), { recursive: true })
    await mkdir(join(plugins, 'node_modules'), { recursive: true })
    await mkdir(checkout, { recursive: true })
    await writeFile(join(web, 'index.html'), [
      '<!doctype html>',
      '<script>globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()</script>',
      '<script type="module" src="./web-boot.js"></script>',
      '<script type="module" crossorigin src="./assets/index-test.js"></script>',
      '',
    ].join('\n'))
    await writeFile(join(web, 'assets', 'index-test.js'), 'console.log("web")\n')
    await writeWebBuild(web)
    await cp(COPY_ASSETS, join(example, 'scripts', 'copy-bundle-assets.sh'))

    // The real copy script invokes these two entry points with real Node; they
    // stand in for the expensive build and record the exact pack-image pair.
    await writeFile(join(plugins, 'worker-entry', 'build.mjs'), `
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const index = process.argv.indexOf('--out')
const out = process.argv[index + 1]
mkdirSync(join(out, 'www'), { recursive: true })
writeFileSync(join(out, 'worker-entry.js'), 'console.log("entry")\\n')
writeFileSync(join(out, 'tool-worker-python.js'), 'console.log("tool")\\n')
writeFileSync(join(out, 'workflow-isolate.js'), 'console.log("isolate")\\n')
writeFileSync(join(out, 'web-boot.js'), 'console.log("boot")\\n')
writeFileSync(join(out, 'www', 'index.html'), '<!doctype html>\\n')
writeFileSync(join(out, 'www', 'boot.js'), 'export {}\\n')
`)
    await writeFile(join(plugins, 'scripts', 'pack-image.mjs'), `
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const args = process.argv.slice(2)
const value = name => {
  const index = args.indexOf(name)
  if (index < 0) throw new Error('missing ' + name)
  return args[index + 1]
}
const out = value('--out')
const record = {
  checkout: value('--checkout'),
  sha: value('--checkout-sha'),
  version: value('--checkout-version'),
}
mkdirSync(join(out, 'lazy'), { recursive: true })
writeFileSync(join(out, 'image.tar.gz'), 'image\\n')
writeFileSync(join(out, 'sizes.json'), JSON.stringify({
  raw_bytes: 1,
  files: 1,
  dsh_commit: record.sha,
  dsh_version: record.version,
  dsh_pin_commit: '${WEB_COMMIT}',
  dsh_pin_version: '${WEB_VERSION}',
  dsh_expected_commit: record.sha,
  dsh_expected_version: record.version,
  dsh_checkout_overridden: record.sha !== '${WEB_COMMIT}' || record.version !== '${WEB_VERSION}',
  dsh_checkout: record.checkout,
}, null, 2))
writeFileSync(process.env.PDSH_PACK_MARKER, JSON.stringify(record))
`)
    const { workerOut } = await workerOutputs(root)
    const result = spawnSync(STAGING_SHELL, [
      join(example, 'scripts', 'copy-bundle-assets.sh'),
      '--worker-out', workerOut,
      '--checkout', checkout,
      '--force',
    ], {
      encoding: 'utf8',
      env: { ...process.env, HOME: root, PDSH_PACK_MARKER: marker },
    })
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    const record = JSON.parse(await readFile(marker, 'utf8'))
    // The copy script resolves the checkout with `pwd -P`; on macOS the
    // tmpdir symlink (/var -> /private/var) makes that differ from the input
    // spelling, so compare against the resolved path.
    assert.deepEqual(record, {
      checkout: await realpath(checkout),
      sha: WEB_COMMIT,
      version: WEB_VERSION,
    })
    const probe = JSON.parse(await readFile(
      join(example, 'Bundle', 'worker', 'probe-bundle.json'), 'utf8'))
    assert.equal(probe.image.commit, WEB_COMMIT)
    assert.equal(probe.image.dsh_version, WEB_VERSION)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets verifies the Worker checkout against the Web/image pair', async () => {
  const root = await exampleTree()
  try {
    // The Web and image name commit A, but the checkout used to compile the
    // Worker entry is a different clean/built checkout B.
    const { imageOut } = await workerOutputs(root)
    await installVerifier(root)
    const checkout = await gitCheckout(root)
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    await writeFile(join(dest, 'sentinel.txt'), 'keep\n')
    const result = spawnSync(STAGING_SHELL, [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      '--image-out', imageOut,
      '--checkout', checkout,
      '--force',
    ], {
      encoding: 'utf8',
      env: { ...process.env, HOME: root },
    })
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, /HEAD is .*but dsh-pin\.json pins/)
    assert.match(result.stderr, /Worker checkout does not match the Web\/image source/)
    assert.equal(await readFile(join(dest, 'sentinel.txt'), 'utf8'), 'keep\n')
    assert.equal(existsSync(join(dest, 'worker-entry.js')), false,
      'no Worker entry may be staged from a different checkout')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets no-force rejects a bundle missing a staged runtime file', async () => {
  for (const missing of ['web/web-boot.js', 'tool-worker-python.js']) {
    const root = await exampleTree()
    try {
      const outputs = await workerOutputs(root)
      bash('bash "$1" --worker-out "$2" --image-out "$3" --force', [
        join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
        outputs.workerOut,
        outputs.imageOut,
      ])
      const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
      await rm(join(dest, missing))
      const result = spawnSync(STAGING_SHELL, [
        join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      ], {
        encoding: 'utf8',
        env: { ...process.env, HOME: root },
      })
      assert.notEqual(result.status, 0, `missing ${missing}:\n${result.stdout}\n${result.stderr}`)
      assert.match(result.stderr, /does not validate as one same-source bundle/)
      assert.equal(existsSync(join(dest, missing)), false,
        `a failed no-force run must not restore or fabricate ${missing}`)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  }
})

test('copy-bundle-assets no-force rejects an empty staged runtime file', async () => {
  const root = await exampleTree()
  try {
    const outputs = await workerOutputs(root)
    bash('bash "$1" --worker-out "$2" --image-out "$3" --force', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      outputs.workerOut,
      outputs.imageOut,
    ])
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    await writeFile(join(dest, 'worker-entry.js'), '')
    const result = spawnSync(STAGING_SHELL, [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
    ], {
      encoding: 'utf8',
      env: { ...process.env, HOME: root },
    })
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, /Worker entry is empty/)
    assert.equal(await readFile(join(dest, 'worker-entry.js'), 'utf8'), '',
      'a failed no-force run must not replace the existing bundle')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets rejects a Web dist without a real web-build.json', async () => {
  const root = await exampleTree()
  try {
    const { workerOut, imageOut } = await workerOutputs(root)
    const raw = join(root, 'raw-web')
    await mkdir(join(raw, 'assets'), { recursive: true })
    await writeFile(join(raw, 'index.html'), [
      '<!doctype html>',
      '<script type="module" crossorigin src="./assets/index-raw.js"></script>',
      '',
    ].join('\n'))
    await writeFile(join(raw, 'assets', 'index-raw.js'), 'console.log("raw")\n')
    const result = spawnSync('bash', ['-c',
      'bash "$1" --worker-out "$2" --image-out "$3" --web-dist "$4"',
      'probe-staging-test', join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut, imageOut, raw], { encoding: 'utf8' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /web-build\.json/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets rejects image metadata from a different commit', async () => {
  const root = await exampleTree()
  try {
    const { workerOut, imageOut } = await workerOutputs(root, { commit: 'b'.repeat(40) })
    const result = spawnSync('bash', ['-c',
      'bash "$1" --worker-out "$2" --image-out "$3"',
      'probe-staging-test', join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut, imageOut], { encoding: 'utf8' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /does not match image sizes\.json dsh_commit/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets rejects a missing image sizes.json', async () => {
  const root = await exampleTree()
  try {
    const { workerOut, imageOut } = await workerOutputs(root)
    await rm(join(imageOut, 'sizes.json'))
    const result = spawnSync('bash', ['-c',
      'bash "$1" --worker-out "$2" --image-out "$3"',
      'probe-staging-test', join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut, imageOut], { encoding: 'utf8' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /sizes\.json/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets still stages legacy Worker assets without a Web dist', async () => {
  const root = await exampleTree({ web: false })
  try {
    const { workerOut, imageOut } = await workerOutputs(root)
    const output = bash('bash "$1" --worker-out "$2" --image-out "$3"', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut,
      imageOut,
    ])
    assert.match(output, /no full Web dist; staging the legacy Worker\/www assets only/)
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    assert.ok(existsSync(join(dest, 'worker-entry.js')))
    assert.ok(existsSync(join(dest, 'tool-worker-python.js')))
    assert.ok(existsSync(join(dest, 'index.html')))
    assert.ok(existsSync(join(dest, 'boot.js')))
    assert.equal(existsSync(join(dest, 'web', 'index.html')), false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets fails loud when the build has no python tool worker', async () => {
  const root = await exampleTree()
  try {
    const { workerOut, imageOut } = await workerOutputs(root, { toolWorker: false })
    const result = spawnSync('bash', ['-c', 'bash "$1" --worker-out "$2" --image-out "$3"',
      'probe-staging-test', join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      workerOut, imageOut], { encoding: 'utf8' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /tool-worker-python\.js/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('sim_prepare_worker_assets stages a prebuilt python tool worker into the app bundle', async () => {
  const root = await exampleTree()
  try {
    const bundle = await prebuiltBundle(root)
    bash(
      'set -euo pipefail; source "$1"; '
      + 'sim_prepare_worker_assets "$2" "$3" "$4" "$5"',
      [SIM_COMMON, join(root, 'examples', 'probe-app'), join(root, 'staging'), bundle,
        join(bundle, 'image.tar.gz')],
    )
    const staged = await readFile(
      join(root, 'staging', 'worker', 'tool-worker-python.js'), 'utf8')
    assert.equal(staged, 'console.log("tool worker")\n')
    const app = await readFile(
      join(root, 'examples', 'probe-app', 'Bundle', 'worker', 'tool-worker-python.js'), 'utf8')
    assert.equal(app, 'console.log("tool worker")\n')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('sim_prepare_worker_assets stages a legacy prebuilt bundle without a Web dist', async () => {
  const root = await exampleTree({ web: false })
  try {
    const bundle = await prebuiltBundle(root)
    bash(
      'set -euo pipefail; source "$1"; '
      + 'sim_prepare_worker_assets "$2" "$3" "$4" "$5"',
      [SIM_COMMON, join(root, 'examples', 'probe-app'), join(root, 'staging'), bundle,
        join(bundle, 'image.tar.gz')],
    )
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    assert.ok(existsSync(join(dest, 'worker-entry.js')))
    assert.ok(existsSync(join(dest, 'tool-worker-python.js')))
    assert.equal(existsSync(join(dest, 'web', 'index.html')), false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('sim_prepare_worker_assets stages a prebuilt Web dist into Bundle/worker/web', async () => {
  const root = await exampleTree()
  try {
    // Only the prebuilt tree carries the page; the example's own web/ is gone.
    await rm(join(root, 'examples', 'probe-app', 'Bundle', 'worker', 'web'),
      { recursive: true, force: true })
    const bundle = await prebuiltBundle(root)
    await mkdir(join(bundle, 'web', 'assets'), { recursive: true })
    await writeFile(join(bundle, 'web', 'index.html'), [
      '<!doctype html>',
      '<script>globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()</script>',
      '<script type="module" src="./web-boot.js"></script>',
      '<script type="module" crossorigin src="./assets/index-prebuilt.js"></script>',
      '',
    ].join('\n'))
    await writeFile(join(bundle, 'web', 'assets', 'index-prebuilt.js'), 'console.log("prebuilt")\n')
    // The prebuilt tree must carry the real same-source record, not a stand-in:
    // the copy script validates the page bytes and commit/version before staging.
    await writeWebBuild(join(bundle, 'web'))
    bash(
      'set -euo pipefail; source "$1"; '
      + 'sim_prepare_worker_assets "$2" "$3" "$4" "$5"',
      [SIM_COMMON, join(root, 'examples', 'probe-app'), join(root, 'staging'), bundle,
        join(bundle, 'image.tar.gz')],
    )
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker', 'web')
    const index = await readFile(join(dest, 'index.html'), 'utf8')
    assert.match(index, /index-prebuilt\.js/)
    assert.equal(await readFile(join(dest, 'web-boot.js'), 'utf8'),
      'console.log("web boot")\n')
    assert.ok(existsSync(join(dest, 'assets', 'index-prebuilt.js')))
    const record = JSON.parse(await readFile(join(dest, 'web-build.json'), 'utf8'))
    assert.equal(record.commit, WEB_COMMIT)
    assert.equal(record.dsh_version, WEB_VERSION)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('sim_prepare_worker_assets refuses a prebuilt bundle without the tool worker', async () => {
  const root = await exampleTree()
  try {
    const bundle = await prebuiltBundle(root, { toolWorker: false })
    const result = spawnSync('bash', ['-c',
      'set -euo pipefail; source "$1"; sim_prepare_worker_assets "$2" "$3" "$4" "$5"',
      'probe-staging-test', SIM_COMMON, join(root, 'examples', 'probe-app'), join(root, 'staging'),
      bundle, join(bundle, 'image.tar.gz')], { encoding: 'utf8' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /tool-worker-python\.js/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets no-force rejects a new Web record beside an old image', async () => {
  const root = await exampleTree()
  try {
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    const first = await workerOutputs(root)
    bash('bash "$1" --worker-out "$2" --image-out "$3" --force', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      first.workerOut,
      first.imageOut,
    ])
    // build-web-dist.sh can write a new page into the existing bundle before
    // the copy step runs. The old image metadata must not be accepted as the
    // same source merely because the temporary image output happens to match.
    await writeWebBuild(join(dest, 'web'), { commit: 'b'.repeat(40) })
    const next = await workerOutputs(root, { commit: 'b'.repeat(40) })
    const result = spawnSync('bash', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      '--worker-out', next.workerOut,
      '--image-out', next.imageOut,
    ], {
      encoding: 'utf8',
      env: { ...process.env, HOME: root },
    })
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, /pass --force/)
    const sizes = JSON.parse(await readFile(join(dest, 'sizes.json'), 'utf8'))
    assert.equal(sizes.dsh_commit, WEB_COMMIT, 'the old image record is left in place')
    const web = JSON.parse(await readFile(join(dest, 'web', 'web-build.json'), 'utf8'))
    assert.equal(web.commit, 'b'.repeat(40))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets validates the source Web before replacing the bundle', async () => {
  const root = await exampleTree()
  try {
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    const first = await workerOutputs(root)
    bash('bash "$1" --worker-out "$2" --image-out "$3" --force', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      first.workerOut,
      first.imageOut,
    ])
    const oldSizes = await readFile(join(dest, 'sizes.json'), 'utf8')
    const oldProbe = await readFile(join(dest, 'probe-bundle.json'), 'utf8')

    const raw = join(root, 'broken-web')
    await mkdir(join(raw, 'assets'), { recursive: true })
    await writeFile(join(raw, 'index.html'), [
      '<!doctype html>',
      '<script>globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()</script>',
      '<script type="module" src="./web-boot.js"></script>',
      '<script type="module" crossorigin src="./assets/index-raw.js"></script>',
      '',
    ].join('\n'))
    await writeFile(join(raw, 'assets', 'index-raw.js'), 'console.log("raw")\n')
    await writeWebBuild(raw, { commit: 'b'.repeat(40) })
    await rm(join(raw, 'assets', 'index-raw.js'))

    const next = await workerOutputs(root, { commit: 'b'.repeat(40) })
    const result = spawnSync('bash', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      '--worker-out', next.workerOut,
      '--image-out', next.imageOut,
      '--web-dist', raw,
      '--force',
    ], {
      encoding: 'utf8',
      env: { ...process.env, HOME: root },
    })
    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, /missing entry/)
    assert.equal(await readFile(join(dest, 'sizes.json'), 'utf8'), oldSizes)
    assert.equal(await readFile(join(dest, 'probe-bundle.json'), 'utf8'), oldProbe)
    const web = JSON.parse(await readFile(join(dest, 'web', 'web-build.json'), 'utf8'))
    assert.equal(web.commit, WEB_COMMIT, 'the old Web page is left in place')
    assert.ok(existsSync(join(dest, 'worker-entry.js')))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('copy-bundle-assets no-force skips only a fully valid same-source bundle', async () => {
  const root = await exampleTree()
  try {
    const dest = join(root, 'examples', 'probe-app', 'Bundle', 'worker')
    const outputs = await workerOutputs(root)
    bash('bash "$1" --worker-out "$2" --image-out "$3" --force', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
      outputs.workerOut,
      outputs.imageOut,
    ])
    const oldSizes = await readFile(join(dest, 'sizes.json'), 'utf8')
    const oldProbe = await readFile(join(dest, 'probe-bundle.json'), 'utf8')
    const result = spawnSync('bash', [
      join(root, 'examples', 'probe-app', 'scripts', 'copy-bundle-assets.sh'),
    ], {
      encoding: 'utf8',
      env: { ...process.env, HOME: root },
    })
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, /already has verified same-source assets/)
    assert.equal(await readFile(join(dest, 'sizes.json'), 'utf8'), oldSizes)
    assert.equal(await readFile(join(dest, 'probe-bundle.json'), 'utf8'), oldProbe)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
