// SPDX-License-Identifier: MIT
/**
 * Browser half of `@phone-dsh/dsh-phone-model-config`.
 *
 * Registers one read-only tab in the existing DSH **Settings → Plugins**
 * section. It mounts the hand-written `phone/modelConfig` contribution into the
 * shared Client Remote service, reads the Host projection, and renders the real
 * selected provider. There is no save control: the native host owns editing and
 * keeps the API key in the device Keychain.
 *
 * All copy comes from this plugin's own locale namespace. The Host sends only
 * structured issue codes, so switching between zh and en never leaves English
 * diagnostics in a Chinese page (or Chinese diagnostics in an English one).
 *
 * React is resolved from the DSH module table (`dsh.client` requests it as an
 * external), so this bundle never ships a second React copy.
 * @module @phone-dsh/dsh-phone-model-config/client
 */
import { createElement, useEffect, useState, type CSSProperties, type ReactElement } from 'react'
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-api-gateway/client'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-settings/client'
import type { PropsLocale } from '@deepseek-ai/dsh-client-ui-slots'
import type { RemoteResult } from '@deepseek-ai/dsh-typert-protocol'
import type {
  ModelConfigIssue,
  ModelConfigIssueCode,
  ModelConfigSnapshot,
  ProviderPublicConfig,
} from '../model-config.ts'
import { MODEL_PROVIDER_ENV } from '../model-config.ts'
import { MODEL_CONFIG_CONTRIBUTION } from '../remote.ts'
import { en, zh, type PhoneModelConfigLocaleKey } from './locales.ts'

/** Dictionary namespace owned by this plugin. */
export const NS = 'settings.phoneModelConfig'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** Read-only host model service projection. */
    'settings.phoneModelConfig': PhoneModelConfigLocaleKey
  }
}

/** The Remote surface the contribution mounts. */
interface ModelConfigRemote {
  readonly phone: {
    modelConfig(): Promise<RemoteResult<ModelConfigSnapshot>>
  }
}

/** Props assembled by the Plugins settings tab slot. */
export interface ModelProviderSettingsTabInjected {
  /** Read the Host's current projection without writing anything. */
  readonly load: () => Promise<ModelConfigSnapshot>
}

type Translate = PropsLocale<typeof NS>['t']

type TabProps = PropsLocale<typeof NS> & {
  readonly load: () => Promise<ModelConfigSnapshot>
}

type ViewState =
  | { readonly status: 'loading' }
  | { readonly status: 'error'; readonly message: string }
  | { readonly status: 'ready'; readonly snapshot: ModelConfigSnapshot }

const CARD: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 10,
  padding: 14,
  border: '1px solid color-mix(in srgb, currentColor 18%, transparent)',
  borderRadius: 10,
}

const ROW: CSSProperties = {
  display: 'grid',
  gridTemplateColumns: '7.5rem minmax(0, 1fr)',
  gap: 10,
  alignItems: 'baseline',
}

const ACTION: CSSProperties = {
  alignSelf: 'flex-start',
  minHeight: 34,
  padding: '6px 12px',
  borderRadius: 9,
  border: '1px solid color-mix(in srgb, currentColor 22%, transparent)',
  background: 'transparent',
  color: 'inherit',
  font: 'inherit',
  fontSize: 14,
  cursor: 'pointer',
}

/** Handler the native host installs on the same WKWebView as this page. */
const NATIVE_SETTINGS_HANDLER = 'pdshOpenModelSettings'

interface NativeSettingsBridge {
  postMessage(message: unknown): unknown
}

function nativeSettingsBridge(): NativeSettingsBridge | undefined {
  const webkit = (window as unknown as {
    webkit?: { messageHandlers?: Record<string, NativeSettingsBridge | undefined> }
  }).webkit
  const handler = webkit?.messageHandlers?.[NATIVE_SETTINGS_HANDLER]
  return typeof handler?.postMessage === 'function' ? handler : undefined
}

function openNativeSettings(): void {
  nativeSettingsBridge()?.postMessage({ v: 1, action: 'open-model-settings' })
}

function nativeSettingsButton(t: Translate): ReactElement | null {
  if (nativeSettingsBridge() === undefined) return null
  return createElement('button', { type: 'button', style: ACTION, onClick: openNativeSettings },
    t('openNativeSettings'))
}

/** Map every Host issue code to the one dictionary key that explains it. */
const ISSUE_KEYS = {
  'env-missing': 'issue.envMissing',
  'json-invalid': 'issue.jsonInvalid',
  'document-not-object': 'issue.documentNotObject',
  'version-unsupported': 'issue.versionUnsupported',
  'providers-empty': 'issue.providersEmpty',
  'provider-invalid': 'issue.providerInvalid',
  'duplicate-provider-id': 'issue.duplicateProviderId',
  'selected-missing': 'issue.selectedMissing',
  'selected-unknown': 'issue.selectedUnknown',
} as const satisfies Record<ModelConfigIssueCode, PhoneModelConfigLocaleKey>

function issueText(issue: ModelConfigIssue, t: Translate): string {
  if (issue.code === 'provider-invalid' && (issue.providerId === undefined || issue.providerId === '')) {
    return t('issue.providerInvalidAnonymous')
  }
  return t(ISSUE_KEYS[issue.code], {
    env: MODEL_PROVIDER_ENV,
    providerId: issue.providerId ?? '',
  })
}

function detailRow(label: string, value: string): ReactElement {
  return createElement('div', { style: ROW, key: label },
    createElement('span', { style: { opacity: 0.65 } }, label),
    createElement('span', { style: { overflowWrap: 'anywhere', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' } }, value))
}

function providerRows(provider: ProviderPublicConfig, t: Translate): ReactElement[] {
  const rows = [
    detailRow(t('labels.service'), provider.displayName),
    detailRow(t('labels.id'), provider.id),
    detailRow(t('labels.baseURL'), provider.baseURL),
    detailRow(t('labels.model'), provider.model),
  ]
  if (provider.reasoningEffort !== undefined) rows.push(detailRow(t('labels.reasoningEffort'), provider.reasoningEffort))
  return rows
}

function credentialNote(t: Translate): ReactElement {
  return createElement('p', { style: { margin: 0, opacity: 0.7, lineHeight: 1.5 } }, t('credentialNote'))
}

function Unavailable({ snapshot, t }: { readonly snapshot: ModelConfigSnapshot; readonly t: Translate }): ReactElement {
  const detail = snapshot.configured ? undefined : issueText(snapshot.detail, t)
  return createElement('div', { style: CARD, 'data-model-config': 'unavailable' },
    createElement('strong', null, snapshot.configured ? '' : t(snapshot.reason === 'missing' ? 'unavailable.missing' : 'unavailable.invalid')),
    detail === undefined ? null : createElement('p', { style: { margin: 0, opacity: 0.75 } }, detail),
    nativeSettingsButton(t),
    createElement('p', { style: { margin: 0, opacity: 0.7, lineHeight: 1.5 } }, t('searchNote')),
    credentialNote(t))
}

function Snapshot({ snapshot, t }: { readonly snapshot: ModelConfigSnapshot; readonly t: Translate }): ReactElement {
  if (!snapshot.configured) return createElement(Unavailable, { snapshot, t })
  const others = snapshot.providers.filter(provider => provider.id !== snapshot.selectedId)
  return createElement('div', { style: { display: 'flex', flexDirection: 'column', gap: 14 }, 'data-model-config': 'ready' },
    createElement('div', { style: CARD },
      createElement('div', { style: { display: 'flex', alignItems: 'center', gap: 8 } },
        createElement('strong', null, t('title')),
        createElement('span', {
          style: { fontSize: 12, padding: '2px 7px', borderRadius: 999, border: '1px solid currentColor', opacity: 0.7 },
        }, t('injectedByHost'))),
      ...providerRows(snapshot.selected, t)),
    others.length === 0 ? null : createElement('div', { style: CARD },
      createElement('strong', null, t('otherProviders')),
      ...others.map(provider => createElement('div', { key: provider.id, style: { display: 'flex', gap: 8, flexWrap: 'wrap' } },
        createElement('span', null, provider.displayName),
        createElement('code', { style: { opacity: 0.7 } }, `${provider.id} · ${provider.model}`)))),
    nativeSettingsButton(t),
    createElement('p', { style: { margin: 0, opacity: 0.7, lineHeight: 1.5 } }, t('searchNote')),
    credentialNote(t))
}

/** Read-only tab body rendered by the shared Settings slot. */
export function ModelProviderSettingsTab({ load, t }: TabProps): ReactElement {
  const [state, setState] = useState<ViewState>({ status: 'loading' })
  useEffect(() => {
    let active = true
    setState({ status: 'loading' })
    void load().then((snapshot: ModelConfigSnapshot) => {
      if (active) setState({ status: 'ready', snapshot })
    }).catch((error: unknown) => {
      if (active) setState({ status: 'error', message: error instanceof Error ? error.message : String(error) })
    })
    return () => { active = false }
  }, [load])
  if (state.status === 'loading') {
    return createElement('p', { style: { opacity: 0.7 }, role: 'status' }, t('loading'))
  }
  if (state.status === 'error') {
    return createElement('div', { style: CARD, role: 'alert', 'data-model-config': 'error' },
      createElement('strong', null, t('errorTitle')),
      createElement('p', { style: { margin: 0, opacity: 0.75 } }, t('loadFailed', { message: state.message })),
      credentialNote(t))
  }
  return createElement(Snapshot, { snapshot: state.snapshot, t })
}

/** Client services needed before mounting and registering the tab. */
export const inject = ['slots', 'locale', 'remote']

/**
 * Mount the contribution once, then register the read-only tab in the existing
 * Plugins settings section. Both operations live in the caller's fiber, so the
 * tab and namespace are torn down together with this plugin.
 * @param ctx - shared Client context.
 */
export function apply(ctx: Context): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'phone-model-config: dictionaries')

  ctx.effect(() => {
    let dispose: (() => Promise<void>) | undefined
    let active = true
    void ctx.remote.$mount(MODEL_CONFIG_CONTRIBUTION).then(candidate => {
      if (!active) { void candidate(); return }
      dispose = candidate
    }).catch((error: unknown) => {
      ctx.logger.error('phone-model-config: failed to mount phone/modelConfig', error)
    })
    return async () => {
      active = false
      if (dispose !== undefined) await dispose()
    }
  }, 'phone-model-config: remote contribution')

  const t = ctx.locale.bind(NS)
  ctx.inject(['remote.phone'], (phoneCtx: Context) => {
    const remote = phoneCtx.remote as unknown as ModelConfigRemote
    const load = async (): Promise<ModelConfigSnapshot> => {
      const result = await remote.phone.modelConfig()
      if (!result.ok) throw new Error(`${result.error.code}: ${result.error.message}`)
      return result.value
    }
    phoneCtx.slots.inject('settings.plugins.tab', () => phoneCtx.slots.register({
      name: 'settings.plugins.tab',
      id: 'model',
      order: 20,
      label: () => t('tab'),
      locale: NS,
      inject: (): ModelProviderSettingsTabInjected => ({ load }),
    }, ModelProviderSettingsTab as never))
  })
}
