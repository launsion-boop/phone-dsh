/**
 * `pclink/install.sh` branch tests.
 *
 * The real no-TTY path and the Windows refusal run the unmodified script with
 * a detached process (no controlling terminal). Version/no-dsh branches run a
 * temporary copy whose `/dev/tty` plumbing is redirected to regular files,
 * because some sandboxes (including the one this suite was developed in) deny
 * `openpty(3)` and cannot allocate an expect pty. The copy is generated from
 * the real file on every run and differs only in TTY redirections; it is not a
 * checked-in alternate script.
 *
 * The script tests always run through `/bin/bash`. Where that is macOS bash
 * 3.2 and an en_US.UTF-8 locale exists, every run also exports LANG/LC_ALL
 * en_US.UTF-8: bash 3.2 treats the first byte of a following multibyte
 * character as part of a bare `$name`, and with `set -u` that breaks the
 * installer on stock Macs.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { packageSha256 } from '../core/package-info.mjs'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const PCLINK = resolve(HERE, '..')
const INSTALL = join(PCLINK, 'install.sh')
const BASH = '/bin/bash'

/** First UTF-8 locale the host advertises, preferring the macOS name. */
function utf8Locale() {
  const result = spawnSync('locale', ['-a'], { encoding: 'utf8' })
  if (result.status !== 0) return undefined
  const locales = result.stdout.split('\n').map(line => line.trim())
  return locales.find(name => name === 'en_US.UTF-8')
    ?? locales.find(name => name === 'en_US.utf8')
}

const UTF8_LOCALE = utf8Locale()
const BASH_VERSION = spawnSync(BASH, ['--version'], { encoding: 'utf8' }).stdout ?? ''
const MACOS_BASH32_UTF8 = process.platform === 'darwin'
  && /version 3\.2\./.test(BASH_VERSION)
  && UTF8_LOCALE !== undefined

/** Force UTF-8 whenever the host has it; this is what stock Macs use. */
function bashUtf8Env(env = process.env) {
  return UTF8_LOCALE === undefined ? env : { ...env, LANG: UTF8_LOCALE, LC_ALL: UTF8_LOCALE }
}

/** Spawn `/bin/bash`, never the `bash` a modified PATH might resolve elsewhere. */
function spawnBash(args, options = {}) {
  return spawnSync(BASH, args, { ...options, env: bashUtf8Env(options.env) })
}

/** Run this suite's normal `cat script | bash` simulation under /bin/bash. */
function runPipedBash(name, script, options = {}) {
  return spawnBash(['-c', 'cat "$1" | "$2"', name, script, BASH], options)
}

function tempDir(prefix) {
  return mkdtempSync(join(tmpdir(), prefix))
}

function executable(path, text) {
  writeFileSync(path, text)
  chmodSync(path, 0o755)
}

/** Build a copy of install.sh with the controlling terminal replaced by files. */
function ttylessCopy(root) {
  let text = readFileSync(INSTALL, 'utf8')
  assert.ok(text.includes('exec 3</dev/tty'))
  text = text
    .replace('if ! { : </dev/tty; } 2>/dev/null; then', 'if false; then')
    .replace('exec 3</dev/tty', 'exec 3<"$PCLINK_TEST_TTY_IN"')
    .replaceAll('<&3', '<"$PCLINK_TEST_TTY_IN"')
    .replaceAll('>&3', '>>"$PCLINK_TEST_TTY_OUT"')
    .replaceAll('< /dev/tty', '<"$PCLINK_TEST_TTY_IN"')
    .replaceAll('> /dev/tty', '>>"$PCLINK_TEST_TTY_OUT"')
  const path = join(root, 'install-ttyless.sh')
  writeFileSync(path, text)
  return path
}

function baseEnv(bin) {
  const nodeDir = dirname(process.execPath)
  return {
    ...process.env,
    HOME: join(dirname(bin), 'home'),
    PATH: `${bin}:${nodeDir}:/usr/bin:/bin:/usr/sbin:/sbin`,
    DSH_HOME: join(dirname(bin), 'dsh'),
    PCLINK_PLUGIN_SPEC: '/nonexistent/pclink',
  }
}

test('install.sh refuses to run without a controlling terminal (curl | bash)', () => {
  const result = runPipedBash('pclink-install-no-tty', INSTALL, {
    detached: true,
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
    input: '',
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /需要终端（TTY）/)
  assert.match(result.stderr, /配对本身只扫码/)
  // Nothing was installed or paired.
  assert.equal(result.stdout.includes('[1/4]'), false)
})

test('install.sh refuses Windows before any prompt', () => {
  const bin = tempDir('pclink-win-bin-')
  executable(join(bin, 'uname'), '#!/bin/sh\necho MINGW64_NT-10.0\n')
  const result = runPipedBash('pclink-install-win', INSTALL, {
    detached: true,
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
    input: '',
    env: { ...process.env, PATH: `${bin}:/usr/bin:/bin` },
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /Windows 不在 PCLink v1 范围内/)
})

test('version_in_range accepts >=0.2.2-rc.1 <0.3.0 and rejects the rest', () => {
  const source = readFileSync(INSTALL, 'utf8')
  const match = /^version_in_range\(\) \{\n([\s\S]*?)^\}\n/m.exec(source)
  assert.ok(match, 'version_in_range function must remain extractable')
  const script = [
    'version_in_range() {',
    match[1],
    '}',
    'for version in 0.2.2-rc.1 0.2.2 0.2.3 0.2.99 0.2.1 0.2.2-rc.0 0.2.2-beta.1 0.3.0 1.0.0 garbage; do',
    '  if version_in_range "$version"; then printf "%s yes\\n" "$version"; else printf "%s no\\n" "$version"; fi',
    'done',
  ].join('\n')
  const path = join(tempDir('pclink-version-'), 'range.sh')
  writeFileSync(path, script)
  const result = spawnSync('/bin/sh', [path], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(result.stdout.trimEnd().split('\n'), [
    '0.2.2-rc.1 yes',
    '0.2.2 yes',
    '0.2.3 yes',
    '0.2.99 yes',
    '0.2.1 no',
    '0.2.2-rc.0 no',
    '0.2.2-beta.1 no',
    '0.3.0 no',
    '1.0.0 no',
    'garbage no',
  ])
})

test('an out-of-range dsh asks once and a q answer cancels before install', () => {
  const root = tempDir('pclink-out-of-range-')
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'prompts.txt')
  writeFileSync(input, 'q\n')
  const env = baseEnv(bin)
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  executable(join(bin, 'dsh'), '#!/bin/sh\nif [ "$1" = "-V" ]; then echo 0.3.0; exit 0; fi\nexit 0\n')
  const result = runPipedBash('pclink-install-range', script, {
    encoding: 'utf8',
    env: { ...env, PCLINK_TEST_TTY_IN: input, PCLINK_TEST_TTY_OUT: output, DSH_BIN: join(bin, 'dsh') },
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /不在已验证范围/)
  assert.match(result.stderr, /已取消/)
  assert.match(readFileSync(output, 'utf8'), /按 Enter 继续安装/)
  // It cancelled before `dsh plugin add`.
  assert.equal(readFileSync(output, 'utf8').includes('安装/更新 PCLink 插件'), false)
})

test('missing dsh fails with the DSH_BIN/PATH hint before install', () => {
  const root = tempDir('pclink-no-dsh-')
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'prompts.txt')
  writeFileSync(input, '')
  const result = runPipedBash('pclink-install-no-dsh', script, {
    encoding: 'utf8',
    env: { ...baseEnv(bin), PCLINK_TEST_TTY_IN: input, PCLINK_TEST_TTY_OUT: output },
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /找不到 dsh/)
  assert.match(result.stderr, /DSH_BIN/)
})
test('install.sh helpers cannot consume the curl script pipe', () => {
  // The real pclink CLI creates a readline interface on stdin even for
  // `status`. Under `curl | bash` that would eat the rest of the script if
  // helper commands inherited stdin, so every helper is redirected from
  // /dev/null. This fake status reads stdin to EOF to pin that redirect.
  const root = tempDir('pclink-stdin-')
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'pair.out')
  writeFileSync(input, '')
  writeFileSync(output, '')
  const env = baseEnv(bin)
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  const pclink = join(root, 'pclink')
  executable(pclink, '#!/bin/sh\nif [ "$1" = "status" ]; then cat >/dev/null; exit 0; fi\necho "FAKE PAIR $*"\n')
  executable(join(bin, 'dsh'), `#!/bin/sh
if [ "$1" = "-V" ]; then echo 0.2.2-rc.1; exit 0; fi
if [ "$1" = "plugin" ]; then
  mkdir -p "$DSH_HOME/profiles/web/node_modules/.bin" "$DSH_HOME/pclink"
  cp '${pclink}' "$DSH_HOME/profiles/web/node_modules/.bin/pclink"
  chmod +x "$DSH_HOME/profiles/web/node_modules/.bin/pclink"
  : > "$DSH_HOME/pclink/admin.json"
  exit 0
fi
exit 0
`)
  const result = runPipedBash('pclink-install-stdin', script, {
    encoding: 'utf8',
    env: { ...env, PCLINK_TEST_TTY_IN: input, PCLINK_TEST_TTY_OUT: output },
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /\[4\/4\] 打开配对二维码/)
  assert.match(readFileSync(output, 'utf8'), /FAKE PAIR pair/)
})


/** Build a fake profile package with a known version/bytes. */
function writePackage(root, version, marker) {
  mkdirSync(join(root, 'cli'), { recursive: true })
  writeFileSync(join(root, 'package.json'), JSON.stringify({ name: 'dsh-pclink', version }) + '\n')
  writeFileSync(join(root, 'cli', 'bin.mjs'), `// ${marker}\n`)
  return packageSha256(root)
}

/** Fake pclink bin whose `--json` facts follow a marker/counter. */
function fakePclink(path, { oldVersion, oldSha, newVersion, newSha, marker, flipAfterCalls }) {
  executable(path, `#!/bin/sh
if [ "$1" = "pair" ]; then
  printf 'FAKE PAIR %s\\n' "$*" >> "${path}.pair.log"
  exit 0
fi
if [ "$1" = "status" ]; then
  if [ "$2" != "--json" ]; then exit 0; fi
  if [ -n "${flipAfterCalls}" ]; then
    count=0
    [ -f "${path}.count" ] && count=$(cat "${path}.count")
    count=$((count + 1))
    printf '%s' "$count" > "${path}.count"
    if [ "$count" -ge ${flipAfterCalls} ]; then : > "${marker}"; fi
  fi
  if [ -f "${marker}" ]; then
    printf '{"v":1,"plugin":{"version":"${newVersion}","packageSha256":"${newSha}"}}\\n'
  else
    printf '{"v":1,"plugin":{"version":"${oldVersion}","packageSha256":"${oldSha}"}}\\n'
  fi
  exit 0
fi
exit 0
`)
}

/** Shared scaffolding for the upgrade branches. */
function upgradeFixture(root, { withLaunchd, flipAfterCalls }) {
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const home = join(root, 'home')
  const dshHome = join(root, 'dsh')
  const profile = join(dshHome, 'profiles', 'web')
  const packageDir = join(profile, 'node_modules', 'dsh-pclink')
  const oldRoot = join(root, 'old-package')
  const newRoot = join(root, 'new-package')
  const oldSha = writePackage(oldRoot, '0.1.0', 'old')
  const newSha = writePackage(newRoot, '0.2.0', 'new')
  mkdirSync(join(profile, 'node_modules', '.bin'), { recursive: true })
  mkdirSync(join(dshHome, 'pclink'), { recursive: true })
  // Install the old package into the profile before the script starts.
  mkdirSync(join(packageDir, 'cli'), { recursive: true })
  writeFileSync(join(packageDir, 'package.json'), readFileSync(join(oldRoot, 'package.json')))
  writeFileSync(join(packageDir, 'cli', 'bin.mjs'), readFileSync(join(oldRoot, 'cli', 'bin.mjs')))
  writeFileSync(join(dshHome, 'pclink', 'admin.json'), '{}\n')
  const marker = join(root, 'restarted')
  const pclink = join(bin, 'pclink')
  fakePclink(pclink, {
    oldVersion: '0.1.0', oldSha, newVersion: '0.2.0', newSha,
    marker, flipAfterCalls,
  })
  // The path the installer resolves is the profile's .bin/pclink.
  executable(join(profile, 'node_modules', '.bin', 'pclink'), `#!/bin/sh\nexec "${pclink}" "$@"\n`)
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  executable(join(bin, 'dsh'), `#!/bin/sh
if [ "$1" = "-V" ]; then echo 0.2.2; exit 0; fi
if [ "$1" = "plugin" ]; then
  cp '${newRoot}/package.json' '${packageDir}/package.json'
  cp '${newRoot}/cli/bin.mjs' '${packageDir}/cli/bin.mjs'
  exit 0
fi
exit 0
`)
  // Always shadow the host launchctl: a macOS dev machine may run the user's
  // real ai.deepseek.dsh agent, and this test must never restart it.
  executable(join(bin, 'launchctl'), withLaunchd
    ? `#!/bin/sh
if [ "$1" = "print" ]; then exit 0; fi
if [ "$1" = "kickstart" ]; then : > '${marker}'; exit 0; fi
exit 1
`
    : '#!/bin/sh\nexit 1\n')
  return { bin, home, dshHome, newSha, oldSha, marker, pclink, profile }
}

test('upgrade restart: launchd is restarted and the new version/SHA is verified', () => {
  const root = tempDir('pclink-upgrade-launchd-')
  const fixture = upgradeFixture(root, { withLaunchd: true, flipAfterCalls: '' })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'prompts.txt')
  writeFileSync(input, 'y\n')
  writeFileSync(output, '')
  const env = {
    ...baseEnv(fixture.bin),
    HOME: fixture.home,
    DSH_HOME: fixture.dshHome,
    DSH_BIN: join(fixture.bin, 'dsh'),
    PCLINK_PLUGIN_SPEC: '/nonexistent/pclink',
    PCLINK_TEST_TTY_IN: input,
    PCLINK_TEST_TTY_OUT: output,
  }
  const result = runPipedBash('pclink-upgrade-launchd', script, { encoding: 'utf8', env })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /检测到插件已升级/)
  assert.match(readFileSync(output, 'utf8'), /需要重启 dsh web 以加载新版本/)
  assert.match(result.stdout, /运行中的插件已是新版本/)
  assert.ok(existsSync(fixture.marker), 'launchctl kickstart must have run')
  const prompts = readFileSync(output, 'utf8')
  assert.equal((prompts.match(/\[Y\/n\]/g) ?? []).length, 1, 'at most one Y/n prompt')
  assert.match(readFileSync(`${fixture.pclink}.pair.log`, 'utf8'), /pair/)
})

test('upgrade restart: with no service manager it prints the exact command and waits for Enter', () => {
  const root = tempDir('pclink-upgrade-foreground-')
  // Flip on the third status call: initial running_facts (1), first verify (2),
  // second verify (3) — the user pressed Enter and the new process is up.
  const fixture = upgradeFixture(root, { withLaunchd: false, flipAfterCalls: 3 })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'prompts.txt')
  writeFileSync(input, '\n\n')
  writeFileSync(output, '')
  const env = {
    ...baseEnv(fixture.bin),
    HOME: fixture.home,
    DSH_HOME: fixture.dshHome,
    DSH_BIN: join(fixture.bin, 'dsh'),
    PCLINK_PLUGIN_SPEC: '/nonexistent/pclink',
    PCLINK_TEST_TTY_IN: input,
    PCLINK_TEST_TTY_OUT: output,
  }
  const result = runPipedBash('pclink-upgrade-foreground', script, { encoding: 'utf8', env })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /前台：/)
  assert.match(result.stdout, /web --no-open/)
  assert.match(result.stdout, /运行中的插件已是新版本/)
  assert.equal((readFileSync(output, 'utf8').match(/\[Y\/n\]/g) ?? []).length, 0)
})

test('install.sh does not put a bare $NAME directly before a non-ASCII byte', () => {
  // macOS /bin/bash 3.2 with a UTF-8 locale folds the first byte of a
  // multibyte character into a bare variable name. With `set -u`,
  // `$DEFAULT_RELAY（默认）` becomes an unbound `DEFAULT_RELAY\xef` and the
  // installer aborts. `${DEFAULT_RELAY}（默认）` has an unambiguous end.
  const source = readFileSync(INSTALL, 'utf8')
  const offenders = []
  for (const [index, line] of source.split('\n').entries()) {
    for (const match of line.matchAll(/\$(?!\{)[A-Za-z_][A-Za-z0-9_]*/g)) {
      const next = line.codePointAt(match.index + match[0].length)
      if (next !== undefined && next > 0x7f) {
        offenders.push(`line ${index + 1}: ${match[0]}${String.fromCodePoint(next)}`)
      }
    }
  }
  assert.deepEqual(offenders, [], 'a bare $NAME followed by a multibyte byte is unbound under bash 3.2 + UTF-8')
})

test('install.sh uses ${NAME} for every named expansion', () => {
  // The targeted check above is what the bash 3.2 bug requires; bracing every
  // named expansion keeps the next Chinese character from reintroducing it.
  const source = readFileSync(INSTALL, 'utf8')
  const bare = [...source.matchAll(/\$(?!\{)[A-Za-z_][A-Za-z0-9_]*/g)]
    .map(match => `${match[0]} at offset ${match.index}`)
  assert.deepEqual(bare, [], 'use ${NAME} everywhere')
})

test('install.sh prints the default relay under macOS bash 3.2 + UTF-8', (t) => {
  if (!MACOS_BASH32_UTF8) {
    t.skip(`needs macOS /bin/bash 3.2 + en_US.UTF-8 (bash: ${BASH_VERSION.split('\n')[0]}, locale: ${UTF8_LOCALE ?? 'none'})`)
    return
  }
  const root = tempDir('pclink-utf8-relay-')
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'prompts.txt')
  writeFileSync(input, '')
  writeFileSync(output, '')
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  executable(join(bin, 'dsh'), '#!/bin/sh\nif [ "$1" = "-V" ]; then echo 0.2.2; exit 0; fi\nexit 9\n')
  const env = baseEnv(bin)
  delete env.PCLINK_RELAY_URL
  const result = runPipedBash('pclink-install-utf8-relay', script, {
    encoding: 'utf8',
    env: {
      ...env,
      PCLINK_TEST_TTY_IN: input,
      PCLINK_TEST_TTY_OUT: output,
      DSH_BIN: join(bin, 'dsh'),
    },
  })
  assert.doesNotMatch(result.stderr, /unbound variable/)
  assert.match(result.stdout, /中继：https:\/\/pclink\.tonoai\.cn（默认）/)
  assert.equal(result.status, 1)
  assert.match(result.stderr, /dsh plugin add 失败/)
})

test('install.sh pairing-failure die uses $pair_status under macOS bash 3.2 + UTF-8', (t) => {
  if (!MACOS_BASH32_UTF8) {
    t.skip(`needs macOS /bin/bash 3.2 + en_US.UTF-8 (bash: ${BASH_VERSION.split('\n')[0]}, locale: ${UTF8_LOCALE ?? 'none'})`)
    return
  }
  const root = tempDir('pclink-utf8-pair-')
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'pair.out')
  writeFileSync(input, '')
  writeFileSync(output, '')
  const env = baseEnv(bin)
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  const pclink = join(root, 'pclink')
  executable(pclink, '#!/bin/sh\nif [ "$1" = "status" ]; then exit 0; fi\nexit 7\n')
  executable(join(bin, 'dsh'), `#!/bin/sh
if [ "$1" = "-V" ]; then echo 0.2.2; exit 0; fi
if [ "$1" = "plugin" ]; then
  mkdir -p "$DSH_HOME/profiles/web/node_modules/.bin" "$DSH_HOME/pclink"
  cp '${pclink}' "$DSH_HOME/profiles/web/node_modules/.bin/pclink"
  chmod +x "$DSH_HOME/profiles/web/node_modules/.bin/pclink"
  : > "$DSH_HOME/pclink/admin.json"
  exit 0
fi
exit 0
`)
  const result = runPipedBash('pclink-install-utf8-pair', script, {
    encoding: 'utf8',
    env: {
      ...env,
      PCLINK_RELAY_URL: 'https://relay.example',
      PCLINK_TEST_TTY_IN: input,
      PCLINK_TEST_TTY_OUT: output,
    },
  })
  assert.doesNotMatch(result.stderr, /unbound variable/)
  assert.match(result.stdout, /中继：https:\/\/relay\.example（PCLINK_RELAY_URL）/)
  assert.equal(result.status, 1)
  assert.match(result.stderr, /配对未完成（退出码 7）/)
})
