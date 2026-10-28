// SPDX-License-Identifier: MIT
/**
 * `llm-bridge`: the model (and MCP / web) HTTP transport for DSH in the phone
 * runtime. While loaded it replaces `globalThis.fetch` with a node:http(s)
 * implementation when Node's own fetch cannot run (`--jitless`), optionally
 * routing upstream traffic through the host app's HTTP egress.
 *
 * Why the transport and not an adapter or `llm/stream`: the shipped adapters
 * call the global fetch directly (the DeepSeek Messages adapter has no
 * transport injection point; pi-ai providers use SDKs that call fetch too), and
 * `llm/stream` sits above request serialization, so owning it would mean
 * re-implementing every provider's wire protocol. DSH already scopes transport
 * policy per process (its HTTP proxy support swaps undici's global dispatcher
 * before plugins mount); this plugin swaps the transport one level lower,
 * where WebAssembly is no longer needed.
 *
 * The phone bundle entry also installs the same transport before the tree
 * boots, so fetch calls made during plugin activation (MCP connect) work; this
 * plugin then re-installs with its own configuration and restores the
 * previous transport on unload.
 * @module @phone-dsh/dsh-llm-bridge
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { installNodeFetch, nativeFetchUsable, nodeFetchInstalled } from './install.ts'
import type { InstallMode } from './install.ts'
import type { NodeFetchOptions } from './node-fetch.ts'

export {
  installNodeFetch, nativeFetchUsable, nodeFetchInstalled, NODE_FETCH_MARK,
  DeliveryTimeoutError, DEFAULT_DELIVERY_IDLE_TIMEOUT_MS,
  RESUME_FROM_HEADER, RESUMED_HEADER, MAX_DELIVERY_RESUMES,
  deliveryMetricsSnapshot,
} from './install.ts'
export type { DeliveryMetricsSnapshot } from './install.ts'

/**
 * Create the desktop node:http(s) fetch. The transport module is imported on
 * the first call, so loading this package entry in the Worker never evaluates
 * `node:http`, `node:https`, `node:stream` or `node:zlib` (the Worker route
 * uses the platform fetch and the host `/v1/http` bearer route instead).
 * @param options - host proxy route and per-request header hook.
 * @returns a fetch function with the global fetch signature.
 */
export function createNodeFetch(options: NodeFetchOptions = {}): typeof fetch {
  let pending: Promise<typeof fetch> | undefined
  const lazy = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    pending ??= import('./node-fetch.ts').then(module => module.createNodeFetch(options))
    return await (await pending)(input, init)
  }) as typeof fetch
  return lazy
}

export const name = 'llm-bridge'

export interface Config {
  /** `auto`: only when WebAssembly is unavailable; `always`: also with JIT; `never`: keep Node's fetch. */
  mode: InstallMode
  /** Route requests through the host app's `POST /v1/http`. */
  hostProxy: boolean
  /** `external`: only non-loopback URLs use the host route; `all`: loopback upstreams too. */
  hostProxyRoutes: 'external' | 'all'
  /** Exec-bridge URL for the host route; defaults to `$PDSH_EXEC_BRIDGE_URL`. */
  bridgeUrl?: string
  /** Environment variable holding the exec-bridge token. */
  tokenEnv: string
  /** Extra non-loopback hostnames that receive the tool-call idempotency header. */
  idempotencyHosts: string[]
}

export const Config: z<Config> = z.object({
  mode: z.union(['auto', 'always', 'never'] as const).default('auto'),
  hostProxy: z.boolean().default(false),
  hostProxyRoutes: z.union(['external', 'all'] as const).default('external'),
  bridgeUrl: z.string(),
  tokenEnv: z.string().default('PDSH_EXEC_BRIDGE_TOKEN'),
  idempotencyHosts: z.array(String).default([]),
}) as z<Config>

export function apply(ctx: Context, config: Config): void {
  let proxy: { url: string; token: string; match?: (url: URL) => boolean } | undefined
  if (config.hostProxy) {
    const url = config.bridgeUrl ?? process.env.PDSH_EXEC_BRIDGE_URL
    const token = process.env[config.tokenEnv]
    if (url === undefined || url === '' || token === undefined || token === '') {
      throw new Error(`llm-bridge: hostProxy needs the exec-bridge URL and ${config.tokenEnv}`)
    }
    proxy = { url, token, ...config.hostProxyRoutes === 'all' ? { match: () => true } : {} }
  }
  const restore = installNodeFetch({ mode: config.mode, proxy, idempotencyHosts: config.idempotencyHosts })
  ctx.effect(() => restore, 'llm-bridge global fetch')
  ctx.logger('llm-bridge').debug('transport: %s', nodeFetchInstalled()
    ? `node:http${proxy === undefined ? '' : ' via host proxy'}`
    : `native fetch (WebAssembly ${nativeFetchUsable() ? 'available' : 'missing'})`)
}
