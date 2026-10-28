// SPDX-License-Identifier: MIT
/**
 * The `phone-shell` right-Sidebar body.
 *
 * It is a command console, not a terminal: there is no xterm, no PTY, no
 * terminal session protocol, and no fake prompt. The body asks the Host
 * Remote for the real xz-shell caps, then either runs one Worker `bash -c`
 * command through the VFS or an exact argv on an advertised read-only
 * accelerator. Every output line and exit status below came from the
 * subprocess provider.
 * @module @phone-dsh/dsh-phone-shell/client/console
 */

import { createElement, Fragment, useCallback, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Button, Input, Tag } from '@deepseek-ai/dsh-client-ui-primitives'
import type { InjectFace, PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
import type {} from '@deepseek-ai/dsh-client-ui-sidebar-right/client'
import {
  PHONE_SHELL_DEFAULT_CWD,
  PHONE_SHELL_DEFAULT_TIMEOUT_MS,
  PHONE_SHELL_LOCALE_NS,
  parseConsoleTimeout,
  splitAcceleratorArguments,
} from '../contract.ts'
import type { PhoneShellCaps, PhoneShellRunRequest, PhoneShellRunResult } from '../contract.ts'
import type { PhoneShellConsoleClient } from './remote.ts'

/** Business face injected into the console body. */
export interface PhoneShellConsoleInjected {
  /** Host Remote calls over the page's existing Connection RPC. */
  readonly phoneShell: PhoneShellConsoleClient
}

/** Props of the tab body: framework tab identity, copy, and the injected Remote face. */
export type PhoneShellConsoleProps = PropsRuntime<'sidebar.right.pane.tab'>
  & PropsLocale<typeof PHONE_SHELL_LOCALE_NS>
  & InjectFace<PhoneShellConsoleInjected>

/** Props of the tab chip: the framework tab identity and localized copy. */
export type PhoneShellTitleProps = PropsRuntime<'sidebar.right.pane.tab.title'>
  & PropsLocale<typeof PHONE_SHELL_LOCALE_NS>

type CapsState =
  | { readonly status: 'loading' }
  | { readonly status: 'ready'; readonly caps: PhoneShellCaps }
  | { readonly status: 'failed'; readonly message: string }

const PANEL_STYLE = {
  display: 'flex', flexDirection: 'column', gap: '10px', padding: '12px',
  height: '100%', minHeight: 0, overflow: 'auto', boxSizing: 'border-box',
} as const
const ROW_STYLE = { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' } as const
const FIELD_STYLE = { display: 'flex', flexDirection: 'column', gap: '4px', minWidth: 0 } as const
const LABEL_STYLE = { fontSize: '12px', color: 'var(--dsw-alias-text-tertiary, #666)' } as const
const CODE_STYLE = {
  margin: 0, padding: '8px', borderRadius: '6px', overflow: 'auto', maxHeight: '260px',
  whiteSpace: 'pre-wrap', wordBreak: 'break-word',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: '12px',
  background: 'var(--dsw-alias-surface-secondary, rgba(127,127,127,.08))',
} as const
const NOTE_STYLE = { margin: 0, fontSize: '12px', color: 'var(--dsw-alias-text-secondary, #555)' } as const
const ERROR_STYLE = { margin: 0, fontSize: '12px', color: 'var(--dsw-alias-text-danger, #b42318)' } as const
const TEXTAREA_STYLE = {
  width: '100%', minHeight: '72px', resize: 'vertical', boxSizing: 'border-box',
  padding: '6px 8px', borderRadius: '6px', border: '1px solid var(--dsw-alias-border-default, #ccc)',
  background: 'var(--dsw-alias-surface-primary, transparent)', color: 'inherit',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: '12px',
} as const
const SELECT_STYLE = {
  minWidth: '220px', padding: '5px 8px', borderRadius: '6px',
  border: '1px solid var(--dsw-alias-border-default, #ccc)',
  background: 'var(--dsw-alias-surface-primary, transparent)', color: 'inherit',
} as const

/**
 * Render the console body.
 * @param props - localized copy and the Host Remote face.
 * @returns the console controls and the real output of the last run.
 */
export function PhoneShellConsole({ phoneShell, t }: PhoneShellConsoleProps): ReactNode {
  const [caps, setCaps] = useState<CapsState>({ status: 'loading' })
  const [mode, setMode] = useState<'command' | 'accelerator'>('command')
  const [command, setCommand] = useState('')
  const [accelerator, setAccelerator] = useState('')
  const [argumentsText, setArgumentsText] = useState('')
  const [cwd, setCwd] = useState(PHONE_SHELL_DEFAULT_CWD)
  const [timeoutMs, setTimeoutMs] = useState(String(PHONE_SHELL_DEFAULT_TIMEOUT_MS))
  const [running, setRunning] = useState(false)
  const [cancelling, setCancelling] = useState(false)
  const [result, setResult] = useState<PhoneShellRunResult | undefined>()
  const [error, setError] = useState<string | undefined>()
  const execId = useRef<string | undefined>(undefined)
  const abort = useRef<AbortController | undefined>(undefined)

  const loadCaps = useCallback(() => {
    const controller = new AbortController()
    setCaps({ status: 'loading' })
    void phoneShell.caps(controller.signal).then(
      facts => {
        if (controller.signal.aborted) return
        setCaps({ status: 'ready', caps: facts })
        setAccelerator(current => current !== '' && facts.accelerators.includes(current) ? current : (facts.accelerators[0] ?? ''))
        if (facts.accelerators.length === 0) setMode('command')
      },
      (reason: unknown) => {
        if (controller.signal.aborted) return
        setCaps({ status: 'failed', message: reason instanceof Error ? reason.message : String(reason) })
      },
    )
    return controller
  }, [phoneShell])

  useEffect(() => {
    const controller = loadCaps()
    return () => { controller.abort() }
  }, [loadCaps])

  useEffect(() => () => {
    abort.current?.abort()
    const id = execId.current
    if (id !== undefined) void phoneShell.cancel(id).catch(() => {})
  }, [phoneShell])

  const ready = caps.status === 'ready' ? caps.caps : undefined
  const accelerators = ready?.accelerators ?? []
  const canRun = ready !== undefined && ready.transportSupported && !running

  const run = async (): Promise<void> => {
    if (ready === undefined || running) return
    let request: PhoneShellRunRequest
    try {
      const resolvedCwd = cwd.trim()
      if (!resolvedCwd.startsWith('/')) throw new Error(t('invalid.cwd'))
      const timeout = parseConsoleTimeout(Number(timeoutMs), PHONE_SHELL_DEFAULT_TIMEOUT_MS)
      if (mode === 'accelerator') {
        if (!accelerators.includes(accelerator)) throw new Error(t('invalid.command'))
        request = {
          argv: [accelerator, ...splitAcceleratorArguments(argumentsText)],
          cwd: resolvedCwd,
          timeoutMs: timeout,
        }
      } else {
        if (command.trim() === '') throw new Error(t('invalid.command'))
        request = { command, cwd: resolvedCwd, timeoutMs: timeout }
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
      return
    }
    const id = `phone-shell-${globalThis.crypto?.randomUUID?.() ?? `${String(Date.now())}-${Math.random().toString(36).slice(2)}`}`
    const controller = new AbortController()
    execId.current = id
    abort.current = controller
    setRunning(true)
    setCancelling(false)
    setError(undefined)
    setResult(undefined)
    try {
      const settled = await phoneShell.run({ ...request, execId: id }, controller.signal)
      setResult(settled)
    } catch (reason) {
      if (!controller.signal.aborted) {
        setError(reason instanceof Error ? reason.message : String(reason))
      }
    } finally {
      execId.current = undefined
      abort.current = undefined
      setRunning(false)
      setCancelling(false)
    }
  }

  const cancel = (): void => {
    const id = execId.current
    if (id === undefined) return
    setCancelling(true)
    void phoneShell.cancel(id).catch((reason: unknown) => {
      setError(reason instanceof Error ? reason.message : String(reason))
    })
  }

  return createElement(
    'section',
    { style: PANEL_STYLE, 'data-phone-shell': 'console', 'aria-label': t('tab.title') },
    header(t, caps, loadCaps, running),
    modeField(t, mode, setMode, accelerators),
    mode === 'accelerator'
      ? acceleratorArgumentsField(t, accelerators, accelerator, setAccelerator, argumentsText, setArgumentsText)
      : commandField(t, command, setCommand),
    pathFields(t, cwd, setCwd, timeoutMs, setTimeoutMs),
    createElement(
      'div',
      { style: ROW_STYLE, 'data-phone-shell-actions': 'true' },
      createElement(Button, {
        variant: 'primary', size: 'sm', disabled: !canRun, onClick: () => { void run() },
      }, running ? t('running') : t('run')),
      running && createElement(Button, {
        variant: 'outline', size: 'sm', disabled: cancelling, onClick: cancel,
      }, t('cancel')),
    ),
    error !== undefined && createElement('p', { style: ERROR_STYLE, role: 'alert' }, `${t('error.prefix')}: ${error}`),
    output(t, result),
  )
}

/**
 * Render the tab chip. The title states that this is a command console, not a
 * PTY, so the chip cannot be mistaken for the old terminal tab.
 * @param props - localized copy.
 * @returns the chip text.
 */
export function PhoneShellTitle({ t }: PhoneShellTitleProps): ReactNode {
  return createElement('span', { 'data-phone-shell-title': 'true' }, t('tab.title'))
}

function header(
  t: PhoneShellConsoleProps['t'],
  caps: CapsState,
  reload: () => AbortController,
  running: boolean,
): ReactNode {
  const facts = caps.status === 'ready' ? caps.caps : undefined
  return createElement(
    Fragment,
    null,
    createElement('h2', { style: { margin: 0, fontSize: '14px' } }, t('tab.title')),
    caps.status === 'loading' && createElement('p', { style: NOTE_STYLE, role: 'status' }, t('caps.loading')),
    caps.status === 'failed' && createElement(
      Fragment,
      null,
      createElement('p', { style: ERROR_STYLE, role: 'alert' }, `${t('caps.failed')} ${caps.message}`),
      createElement(Button, { variant: 'outline', size: 'sm', onClick: () => { reload() } }, t('caps.retry')),
    ),
    facts !== undefined && createElement(
      Fragment,
      null,
      createElement(
        'div',
        { style: ROW_STYLE },
        createElement(Tag, { tone: facts.linked ? 'success' : 'warning' }, facts.linked ? t('caps.linked') : t('caps.unlinked')),
        createElement(
          'span',
          { style: NOTE_STYLE, 'data-phone-shell-provider': facts.provider ?? 'unknown' },
          facts.provider === undefined ? t('caps.providerUnknown') : `${facts.provider}${facts.version === undefined ? '' : ` ${facts.version}`}`,
        ),
        running && createElement(Tag, { tone: 'info' }, t('running')),
      ),
      !facts.transportSupported
        ? createElement('p', { style: NOTE_STYLE, 'data-phone-shell-transport': 'unsupported' }, t('caps.transportUnsupported'))
        : !facts.linked
          ? createElement('p', { style: NOTE_STYLE }, t('caps.unlinkedDetail'))
          : createElement('p', { style: NOTE_STYLE }, t('caps.workerNote')),
      facts.accelerators.length > 0 && createElement(
        'p',
        { style: NOTE_STYLE, 'data-phone-shell-accelerators': facts.accelerators.join(',') },
        `${t('caps.accelerators')}: ${facts.accelerators.join(', ')}`,
      ),
      facts.mounts === undefined
        ? createElement('p', { style: NOTE_STYLE, 'data-phone-shell-mounts': 'unknown' }, t('caps.mountsUnknown'))
        : facts.mounts.length > 0 && createElement(
          'p',
          { style: NOTE_STYLE, 'data-phone-shell-mounts': facts.mounts.map(mount => mount.guestPath).join(',') },
          `${t('caps.mounts')}: ${facts.mounts.map(mount => `${mount.guestPath} (${mount.readOnly ? t('caps.mountReadOnly') : t('caps.mountHost')})`).join(', ')}`,
        ),
      createElement(
        'p',
        { style: NOTE_STYLE, 'data-phone-shell-limits': 'console' },
        `${t('caps.consoleLimits')}: ${String(facts.limits.timeoutMs)} ms / ${String(facts.limits.maxOutputBytes)} B`,
      ),
      facts.hostLimits !== undefined && createElement(
        'p',
        { style: NOTE_STYLE, 'data-phone-shell-limits': 'host' },
        `${t('caps.hostLimits')}: ${Object.entries(facts.hostLimits).map(([key, value]) => `${key}=${String(value)}`).join(', ')}`,
      ),
    ),
  )
}

function commandField(
  t: PhoneShellConsoleProps['t'],
  command: string,
  setCommand: (value: string) => void,
): ReactNode {
  return createElement(
    'label',
    { style: FIELD_STYLE, 'data-phone-shell-input': 'command' },
    createElement('span', { style: LABEL_STYLE }, t('command.label')),
    createElement(Input, {
      value: command,
      placeholder: t('command.placeholder'),
      spellCheck: false,
      autoCapitalize: 'off',
      autoCorrect: 'off',
      onChange: (event: { currentTarget: { value: string } }) => { setCommand(event.currentTarget.value) },
    }),
  )
}

function modeField(
  t: PhoneShellConsoleProps['t'],
  mode: 'command' | 'accelerator',
  setMode: (mode: 'command' | 'accelerator') => void,
  accelerators: readonly string[],
): ReactNode {
  return createElement(
    'label',
    { style: FIELD_STYLE },
    createElement('span', { style: LABEL_STYLE }, t('mode.label')),
    createElement(
      'select',
      {
        style: SELECT_STYLE,
        value: mode,
        onChange: (event: { currentTarget: { value: string } }) => {
          setMode(event.currentTarget.value === 'accelerator' && accelerators.length > 0 ? 'accelerator' : 'command')
        },
        'data-phone-shell-input': 'mode',
      },
      createElement('option', { value: 'command' }, t('mode.command')),
      accelerators.length > 0 && createElement('option', { value: 'accelerator' }, t('mode.accelerator')),
    ),
  )
}

function acceleratorArgumentsField(
  t: PhoneShellConsoleProps['t'],
  accelerators: readonly string[],
  accelerator: string,
  setAccelerator: (value: string) => void,
  argumentsText: string,
  setArgumentsText: (value: string) => void,
): ReactNode {
  return createElement(
    Fragment,
    null,
    createElement(
      'label',
      { style: FIELD_STYLE },
      createElement('span', { style: LABEL_STYLE }, t('caps.accelerators')),
      createElement(
        'select',
        {
          style: SELECT_STYLE,
          value: accelerator,
          onChange: (event: { currentTarget: { value: string } }) => { setAccelerator(event.currentTarget.value) },
          'data-phone-shell-input': 'accelerator',
        },
        ...accelerators.map(name => createElement('option', { key: name, value: name }, name)),
      ),
    ),
    createElement(
      'label',
      { style: FIELD_STYLE },
      createElement('span', { style: LABEL_STYLE }, t('arguments.label')),
      createElement('textarea', {
        style: TEXTAREA_STYLE,
        value: argumentsText,
        placeholder: t('arguments.placeholder'),
        spellCheck: false,
        autoCapitalize: 'off',
        autoCorrect: 'off',
        onChange: (event: { currentTarget: { value: string } }) => { setArgumentsText(event.currentTarget.value) },
        'data-phone-shell-input': 'arguments',
      }),
    ),
  )
}

function pathFields(
  t: PhoneShellConsoleProps['t'],
  cwd: string,
  setCwd: (value: string) => void,
  timeoutMs: string,
  setTimeoutMs: (value: string) => void,
): ReactNode {
  return createElement(
    'div',
    { style: ROW_STYLE },
    createElement(
      'label',
      { style: { ...FIELD_STYLE, flex: '1 1 220px' }, 'data-phone-shell-input': 'cwd' },
      createElement('span', { style: LABEL_STYLE }, t('cwd.label')),
      createElement(Input, {
        value: cwd,
        spellCheck: false,
        autoCapitalize: 'off',
        autoCorrect: 'off',
        onChange: (event: { currentTarget: { value: string } }) => { setCwd(event.currentTarget.value) },
      }),
    ),
    createElement(
      'label',
      { style: { ...FIELD_STYLE, flex: '0 1 160px' }, 'data-phone-shell-input': 'timeout' },
      createElement('span', { style: LABEL_STYLE }, t('timeout.label')),
      createElement(Input, {
        value: timeoutMs,
        inputMode: 'numeric',
        spellCheck: false,
        onChange: (event: { currentTarget: { value: string } }) => { setTimeoutMs(event.currentTarget.value) },
      }),
    ),
  )
}

function output(t: PhoneShellConsoleProps['t'], result: PhoneShellRunResult | undefined): ReactNode {
  if (result === undefined) return createElement('p', { style: NOTE_STYLE }, t('output.empty'))
  const statuses: ReactNode[] = []
  statuses.push(createElement(Tag, {
    key: 'exit',
    tone: result.exitCode === 0 && result.signal === null && !result.timedOut && !result.cancelled ? 'success' : 'danger',
  }, `${t('status.exit')} ${String(result.exitCode ?? '—')}`))
  if (result.signal !== null) statuses.push(createElement(Tag, { key: 'signal', tone: 'warning' }, `${t('status.signal')} ${result.signal}`))
  if (result.timedOut) statuses.push(createElement(Tag, { key: 'timeout', tone: 'warning' }, t('status.timedOut')))
  if (result.cancelled) statuses.push(createElement(Tag, { key: 'cancelled', tone: 'warning' }, t('status.cancelled')))
  if (result.truncated) statuses.push(createElement(Tag, { key: 'truncated', tone: 'warning' }, t('status.truncated')))
  statuses.push(createElement(Tag, { key: 'duration', tone: 'neutral' }, `${t('status.duration')} ${String(result.durationMs)} ms`))
  return createElement(
    'div',
    { style: FIELD_STYLE, 'data-phone-shell-result': result.execId },
    createElement('h3', { style: { margin: 0, fontSize: '13px' } }, t('output.title')),
    createElement('div', { style: ROW_STYLE }, ...statuses),
    createElement('p', { style: NOTE_STYLE }, `${t('output.stdout')}:`),
    createElement('pre', { style: CODE_STYLE, 'data-phone-shell-stream': 'stdout' }, result.stdout === '' ? t('output.noStdout') : result.stdout),
    createElement('p', { style: NOTE_STYLE }, `${t('output.stderr')}:`),
    createElement('pre', { style: CODE_STYLE, 'data-phone-shell-stream': 'stderr' }, result.stderr === '' ? t('output.noStderr') : result.stderr),
  )
}
