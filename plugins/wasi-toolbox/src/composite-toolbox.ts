// SPDX-License-Identifier: MIT
/**
 * Route one shell command table across more than one WASI toolbox.
 *
 * Each `WasiToolbox` owns a dedicated tool worker and its own module cache.
 * The Worker publishes exactly one toolbox global, so an image that carries
 * both the Python runtime and the jq engine needs one routing object: programs
 * are dispatched to the toolbox that registered them, while `list()`/`has()`
 * and the teardown/cancellation hooks stay the single surface the shell and
 * `subprocess-xl` already use.
 * @module @phone-dsh/dsh-wasi-toolbox/composite-toolbox
 */
import type { ToolboxCommandSummary, WorkerToolbox } from './toolbox.ts'
import type { GuestPreopen, ToolboxResult, ToolboxRunRequest } from './types.ts'

/** One toolbox that knows whether it serves a program. */
type Member = WorkerToolbox & { readonly dispose?: () => Promise<void> }

/** A deterministic router over a fixed toolbox list. */
export class CompositeWorkerToolbox implements WorkerToolbox {
  readonly preopenTable: readonly GuestPreopen[] | undefined
  private readonly members: readonly Member[]

  constructor(members: readonly Member[]) {
    if (members.length === 0) throw new Error('composite toolbox: at least one member is required')
    this.members = members
    this.preopenTable = members.find(member => member.preopenTable !== undefined)?.preopenTable
  }

  list(): readonly ToolboxCommandSummary[] {
    return this.members.flatMap(member => member.list())
  }

  has(program: string): boolean {
    return this.members.some(member => member.has(program))
  }

  async run(request: ToolboxRunRequest): Promise<ToolboxResult> {
    const member = this.members.find(candidate => candidate.has(request.program))
    if (member === undefined) {
      throw new Error(`composite toolbox: no member serves ${request.program}`)
    }
    return member.run(request)
  }

  /** Hard-stop every member; the member tool workers are independent. */
  terminate(cause?: Parameters<NonNullable<WorkerToolbox['terminate']>>[0]): number {
    return this.members.reduce((total, member) => total + (member.terminate?.(cause) ?? 0), 0)
  }

  /** Await every member's partial-write markers. */
  async partialWritesSettled(): Promise<void> {
    await Promise.all(this.members.map(member => member.partialWritesSettled?.()))
  }

  /** Dispose every warm tool worker. */
  async dispose(): Promise<void> {
    await Promise.all(this.members.map(member => member.dispose?.()))
  }
}

/**
 * Combine zero, one or many toolboxes without changing the single-toolbox
 * shape the rest of the Worker already consumes.
 * @param members - toolboxes that may be present for this boot.
 * @returns the one published toolbox, or undefined when none is present.
 */
export function combineWorkerToolboxes(
  members: readonly (Member | undefined)[],
): WorkerToolbox | undefined {
  const present = members.filter((member): member is Member => member !== undefined)
  if (present.length === 0) return undefined
  if (present.length === 1) return present[0]
  return new CompositeWorkerToolbox(present)
}
