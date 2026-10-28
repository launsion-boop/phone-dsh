// SPDX-License-Identifier: MIT
/**
 * Wire protocol between the parent Worker workflow engine and its dedicated
 * workflow isolate.
 *
 * Every message is structured-clone data. The isolate never receives a
 * function, module loader, VFS handle, token, environment or Agent object; the
 * only capabilities are JSON child requests answered by the parent's real
 * `ctx.subagents`, plus progress observations.
 * @module @phone-dsh/dsh-workflow-worker/protocol
 */
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import type { ObjectJsonSchema } from '@deepseek-ai/dsh-tools'
import type {
  WorkflowAgentEndInfo, WorkflowAgentInfo, WorkflowMeta, WorkflowResult,
} from '@deepseek-ai/dsh-workflow'
import type { ChildStartRequest, WorkerLimits } from '@deepseek-ai/dsh-workflow-ptc'

/** Initialization data sent once, before the isolate compiles the script. */
export interface IsolateRun {
  readonly type: 'run'
  readonly meta: WorkflowMeta
  readonly body: string
  readonly args: unknown
  readonly limits: WorkerLimits
}

/** One child request the isolate asks the parent to start through `ctx.subagents`. */
export interface IsolateChildStart {
  readonly type: 'child-start'
  /** Isolate-local correlation id. */
  readonly callId: number
  readonly request: ChildStartRequest
}

/** The parent accepted a child and published it. */
export interface ParentChildStarted {
  readonly type: 'child-started'
  readonly callId: number
  readonly childId: string
}

/** The parent refused to start a child. */
export interface ParentChildStartFailed {
  readonly type: 'child-start-failed'
  readonly callId: number
  readonly error: string
}

/** The isolate asks for one child's terminal result. */
export interface IsolateChildResult {
  readonly type: 'child-result'
  readonly callId: number
}

/** One child's result as the official runtime's ChildResult shape. */
export interface ParentChildResult {
  readonly type: 'child-result-ok'
  readonly callId: number
  readonly result: {
    readonly output: ContentBlock[]
    readonly stopReason: string
    readonly structured?: unknown
  }
}

/** One child result could not be read (infrastructure fault). */
export interface ParentChildResultFailed {
  readonly type: 'child-result-failed'
  readonly callId: number
  readonly error: string
}

/** The isolate asks the parent to dispose one child and await cleanup. */
export interface IsolateChildDispose {
  readonly type: 'child-dispose'
  readonly callId: number
}

/** The parent finished disposing one child. */
export interface ParentChildDisposed {
  readonly type: 'child-disposed'
  readonly callId: number
}

/** Progress observation from the official `ExecutionObserver`. */
export type IsolateProgress =
  | { readonly type: 'phase'; readonly title: string }
  | { readonly type: 'log'; readonly message: string }
  | { readonly type: 'agent-start'; readonly info: WorkflowAgentInfo }
  | { readonly type: 'agent-end'; readonly info: WorkflowAgentEndInfo }

/** The isolate loaded its realm and is ready for the run's first slice. */
export interface IsolateReady {
  readonly type: 'ready'
}

/** The initial synchronous slice returned control (or threw and was handled). */
export interface IsolateSyncYield {
  readonly type: 'sync-yield'
}

/** The official execution settled. */
export interface IsolateDone {
  readonly type: 'done'
  readonly result: WorkflowResult
}

/** The isolate could not construct or drive the official execution. */
export interface IsolateFatal {
  readonly type: 'fatal'
  readonly error: string
}

/** Messages the parent sends into the isolate. */
export type ParentToIsolate =
  | IsolateRun
  | ParentChildStarted
  | ParentChildStartFailed
  | ParentChildResult
  | ParentChildResultFailed
  | ParentChildDisposed

/** Messages the isolate sends to the parent. */
export type IsolateToParent =
  | IsolateReady
  | IsolateProgress
  | IsolateSyncYield
  | IsolateChildStart
  | IsolateChildResult
  | IsolateChildDispose
  | IsolateDone
  | IsolateFatal

/**
 * Narrow a structured-clone message to an object with a string tag.
 * @param value - unvalidated message.
 * @returns the record when it is an object with a `type` string.
 */
export function isTagged(value: unknown): value is { readonly type: string; readonly [key: string]: unknown } {
  return typeof value === 'object' && value !== null && typeof (value as { type?: unknown }).type === 'string'
}

/**
 * Render an unknown thrown value without trusting it.
 * @param error - thrown value.
 * @returns a display string.
 */
export function renderError(error: unknown): string {
  try {
    if (error instanceof Error) return error.stack ?? error.message
    return String(error)
  } catch {
    return '[unrenderable thrown value]'
  }
}

/** Compile-time check that the request schema is object-rooted, matching the seam. */
export type WorkflowRequestSchema = ObjectJsonSchema
