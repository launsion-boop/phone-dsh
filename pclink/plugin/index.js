/**
 * dsh-pclink Cordis plugin entry.
 *
 * `connection` is the only hard service. `typertGateway` is optional in DSH,
 * so it is read without putting it in `inject`; an unsupported profile reports
 * `unsupported-profile` and does not dial the relay or advertise an endpoint.
 */
import { hostname } from 'node:os'
import { validateRelayOrigin } from '../core/relay.mjs'
import { validateName } from '../core/encoding.mjs'
import { dshRuntimeInfo } from './dsh-info.mjs'
import { adminOperationForPath, adminRoutePaths } from './admin-plane.mjs'
import { PclinkRuntime } from './pclink.mjs'

export const name = 'dsh-pclink'
export const inject = ['connection']

const LOG_PREFIX = '[pclink]'
const DEFAULT_RELAY = 'https://pclink.tonoai.cn'

function log(...args) {
  console.log(LOG_PREFIX, ...args)
}

/**
 * Convert a configured WebSocket URL or origin into the lowercase HTTP origin.
 * @param {unknown} value Configured value.
 * @returns {string} validated relay origin.
 */
function normalizeRelayOrigin(value) {
  if (typeof value !== 'string' || value === '') throw new TypeError('pclink: relay URL must be a non-empty string')
  let origin = value
  if (origin.startsWith('wss://')) origin = `https://${origin.slice('wss://'.length)}`
  else if (origin.startsWith('ws://')) origin = `http://${origin.slice('ws://'.length)}`
  origin = origin.replace(/\/+$/, '')
  return validateRelayOrigin(origin)
}

/**
 * Resolve plugin config, falling back to documented environment variables.
 * @param {Record<string, unknown> | undefined} raw Raw Cordis config.
 * @returns {{relayOrigin: string, pcName: string, dshHome: string}} resolved config.
 */
export function resolvePluginConfig(raw) {
  const config = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  const relay = config.relayUrl ?? config.relayOrigin ?? process.env.PCLINK_RELAY_URL ?? DEFAULT_RELAY
  const relayOrigin = normalizeRelayOrigin(relay)
  let pcName = config.name ?? process.env.PCLINK_PC_NAME ?? hostname()
  try {
    validateName(pcName, 'PC name')
  } catch {
    pcName = 'My PC'
  }
  const dshHome = typeof config.dshHome === 'string' && config.dshHome !== ''
    ? config.dshHome
    : process.env.DSH_HOME ?? `${process.env.HOME ?? process.cwd()}/.dsh`
  return { relayOrigin, pcName, dshHome }
}

/**
 * Cordis apply.
 * @param {import('@deepseek-ai/cordis').Context} ctx Host context.
 * @param {Record<string, unknown>} [raw] Plugin config.
 */
export async function apply(ctx, raw) {
  const gateway = ctx.get('typertGateway')
  if (gateway === undefined) {
    log('unsupported-profile: ctx.typertGateway is absent; the relay connection was not started')
    return
  }
  const config = resolvePluginConfig(raw)
  const runtime = new PclinkRuntime({
    connection: ctx.connection,
    gateway,
    dshHome: config.dshHome,
    relayOrigin: config.relayOrigin,
    pcName: config.pcName,
    WebSocketCtor: globalThis.WebSocket,
    log,
    dshInfo: dshRuntimeInfo(log),
  })
  await runtime.start()
  let disposers
  try {
    disposers = adminRoutePaths().map(path => {
      const operation = adminOperationForPath(path)
      return ctx.connection.fetch.register({
        path,
        methods: ['POST'],
        requestBody: 'buffered',
        fetch: async request => runtime.handleAdminHttp(request, operation),
      })
    })
  } catch (error) {
    await runtime.stop()
    throw error
  }
  ctx.effect(() => async () => {
    for (const dispose of disposers.reverse()) {
      try { await dispose() } catch { /* already disposed */ }
    }
    await runtime.stop()
  }, 'pclink: runtime and owner admin routes')
  log(`started relay=${config.relayOrigin} name=${JSON.stringify(config.pcName)} state=${config.dshHome}/pclink`)
}
