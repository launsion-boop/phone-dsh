// SPDX-License-Identifier: MIT
/**
 * The single global fail-closed guard for host-minted restricted sessions.
 *
 * Both the read-only verifier (`pdsh-verifier`) and the background memory
 * maintainer (`phone-bot-maintainer`) are resolved by their immutable
 * creation header, with the reserved `gb-<kind>-` prefix as a fallback. The
 * guard rule itself comes from {@link ./restricted-session.ts}, so a missed or
 * later-changed preset scope still cannot widen either session, and the two
 * kinds cannot drift apart.
 */
import type { Context } from '@deepseek-ai/cordis'
import { applyRestrictedGuard } from './restricted-session.ts'

export const name = 'phone-restricted-session-guard'
export const inject = ['tools']

export function apply(ctx: Context): void {
  applyRestrictedGuard(ctx)
}
