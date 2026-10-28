// SPDX-License-Identifier: MIT
// The legacy `@phone-dsh/dsh-tool-journal/persistence` face is no longer
// mounted on the phone path (see profile/phone.worker.cordis.patch.yml), but
// tsc still type-checks its source. 0.2.1's session-persistence-jsonl dropped
// the default-exported class that face extends; declare the 0.1.7 shape so the
// dead face keeps compiling until its source is rewritten outside this task.
declare module '@deepseek-ai/dsh-session-persistence-jsonl' {
  import type { Context } from '@deepseek-ai/cordis'
  import type { SessionHandle } from '@deepseek-ai/dsh-session-persistence'
  export default class JsonlSessionPersistence {
    protected readonly ctx: Context
    constructor(ctx: Context, config: Record<string, unknown>, ...rest: unknown[])
    open(...args: unknown[]): Promise<SessionHandle>
  }
}
