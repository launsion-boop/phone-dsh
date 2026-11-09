/** `pclink install`: find DSH, check version/native module, add the bundle, restart and pair. */

import { spawnSync, spawn } from 'node:child_process'
import { accessSync, constants, existsSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { AdminClient } from '../core/admin.mjs'
import { isDshVersionTested } from '../core/inner.mjs'
import { pclinkError } from '../core/errors.mjs'
import { FULL_OWNER_WARNING, packageSha256 } from './commands.mjs'

/** Package-relative default install spec for a source checkout. */
export function defaultLocalSpec() {
  const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  return existsSync(join(packageRoot, 'plugin', 'package.json')) ? packageRoot : undefined
}

/**
 * Find a DSH executable or source checkout.
 * @param {{env?: NodeJS.ProcessEnv, exists?: (path: string) => boolean}} [options] Environment.
 * @returns {{command: string, args: string[], source: 'path'|'source'|'env', root?: string, version?: string}} descriptor.
 */
export function findDsh(options = {}) {
  const env = options.env ?? process.env
  const exists = options.exists ?? existsSync
  if (env.DSH_BIN !== undefined && env.DSH_BIN !== '') {
    return { command: env.DSH_BIN, args: [], source: 'env', root: dirname(env.DSH_BIN) }
  }
  for (const directory of (env.PATH ?? '').split(':')) {
    if (directory === '') continue
    const candidate = join(directory, 'dsh')
    try {
      accessSync(candidate, constants.X_OK)
      return { command: candidate, args: [], source: 'path' }
    } catch {
      // keep searching
    }
  }
  const sourceRoots = [env.DSH_SOURCE, env.DSH_PIN_ROOT].filter(value => typeof value === 'string' && value !== '')
  for (const root of sourceRoots) {
    const bin = join(root, 'apps', 'cli', 'lib', 'bin.js')
    if (exists(bin)) return { command: process.execPath, args: [bin], source: 'source', root }
  }
  throw pclinkError('unavailable', 'cannot find dsh on PATH or a source checkout (set DSH_BIN or DSH_SOURCE)')
}

/**
 * Run one command and capture its output.
 * @param {string} command Executable.
 * @param {string[]} args Arguments.
 * @param {{env?: NodeJS.ProcessEnv, spawnSyncImpl?: typeof spawnSync}} [options] Environment/spawner.
 * @returns {{status: number, stdout: string, stderr: string}} result.
 */
export function runCaptured(command, args, options = {}) {
  const runner = options.spawnSyncImpl ?? spawnSync
  const result = runner(command, args, { encoding: 'utf8', env: options.env ?? process.env, stdio: ['ignore', 'pipe', 'pipe'] })
  return { status: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.stderr ?? '' }
}

/**
 * Read and check the DSH version.
 * @param {ReturnType<typeof findDsh>} dsh DSH descriptor.
 * @param {{spawnSyncImpl?: typeof spawnSync, env?: NodeJS.ProcessEnv}} [options] Test seams.
 * @returns {string} version.
 */
export function checkDshVersion(dsh, options = {}) {
  const result = runCaptured(dsh.command, [...dsh.args, '-V'], options)
  if (result.status !== 0) throw pclinkError('unavailable', `dsh -V failed: ${result.stderr.trim() || `exit ${String(result.status)}`}`)
  const version = result.stdout.trim() || result.stderr.trim()
  if (!isDshVersionTested(version)) {
    throw pclinkError('version_unsupported', `dsh ${version || '(unknown)'} is outside the tested range >=0.2.2-rc.1 <0.3.0`)
  }
  return version
}

/**
 * Check the host native module beside a source checkout.
 * @param {ReturnType<typeof findDsh>} dsh DSH descriptor.
 * @param {{platform?: string, arch?: string}} [options] Host facts.
 * @returns {{ok: boolean, path?: string, detail: string}} check result.
 */
export function checkNativeModule(dsh, options = {}) {
  if (dsh.root === undefined) return { ok: true, detail: 'packaged dsh: native module location is installation-specific' }
  const platform = options.platform ?? process.platform
  const arch = options.arch ?? process.arch
  const candidates = [
    join(dsh.root, 'native', 'system', 'packages', `${platform}-${arch}`, 'bin', 'system.node'),
    join(dsh.root, 'native', 'system', 'packages', `${platform}-${arch}`, 'system.node'),
    join(dsh.root, 'node_modules', '@deepseek-ai', `dsh-native-${platform}-${arch}`, 'system.node'),
  ]
  for (const candidate of candidates) {
    if (existsSync(candidate)) return { ok: true, path: candidate, detail: candidate }
  }
  return {
    ok: false,
    detail: `missing ${platform}-${arch} system.node (pin checkouts usually need a local native build; packaged npm dsh may differ)`,
  }
}

/**
 * Choose the default plugin install spec.
 * @param {{env?: NodeJS.ProcessEnv}} [options] Environment.
 * @returns {string} spec.
 */
export function defaultInstallSpec(options = {}) {
  const env = options.env ?? process.env
  if (typeof env.PCLINK_PLUGIN_SPEC === 'string' && env.PCLINK_PLUGIN_SPEC !== '') return env.PCLINK_PLUGIN_SPEC
  const local = defaultLocalSpec()
  if (local !== undefined) return local
  throw pclinkError('unavailable', 'set PCLINK_PLUGIN_SPEC (e.g. github:owner/repo#<commit>&path:/pclink) before installing from a published package')
}

/**
 * Run `dsh plugin --profile web add <spec>`.
 * @param {ReturnType<typeof findDsh>} dsh DSH descriptor.
 * @param {string} spec Package spec.
 * @param {{spawnSyncImpl?: typeof spawnSync, env?: NodeJS.ProcessEnv, output?: {write: Function}}} [options] Test seams.
 * @returns {{status: number, stdout: string, stderr: string}} result.
 */
export function addPlugin(dsh, spec, options = {}) {
  const output = options.output ?? process.stdout
  output.write('DSH 可能会弹出构建脚本审批，请核对并同意。\n')
  const runner = options.spawnSyncImpl ?? spawnSync
  const result = runner(dsh.command, [...dsh.args, 'plugin', '--profile', 'web', 'add', spec], {
    env: options.env ?? process.env,
    stdio: 'inherit',
  })
  return { status: result.status ?? 1 }
}

/**
 * Ask whether to restart `dsh web`.
 * @param {{ask: (prompt: string) => Promise<string>, output: {write: Function}}} options Prompt seam.
 * @returns {Promise<boolean>} true to restart.
 */
export async function askRestart(options) {
  const answer = await options.ask('现在重启 dsh web 吗？[y/N] ')
  return /^y(es)?$/i.test(answer.trim())
}

/**
 * Start `dsh web` detached when the operator asks for a restart.
 * @param {ReturnType<typeof findDsh>} dsh DSH descriptor.
 * @param {{spawnImpl?: typeof spawn, env?: NodeJS.ProcessEnv, output?: {write: Function}}} [options] Test seams.
 * @returns {import('node:child_process').ChildProcess | undefined} spawned process.
 */
export function restartDshWeb(dsh, options = {}) {
  const output = options.output ?? process.stdout
  const spawner = options.spawnImpl ?? spawn
  output.write('正在启动 dsh web（后台）…\n')
  try {
    const child = spawner(dsh.command, [...dsh.args, 'web', '--no-open'], {
      detached: true,
      stdio: 'ignore',
      env: options.env ?? process.env,
    })
    child.unref?.()
    return child
  } catch (error) {
    output.write(`无法自动重启 dsh web：${error.message}；请手动重启。\n`)
    return undefined
  }
}

/**
 * Poll the loopback admin API until the plugin is healthy.
 * @param {string} dshHome DSH home.
 * @param {{timeoutMs?: number, pollMs?: number, clientFactory?: (dir: string) => AdminClient}} [options] Timing seams.
 * @returns {Promise<object>} status body.
 */
export async function waitForPlugin(dshHome, options = {}) {
  const timeoutMs = options.timeoutMs ?? 60_000
  const pollMs = options.pollMs ?? 500
  const client = options.clientFactory?.(join(dshHome, 'pclink')) ?? new AdminClient({ dir: join(dshHome, 'pclink') })
  const deadline = Date.now() + timeoutMs
  let lastError
  while (Date.now() < deadline) {
    try {
      return await client.status()
    } catch (error) {
      lastError = error
      await new Promise(resolve => setTimeout(resolve, pollMs))
    }
  }
  throw pclinkError('unavailable', `plugin did not become healthy: ${lastError?.message ?? 'timeout'}`)
}

/**
 * Full install command (interactive).
 * @param {{
 *   dshHome: string,
 *   output: {write: Function},
 *   ask: (prompt: string) => Promise<string>,
 *   spec?: string,
 *   noRestart?: boolean,
 *   noPair?: boolean,
 *   pair: (options: object) => Promise<object>,
 *   env?: NodeJS.ProcessEnv,
 *   spawnSyncImpl?: typeof spawnSync,
 *   spawnImpl?: typeof spawn,
 *   findDshImpl?: typeof findDsh,
 *   waitForPluginImpl?: typeof waitForPlugin,
 * }} options Install dependencies.
 * @returns {Promise<{version: string, spec: string, sha256: string, status?: object, paired?: boolean}>} summary.
 */
export async function runInstall(options) {
  const env = options.env ?? process.env
  const dsh = (options.findDshImpl ?? findDsh)({ env })
  const version = checkDshVersion(dsh, { env, spawnSyncImpl: options.spawnSyncImpl })
  options.output.write(`找到 dsh ${version}（${dsh.source}${dsh.root === undefined ? '' : `: ${dsh.root}`}）\n`)
  const native = checkNativeModule(dsh)
  if (!native.ok) {
    options.output.write(`警告：${native.detail}\n`)
    options.output.write('继续安装前请先编译本机模块（见仓库 CONTRIBUTING / DSH 安装说明）。\n')
  }
  const spec = options.spec ?? defaultInstallSpec({ env })
  const packageRoot = defaultLocalSpec()
  const sha256 = packageRoot === undefined ? 'unknown' : packageSha256(packageRoot)
  options.output.write(`插件来源：${spec}\n包 SHA-256：${sha256}\n`)
  const added = addPlugin(dsh, spec, { env, output: options.output, spawnSyncImpl: options.spawnSyncImpl })
  if (added.status !== 0) throw pclinkError('unavailable', `dsh plugin add failed with exit ${String(added.status)}`)
  options.output.write('插件已安装。请确认 dsh web 使用的是 web profile。\n')
  if (options.noRestart !== true) {
    const restart = await askRestart(options)
    if (restart) restartDshWeb(dsh, { env, output: options.output, spawnImpl: options.spawnImpl })
  }
  const status = await (options.waitForPluginImpl ?? waitForPlugin)(options.dshHome)
  options.output.write(`插件已就绪：relay=${status.relay.origin} state=${status.relay.state}\n`)
  if (options.noPair === true) return { version, spec, sha256, status }
  options.output.write(`${FULL_OWNER_WARNING}\n`)
  await options.pair({ mode: 'qr' })
  return { version, spec, sha256, status, paired: true }
}
