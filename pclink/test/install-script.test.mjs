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
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const PCLINK = resolve(HERE, '..')
const INSTALL = join(PCLINK, 'install.sh')

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
    .replaceAll('>&3', '>"$PCLINK_TEST_TTY_OUT"')
    .replaceAll('< /dev/tty', '<"$PCLINK_TEST_TTY_IN"')
    .replaceAll('> /dev/tty', '>"$PCLINK_TEST_TTY_OUT"')
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
  const result = spawnSync('/bin/bash', ['-c', 'cat "$1" | bash', 'pclink-install-no-tty', INSTALL], {
    detached: true,
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
    input: '',
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /需要终端（TTY）/)
  assert.match(result.stderr, /不会自动批准/)
  // Nothing was installed or paired.
  assert.equal(result.stdout.includes('[1/4]'), false)
})

test('install.sh refuses Windows before any prompt', () => {
  const bin = tempDir('pclink-win-bin-')
  executable(join(bin, 'uname'), '#!/bin/sh\necho MINGW64_NT-10.0\n')
  const result = spawnSync('/bin/bash', ['-c', 'cat "$1" | bash', 'pclink-install-win', INSTALL], {
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

test('an out-of-range dsh asks once and a no answer cancels before install', () => {
  const root = tempDir('pclink-out-of-range-')
  const bin = join(root, 'bin')
  mkdirSync(bin, { recursive: true })
  const script = ttylessCopy(root)
  const input = join(root, 'answers.txt')
  const output = join(root, 'prompts.txt')
  writeFileSync(input, 'n\n')
  const env = baseEnv(bin)
  executable(join(bin, 'pnpm'), '#!/bin/sh\necho 11.0.0\n')
  executable(join(bin, 'dsh'), '#!/bin/sh\nif [ "$1" = "-V" ]; then echo 0.3.0; exit 0; fi\nexit 0\n')
  const result = spawnSync('/bin/bash', ['-c', 'cat "$1" | bash', 'pclink-install-range', script], {
    encoding: 'utf8',
    env: { ...env, PCLINK_TEST_TTY_IN: input, PCLINK_TEST_TTY_OUT: output, DSH_BIN: join(bin, 'dsh') },
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /不在已验证范围/)
  assert.match(result.stderr, /已取消/)
  assert.match(readFileSync(output, 'utf8'), /仍要继续安装吗/)
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
  const result = spawnSync('/bin/bash', ['-c', 'cat "$1" | bash', 'pclink-install-no-dsh', script], {
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
  const result = spawnSync('/bin/bash', ['-c', 'cat "$1" | bash', 'pclink-install-stdin', script], {
    encoding: 'utf8',
    env: { ...env, PCLINK_TEST_TTY_IN: input, PCLINK_TEST_TTY_OUT: output },
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /\[4\/4\] 打开配对二维码/)
  assert.match(readFileSync(output, 'utf8'), /FAKE PAIR pair/)
})
