// SPDX-License-Identifier: MIT
/**
 * Project the shipped Session list into preset targets.
 *
 * `SessionListState.ids` is the Host-list membership; `byId` also carries
 * retained subagent fallbacks that are not selectable preset targets. The
 * projection therefore walks `ids`, drops dangling rows, and excludes
 * subagent-origin Sessions even when the Host list names them.
 * @module @phone-dsh/dsh-feature-admin/client/session-options
 */

import type { SessionListState } from '@deepseek-ai/dsh-api-session-controller/client'
import type { FeatureAdminSessionView } from '../contracts.ts'

/**
 * Build the one live target list the preset control renders.
 * @param snapshot - current Client Session list.
 * @returns Host-listed, non-subagent Sessions ordered by display title.
 */
export function sessionOptionsFromList(
  snapshot: SessionListState | undefined,
): readonly FeatureAdminSessionView[] {
  if (snapshot === undefined) return []
  const options: FeatureAdminSessionView[] = []
  for (const id of snapshot.ids) {
    const session = snapshot.byId[id]
    if (session === undefined || session.origin === 'subagent') continue
    options.push({
      id: String(session.id),
      title: session.displayTitle,
      blank: session.blank,
      ...typeof session.projectionValues?.agentPreset === 'string'
        ? { agentPreset: session.projectionValues.agentPreset }
        : {},
    })
  }
  return options.sort((left, right) => left.title.localeCompare(right.title))
}
