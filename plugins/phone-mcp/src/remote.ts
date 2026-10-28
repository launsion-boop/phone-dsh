// SPDX-License-Identifier: MIT
/**
 * Host Remote face over the live manager: the generic `phone/mcp` dispatcher and
 * the specific `phone/mcpList` / `phone/mcpUpsert` / `phone/mcpRemove` /
 * `phone/mcpReconnect` endpoints. The methods are thin so the browser Settings
 * tab and native transports read and write the same authority.
 *
 * @module @phone-dsh/dsh-phone-mcp/remote
 */

import type { Context } from '@deepseek-ai/cordis'
import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import type { PhoneMcpManager } from './manager.ts'
import type { McpDispatchRequest, McpServerRef, McpServerUpsertRequest, McpServerView, McpSnapshot } from './protocol.ts'

/** Construction config from the package plugin. */
export interface PhoneMcpRemoteConfig {
  readonly manager: PhoneMcpManager
}

/**
 * One phone-only Remote service. `phone` is already the phone adapter
 * namespace; these method names stay distinct from `phone/listTools` and
 * `phone/createSchedule`.
 */
export class PhoneMcpRemote extends TypertRemoteService {
  private readonly manager: PhoneMcpManager

  constructor(ctx: Context, config: PhoneMcpRemoteConfig) {
    super(ctx, 'phoneMcpRemote', { namespace: 'phone' })
    this.manager = config.manager
  }

  /** One generic endpoint for native callers: `phone/mcp` with an action. */
  async mcp(request: McpDispatchRequest): Promise<McpSnapshot | McpServerView | { serverName: string; removed: true }> {
    switch (request.action) {
      case 'list': return this.manager.list()
      case 'upsert': return this.manager.upsert(request.request)
      case 'remove': return this.manager.remove(request.request.serverName)
      case 'reconnect': return this.manager.reconnect(request.request.serverName)
    }
  }

  /** Read the persisted registry with live mount state and real tool names. */
  mcpList(): McpSnapshot {
    return this.manager.list()
  }

  /** Validate, mount, and then persist one server row. */
  mcpUpsert(request: McpServerUpsertRequest): Promise<McpServerView> {
    return this.manager.upsert(request)
  }

  /** Dispose one server's tools and remove its row. */
  mcpRemove(request: McpServerRef): Promise<{ serverName: string; removed: true }> {
    return this.manager.remove(request.serverName)
  }

  /** Reconnect one enabled row with freshly resolved environment headers. */
  mcpReconnect(request: McpServerRef): Promise<McpServerView> {
    return this.manager.reconnect(request.serverName)
  }
}

// Node's built-in TypeScript stripping cannot evaluate decorator syntax, so
// apply the same canonical marker explicitly (the pattern used by
// surface-phone's management Remote).
function markRemoteMethod(
  name: 'mcp' | 'mcpList' | 'mcpUpsert' | 'mcpRemove' | 'mcpReconnect',
  options?: Parameters<typeof Remote>[0],
): void {
  const descriptor = Object.getOwnPropertyDescriptor(PhoneMcpRemote.prototype, name)
  if (typeof descriptor?.value !== 'function') throw new TypeError(`phone-mcp remote method is missing: ${name}`)
  let initializer: ((this: PhoneMcpRemote) => void) | undefined
  const context = {
    name,
    private: false,
    static: false,
    addInitializer(fn: (this: PhoneMcpRemote) => void) { initializer = fn },
  } as unknown as ClassMethodDecoratorContext<PhoneMcpRemote, (this: PhoneMcpRemote, ...args: unknown[]) => unknown>
  const decorator = options === undefined ? Remote : Remote(options)
  decorator(descriptor.value as never, context as never)
  if (initializer === undefined) throw new TypeError(`phone Remote decorator did not initialize: ${name}`)
  initializer.call(Object.create(PhoneMcpRemote.prototype) as PhoneMcpRemote)
}

markRemoteMethod('mcp')
markRemoteMethod('mcpList')
markRemoteMethod('mcpUpsert')
markRemoteMethod('mcpRemove')
markRemoteMethod('mcpReconnect')
