// SPDX-License-Identifier: MIT
/** Browser entry: register one MCP tab in Settings → Plugins. */

import type { ConnectionHandle } from '@deepseek-ai/dsh-client-connection/client'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-modules/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
import type {} from '@deepseek-ai/dsh-client-ui-slots'
import type { Context as ClientContext } from '@deepseek-ai/cordis'
import { McpSettingsTab } from './McpSettingsTab.tsx'
import type { McpSettingsTabInjected } from './McpSettingsTab.tsx'
import { createPhoneMcpClient } from './remote.ts'
import { en, zh, type PhoneMcpLocaleKey } from './locales.ts'

export type { McpSettingsTabInjected, McpSettingsTabProps } from './McpSettingsTab.tsx'
export type { PhoneMcpLocaleKey } from './locales.ts'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** HTTP MCP management copy. */
    'settings.phoneMcp': PhoneMcpLocaleKey
  }
}

/** Dictionary namespace owned by this plugin. */
export const NS = 'settings.phoneMcp'

/** Services required by the Settings registration and the shared Connection. */
export const inject = ['slots', 'locale', 'connection']

/**
 * Contribute the MCP tab. The client object is built once over the active
 * `ctx.connection`, so every call uses the same DSH RPC carrier and modules.
 * @param ctx - browser plugin context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'phone-mcp: dictionaries')
  const t = ctx.locale.bind(NS)
  // The typed service handle is the same Connection the shipped page owns;
  // do not guess a Context augmentation from another Host module.
  const connection = ctx.get('connection') as ConnectionHandle | undefined
  if (connection === undefined) {
    throw new Error('phone-mcp: the client Connection service is not mounted')
  }
  const client = createPhoneMcpClient(connection)
  const injected = (): McpSettingsTabInjected => ({ client })

  ctx.slots.inject('settings.plugins.tab', () => ctx.slots.register({
    name: 'settings.plugins.tab',
    id: 'phone-mcp',
    order: 20,
    label: () => t('tab'),
    locale: NS,
    inject: injected,
  }, McpSettingsTab))
}
