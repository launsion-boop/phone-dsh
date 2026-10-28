// SPDX-License-Identifier: MIT
/**
 * The JSONL session backend with one change: a session opened for writing is
 * reconciled against the tool journal before the handle is returned. AgentLoop
 * opens the stored session for writing, reads it, and only then computes its
 * synthetic `interruptedTurnClosers`; reconciling inside `open` is therefore
 * the last point where journaled results can still replace "outcome unknown".
 *
 * Mount it in place of `@deepseek-ai/dsh-session-persistence-jsonl` (same
 * config). Without a `toolJournal` service it behaves exactly like the base.
 * @module @phone-dsh/dsh-tool-journal/persistence
 */

import JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type { SessionAccess, SessionHandle, SessionPersistenceOpenOptions } from '@deepseek-ai/dsh-session-persistence'
import type {} from './index.ts'

export class JournaledJsonlSessionPersistence extends JsonlSessionPersistence {
  override async open(id: SessionId, access: SessionAccess, options?: SessionPersistenceOpenOptions): Promise<SessionHandle> {
    const handle = await super.open(id, access, options)
    if (access !== 'write') return handle
    const journal = this.ctx.get('toolJournal')
    if (journal === undefined) return handle
    try {
      await journal.reconcile(String(id), handle, options?.signal)
    } catch (error) {
      await handle.close().catch(() => {})
      throw error
    }
    return handle
  }
}

export default JournaledJsonlSessionPersistence
