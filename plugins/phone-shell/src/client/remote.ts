// SPDX-License-Identifier: MIT
/**
 * Browser client for the `phone/shell*` Remote methods.
 *
 * The full DSH Web page already owns the generic Connection RPC carrier; this
 * helper sends the same `{ args }` envelope the Gateway's generated client
 * sends, so the console needs no second transport and no generated artifact
 * that would drift from the Host method signatures. Failures carry the Host's
 * `RemoteError` code instead of being flattened into a provider message.
 * @module @phone-dsh/dsh-phone-shell/client/remote
 */

import {
  PHONE_SHELL_ENDPOINTS,
} from '../contract.ts'
import type {
  PhoneShellCaps,
  PhoneShellRpc,
  PhoneShellRpcResult,
  PhoneShellRunRequest,
  PhoneShellRunResult,
} from '../contract.ts'

/** One failed console Remote call, preserving the Host code. */
export class PhoneShellRemoteError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.name = 'PhoneShellRemoteError'
    this.code = code
  }
}

/** Typed console calls over the page's existing Connection RPC. */
export interface PhoneShellConsoleClient {
  /** Read the real xz-shell caps and mounts from the live exec-bridge hello. */
  caps(signal?: AbortSignal): Promise<PhoneShellCaps>
  /** Run one Worker command or exact argv through the shared subprocess provider. */
  run(request: PhoneShellRunRequest, signal?: AbortSignal): Promise<PhoneShellRunResult>
  /** Cancel one client-identified running request. */
  cancel(execId: string, signal?: AbortSignal): Promise<boolean>
}

/**
 * Build the console client over a Connection RPC service.
 * @param rpc - `ctx.connection.rpc` from the page's existing Connection.
 * @returns typed caps/run/cancel calls.
 */
export function createPhoneShellClient(rpc: PhoneShellRpc): PhoneShellConsoleClient {
  return {
    caps: signal => invoke<PhoneShellCaps>(rpc, PHONE_SHELL_ENDPOINTS.caps, {}, signal),
    run: (request, signal) => invoke<PhoneShellRunResult>(rpc, PHONE_SHELL_ENDPOINTS.run, { request }, signal),
    cancel: (execId, signal) => invoke<boolean>(rpc, PHONE_SHELL_ENDPOINTS.cancel, { execId }, signal),
  }
}

async function invoke<T>(
  rpc: PhoneShellRpc,
  endpoint: string,
  args: Readonly<Record<string, unknown>>,
  signal: AbortSignal | undefined,
): Promise<T> {
  let result: PhoneShellRpcResult
  try {
    result = await rpc.call('/api', endpoint, { args }, signal)
  } catch (error) {
    signal?.throwIfAborted()
    throw new PhoneShellRemoteError('phone-shell/transport-failed', error instanceof Error ? error.message : String(error))
  }
  if (!result.ok) throw new PhoneShellRemoteError(result.error.code, result.error.message)
  return result.value as T
}
