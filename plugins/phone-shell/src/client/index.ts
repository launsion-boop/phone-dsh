// SPDX-License-Identifier: MIT
/**
 * Browser half of the phone command console.
 *
 * It registers one right-Sidebar page type, `phone-shell`, plus the keyed body
 * and chip seats the Sidebar already declares. The type also contributes a
 * guide entry, which is the ordinary path a user opens a page type from. The
 * body talks to the Host over the page's existing Connection RPC; it does not
 * create a second React root, a second slot registry, or a terminal emulator.
 * @module @phone-dsh/dsh-phone-shell/client
 */

import type { Context as ClientContext } from '@deepseek-ai/cordis'
import type { ConnectionHandle } from '@deepseek-ai/dsh-client-connection/client'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-sidebar-right/client'
import type {} from '@deepseek-ai/dsh-client-ui-slots'
import {
  PHONE_SHELL_LOCALE_NS,
  PHONE_SHELL_TAB_ID,
  PHONE_SHELL_TAB_KIND,
} from '../contract.ts'
import { PhoneShellConsole, PhoneShellTitle } from './console.ts'
import { en, zh, type PhoneShellLocaleKey } from './locales.ts'
import { createPhoneShellClient } from './remote.ts'

export { PhoneShellConsole, PhoneShellTitle } from './console.ts'
export type * from './console.ts'
export { en, zh } from './locales.ts'
export type * from './locales.ts'
export { PhoneShellRemoteError, createPhoneShellClient } from './remote.ts'
export type * from './remote.ts'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** Command-console body and tab-chip copy. */
    'phone-shell': PhoneShellLocaleKey
  }
}

/** Required browser services: the shared slot registry, copy, and the existing Connection. */
export const inject = ['slots', 'locale', 'connection', 'sidebarRightTabs']

/**
 * Register the console tab type, its two keyed seats, and its guide entry.
 * @param ctx - browser root context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(PHONE_SHELL_LOCALE_NS, { zh, en }), 'phone-shell: dictionaries')
  const t = ctx.locale.bind(PHONE_SHELL_LOCALE_NS)
  const connection = ctx.get('connection') as ConnectionHandle | undefined
  if (connection === undefined) throw new Error('phone-shell: the client Connection service is not mounted')
  const phoneShell = createPhoneShellClient(connection.rpc)

  ctx.effect(() => ctx.sidebarRightTabs.register({
    id: PHONE_SHELL_TAB_ID,
    kind: PHONE_SHELL_TAB_KIND,
    priority: 'builtin',
    title: () => t('tab.title'),
    guide: [{
      id: 'console',
      order: 10,
      title: () => t('tab.title'),
      description: () => t('guide.description'),
    }],
  }), 'phone-shell: sidebar type')

  ctx.slots.inject('sidebar.right.pane.tab', () => ctx.slots.register({
    name: 'sidebar.right.pane.tab',
    key: PHONE_SHELL_TAB_ID,
    locale: PHONE_SHELL_LOCALE_NS,
    inject: () => ({ phoneShell }),
  }, PhoneShellConsole))

  ctx.slots.inject('sidebar.right.pane.tab.title', () => ctx.slots.register({
    name: 'sidebar.right.pane.tab.title',
    key: PHONE_SHELL_TAB_ID,
    locale: PHONE_SHELL_LOCALE_NS,
  }, PhoneShellTitle))
}
