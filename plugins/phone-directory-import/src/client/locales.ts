// SPDX-License-Identifier: MIT
/**
 * `phoneDirectoryImport` dictionaries for the Files-panel action.
 *
 * The file tree action is intentionally terse: one compact button, a live
 * progress line while the native importer works, and a real success path or
 * failure message afterwards.
 */

import type {} from '@deepseek-ai/dsh-client-ui-slots'

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** Directory import action, progress and result copy. */
    phoneDirectoryImport: DirectoryImportKey
  }
}

/** Dictionary namespace owned by this plugin. */
export const NS = 'phoneDirectoryImport'

/** Simplified Chinese dictionary and key-set source of truth. */
export const zh = {
  'import.button': '导入文件夹',
  'import.buttonTitle': '从 iPhone 文件选择一个文件夹，导入当前会话工作区',
  'import.busy': '导入中…',
  'import.cancel': '取消导入',
  'import.cancelling': '正在取消…',
  'import.success': '已导入 {count} 个文件（{bytes}）到 {path}',
  'import.failure': '导入失败：{message}',
  'import.unavailable': '当前 App 未提供文件夹导入',
  'phase.scanning': '正在扫描…',
  'phase.staging': '正在暂存…',
  'phase.uploading': '正在写入工作区…',
  'phase.committing': '正在提交…',
} satisfies Record<string, string>

/** English dictionary, checked against the Chinese key set. */
export const en = {
  'import.button': 'Import folder',
  'import.buttonTitle': 'Choose a folder in iPhone Files and import it into this session workspace',
  'import.busy': 'Importing…',
  'import.cancel': 'Cancel import',
  'import.cancelling': 'Cancelling…',
  'import.success': 'Imported {count} files ({bytes}) to {path}',
  'import.failure': 'Import failed: {message}',
  'import.unavailable': 'This app does not provide folder import',
  'phase.scanning': 'Scanning…',
  'phase.staging': 'Staging…',
  'phase.uploading': 'Writing to workspace…',
  'phase.committing': 'Committing…',
} satisfies Record<DirectoryImportKey, string>

/** Key domain of the `phoneDirectoryImport` namespace. */
export type DirectoryImportKey = keyof typeof zh
