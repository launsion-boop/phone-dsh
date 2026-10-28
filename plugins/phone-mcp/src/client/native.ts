// SPDX-License-Identifier: MIT
/**
 * Optional WKWebView bridge to the native host.
 *
 * The MCP tab is the normal management surface on desktop too, so every call
 * is a no-op when the native handler is absent. On the phone the host answers
 * with `WKScriptMessageHandlerWithReply`: the grant commit finishes before the
 * Worker upsert starts, and no header value ever crosses this bridge.
 *
 * @module @phone-dsh/dsh-phone-mcp/client/native
 */

/** Handler installed by the Swift `MCPControlBridge` on the local Web host. */
export const NATIVE_MCP_HANDLER = 'pdshMcpControl'

interface NativeReplyHandler {
  postMessage(message: unknown): Promise<unknown> | undefined
}

interface NativeGrantReply {
  readonly ok?: boolean
  readonly hostManagedHeaders?: readonly string[]
  readonly url?: string
  readonly transaction?: string
  readonly needsValues?: boolean
}

/** One native grant plus the rollback token for the following Worker upsert. */
export interface NativeMCPGrant {
  readonly hostManagedHeaders: readonly string[]
  /** Canonical URL the host actually granted, when the bridge supplied it. */
  readonly url?: string
  readonly transaction?: string
  readonly needsValues: boolean
}

interface NativeCommitReply {
  readonly committed?: boolean
  readonly cleanupPending?: boolean
  readonly commitPending?: boolean
}

/** Result of closing a native grant after a successful Worker upsert. */
export interface NativeMCPCommit {
  readonly committed: boolean
  /** The Worker row is committed but old Keychain/document cleanup is retried. */
  readonly cleanupPending: boolean
}

/** Native verdict for a lost upsert reply; only a registry read produces it. */
export type NativeMCPSettleResolution = 'committed' | 'commitPending' | 'rolled-back' | 'unknown'

/** Result of settling a native grant against the authoritative registry. */
export interface NativeMCPSettleResult {
  readonly committed: boolean
  readonly cleanupPending: boolean
  readonly resolved: NativeMCPSettleResolution
}

/**
 * Canonical identity of the exact HTTP endpoint: scheme, lower-case host,
 * effective port, normalized path and the actual query. The fragment never
 * participates. This mirrors the native `canonicalEndpointKey` used by grant,
 * settle and resolve so a trailing slash or explicit default port cannot make
 * a committed row look like the old one.
 * @param raw - URL as typed or as returned by `phone/mcpList`.
 * @returns the canonical key, or undefined for a non-HTTP URL.
 */
export function canonicalMCPEndpoint(raw: string): string | undefined {
  try {
    const url = new URL(raw.trim())
    const scheme = url.protocol === 'https:' ? 'https'
      : url.protocol === 'http:' ? 'http'
        : undefined
    if (scheme === undefined) return undefined
    const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '')
    if (host.length === 0) return undefined
    const port = url.port.length > 0 ? Number(url.port) : (scheme === 'https' ? 443 : 80)
    const segments: string[] = []
    for (const segment of url.pathname.split('/')) {
      if (segment.length === 0 || segment === '.') continue
      if (segment === '..') { segments.pop(); continue }
      segments.push(segment)
    }
    const path = segments.length === 0 ? '/' : `/${segments.join('/')}`
    const query = url.search.startsWith('?') ? url.search.slice(1) : ''
    return `${scheme}://${host}:${port}${path}${query.length === 0 ? '' : `?${query}`}`
  } catch {
    return undefined
  }
}

function bridge(): NativeReplyHandler | undefined {
  const webkit = (window as unknown as {
    webkit?: { messageHandlers?: Record<string, NativeReplyHandler | undefined> }
  }).webkit
  const handler = webkit?.messageHandlers?.[NATIVE_MCP_HANDLER]
  return typeof handler?.postMessage === 'function' ? handler : undefined
}

/** Whether the page runs inside the phone host with the native MCP bridge. */
export function nativeMCPBridgeAvailable(): boolean {
  return bridge() !== undefined
}

async function call(message: object): Promise<unknown> {
  const handler = bridge()
  if (handler === undefined) return undefined
  const result = handler.postMessage({ v: 1, ...message })
  if (result === undefined) return undefined
  return await result
}

/**
 * Ask the host to commit the exact-origin/path grant before upserting.
 * @param serverName - registry key.
 * @param url - exact MCP endpoint.
 * @param headers - header name to environment-variable name; only names matter.
 * @returns Header names the Worker must mark host-managed and the rollback
 * token, or `undefined` when the page is not hosted by the phone app.
 */
export async function grantNativeMCP(
  serverName: string,
  url: string,
  headers: Readonly<Record<string, string>>,
): Promise<NativeMCPGrant | undefined> {
  if (!nativeMCPBridgeAvailable()) return undefined
  const reply = await call({ action: 'grant', serverName, url, headers }) as NativeGrantReply | undefined
  return {
    hostManagedHeaders: reply?.hostManagedHeaders ?? Object.keys(headers),
    ...(reply?.url === undefined ? {} : { url: reply.url }),
    ...(reply?.transaction === undefined ? {} : { transaction: reply.transaction }),
    needsValues: reply?.needsValues === true,
  }
}

/**
 * Close a native grant transaction after the Worker upsert succeeded. A
 * cleanup failure is reported as commit-pending, never as a rollback-able
 * transaction; the native durable staging remains for the next reconcile.
 * @param transaction - token returned by {@link grantNativeMCP}.
 * @returns whether the grant closed and whether cleanup is still pending.
 */
export async function commitNativeMCP(transaction: string | undefined): Promise<NativeMCPCommit> {
  if (transaction === undefined || !nativeMCPBridgeAvailable()) {
    return { committed: true, cleanupPending: false }
  }
  const reply = await call({ action: 'commit', transaction }) as NativeCommitReply | undefined
  return {
    committed: reply?.committed !== false,
    cleanupPending: reply?.cleanupPending === true || reply?.commitPending === true,
  }
}

/** Restore the previous grant and Keychain value after a failed Worker upsert. */
export async function rollbackNativeMCP(transaction: string | undefined): Promise<void> {
  if (transaction === undefined || !nativeMCPBridgeAvailable()) return
  await call({ action: 'rollback', transaction })
}

/**
 * Keep staging for an unknown upsert result without rolling it back. The next
 * real `phone/mcpList` or materialized-registry read decides. Passing one
 * token leaves other in-flight transactions alone.
 * @param transaction - token returned by {@link grantNativeMCP}.
 */
export async function abandonNativeMCP(transaction: string | undefined): Promise<void> {
  if (transaction === undefined || !nativeMCPBridgeAvailable()) return
  await call({ action: 'abandon', transaction })
}

/**
 * Settle a transaction after the page queried the real registry following a
 * lost `phone/mcpUpsert` reply. A canonical matching URL commits; only a
 * confirmed previous row (or a confirmed absent new row) rolls back. The
 * native side keeps staging when it cannot prove either outcome.
 * @param transaction - token returned by {@link grantNativeMCP}.
 * @param registryURL - URL the successful list returned, or undefined.
 * @returns the consumed native verdict, including pending cleanup.
 */
export async function settleNativeMCP(
  transaction: string | undefined,
  registryURL: string | undefined,
): Promise<NativeMCPSettleResult> {
  if (transaction === undefined || !nativeMCPBridgeAvailable()) {
    return { committed: false, cleanupPending: false, resolved: 'unknown' }
  }
  const reply = await call({
    action: 'settle',
    transaction,
    ...(registryURL === undefined ? {} : { registryURL }),
  }) as {
    readonly committed?: boolean
    readonly cleanupPending?: boolean
    readonly resolved?: string
  } | undefined
  const resolved: NativeMCPSettleResolution = reply?.resolved === 'committed'
    || reply?.resolved === 'commitPending'
    || reply?.resolved === 'rolled-back'
    || reply?.resolved === 'unknown'
    ? reply.resolved
    : 'unknown'
  return {
    committed: reply?.committed === true,
    cleanupPending: reply?.cleanupPending === true,
    resolved,
  }
}

/** Revoke one server's exact grant and Keychain value after a successful remove. */
export async function revokeNativeMCP(serverName: string): Promise<void> {
  if (!nativeMCPBridgeAvailable()) return
  await call({ action: 'revoke', serverName })
}

/** Reconcile grants with a successful `phone/mcpList` response. */
export async function syncNativeMCP(
  servers: readonly { readonly serverName: string; readonly url: string }[],
): Promise<void> {
  if (!nativeMCPBridgeAvailable()) return
  await call({
    action: 'sync',
    servers: servers.map(({ serverName, url }) => ({ serverName, url })),
  })
}

/** One non-secret row the native sheet can prefill for key entry. */
export interface NativeMCPDraft {
  readonly serverName: string
  readonly url: string
  readonly headersFromEnv: Readonly<Record<string, string>>
  readonly enabled: boolean
  readonly toolCallTimeoutMs: number
}

/** Open the native MCP network/credential sheet from the Web tab. */
export function openNativeMCPSettings(draft?: NativeMCPDraft): void {
  const handler = bridge()
  if (handler === undefined) return
  void handler.postMessage({ v: 1, action: 'open', ...(draft === undefined ? {} : { draft }) })
}
