// SPDX-License-Identifier: MIT
/**
 * The tool-call context that ties a spawned command or an outgoing HTTP
 * request to the DSH tool call that caused it. The tool journal opens one
 * context per top-level tool call; the subprocess provider and the fetch
 * transport read it to derive deterministic `exec_id`s and `idem_key`s and to
 * attach `XL_IDEMPOTENCY_KEY` / `X-PDSH-Idempotency-Key`.
 *
 * The AsyncLocalStorage instance lives under a global symbol so the packages
 * stay independent: any of them may be loaded without the others.
 * @module @phone-dsh/dsh-exec-bridge/call-context
 */

import { AsyncLocalStorage } from 'node:async_hooks'

/** Global registry key; part of the cross-package contract. */
export const TOOL_CALL_CONTEXT_KEY = Symbol.for('phone-dsh.dsh.tool-call-context')

export interface ToolCallContext {
  readonly sessionId: string
  readonly callId: string
  /** `XL_IDEMPOTENCY_KEY` for this call. */
  readonly key: string
  /** DSH turn number of the call, decimal ASCII (exec.md §1 fallback). */
  readonly turnId?: string
  /** D20 ordinal of the tool call within its turn, decimal ASCII without leading zeros. */
  readonly stepId?: string
  /** Number of spawns already issued by this call; the next spawn uses this index. */
  spawns: number
}

type Registry = { [TOOL_CALL_CONTEXT_KEY]?: AsyncLocalStorage<ToolCallContext> }

/** Return the shared storage, creating and registering it on first use. */
export function toolCallStorage(): AsyncLocalStorage<ToolCallContext> {
  const registry = globalThis as Registry
  registry[TOOL_CALL_CONTEXT_KEY] ??= new AsyncLocalStorage<ToolCallContext>()
  return registry[TOOL_CALL_CONTEXT_KEY]
}

/** The context of the tool call currently executing on this async path, if any. */
export function currentToolCall(): ToolCallContext | undefined {
  return (globalThis as Registry)[TOOL_CALL_CONTEXT_KEY]?.getStore()
}
