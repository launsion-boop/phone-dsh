// SPDX-License-Identifier: MIT
/**
 * Behaviour tests for scripts/ci/build-web-dist.sh.
 *
 * The script must verify the source checkout through plugins/scripts/
 * dsh-checkout.mjs, build the canonical pin by default, and build an explicit
 * clean/built commit only when the paired --commit/--version options name it.
 * These tests copy the real script and verifier into a throwaway tree with a
 * fake pin and a fake DSH checkout; only pnpm itself is stubbed, because this
 * test exercises argument handling, checkout verification, clone/checkout and
 * web-build.json metadata rather than a real multi-minute DSH compile.
 */
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(HERE, '..', '..')
const BUILD_SCRIPT = join(REPO_ROOT, 'scripts', 'ci', 'build-web-dist.sh')
const CHECKOUT_SCRIPT = join(REPO_ROOT, 'plugins', 'scripts', 'dsh-checkout.mjs')
const PIN_VERSION = '0.2.1-rc.2'
// Run the real script with a specific shell (for example macOS /bin/bash 3.2):
// PDSH_BUILD_WEB_DIST_SHELL=/bin/bash node --test plugins/tests/build-web-dist.test.ts
const BUILD_SHELL = process.env.PDSH_BUILD_WEB_DIST_SHELL ?? 'bash'
const REQUIRED_BUILDS = [
  'packages/experimental/webworker-runtime/lib/worker.js',
  'packages/experimental/webworker-runtime/lib/client.js',
  'packages/experimental/webworker-runtime/lib/index.js',
  'packages/experimental/webworker-packer/lib/index.js',
  'packages/experimental/webworker-packer/lib/bin.js',
  'packages/boot/app-boot/lib/index.js',
  'packages/client/modules/lib/index.js',
]
const scratch: string[] = []

after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

function git(directory: string, ...args: string[]): string {
  return execFileSync('git', ['-C', directory, ...args], { encoding: 'utf8' }).trim()
}

function commitAll(directory: string, message: string): string {
  execFileSync('git', ['-C', directory, 'add', '-A'])
  execFileSync('git', ['-C', directory, 'commit', '-q', '-m', message])
  return git(directory, 'rev-parse', 'HEAD')
}

interface Harness {
  readonly root: string
  readonly repo: string
  readonly script: string
  readonly checkout: string
  readonly firstCommit: string
  readonly head: string
  readonly env: NodeJS.ProcessEnv
}

/**
 * Creates a throwaway repository (real script + verifier + fake pin) and a
 * real git checkout with the build artifacts git ignores.
 */
function harness(options: { secondCommit?: boolean; version?: string } = {}): Harness {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-build-web-test-'))
  scratch.push(root)
  const repo = join(root, 'repo')
  mkdirSync(join(repo, 'scripts', 'ci'), { recursive: true })
  mkdirSync(join(repo, 'plugins', 'scripts'), { recursive: true })
  cpSync(BUILD_SCRIPT, join(repo, 'scripts', 'ci', 'build-web-dist.sh'))
  cpSync(CHECKOUT_SCRIPT, join(repo, 'plugins', 'scripts', 'dsh-checkout.mjs'))

  const checkout = join(root, 'checkout')
  mkdirSync(checkout, { recursive: true })
  execFileSync('git', ['init', '-q', checkout])
  execFileSync('git', ['-C', checkout, 'config', 'user.email', 'worker@example.invalid'])
  execFileSync('git', ['-C', checkout, 'config', 'user.name', 'worker'])
  // Built lib/ trees and the Vite dist are ignored output, exactly as in DSH.
  writeFileSync(join(checkout, '.gitignore'), 'lib/\napps/web/dist/\nnode_modules/\n')
  mkdirSync(join(checkout, 'apps', 'cli'), { recursive: true })
  mkdirSync(join(checkout, 'apps', 'web'), { recursive: true })
  const version = options.version ?? PIN_VERSION
  writeFileSync(
    join(checkout, 'apps', 'cli', 'package.json'),
    `${JSON.stringify({ name: '@deepseek-ai/dsh', version })}\n`,
  )
  writeFileSync(
    join(checkout, 'apps', 'web', 'package.json'),
    `${JSON.stringify({ name: '@deepseek-ai/dsh-web-frontend', version })}\n`,
  )
  writeFileSync(join(checkout, 'tracked.txt'), 'first\n')
  const firstCommit = commitAll(checkout, 'first')
  for (const file of REQUIRED_BUILDS) {
    mkdirSync(dirname(join(checkout, file)), { recursive: true })
    writeFileSync(join(checkout, file), '// built\n')
  }

  let head = firstCommit
  if (options.secondCommit === true) {
    writeFileSync(join(checkout, 'tracked.txt'), 'second\n')
    head = commitAll(checkout, 'second')
  }

  writeFileSync(
    join(repo, 'plugins', 'dsh-pin.json'),
    `${JSON.stringify({
      repo: 'https://example.invalid/deepseek-harness',
      commit: firstCommit,
      version: PIN_VERSION,
    }, null, 2)}\n`,
  )

  // Only the package manager is a stub: it answers the exact build sequence
  // with a minimal apps/web/dist so the script's real post-build metadata and
  // clone/checkout logic runs.
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const pnpm = join(bin, 'pnpm')
  writeFileSync(pnpm, `#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  install) exit 0 ;;
  exec) exit 0 ;;
  run)
    [ "\${2:-}" = "build:web" ] || { echo "unexpected pnpm run \${2:-}" >&2; exit 1; }
    mkdir -p apps/web/dist/assets
    if [ -n "\${PDSH_TEST_INDEX_HTML:-}" ]; then
      cp "$PDSH_TEST_INDEX_HTML" apps/web/dist/index.html
    else
      cat > apps/web/dist/index.html <<'HTML'
<!doctype html>
<html><body><div id="app"></div>
<script type="module" crossorigin src="./assets/index-test.js"></script>
</body></html>
HTML
    fi
    printf 'console.log("web")\\n' > apps/web/dist/assets/index-test.js
    ;;
  *) echo "unexpected pnpm $*" >&2; exit 1 ;;
esac
`)
  chmodSync(pnpm, 0o755)

  const home = join(root, 'home')
  mkdirSync(home, { recursive: true })
  return {
    root,
    repo,
    script: join(repo, 'scripts', 'ci', 'build-web-dist.sh'),
    checkout,
    firstCommit,
    head,
    env: {
      ...process.env,
      HOME: home,
      PATH: `${bin}:${process.env.PATH ?? ''}`,
    },
  }
}

function runBuild(
  test: Harness,
  args: string[],
  extraEnv: NodeJS.ProcessEnv = {},
  cwd?: string,
) {
  return spawnSync(BUILD_SHELL, [test.script, ...args], {
    encoding: 'utf8',
    env: { ...test.env, ...extraEnv },
    timeout: 60_000,
    ...(cwd === undefined ? {} : { cwd }),
  })
}

function output(test: Harness, name = 'out'): string {
  return join(test.root, name)
}

function readBuild(test: Harness): Record<string, unknown> {
  return JSON.parse(readFileSync(join(output(test), 'web-build.json'), 'utf8'))
}

test('default build verifies and builds the canonical pin commit', () => {
  const testTree = harness()
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  const record = readBuild(testTree)
  assert.equal(record.commit, testTree.firstCommit)
  assert.equal(record.dsh_pin_commit, testTree.firstCommit)
  assert.equal(record.dsh_version, PIN_VERSION)
  assert.equal(record.dsh_checkout_overridden, false)
  assert.ok(existsSync(join(output(testTree), 'index.html')))
  assert.ok(existsSync(join(output(testTree), 'assets', 'index-test.js')))
  const index = readFileSync(join(output(testTree), 'index.html'), 'utf8')
  const bootReady = index.indexOf('globalThis.__DSH_BOOT_READY__')
  const bootScript = index.indexOf('src="./web-boot.js"')
  const viteEntry = index.indexOf('src="./assets/index-test.js"')
  assert.ok(bootReady >= 0, 'the boot-readiness tag is missing from index.html')
  assert.ok(bootScript > bootReady, 'web-boot.js must follow the readiness tag')
  assert.ok(viteEntry > bootScript, 'both boot tags must precede the Vite entry')
  const entry = readFileSync(join(output(testTree), 'assets', 'index-test.js'))
  assert.equal(record.entry, 'assets/index-test.js')
  assert.equal(record.entry_sha256, createHash('sha256').update(entry).digest('hex'))
  assert.equal(record.index_sha256, createHash('sha256').update(index).digest('hex'))
})

test('the injected boot script polyfills Promise.withResolvers for iOS 17.0', async () => {
  const testTree = harness()
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  const index = readFileSync(join(output(testTree), 'index.html'), 'utf8')
  const inline = /<script>([\s\S]*?)<\/script>/i.exec(index)
  assert.ok(inline, 'the earliest boot script must be inline')
  const bootScript = inline[1]
  assert.ok(bootScript, 'the earliest boot script must not be empty')
  assert.ok(index.indexOf(bootScript) < index.indexOf('src="./web-boot.js"'),
    'the polyfill must run before web-boot.js')
  assert.ok(index.indexOf(bootScript) < index.indexOf('src="./assets/index-test.js"'),
    'the polyfill must run before the client bundle')
  const context = vm.createContext({})
  vm.runInContext('delete Promise.withResolvers', context)
  vm.runInContext(bootScript, context)
  const state = await vm.runInContext(`(async () => {
    if (typeof Promise.withResolvers !== 'function') return 'missing polyfill'
    const gate = globalThis.__DSH_BOOT_READY__
    if (gate === undefined) return 'missing readiness gate'
    const other = Promise.withResolvers()
    if (typeof other.resolve !== 'function' || typeof other.reject !== 'function') {
      return 'broken polyfill'
    }
    gate.resolve('ready')
    return await gate.promise
  })()`, context)
  assert.equal(state, 'ready')
})

test('a root-relative Vite asset exits non-zero and keeps the previous dist', () => {
  const testTree = harness()
  const badIndex = join(testTree.root, 'root-relative.html')
  writeFileSync(badIndex, `<!doctype html>
<script type="module" src="./assets/index-test.js"></script>
<link rel="stylesheet" href="/assets/index-test.css">
`)
  const out = output(testTree)
  mkdirSync(out, { recursive: true })
  writeFileSync(join(out, 'sentinel.txt'), 'keep\n')
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--out', out,
    '--store', join(testTree.root, 'store'),
  ], { PDSH_TEST_INDEX_HTML: badIndex })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /root-relative asset/)
  assert.equal(readFileSync(join(out, 'sentinel.txt'), 'utf8'), 'keep\n')
  assert.equal(existsSync(join(out, 'web-build.json')), false)
})

test('a paired explicit commit builds the new checkout, never the old pin', () => {
  const testTree = harness({ secondCommit: true })
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--commit', testTree.head,
    '--version', PIN_VERSION,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  const record = readBuild(testTree)
  assert.equal(record.commit, testTree.head)
  assert.notEqual(record.commit, testTree.firstCommit)
  assert.equal(record.dsh_pin_commit, testTree.firstCommit)
  assert.equal(record.dsh_checkout_overridden, true)
})

test('the default pin is not silently checked out when the source HEAD moved', () => {
  const testTree = harness({ secondCommit: true })
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /HEAD is .*but dsh-pin\.json pins/)
  assert.equal(existsSync(join(output(testTree), 'web-build.json')), false)
})

test('a paired override rejects a mismatched installation version', () => {
  const testTree = harness({ secondCommit: true, version: '9.9.9' })
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--commit', testTree.head,
    '--version', PIN_VERSION,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /checkout version is 9\.9\.9, but dsh-pin\.json pins/)
})

test('a paired override rejects a dirty checkout', () => {
  const testTree = harness({ secondCommit: true })
  writeFileSync(join(testTree.checkout, 'tracked.txt'), 'dirty\n')
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--commit', testTree.head,
    '--version', PIN_VERSION,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /tracked modifications/)
})

test('a paired override rejects a checkout without built artifacts', () => {
  const testTree = harness({ secondCommit: true })
  const requiredBuild = REQUIRED_BUILDS[0]
  assert.ok(requiredBuild, 'the fixture must name one required build artifact')
  rmSync(join(testTree.checkout, requiredBuild))
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--commit', testTree.head,
    '--version', PIN_VERSION,
    '--out', output(testTree),
    '--store', join(testTree.root, 'store'),
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /missing built artifacts/)
})

test('--commit and --version must be supplied together', () => {
  const testTree = harness()
  const result = runBuild(testTree, ['--commit', testTree.firstCommit])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /--commit and --version must be supplied together/)
})

test('explicitly empty --commit/--version values never fall back to the canonical pin', () => {
  const testTree = harness()
  const cases: Array<{ args: string[]; message: RegExp }> = [
    { args: ['--commit', '', '--version', ''], message: /--commit must not be empty/ },
    { args: ['--commit=', '--version='], message: /--commit must not be empty/ },
    { args: ['--commit', '', '--version', PIN_VERSION], message: /--commit must not be empty/ },
    { args: ['--commit', testTree.firstCommit, '--version', ''], message: /--version must not be empty/ },
    { args: ['--commit', testTree.firstCommit, '--version='], message: /--version must not be empty/ },
    { args: ['--version', ''], message: /--version must not be empty/ },
  ]
  for (const { args, message } of cases) {
    const result = runBuild(testTree, [
      '--source', testTree.checkout,
      ...args,
      '--out', output(testTree),
      '--store', join(testTree.root, 'store'),
    ])
    assert.notEqual(result.status, 0, `${args.join(' ')} must fail\n${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, message)
    assert.equal(existsSync(join(output(testTree), 'web-build.json')), false)
  }
})

test('an explicitly empty --source is rejected instead of falling back', () => {
  const testTree = harness()
  for (const args of [['--source', ''], ['--source=']]) {
    const result = runBuild(testTree, [
      ...args,
      '--out', output(testTree),
      '--store', join(testTree.root, 'store'),
    ])
    assert.notEqual(result.status, 0, `${args.join(' ')} must fail\n${result.stdout}\n${result.stderr}`)
    assert.match(result.stderr, /--source must not be empty/)
    assert.equal(existsSync(join(output(testTree), 'web-build.json')), false)
  }
})

test('--commit rejects a short or non-hex SHA before building', () => {
  const testTree = harness()
  const short = runBuild(testTree, ['--commit', 'abc', '--version', PIN_VERSION])
  assert.notEqual(short.status, 0)
  assert.match(short.stderr, /full 40-character lowercase hex sha/)
  const nonHex = runBuild(testTree, ['--commit', 'z'.repeat(40), '--version', PIN_VERSION])
  assert.notEqual(nonHex.status, 0)
  assert.match(nonHex.stderr, /full 40-character lowercase hex sha/)
})

test('--out inside the source checkout is rejected without creating it', () => {
  const testTree = harness()
  const target = join(testTree.checkout, 'build', 'web')
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--out', target,
    '--store', join(testTree.root, 'store'),
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /inside the source checkout/)
  assert.equal(existsSync(join(testTree.checkout, 'build')), false)
})

test('--out at the repository root or "." is rejected without clearing it', () => {
  const testTree = harness()
  const sentinel = join(testTree.repo, 'sentinel.txt')
  writeFileSync(sentinel, 'keep\n')
  for (const out of [testTree.repo, '.']) {
    const result = runBuild(testTree, [
      '--source', testTree.checkout,
      '--out', out,
      '--store', join(testTree.root, 'store'),
    ], {}, testTree.repo)
    assert.notEqual(result.status, 0, `--out ${out} should fail`)
    assert.match(result.stderr, /repository root/)
    assert.equal(readFileSync(sentinel, 'utf8'), 'keep\n')
    assert.ok(existsSync(join(testTree.repo, 'scripts', 'ci', 'build-web-dist.sh')))
    assert.equal(existsSync(join(testTree.repo, 'web-build.json')), false)
  }
})

test('--out through a symlink to the repository root is rejected', () => {
  const testTree = harness()
  const link = join(testTree.root, 'repo-link')
  symlinkSync(testTree.repo, link)
  const result = runBuild(testTree, [
    '--source', testTree.checkout,
    '--out', link,
    '--store', join(testTree.root, 'store'),
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /repository root/)
  assert.ok(existsSync(join(testTree.repo, 'scripts', 'ci', 'build-web-dist.sh')))
  assert.equal(existsSync(join(testTree.repo, 'web-build.json')), false)
})
