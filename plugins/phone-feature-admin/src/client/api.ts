// SPDX-License-Identifier: MIT
/** Typed caller for the existing phone Remote namespace. */

import type { ConnectionRpcResult } from '@deepseek-ai/dsh-client-connection/client'
import type { FeatureAdminResult } from '../contracts.ts'

/** Feature Admin methods registered by the Host service. */
export type FeatureAdminMethod =
  | 'pluginList'
  | 'pluginSetEnabled'
  | 'skillsList'
  | 'skillsRead'
  | 'skillsWrite'
  | 'skillsDelete'
  | 'agentPresets'

/** The one transport face this tab needs from the page's Connection service. */
export interface FeatureAdminCarrier {
  call(channel: string, endpoint: string, payload: unknown, signal?: AbortSignal): Promise<ConnectionRpcResult<unknown>>
}

/** A carrier failure the page can show beside a Host refusal. */
export class FeatureAdminCarrierError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.name = 'FeatureAdminCarrierError'
    this.code = code
  }
}

/**
 * Invoke `phone/<method>` on the same Connection the rest of the Web client
 * uses. No second transport, session or React tree is involved.
 * @param carrier - live `ctx.connection.rpc`.
 * @param method - Feature Admin method.
 * @param args - named argument object the Typert server binds to the method.
 * @param signal - optional cancellation.
 * @returns the Host's structured result, including `unsupported`.
 */
export async function callFeatureAdmin<Value>(
  carrier: FeatureAdminCarrier,
  method: FeatureAdminMethod,
  args: Readonly<Record<string, unknown>> = {},
  signal?: AbortSignal,
): Promise<FeatureAdminResult<Value>> {
  const result = await carrier.call('/api', `phone/${method}`, { args }, signal)
  if (!result.ok) throw new FeatureAdminCarrierError(result.error.code, result.error.message)
  return result.value as FeatureAdminResult<Value>
}
