// SPDX-License-Identifier: MIT
// Browser plugin entry: registers the native Office body only when the
// WKWebView `pdshNativePreview` handler is present. No second React, no DSH
// renderer fork, and no Office-to-PDF call.

import type { Context } from '@deepseek-ai/cordis'
import { NativePreviewBody } from './NativePreviewBody.ts'
import { registerNativePreview } from './register.ts'
import type { NativePreviewComponent, NativePreviewServices } from './register.ts'
import type { NativePreviewScope } from './protocol.ts'

export const inject = ['slots', 'locale', 'documentPreviews']

/**
 * Client plugin body. Without the native handler it registers nothing.
 * @param ctx - DSH client root context.
 */
export function apply(ctx: Context): void {
  registerNativePreview(
    ctx as Context & NativePreviewServices,
    NativePreviewBody as unknown as NativePreviewComponent,
  )
}

/**
 * Test seam for the same registration with an explicit browser window.
 * @param ctx - DSH client root context.
 * @param scope - injected bridge scope.
 * @returns true when the bridge existed and registration ran.
 */
export function applyWithScope(ctx: Context, scope: NativePreviewScope): boolean {
  return registerNativePreview(
    ctx as Context & NativePreviewServices,
    NativePreviewBody as unknown as NativePreviewComponent,
    scope,
  )
}
