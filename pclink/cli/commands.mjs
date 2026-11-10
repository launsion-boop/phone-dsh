/** Interactive CLI command implementations (TTY-gated fingerprint approval). */

import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { AdminClient } from '../core/admin.mjs'
import { fingerprintOf, normalizeFingerprintInput } from '../core/encoding.mjs'
import { pclinkError } from '../core/errors.mjs'
import { encodeQr, renderQrUnicode } from '../core/qr.mjs'
import { packageSha256, packageVersion, pluginBuildInfo } from '../core/package-info.mjs'

export { packageSha256, packageVersion, pluginBuildInfo }

/** The exact §4.6 full-owner warning shown before any pairing/approval. */
export const FULL_OWNER_WARNING = '此手机将能完整操作这台电脑上的 DSH：对话、在电脑上执行 Shell 和读写文件、处理审批、修改设置和插件。'
/** The exact §10 long-offline hint for a phone that cannot see a PC identity change. */
export const LONG_OFFLINE_HINT = '电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。'
/** Required TTY confirmation phrase for rotate-identity. */
export const ROTATE_PHRASE = 'rotate-identity'

/**
 * Delay helper with an injectable clock for tests.
 * @param {number} ms Milliseconds.
 * @returns {Promise<void>} resolves later.
 */
export function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Resolve one admin status pair from a CLI argument.
 * @param {object} status Admin status body.
 * @param {string} argument Name, machineId or fingerprint.
 * @returns {Record<string, unknown>} matching pair.
 */
export function resolvePairTarget(status, argument) {
  const pairs = Array.isArray(status?.pairs) ? status.pairs : []
  const exact = pairs.filter(pair => pair.peerMachineId === argument)
  if (exact.length === 1) return exact[0]
  const byName = pairs.filter(pair => pair.peerName === argument)
  if (byName.length === 1) return byName[0]
  if (byName.length > 1) throw pclinkError('bad_frame', `multiple pairings are named ${JSON.stringify(argument)}; use the machineId or fingerprint`)
  let normalized
  try {
    normalized = normalizeFingerprintInput(argument)
  } catch {
    normalized = undefined
  }
  if (normalized !== undefined) {
    const byFingerprint = pairs.filter(pair => fingerprintOf(pair.peerMachineId) === `${normalized.slice(0, 4)}-${normalized.slice(4, 8)}-${normalized.slice(8, 12)}`)
    if (byFingerprint.length === 1) return byFingerprint[0]
    if (byFingerprint.length > 1) throw pclinkError('bad_frame', 'fingerprint matches multiple pairings')
  }
  throw pclinkError('bad_frame', `no pairing matches ${JSON.stringify(argument)}`)
}

function printPairing(output, pairing) {
  if (pairing === undefined) return
  if (pairing.state === 'failed') {
    output.write(`配对失败：${pairing.error}\n`)
    return
  }
  if (pairing.state === 'completed') {
    output.write(`配对完成：${pairing.peerName}（${pairing.peerFingerprint}）\n`)
    if (pairing.peerMachineId !== undefined) {
      output.write(`撤销这台手机：pclink unpair ${pairing.peerMachineId}\n`)
    } else {
      output.write('撤销这台手机：pclink unpair --all\n')
    }
    return
  }
  if (pairing.state === 'awaiting_approval') {
    // Legacy pre-v1.6 PC: this CLI does not type fingerprints, but keeps
    // polling so an operator using the old PC's own prompt can finish it.
    output.write(`这台电脑仍在运行旧版配对流程，正在等待本机操作员在电脑上确认（手机名称 ${pairing.peerName}）。\n`)
    return
  }
  output.write(`配对状态：${pairing.state}\n`)
  if (pairing.qrURI !== undefined) output.write(`配对 URI（用手机扫码/粘贴）：\n${pairing.qrURI}\n`)
  if (pairing.manualCode !== undefined) output.write(`手动码：${pairing.manualCode}\n`)
  output.write(`五分钟后过期（${pairing.expiresAt}）。${FULL_OWNER_WARNING}\n`)
}

/**
 * Render a QR in the terminal. `qrencode` is preferred when installed; the
 * built-in encoder always renders the URI otherwise, so pairing never depends
 * on an optional external binary.
 * @param {string} uri Pairing URI.
 * @param {{write: (text: string) => void}} output Output.
 * @param {{spawnSyncImpl?: typeof spawnSync, ansi?: boolean}} [options] Test seams.
 * @returns {boolean} true when a QR was printed.
 */
export function renderQrCode(uri, output, options = {}) {
  const runner = options.spawnSyncImpl ?? spawnSync
  const ansi = options.ansi ?? true
  try {
    const result = runner('qrencode', ['-t', 'ANSIUTF8', '-o', '-', uri], { encoding: 'utf8', timeout: 3_000 })
    if (result.status === 0 && typeof result.stdout === 'string' && result.stdout.trim() !== '') {
      output.write(`${result.stdout}\n`)
      return true
    }
  } catch {
    // Fall through to the bundled encoder.
  }
  try {
    const { modules } = encodeQr(uri)
    output.write(`${renderQrUnicode(modules, { quietZone: 4, ansi })}\n`)
    return true
  } catch (error) {
    output.write(`（无法在终端渲染二维码：${error.message}；上面的 pclink:// URI 是完整配对内容，可在手机配对页粘贴。）\n`)
    return false
  }
}

/**
 * Start a pairing and poll until terminal. No TTY, fingerprint or operator
 * input is involved: the phone's scan/code entry is the approval (§4.4).
 *
 * A single admin request timeout or connection failure is retried inside the
 * deadline, because `dsh web` may be busy during a restart (§8.3).
 *
 * @param {{
 *   client: AdminClient,
 *   mode?: 'qr'|'manual',
 *   output: {write: (text: string) => void},
 *   pollMs?: number,
 *   timeoutMs?: number,
 *   onStatus?: (status: object) => void,
 *   signal?: AbortSignal,
 *   now?: () => number,
 *   delayImpl?: (ms: number) => Promise<void>,
 * }} options Pairing dependencies.
 * @returns {Promise<object>} final status body.
 */
export async function runPair(options) {
  const mode = options.mode ?? 'qr'
  const pollMs = options.pollMs ?? 250
  const timeoutMs = options.timeoutMs ?? 300_000
  const now = options.now ?? (() => Date.now())
  const wait = options.delayImpl ?? delay
  const started = await options.client.pair({ mode })
  const pairingId = started.pairing.id
  options.output.write(`PCLink 配对已开始（${mode === 'manual' ? '手动码' : 'QR'}）。\n`)
  printPairing(options.output, {
    id: pairingId,
    state: 'waiting',
    mode,
    qrURI: started.pairing.qrURI,
    manualCode: started.pairing.manualCode,
    expiresAt: started.pairing.expiresAt,
  })
  if (mode === 'qr' && started.pairing.qrURI !== undefined) renderQrCode(started.pairing.qrURI, options.output)
  const deadline = now() + timeoutMs
  let retrying = false
  for (;;) {
    if (options.signal?.aborted === true) throw pclinkError('unavailable', 'pairing cancelled')
    if (now() > deadline) throw pclinkError('session_expired', 'pairing did not complete in time')
    let status
    try {
      status = await options.client.status()
    } catch (error) {
      // A transient admin timeout/connection failure while dsh web restarts is
      // not a terminal pairing result. Keep the slot alive and retry.
      if (error?.code === 'unavailable') {
        if (!retrying) {
          retrying = true
          options.output.write('等待插件响应（dsh web 可能正在重启），配对继续…\n')
        }
        await wait(pollMs)
        continue
      }
      throw error
    }
    retrying = false
    options.onStatus?.(status)
    const pairing = status.pairing
    if (pairing === undefined || pairing.id !== pairingId) {
      throw pclinkError('unavailable', 'pairing slot disappeared before completion')
    }
    if (pairing.state === 'failed') throw pclinkError(pairing.error ?? 'unavailable', `pairing failed: ${pairing.error ?? 'unavailable'}`)
    if (pairing.state === 'completed') {
      options.output.write(`配对完成：${pairing.peerName}（${pairing.peerFingerprint}）\n`)
      options.output.write(pairing.peerMachineId === undefined
        ? '撤销这台手机：pclink unpair --all\n'
        : `撤销这台手机：pclink unpair ${pairing.peerMachineId}\n`)
      return status
    }
    if (pairing.state === 'awaiting_approval') {
      printPairing(options.output, pairing)
    }
    await wait(pollMs)
  }
}

/**
 * Print admin status, including plugin build facts and the pending pairing.
 * @param {object} status Admin status body.
 * @param {{write: (text: string) => void}} output Output.
 */
export function printStatus(status, output) {
  const plugin = status.plugin
  if (plugin === undefined) {
    output.write('插件：旧版（status 未提供 plugin 构建信息）\n')
  } else {
    output.write(`插件：${plugin.version}  sha256=${plugin.packageSha256}\n`)
  }
  output.write(`PC 身份：${status.identity.name}  ${status.identity.machineId}  ${fingerprintOf(status.identity.machineId)}\n`)
  output.write(`中继：${status.relay.origin}  ${status.relay.state}\n`)
  if (status.pairs.length === 0) {
    output.write('已配对手机：无\n')
  } else {
    output.write('已配对手机：\n')
    for (const pair of status.pairs) {
      const via = pair.approvedVia === 'qr'
        ? '扫码'
        : pair.approvedVia === 'manual'
          ? '手动码'
          : `旧版批准（${pair.approvedVia}）`
      output.write(`  - ${pair.peerName}  ${pair.peerMachineId}  ${fingerprintOf(pair.peerMachineId)}  approved=${pair.approvedAt} via=${via} online=${String(pair.online)} usable=${String(pair.usable)}${pair.reason === undefined ? '' : ` reason=${pair.reason}`}\n`)
    }
  }
  if (status.pairing !== undefined) {
    const pairing = status.pairing
    if (pairing.state === 'awaiting_approval') {
      output.write(`进行中的配对：旧版 PC 流程等待本机操作员确认，手机名称 ${pairing.peerName}（不显示对方指纹/机器码）\n`)
    } else if (pairing.state === 'joined') {
      output.write(`进行中的配对：已收到手机证明，正在完成（${pairing.peerName}）\n`)
    } else if (pairing.state === 'completed') {
      output.write(`最近配对完成：${pairing.peerName} ${pairing.peerFingerprint}\n`)
    } else if (pairing.state === 'failed') {
      output.write(`进行中的配对失败：${pairing.error}\n`)
    } else {
      output.write(`进行中的配对：${pairing.state} ${pairing.mode} ${pairing.qrURI ?? pairing.manualCode ?? ''}\n`)
    }
  }
  for (const warning of status.warnings) output.write(`警告：${warning}\n`)
}

/**
 * Revoke one pair (or all) after a TTY confirmation.
 * @param {{
 *   client: AdminClient,
 *   status: object,
 *   target?: string,
 *   all?: boolean,
 *   output: {write: (text: string) => void},
 *   stdinIsTTY: boolean,
 *   confirm: (prompt: string) => Promise<string>,
 * }} options Unpair dependencies.
 * @returns {Promise<object>} admin response.
 */
export async function runUnpair(options) {
  if (!options.stdinIsTTY) throw pclinkError('unavailable', 'unpair requires a TTY confirmation')
  let peerMachineIds
  if (options.all === true || options.target === undefined) {
    if (options.status.pairs.length === 0) throw pclinkError('bad_frame', 'no pairings to remove')
    peerMachineIds = options.status.pairs.map(pair => pair.peerMachineId)
    options.output.write(`将解除全部 ${String(peerMachineIds.length)} 台手机：\n`)
    for (const pair of options.status.pairs) options.output.write(`  - ${pair.peerName} ${fingerprintOf(pair.peerMachineId)}\n`)
  } else {
    const pair = resolvePairTarget(options.status, options.target)
    peerMachineIds = [pair.peerMachineId]
    options.output.write(`将解除配对：${pair.peerName} ${fingerprintOf(pair.peerMachineId)}\n`)
  }
  options.output.write('如果手机丢失或被盗：先解除全部配对，再运行 pclink rotate-identity。\n')
  const answer = await options.confirm('输入 yes 确认解除（其他输入取消）： ')
  if (answer.trim().toLowerCase() !== 'yes') throw pclinkError('unavailable', 'unpair cancelled')
  return options.all === true || options.target === undefined
    ? options.client.unpair({ all: true })
    : options.client.unpair({ peerMachineId: peerMachineIds[0] })
}

/**
 * Rotate the PC identity after the literal TTY phrase and warning.
 * @param {{
 *   client: AdminClient,
 *   output: {write: (text: string) => void},
 *   stdinIsTTY: boolean,
 *   ask: (prompt: string) => Promise<string>,
 * }} options Rotate dependencies.
 * @returns {Promise<object>} admin response.
 */
export async function runRotateIdentity(options) {
  if (!options.stdinIsTTY) throw pclinkError('unavailable', 'rotate-identity requires a TTY confirmation')
  options.output.write('这会生成新的 PC 身份，所有旧配对立即失效，每台手机都必须重新配对。\n')
  options.output.write(`离线手机不会自动知道新身份，会一直显示电脑离线；请手动解除旧配对。\n`)
  const answer = await options.ask(`输入 ${ROTATE_PHRASE} 确认旋转身份： `)
  if (answer.trim() !== ROTATE_PHRASE) throw pclinkError('unavailable', 'rotate-identity cancelled')
  return options.client.rotateIdentity(ROTATE_PHRASE)
}

/**
 * Construct the CLI admin client for one DSH home.
 * @param {string} dshHome DSH home.
 * @returns {AdminClient} admin client.
 */
export function createCliAdminClient(dshHome) {
  return new AdminClient({ dir: join(dshHome, 'pclink') })
}
