// SPDX-License-Identifier: MIT
// Native Office preview wire contract: extension selection, DSH file-address
// parsing, the WKWebView message and its result callback.
//
// This module is browser-only and imports no React. The registration module
// and the tests can use it without a WebKit or DOM host.

import { parseFileAddress } from '@deepseek-ai/dsh-util-workspace-path'

/** Handler name the native side installs on WKUserContentController. */
export const NATIVE_PREVIEW_HANDLER = 'pdshNativePreview'
/** The only message version the native bridge accepts. */
export const NATIVE_PREVIEW_VERSION = 1
/** Office suffixes system Quick Look opens; every other renderer keeps its DSH body. */
export const NATIVE_PREVIEW_EXTENSIONS = Object.freeze(['doc', 'docx', 'ppt', 'pptx'] as const)

export type NativePreviewExtension = (typeof NATIVE_PREVIEW_EXTENSIONS)[number]

/** A Session-scoped file the native Quick Look bridge can open. */
export interface NativePreviewTarget {
  readonly sessionId: string
  readonly path: string
}

/** The exact message the native handler accepts. */
export interface NativePreviewMessage extends NativePreviewTarget {
  readonly v: typeof NATIVE_PREVIEW_VERSION
  readonly id: string
}

/** The callback object the native handler evaluates. */
export interface NativePreviewResult {
  readonly id: string
  readonly ok: boolean
  readonly code: string
  readonly message: string
}

/** The minimum bridge surface; no other WKWebView API is touched. */
export interface NativePreviewBridge {
  postMessage(message: NativePreviewMessage): void
}

/** Browser globals used by the bridge, injectable for tests. */
export interface NativePreviewScope {
  readonly webkit?: {
    readonly messageHandlers?: Readonly<Record<string, {
      postMessage?: (message: unknown) => void
    } | undefined>>
  }
  __PDSH_NATIVE_PREVIEW_RESULT__?: (result: unknown) => void
}

/**
 * The suffix of `path`, lower-cased, or `undefined` when it has no stem.
 * Both path separators are accepted even though the page only emits `/`.
 * @param path - workspace-relative or absolute path.
 * @returns the suffix without the dot.
 */
export function nativePreviewExtension(path: string): string | undefined {
  const normalized = path.replace(/\\/g, '/')
  const name = normalized.slice(normalized.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  if (dot <= 0 || dot === name.length - 1) return undefined
  return name.slice(dot + 1).toLowerCase()
}

/**
 * Whether this path is one of the four Office suffixes the native bridge owns.
 * Images, PDF, spreadsheets, HTML and text are deliberately excluded.
 * @param path - workspace-relative or absolute path.
 * @returns true for doc/docx/ppt/pptx.
 */
export function isNativePreviewPath(path: string): boolean {
  const extension = nativePreviewExtension(path)
  return extension !== undefined
    && (NATIVE_PREVIEW_EXTENSIONS as readonly string[]).includes(extension)
}

/**
 * Resolve one tab address to the Session and workspace path the native bridge
 * receives. Uses DSH's own `dsh-resource://file` parser; an absolute address
 * has no Session and is not accepted.
 * @param address - a tab's `dsh-resource://file/...` address.
 * @returns the target, or undefined for another scope/suffix.
 */
export function nativePreviewTarget(address: string): NativePreviewTarget | undefined {
  const parsed = parseFileAddress(address)
  if (parsed === undefined || parsed.scope !== 'session') return undefined
  if (!isNativePreviewPath(parsed.path)) return undefined
  return { sessionId: parsed.sessionId, path: parsed.path }
}

/**
 * Build the one accepted message shape.
 * @param id - caller correlation id.
 * @param target - the Session and path.
 * @returns the exact `{v,id,sessionId,path}` message.
 */
export function nativePreviewMessage(id: string, target: NativePreviewTarget): NativePreviewMessage {
  return {
    v: NATIVE_PREVIEW_VERSION,
    id,
    sessionId: target.sessionId,
    path: target.path,
  }
}

/**
 * Read the native bridge from the page's `window.webkit.messageHandlers`.
 * @param scope - browser window, or an injected stand-in in tests.
 * @returns the bridge, or undefined when the native handler is absent.
 */
export function nativePreviewBridge(
  scope: NativePreviewScope | undefined = typeof window === 'undefined'
    ? undefined
    : window as unknown as NativePreviewScope,
): NativePreviewBridge | undefined {
  const handler = scope?.webkit?.messageHandlers?.[NATIVE_PREVIEW_HANDLER]
  if (handler === undefined || typeof handler.postMessage !== 'function') return undefined
  return { postMessage: message => handler.postMessage?.(message) }
}

/**
 * Validate an object the native side handed back to the page.
 * @param value - the evaluated JavaScript argument.
 * @returns the typed result, or undefined for a malformed object.
 */
export function decodeNativePreviewResult(value: unknown): NativePreviewResult | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const record = value as Record<string, unknown>
  if (typeof record.id !== 'string' || record.id === '') return undefined
  if (typeof record.ok !== 'boolean') return undefined
  if (typeof record.code !== 'string' || record.code === '') return undefined
  if (typeof record.message !== 'string') return undefined
  return {
    id: record.id,
    ok: record.ok,
    code: record.code,
    message: record.message,
  }
}

const pending = new Map<string, (result: NativePreviewResult) => void>()

function dispatchNativePreviewResult(value: unknown): void {
  const result = decodeNativePreviewResult(value)
  if (result === undefined) return
  const settle = pending.get(result.id)
  if (settle === undefined) return
  pending.delete(result.id)
  settle(result)
}

function installNativePreviewResultDispatcher(scope: NativePreviewScope): void {
  if (scope.__PDSH_NATIVE_PREVIEW_RESULT__ === dispatchNativePreviewResult) return
  scope.__PDSH_NATIVE_PREVIEW_RESULT__ = dispatchNativePreviewResult
}

let nextIdentifier = 0

function makeIdentifier(): string {
  const crypto = globalThis.crypto
  if (crypto !== undefined && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  nextIdentifier += 1
  return `native-preview-${Date.now().toString(36)}-${nextIdentifier.toString(36)}`
}

/** Options for one native preview request. */
export interface NativePreviewRequestOptions {
  readonly bridge?: NativePreviewBridge
  readonly scope?: NativePreviewScope
  readonly id?: string
  readonly timeoutMs?: number
}

/**
 * Post one Office file to the native bridge and resolve with its result.
 *
 * The page never reads the file. A missing bridge is a real failure
 * (`native-bridge-unavailable`), not a silent fallback that pretends the
 * document opened.
 * @param target - Session and workspace path.
 * @param options - injected bridge/scope, id and timeout.
 * @returns the native outcome, or a local transport failure.
 */
export function postNativePreview(
  target: NativePreviewTarget,
  options: NativePreviewRequestOptions = {},
): Promise<NativePreviewResult> {
  const scope = options.scope
    ?? (typeof window === 'undefined' ? undefined : window as unknown as NativePreviewScope)
  const bridge = options.bridge ?? nativePreviewBridge(scope)
  const id = options.id ?? makeIdentifier()
  if (bridge === undefined || scope === undefined) {
    return Promise.resolve({
      id,
      ok: false,
      code: 'native-bridge-unavailable',
      message: 'The native Quick Look bridge is not installed.',
    })
  }
  installNativePreviewResultDispatcher(scope)
  const message = nativePreviewMessage(id, target)
  return new Promise<NativePreviewResult>(resolve => {
    let settled = false
    const finish = (result: NativePreviewResult): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      pending.delete(id)
      resolve(result)
    }
    const timer = setTimeout(() => {
      finish({
        id,
        ok: false,
        code: 'native-preview-timeout',
        message: 'The native Quick Look bridge did not answer in time.',
      })
    }, options.timeoutMs ?? 20_000)
    pending.set(id, finish)
    try {
      bridge.postMessage(message)
    } catch (error) {
      finish({
        id,
        ok: false,
        code: 'native-bridge-failed',
        message: error instanceof Error ? error.message : String(error),
      })
    }
  })
}
