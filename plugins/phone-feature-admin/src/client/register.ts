// SPDX-License-Identifier: MIT
/** Exact `settings.plugins.tab` registration contract; React stays in the component module. */

import type { Context as ClientContext } from '@deepseek-ai/cordis'
import type { ReactNode } from 'react'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
import type {
  InjectFace,
  PropsLocale,
  PropsRuntime,
} from '@deepseek-ai/dsh-client-ui-slots'
import type { SessionListState } from '@deepseek-ai/dsh-api-session-controller/client'
import type {
  FeatureAdminResult,
  FeatureAdminSessionView,
} from '../contracts.ts'
import type { FeatureAdminMethod } from './api.ts'

/** Locale namespace owned by this tab. */
export const FEATURE_ADMIN_NS = 'settings.phoneFeatureAdmin'

/** Tab key inside the shipped Plugins settings section. */
export const FEATURE_ADMIN_TAB_ID = 'phone-capabilities'

/** Carrier + session projection the tab renders. */
export interface FeatureAdminTabInjected {
  /** Invoke one Host method and return its structured result. */
  call: <Value>(
    method: FeatureAdminMethod,
    args?: Readonly<Record<string, unknown>>,
    signal?: AbortSignal,
  ) => Promise<FeatureAdminResult<Value>>
  /** Current Host-list projection; the component subscribes to this source. */
  sessions: {
    getSnapshot: () => SessionListState
    subscribe: (listener: () => void) => () => void
  }
  /** One snapshot of the same projection, retained for non-React callers. */
  sessionOptions: () => readonly FeatureAdminSessionView[]
}

/** Props the shipped Settings renderer composes for this tab. */
export type FeatureAdminTabProps =
  PropsRuntime<'settings.plugins.tab'>
  & PropsLocale<typeof FEATURE_ADMIN_NS>
  & InjectFace<FeatureAdminTabInjected>

/** One registration input. */
export interface FeatureAdminTabRegistration {
  readonly component: (props: FeatureAdminTabProps) => ReactNode
  readonly injected: () => FeatureAdminTabInjected
  readonly label: () => string
}

/**
 * Register the tab through the same slot instance the shipped Plugins section
 * owns. The tab is a sibling of the official read-only inventory tab, not a
 * replacement settings shell.
 */
export function registerFeatureAdminTab(
  ctx: ClientContext,
  registration: FeatureAdminTabRegistration,
): () => void {
  return ctx.slots.inject('settings.plugins.tab', () => ctx.slots.register({
    name: 'settings.plugins.tab',
    id: FEATURE_ADMIN_TAB_ID,
    order: 20,
    label: registration.label,
    locale: FEATURE_ADMIN_NS,
    inject: registration.injected,
  }, registration.component))
}
