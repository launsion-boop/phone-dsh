// SPDX-License-Identifier: MIT
/** Browser client for the phone-owned MCP Remote methods over the shared Connection. */

import type { ConnectionHandle } from '@deepseek-ai/dsh-client-connection/client'
import type {
  McpServerRef,
  McpServerUpsertRequest,
  McpServerView,
  McpSnapshot,
} from '../protocol.ts'

/** Remote face injected into the Settings tab component. */
export interface PhoneMcpClient {
  list(): Promise<McpSnapshot>
  upsert(request: McpServerUpsertRequest): Promise<McpServerView>
  remove(request: McpServerRef): Promise<{ serverName: string; removed: true }>
  reconnect(request: McpServerRef): Promise<McpServerView>
}

/**
 * Build the tab's Remote face over `ctx.connection.rpc` — the same Connection
 * instance every DSH client module uses, never a second transport.
 *
 * @param connection - the client Connection service.
 * @returns Typed calls to `phone/mcp*`.
 */
export function createPhoneMcpClient(connection: ConnectionHandle): PhoneMcpClient {
  async function invoke<T>(endpoint: string, args: object): Promise<T> {
    const result = await connection.rpc.call('/api', endpoint, { args })
    if (!result.ok) throw new Error(`${result.error.code}: ${result.error.message}`)
    return result.value as T
  }
  return {
    list: () => invoke<McpSnapshot>('phone/mcpList', {}),
    upsert: request => invoke<McpServerView>('phone/mcpUpsert', { request }),
    remove: request => invoke<{ serverName: string; removed: true }>('phone/mcpRemove', { request }),
    reconnect: request => invoke<McpServerView>('phone/mcpReconnect', { request }),
  }
}
