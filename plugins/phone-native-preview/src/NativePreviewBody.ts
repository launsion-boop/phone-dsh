// SPDX-License-Identifier: MIT
// The keyed `sidebar.right.tab.document` body for Office files. The actual
// document is rendered by system Quick Look on top of the app; this body only
// carries the handoff state and the native bridge's real error.

import { createElement, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Button, FileTypeIcon, classifyFileType } from '@deepseek-ai/dsh-client-ui-primitives'
import { nativePreviewTarget, postNativePreview } from './protocol.ts'
import type { NativePreviewResult } from './protocol.ts'
import type { NativePreviewKey } from './locales.ts'

interface ResourceSnapshot {
  readonly value?: { readonly version?: string }
}

interface RendererContent {
  readonly kind: 'renderer'
  readonly revision: number
  readonly loaded: (version: string) => void
  readonly failed: () => void
  readonly reload: () => void
}

interface NativePreviewBodyProps {
  readonly resourceAddress: string
  readonly content: { readonly kind: string } | RendererContent
  readonly useResource: (address: string) => ResourceSnapshot
  readonly t: (key: NativePreviewKey) => string
}

type Phase = 'idle' | 'opening' | 'opened' | 'error'

interface RememberedState {
  readonly revision: number
  readonly phase: Exclude<Phase, 'opening'>
  readonly failure?: NativePreviewResult
}

// The document owner unmounts a body when its tab is hidden; its official store
// keeps renderer state across that. This page-lifetime map does the same for the
// native handoff so returning to a tab does not pop Quick Look again.
const remembered = new Map<string, RememberedState>()

const container = {
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'center',
  gap: '10px',
  boxSizing: 'border-box',
  width: '100%',
  minHeight: '100%',
  padding: '32px 24px',
  textAlign: 'center',
} as const

const headingStyle = {
  margin: 0,
  fontSize: '17px',
  fontWeight: 600,
  lineHeight: 1.3,
} as const

const detailStyle = {
  margin: 0,
  maxWidth: '34em',
  fontSize: '14px',
  lineHeight: 1.45,
  opacity: 0.68,
} as const

const codeStyle = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: '12px',
  opacity: 0.64,
} as const

function requestOf(content: NativePreviewBodyProps['content']): RendererContent | undefined {
  return content.kind === 'renderer' ? content as RendererContent : undefined
}

function fileNameOf(address: string): string {
  const path = address.replace(/[?#].*$/, '')
  return path.slice(path.lastIndexOf('/') + 1)
}

/**
 * Render one Office document handoff.
 * @param props - standard keyed document body props.
 * @returns the handoff status, never a fake document rendering.
 */
export function NativePreviewBody(props: NativePreviewBodyProps): ReactNode {
  const request = requestOf(props.content)
  const meta = props.useResource(props.resourceAddress)
  const version = meta.value?.version
  const memoryKey = props.resourceAddress
  const initial = remembered.get(memoryKey)
  const [phase, setPhase] = useState<Phase>(initial?.phase ?? 'idle')
  const [failure, setFailure] = useState<NativePreviewResult | undefined>(initial?.failure)
  const alive = useRef(true)
  const openedRevision = useRef<number | undefined>(initial?.revision)
  const t = props.t

  useEffect(() => {
    alive.current = true
    return () => { alive.current = false }
  }, [])

  useEffect(() => {
    if (request === undefined) return
    if (openedRevision.current === request.revision) return
    openedRevision.current = request.revision
    void open(request)
    // `open` closes over the current version/address; the revision guard keeps
    // metadata re-renders from reopening Quick Look.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [request?.revision, props.resourceAddress])

  useEffect(() => {
    if (phase !== 'opened' || request === undefined || version === undefined) return
    request.loaded(version)
  }, [phase, version, request?.revision])

  async function open(target: RendererContent): Promise<void> {
    const targetAddress = nativePreviewTarget(props.resourceAddress)
    if (targetAddress === undefined) {
      if (!alive.current) return
      const unsupported: NativePreviewResult = {
        id: '',
        ok: false,
        code: 'not-an-office-document',
        message: t('unsupported'),
      }
      remembered.set(memoryKey, {
        revision: target.revision, phase: 'error', failure: unsupported,
      })
      setFailure(unsupported)
      setPhase('error')
      target.failed()
      return
    }
    setPhase('opening')
    setFailure(undefined)
    const result = await postNativePreview(targetAddress)
    if (result.ok) {
      // The effect above reports the observed metadata version. Inventing one
      // here would make the owner treat the real metadata frame as a change
      // and reopen Quick Look.
      remembered.set(memoryKey, { revision: target.revision, phase: 'opened' })
      if (!alive.current) return
      setPhase('opened')
      return
    }
    remembered.set(memoryKey, {
      revision: target.revision, phase: 'error', failure: result,
    })
    if (!alive.current) return
    setFailure(result)
    setPhase('error')
    target.failed()
  }

  const name = fileNameOf(props.resourceAddress)
  const kind = classifyFileType(name)
  const heading = phase === 'opened'
    ? t('opened')
    : phase === 'error'
      ? t('failed')
      : phase === 'opening'
        ? t('opening')
        : t('title')
  const detail = phase === 'opened'
    ? t('openedHint')
    : failure !== undefined
      ? failure.message
      : undefined

  return createElement(
    'div',
    { style: container, 'data-native-office-preview': phase },
    createElement(FileTypeIcon, { kind, size: 40 }),
    createElement('p', { style: headingStyle }, heading),
    detail !== undefined && detail !== ''
      ? createElement('p', { style: detailStyle }, detail)
      : null,
    failure !== undefined
      ? createElement('code', { style: codeStyle }, failure.code)
      : null,
    request !== undefined
      ? createElement(Button, {
        size: 'sm',
        onClick: () => { void open(request) },
      }, phase === 'error' ? t('retry') : t('reopen'))
      : null,
  )
}
