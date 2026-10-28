// SPDX-License-Identifier: MIT
// Copy for the native Quick Look Office surface. The system preview itself is
// the document UI; this dictionary only labels the handoff and its real error.

/** DSH locale namespace used by the native preview body. */
export const NS = 'sidebarNativePreview'

/** English labels. */
export const en = {
  title: 'System Quick Look',
  opening: 'Opening in Quick Look…',
  opened: 'Opened in Quick Look',
  openedHint: 'The document is shown by the system preview. Nothing was converted or copied.',
  failed: 'Quick Look could not open this document',
  reopen: 'Open again',
  retry: 'Try again',
  unsupported: 'Only Word and PowerPoint documents use the native preview.',
} as const

/** One label key. */
export type NativePreviewKey = keyof typeof en

/** Chinese labels, matching every English key. */
export const zh = {
  title: '系统快速查看',
  opening: '正在快速查看中打开…',
  opened: '已在快速查看中打开',
  openedHint: '文档由系统预览显示，未转换或复制任何文件。',
  failed: '快速查看无法打开此文档',
  reopen: '再次打开',
  retry: '重试',
  unsupported: '只有 Word 和 PowerPoint 文档使用原生预览。',
} satisfies Record<NativePreviewKey, string>
