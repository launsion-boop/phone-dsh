// SPDX-License-Identifier: MIT
/**
 * Browser half: one compact action in the existing Files-panel header.
 *
 * The page never calls a Remote for this feature. It posts a `pick` message to
 * the host's `pdshDirectoryImport` script-message handler and renders the
 * native progress/result events dispatched on `window`. When the host did not
 * install that bridge the action renders nothing rather than pretending to be
 * available.
 *
 * @module @phone-dsh/dsh-phone-directory-import/client
 */

import type { Context as ClientContext } from '@deepseek-ai/cordis'
import type { CSSProperties } from 'react'
import { createElement, useEffect, useRef, useState } from 'react'
import type {} from '@deepseek-ai/dsh-client-locale/client'
import type {} from '@deepseek-ai/dsh-client-ui-renderer/client'
import type {} from '@deepseek-ai/dsh-client-ui-session/client'
import type {} from '@deepseek-ai/dsh-client-ui-sidebar-files/client'
import type { PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
import { en, NS, zh, type DirectoryImportKey } from './locales.ts'

/** Required browser services: the slot registry and copy. */
export const inject = ['slots', 'locale']

/** Native -> page event name; mirrors `WebEngineDirectoryImport.eventName`. */
const EVENT_NAME = 'pdsh-directory-import'
/** Page -> native handler name; mirrors `WebEngineDirectoryImport.messageHandlerName`. */
const HANDLER_NAME = 'pdshDirectoryImport'

type Phase = 'scanning' | 'staging' | 'uploading' | 'committing'

type DirectoryImportEvent =
  | {
    readonly v: 1
    readonly id: string
    readonly type: 'progress'
    readonly phase: Phase
    readonly filesDone: number
    readonly filesTotal: number
    readonly bytesDone: number
    readonly bytesTotal: number
    readonly currentPath: string
  }
  | {
    readonly v: 1
    readonly id: string
    readonly type: 'result'
    readonly ok: true
    readonly workspacePath: string
    readonly absolutePath: string
    readonly fileCount: number
    readonly totalBytes: number
  }
  | {
    readonly v: 1
    readonly id: string
    readonly type: 'result'
    readonly ok: false
    readonly code: string
    readonly message: string
  }

type ViewState =
  | { readonly kind: 'idle' }
  | {
    readonly kind: 'running'
    readonly id: string
    readonly phase: Phase
    readonly filesDone: number
    readonly filesTotal: number
    readonly bytesDone: number
    readonly bytesTotal: number
  }
  | {
    readonly kind: 'success'
    readonly id: string
    readonly workspacePath: string
    readonly fileCount: number
    readonly totalBytes: number
  }
  | { readonly kind: 'failure'; readonly id: string; readonly code: string; readonly message: string }

interface DirectoryImportBridge {
  postMessage(message: unknown): Promise<unknown> | unknown
}

/** The injected host bridge, only when WKWebView actually installed it. */
function directoryImportBridge(): DirectoryImportBridge | undefined {
  const webkit = (window as unknown as {
    webkit?: { messageHandlers?: Record<string, DirectoryImportBridge | undefined> }
  }).webkit
  const handler = webkit?.messageHandlers?.[HANDLER_NAME]
  return typeof handler?.postMessage === 'function' ? handler : undefined
}

function failureMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

const buttonStyle: CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 4,
  minHeight: 28,
  padding: '3px 8px',
  border: '1px solid transparent',
  borderRadius: 7,
  background: 'transparent',
  color: 'inherit',
  font: 'inherit',
  fontSize: 12,
  lineHeight: '18px',
  cursor: 'pointer',
}

const statusStyle: CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 6,
  maxWidth: 280,
  minWidth: 0,
  fontSize: 11,
  lineHeight: '18px',
  opacity: 0.72,
}

const statusTextStyle: CSSProperties = {
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
}

type DirectoryImportActionProps =
  PropsRuntime<'sidebar.right.tab.files.actions'>
  & PropsLocale<typeof NS>

/** Compact Files-header action with native progress, cancel and real results. */
function DirectoryImportAction(props: DirectoryImportActionProps): ReturnType<typeof createElement> | null {
  const bridge = directoryImportBridge()
  const [state, setState] = useState<ViewState>({ kind: 'idle' })
  const [cancelRequested, setCancelRequested] = useState(false)
  const activeId = useRef<string | undefined>(undefined)
  const { t } = props

  useEffect(() => {
    const listener = (event: Event): void => {
      const detail = (event as CustomEvent<DirectoryImportEvent>).detail
      if (typeof detail !== 'object' || detail === null || detail.v !== 1 || detail.id !== activeId.current) return
      if (detail.type === 'progress') {
        setState(previous => previous.kind === 'running' && previous.id === detail.id
          ? {
            ...previous,
            phase: detail.phase,
            filesDone: detail.filesDone,
            filesTotal: detail.filesTotal,
            bytesDone: detail.bytesDone,
            bytesTotal: detail.bytesTotal,
          }
          : previous)
        return
      }
      activeId.current = undefined
      setCancelRequested(false)
      if (detail.ok) {
        setState({
          kind: 'success',
          id: detail.id,
          workspacePath: detail.workspacePath,
          fileCount: detail.fileCount,
          totalBytes: detail.totalBytes,
        })
      } else {
        setState({ kind: 'failure', id: detail.id, code: detail.code, message: detail.message })
      }
    }
    window.addEventListener(EVENT_NAME, listener)
    return () => { window.removeEventListener(EVENT_NAME, listener) }
  }, [])

  if (bridge === undefined) return null

  const start = (): void => {
    if (activeId.current !== undefined) return
    const id = globalThis.crypto.randomUUID()
    activeId.current = id
    setCancelRequested(false)
    setState({
      kind: 'running',
      id,
      phase: 'scanning',
      filesDone: 0,
      filesTotal: 0,
      bytesDone: 0,
      bytesTotal: 0,
    })
    void Promise.resolve(bridge.postMessage({
      v: 1,
      id,
      action: 'pick',
      sessionId: props.sessionId,
      targetDirectory: props.absolutePath,
    })).catch((error: unknown) => {
      if (activeId.current !== id) return
      activeId.current = undefined
      setState({ kind: 'failure', id, code: 'bridge-failed', message: failureMessage(error) })
    })
  }

  const cancel = (): void => {
    const id = activeId.current
    // `committing` is the native point of no return: the Worker is publishing
    // the final directory and a late cancel cannot roll it back. Do not offer
    // or send cancellation once that phase is visible.
    if (id === undefined || cancelRequested || (state.kind === 'running' && state.phase === 'committing')) return
    setCancelRequested(true)
    void Promise.resolve(bridge.postMessage({ v: 1, id, action: 'cancel' })).catch((error: unknown) => {
      if (activeId.current !== id) return
      activeId.current = undefined
      setCancelRequested(false)
      setState({ kind: 'failure', id, code: 'bridge-failed', message: failureMessage(error) })
    })
  }

  const busy = state.kind === 'running'
  const label = busy ? t('import.busy') : t('import.button')
  const button = createElement('button', {
    type: 'button',
    style: { ...buttonStyle, cursor: busy ? 'default' : 'pointer', opacity: busy ? 0.6 : 1 },
    title: t('import.buttonTitle'),
    disabled: busy,
    'aria-label': label,
    onClick: start,
  }, label)

  const fragments: ReturnType<typeof createElement>[] = [button]
  if (state.kind === 'running') {
    const phaseLabel = t(`phase.${state.phase}` as DirectoryImportKey)
    const progress = state.filesTotal > 0 ? ` ${state.filesDone}/${state.filesTotal}` : ''
    // Commit is atomic from here on: hiding the control is more honest than
    // showing a cancel button whose click the native side must ignore.
    if (state.phase !== 'committing') {
      fragments.push(createElement('button', {
        type: 'button',
        style: { ...buttonStyle, textDecoration: 'underline' },
        title: t('import.cancel'),
        disabled: cancelRequested,
        onClick: cancel,
      }, cancelRequested ? t('import.cancelling') : t('import.cancel')))
    }
    fragments.push(createElement('span', {
      role: 'status',
      'aria-live': 'polite',
      style: statusStyle,
      title: `${phaseLabel}${progress} · ${formatBytes(state.bytesDone)}/${formatBytes(state.bytesTotal)}`,
    }, createElement('span', { style: statusTextStyle }, `${phaseLabel}${progress}`)))
  } else if (state.kind === 'success') {
    fragments.push(createElement('span', {
      role: 'status',
      'aria-live': 'polite',
      style: statusStyle,
      title: state.workspacePath,
    }, createElement('span', { style: statusTextStyle }, t('import.success', {
      count: state.fileCount,
      bytes: formatBytes(state.totalBytes),
      path: state.workspacePath,
    }))))
  } else if (state.kind === 'failure') {
    fragments.push(createElement('span', {
      role: 'status',
      'aria-live': 'polite',
      style: { ...statusStyle, color: 'var(--dsh-danger, #c0362c)' },
      title: `${state.code}: ${state.message}`,
    }, createElement('span', { style: statusTextStyle }, t('import.failure', { message: state.message }))))
  }

  return createElement('span', {
    style: { display: 'inline-flex', alignItems: 'center', gap: 4, minWidth: 0 },
    'data-phone-directory-import': true,
  }, fragments)
}

/**
 * Register the one Files-panel action. The plugin adds no tab, page, navigation
 * or chat surface; the resident Files tree keeps owning the workspace view.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'phone-directory-import: dictionaries')
  ctx.slots.inject('sidebar.right.tab.files.actions', () => ctx.slots.register({
    name: 'sidebar.right.tab.files.actions',
    id: 'phone-directory-import',
    order: 20,
    locale: NS,
  }, DirectoryImportAction))
}
