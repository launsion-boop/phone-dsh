// SPDX-License-Identifier: MIT
/**
 * Locale-owned text for one installed-plugin row.
 *
 * The Host's `readOnlyReason`/`management.reason` strings are technical
 * diagnostics, not zh-CN body copy. This module turns the row state and fiber
 * phase into dictionary labels and keeps the English reason available only as
 * a hover `title`. It has no React import so the mapping is testable without a
 * browser renderer; the component still consumes this exact function.
 * @module @phone-dsh/dsh-feature-admin/client/presentation
 */

import type { PluginListEntry, PluginListView } from '../contracts.ts'
import { pluginToggleAvailability } from '../protection.ts'
import type { FeatureAdminLocaleKey } from './locales.ts'

/** Translate one dictionary key in the active page locale. */
export type Translate = (
  key: FeatureAdminLocaleKey,
  params?: Readonly<Record<string, string | number>>,
) => string

type FiberPhase = PluginListEntry['fiberPhase']

const PHASE_KEYS: Record<Exclude<FiberPhase, null>, FeatureAdminLocaleKey> = {
  pending: 'pluginPhasePending',
  loading: 'pluginPhaseLoading',
  active: 'pluginPhaseActive',
  failed: 'pluginPhaseFailed',
  unloading: 'pluginPhaseUnloading',
}

/**
 * Localize one inventory fiber phase. Unknown future phases fall back to a
 * translated label instead of leaking the raw Host token into the body.
 * @param t - bound dictionary translator.
 * @param phase - official inventory phase, or null when no root Fiber lives.
 * @returns localized phase text.
 */
export function pluginPhaseLabel(t: Translate, phase: FiberPhase | undefined): string {
  if (phase === undefined || phase === null) return t('pluginPhaseUnobserved')
  const key = (PHASE_KEYS as Readonly<Record<string, FeatureAdminLocaleKey | undefined>>)[phase]
  return key === undefined ? t('pluginPhaseUnknown') : t(key)
}

/** Locale-owned body text and the technical reason reserved for the title attribute. */
export interface PluginRowCopy {
  /** Module specifier plus the localized runtime phase. */
  readonly phaseText: string
  /** Localized availability/protection pill. */
  readonly stateText: string
  /** Host diagnostic rendered only as a `title`, never as visible body copy. */
  readonly reasonTitle?: string
  /** Whether the row may render a real switch through the profile writer. */
  readonly switchable: boolean
}

/**
 * Build one row's localized copy from the same Host projection the page shows.
 * @param t - bound dictionary translator.
 * @param row - official inventory row, including the Host read-only reason.
 * @param management - Host profile-patch availability.
 * @returns body labels, title-only reason and the switch decision.
 */
export function pluginRowCopy(
  t: Translate,
  row: PluginListEntry,
  management: PluginListView['management'],
): PluginRowCopy {
  const availability = pluginToggleAvailability(row.moduleName, row.readOnlyReason)
  const reason = availability.available ? management.reason : availability.reason
  return {
    phaseText: `${row.moduleName} · ${t('pluginPhase')}: ${pluginPhaseLabel(t, row.fiberPhase)}`,
    stateText: availability.available ? t('pluginReadOnly') : t('pluginProtected'),
    ...reason === undefined ? {} : { reasonTitle: reason },
    switchable: availability.available && management.available,
  }
}
