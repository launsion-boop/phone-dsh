// SPDX-License-Identifier: MIT
/**
 * Crash-only resume planning. Given a persisted session log whose tail turn is
 * open and the tool journal, decide per interrupted call:
 * - `backfill`: the journal holds the result → write it as the `tool/result`.
 * - `rerun`: no result, but the tool is read-only or idempotent → run again.
 * - `unknown`: no result and the tool may have side effects (or the journal
 *   was written by another profile / tool schema) → tell the model the
 *   outcome is unknown, with the idempotency key it can use to check.
 * - `skip`: the call never reached a durable `tool/call`; DSH's own
 *   interrupted-turn closer reports it as not started.
 *
 * This runs before AgentLoop's `interruptedTurnClosers`, which then only closes
 * the step and turn (and any call this plan skipped).
 * @module @phone-dsh/dsh-tool-journal/reconcile
 */

import type { CallEntry, JournaledResult } from './journal.ts'
import type { ToolClass } from './classify.ts'

/** The subset of a persisted DSH session event this module reads and writes. */
export interface LogEvent {
  type: string
  seq: number
  time: number
  data?: unknown
  surfaceOp?: string
  sourceEventSeqs?: number[]
}

export interface InterruptedCall {
  callId: string
  turn: number
  step: number
  name: string
  /** Raw model arguments (JSON text). */
  arguments: string
  /** Seq of the durable `tool/call`; undefined when the call never started. */
  callSeq?: number
}

/** Calls of the open tail step that have no `tool/result`, in transcript order. */
export function interruptedCalls(events: readonly LogEvent[]): InterruptedCall[] {
  let openTurn: number | null = null
  let openStep: number | null = null
  let pending = new Map<string, InterruptedCall>()
  for (const event of events) {
    const data = (event.data ?? {}) as Record<string, unknown>
    switch (event.type) {
      case 'turn/start':
        openTurn = data.turn as number
        openStep = null
        pending = new Map()
        break
      case 'turn/end':
        openTurn = null
        openStep = null
        pending = new Map()
        break
      case 'step/start':
        openStep = data.step as number
        break
      case 'step/end':
        openStep = null
        pending = new Map()
        break
      case 'assistant/message': {
        const message = data.message as { content?: Array<Record<string, unknown>> } | undefined
        for (const block of message?.content ?? []) {
          if (block.type !== 'tool-call') continue
          pending.set(block.id as string, {
            callId: block.id as string,
            turn: (data.turn as number | undefined) ?? openTurn ?? 0,
            step: data.step as number,
            name: block.name as string,
            arguments: typeof block.arguments === 'string' ? block.arguments : JSON.stringify(block.arguments ?? {}),
          })
        }
        break
      }
      case 'tool/call': {
        const call = pending.get(data.callId as string)
        if (call !== undefined) {
          call.callSeq = event.seq
          if (typeof data.arguments === 'string') call.arguments = data.arguments
        }
        break
      }
      case 'tool/result': {
        const message = data.message as { source?: { callId?: string }; toolCallId?: string } | undefined
        const id = message?.source?.callId ?? message?.toolCallId
        if (id !== undefined) pending.delete(id)
        break
      }
      default:
        break
    }
  }
  if (openTurn === null || openStep === null) return []
  return [...pending.values()]
}

export type Decision =
  | { kind: 'skip'; call: InterruptedCall }
  | { kind: 'backfill'; call: InterruptedCall; result: JournaledResult; source: 'done' | 'executed' }
  | { kind: 'rerun'; call: InterruptedCall; toolClass: ToolClass }
  | { kind: 'unknown'; call: InterruptedCall; toolClass: ToolClass; reason: string }

export interface PlanInput {
  calls: readonly InterruptedCall[]
  journal: Map<string, CallEntry>
  /** Profile identity of the running harness. */
  profile: string
  classify(name: string): ToolClass
  /** Current schema hash of a tool, or undefined when it is not registered. */
  schemaHash(name: string): string | undefined
}

/** Decide what to do with each interrupted call. Pure; no I/O. */
export function plan(input: PlanInput): Decision[] {
  return input.calls.map((call): Decision => {
    if (call.callSeq === undefined) return { kind: 'skip', call }
    const toolClass = input.classify(call.name)
    const entry = input.journal.get(call.callId)
    const start = entry?.start
    const currentSchema = input.schemaHash(call.name)
    if (start !== undefined) {
      if (start.profile !== input.profile) {
        return { kind: 'unknown', call, toolClass, reason: `journal profile ${start.profile} differs from running profile ${input.profile}` }
      }
      if (start.schema_sha256 !== null && start.schema_sha256 !== currentSchema) {
        return { kind: 'unknown', call, toolClass, reason: `tool schema of ${call.name} changed since the call was journaled` }
      }
    }
    if (entry?.done !== undefined) return { kind: 'backfill', call, result: entry.done, source: 'done' }
    if (entry?.executed !== undefined) return { kind: 'backfill', call, result: entry.executed, source: 'executed' }
    if (currentSchema === undefined) {
      return { kind: 'unknown', call, toolClass, reason: `tool ${call.name} is not registered in the running profile` }
    }
    if (toolClass === 'read-only' || toolClass === 'idempotent') return { kind: 'rerun', call, toolClass }
    return { kind: 'unknown', call, toolClass, reason: 'non-idempotent' }
  })
}

/** Model-facing text for an interrupted call whose outcome is unknown. */
export function unknownOutcomeText(call: InterruptedCall, key: string, reason: string): string {
  const why = reason === 'non-idempotent'
    ? `The tool is classified as non-idempotent, so the harness did NOT run it again.`
    : `The harness did not reuse the journaled result: ${reason}.`
  return [
    `The harness stopped while this ${call.name} call was running. The tool journal recorded that the call started but holds no result. ${why}`,
    'Its outcome is UNKNOWN: it may have completed, partially completed, or not run at all.',
    `Idempotency key: ${key} (commands saw it as $XL_IDEMPOTENCY_KEY; HTTP requests as X-PDSH-Idempotency-Key).`,
    'Check the external state (for example search for this key) before deciding to retry; if you cannot verify it, ask the user.',
  ].join(' ')
}

/**
 * Calls whose persisted `tool/result` was written by {@link toolResultEvent}.
 *
 * A recovery write-open can append the `tool/result` and then be cancelled
 * before its `resolved` JOURNAL record receives a level-1 ack. The next open
 * sees no interrupted call (the log already holds the result), so only this
 * synthesized-event marker lets it retry the missing acknowledgement instead
 * of reporting success with the host still waiting for step evidence.
 */
export function reconciledCallIds(events: readonly LogEvent[]): Set<string> {
  const ids = new Set<string>()
  for (const event of events) {
    if (event.type !== 'tool/result') continue
    const message = (event.data as { message?: {
      id?: unknown
      source?: { callId?: unknown }
      toolCallId?: unknown
    } } | undefined)?.message
    if (typeof message?.id !== 'string' || !message.id.startsWith('pdsh-journal-tool-result-')) continue
    const callId = message.source?.callId ?? message.toolCallId
    if (typeof callId === 'string') ids.add(callId)
  }
  return ids
}

/**
 * Build the `tool/result` event for one decided call.
 * @param call - the interrupted call.
 * @param seq - the event's seq (continues the log).
 * @param time - the event time (the last durable event's time keeps the log monotonic).
 * @param result - content and error facts.
 * @returns a persisted-log `tool/result` event.
 */
export function toolResultEvent(call: InterruptedCall, seq: number, time: number, result: JournaledResult): LogEvent {
  return {
    type: 'tool/result',
    seq,
    time,
    data: {
      turn: call.turn,
      step: call.step,
      message: {
        id: `pdsh-journal-tool-result-${call.callId}-${seq}`,
        role: 'tool',
        toolCallId: call.callId,
        isError: result.isError,
        source: { kind: 'tool', callId: call.callId },
        content: result.content,
      },
      ...result.error === undefined ? {} : { error: result.error },
      ...result.meta === undefined ? {} : { meta: result.meta },
    },
    surfaceOp: 'append',
    ...call.callSeq === undefined ? {} : { sourceEventSeqs: [call.callSeq] },
  }
}

/** Parse model arguments the way the agent loop does: empty → {}, invalid JSON stays text. */
export function parseArguments(raw: string): unknown {
  try {
    return raw ? JSON.parse(raw) : {}
  } catch {
    return raw
  }
}
