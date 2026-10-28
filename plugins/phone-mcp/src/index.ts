// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-phone-mcp` host entry. It owns `/dsh/home/mcp.json`, mounts
 * enabled Streamable HTTP MCP servers through the official
 * `@deepseek-ai/dsh-mcp-client`, and publishes the `phone/mcp*` Remote methods.
 *
 * Only HTTP(S) is accepted: no stdio process, no inline tokens, and no second
 * transport implementation.
 *
 * @module @phone-dsh/dsh-phone-mcp
 */

import type { Context } from '@deepseek-ai/cordis'
import { PhoneMcpManager } from './manager.ts'
import type { PhoneMcpManagerOptions } from './manager.ts'
import { PhoneMcpRemote } from './remote.ts'

/** Cordis plugin name used in loader diagnostics. */
export const name = 'phone-mcp'

/** Live tool registration requires the harness tool registry. */
export const inject = ['tools']

/** Loader config for the host row. */
export interface Config extends PhoneMcpManagerOptions {}

/**
 * Mount the manager and its Remote face. Startup awaits every enabled server's
 * initial connection and tool sync; individual failures are recorded on their
 * rows instead of aborting the tree, so the Settings tab can show and repair them.
 *
 * @param ctx - host plugin context carrying `tools`.
 * @param config - optional absolute config path / environment override.
 */
export async function apply(ctx: Context, config: Config = {}): Promise<void> {
  const manager = new PhoneMcpManager(ctx, config)
  ctx.effect(() => () => manager.dispose(), 'phone-mcp: managed MCP servers')
  await ctx.plugin(PhoneMcpRemote, { manager })
  await manager.start()
}

export { PhoneMcpManager } from './manager.ts'
export { McpError, defaultConfigPath } from './schema.ts'
export type {
  McpServerConfig,
  McpServerRef,
  McpServerState,
  McpServerUpsertRequest,
  McpServerView,
  McpSnapshot,
} from './protocol.ts'
