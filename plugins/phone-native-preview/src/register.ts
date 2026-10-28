// SPDX-License-Identifier: MIT
// Registration half of the native Office preview. Kept free of React imports so
// tests can prove the no-bridge fallback and the exact renderer registration
// without a browser.

import type { Context } from '@deepseek-ai/cordis'
import { NATIVE_PREVIEW_EXTENSIONS, nativePreviewBridge } from './protocol.ts'
import type { NativePreviewScope } from './protocol.ts'
import { en, NS, zh } from './locales.ts'
import type { NativePreviewKey } from './locales.ts'

/** The document implementation id; unique and external to DSH's Office renderer. */
export const NATIVE_PREVIEW_RENDERER_ID = '@phone-dsh/dsh-phone-native-preview/office'

/** One slot body component; no React type is needed for registration. */
export type NativePreviewComponent = (props: never) => unknown

/** The DSH client services this registration uses. */
export interface NativePreviewServices {
  readonly locale: {
    register(namespace: string,
             dictionaries: Readonly<Record<string, Readonly<Record<string, string>>>>): () => void
    bind(namespace: string): (key: string) => string
  }
  readonly documentPreviews: {
    register(definition: NativePreviewDefinition): () => void
  }
  readonly slots: {
    inject(name: string, callback: () => () => void): () => void
    register(options: NativePreviewSlotOptions, body: NativePreviewComponent): () => void
  }
}

/** One document-preview definition as the DSH registry consumes it. */
export interface NativePreviewDefinition {
  readonly id: string
  readonly extensions: readonly string[]
  readonly binaryExtensions: readonly string[]
  readonly priority: 'extension'
  readonly title: () => string
  readonly loading: 'renderer'
  readonly wrap: false
}

/** The keyed document-slot registration options. */
export interface NativePreviewSlotOptions {
  readonly name: 'sidebar.right.tab.document'
  readonly key: string
  readonly locale: string
}

/**
 * Register the native Office preview only when the WKWebView bridge exists.
 *
 * Without the bridge nothing is registered: DSH's own Office renderer remains
 * selected and reports its real conversion/provider failure. No image, PDF,
 * spreadsheet, HTML or text renderer is touched.
 * @param ctx - DSH client context with locale, document previews and slots.
 * @param body - the keyed document body component.
 * @param scope - browser window, injectable in tests.
 * @returns true when registration happened.
 */
export function registerNativePreview(
  ctx: Context & NativePreviewServices,
  body: NativePreviewComponent,
  scope?: NativePreviewScope,
): boolean {
  if (nativePreviewBridge(scope) === undefined) return false
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'phone-native-preview: dictionaries')
  const t = ctx.locale.bind(NS) as (key: NativePreviewKey) => string
  ctx.effect(() => ctx.documentPreviews.register({
    id: NATIVE_PREVIEW_RENDERER_ID,
    extensions: [...NATIVE_PREVIEW_EXTENSIONS],
    binaryExtensions: [...NATIVE_PREVIEW_EXTENSIONS],
    priority: 'extension',
    title: () => t('title'),
    loading: 'renderer',
    wrap: false,
  }), 'phone-native-preview: document definition')
  ctx.effect(() => ctx.slots.inject(
    'sidebar.right.tab.document',
    () => ctx.slots.register({
      name: 'sidebar.right.tab.document',
      key: NATIVE_PREVIEW_RENDERER_ID,
      locale: NS,
    }, body),
  ), 'phone-native-preview: document body')
  return true
}
