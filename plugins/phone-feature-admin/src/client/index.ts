// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-feature-admin/client` — browser half.
 *
 * It registers one tab into the shipped Plugins settings section, using the
 * page's own React, locale, Connection and slot services. Calls go to the
 * existing `phone/featureAdmin` namespace; no second transport, session or
 * chat protocol exists here.
 * @module @phone-dsh/dsh-feature-admin/client
 */

import type { Context as ClientContext } from '@deepseek-ai/cordis'
import type { ConnectionHandle } from '@deepseek-ai/dsh-client-connection/client'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
import type {} from '@deepseek-ai/dsh-client-ui-slots'
import type { ISessions, SessionListState } from '@deepseek-ai/dsh-api-session-controller/client'
import type { FeatureAdminSessionView } from '../contracts.ts'
import { callFeatureAdmin, type FeatureAdminCarrier } from './api.ts'
import { FeatureAdminSettings } from './FeatureAdminSettings.ts'
import { en, zh, type FeatureAdminLocaleKey } from './locales.ts'
import { FEATURE_ADMIN_NS, registerFeatureAdminTab } from './register.ts'
import { sessionOptionsFromList } from './session-options.ts'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** Phone capability settings copy. */
    'settings.phoneFeatureAdmin': FeatureAdminLocaleKey
  }
}

/** Required browser services: the shipped shell, locale, transport and session list. */
export const inject = ['slots', 'locale', 'connection', 'sessions']

/** Mount the one Phone capabilities settings tab. */
export function apply(ctx: ClientContext): void {
  ctx.effect(
    () => ctx.locale.register(FEATURE_ADMIN_NS, { zh, en }),
    'phone-feature-admin: dictionaries',
  )
  const t = ctx.locale.bind(FEATURE_ADMIN_NS)
  // Read the live services through their typed handles. `ctx.connection` and
  // `ctx.sessions` are declared by different Host/Client augmentations; the
  // handle is the same service the shipped page uses and avoids picking the
  // wrong merged declaration.
  const connection = ctx.get('connection') as ConnectionHandle | undefined
  if (connection === undefined) {
    throw new Error('phone-feature-admin: the client Connection service is not mounted')
  }
  const sessions = ctx.get('sessions') as ISessions | undefined
  if (sessions === undefined) {
    throw new Error('phone-feature-admin: the client Session service is not mounted')
  }
  const carrier: FeatureAdminCarrier = connection.rpc
  registerFeatureAdminTab(ctx, {
    component: FeatureAdminSettings,
    label: () => t('tab'),
    injected: () => ({
      call: (method, args, signal) => callFeatureAdmin(carrier, method, args, signal),
      sessionOptions: (): readonly FeatureAdminSessionView[] =>
        sessionOptionsFromList(sessions.list.getSnapshot()),
      sessions: {
        getSnapshot: (): SessionListState => sessions.list.getSnapshot(),
        subscribe: (listener: () => void): (() => void) => sessions.list.subscribe(listener),
      },
    }),
  })
}
