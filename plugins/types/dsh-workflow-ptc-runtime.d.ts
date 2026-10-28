// SPDX-License-Identifier: MIT
// Type faces for the pinned workflow-ptc source modules the Worker workflow
// bridge bundles from the verified checkout. The published package excludes
// `src/`, so `scripts/pack-image.mjs` resolves these exact specifiers from the
// checkout; keep these declarations aligned with
// `packages/workflow/workflow-ptc/src/runtime.ts` and `.../src/meta.ts`.
declare module '@deepseek-ai/dsh-workflow-ptc/src/runtime.ts' {
  import type {
    WorkflowAgentEndInfo, WorkflowAgentInfo, WorkflowMeta, WorkflowResult,
  } from '@deepseek-ai/dsh-workflow'
  import type { ChildPort, WorkerLimits } from '@deepseek-ai/dsh-workflow-ptc'

  /** Progress observers the official execution reports through. */
  export interface ExecutionObserver {
    phase(title: string): void
    log(message: string): void
    agentStart(info: WorkflowAgentInfo): void
    agentEnd(info: WorkflowAgentEndInfo): void
  }

  /** Official workflow script execution backed by `node:vm`. */
  export class WorkflowExecution {
    constructor(
      meta: WorkflowMeta,
      body: string,
      args: unknown,
      limits: WorkerLimits,
      observer: ExecutionObserver,
      children: ChildPort,
    )
    /**
     * Run the script and materialize its JSON return value.
     * @returns a completed or error result; script failures never reject.
     */
    drive(): Promise<WorkflowResult>
  }
}

declare module '@deepseek-ai/dsh-workflow-ptc/src/meta.ts' {
  import type { WorkflowMeta } from '@deepseek-ai/dsh-workflow'

  /**
   * Validate caller-provided meta data against the workflow meta contract.
   * @param value - untrusted meta data.
   * @returns the validated, normalized meta block.
   */
  export function validateMeta(value: unknown): WorkflowMeta
}
