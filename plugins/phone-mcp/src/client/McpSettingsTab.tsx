// SPDX-License-Identifier: MIT
/** Settings tab for HTTP-SSE MCP servers: real CRUD, mount status, and errors. */

import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Button,
  Input,
  Switch,
  Tag,
} from '@deepseek-ai/dsh-client-ui-primitives'
import type { TagTone } from '@deepseek-ai/dsh-client-ui-primitives'
import type { InjectFace, PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
import type { McpServerView, McpSnapshot } from '../protocol.ts'
import type { PhoneMcpClient } from './remote.ts'
import type { PhoneMcpLocaleKey } from './locales.ts'
import {
  abandonNativeMCP,
  canonicalMCPEndpoint,
  commitNativeMCP,
  grantNativeMCP,
  nativeMCPBridgeAvailable,
  openNativeMCPSettings,
  revokeNativeMCP,
  rollbackNativeMCP,
  settleNativeMCP,
  syncNativeMCP,
} from './native.ts'
import type { NativeMCPGrant } from './native.ts'
import css from './McpSettingsTab.module.css'

/** Injected Remote face plus locale identity for the tab. */
export interface McpSettingsTabInjected {
  readonly client: PhoneMcpClient
}

/** Full props assembled by the Settings slot. */
export type McpSettingsTabProps =
  PropsRuntime<'settings.plugins.tab'>
  & PropsLocale<'settings.phoneMcp'>
  & InjectFace<McpSettingsTabInjected>

type Translate = McpSettingsTabProps['t']

interface FormState {
  serverName: string
  url: string
  headersFromEnv: string
  enabled: boolean
  toolCallTimeoutMs: string
}

const EMPTY_FORM: FormState = {
  serverName: '',
  url: '',
  headersFromEnv: '',
  enabled: true,
  toolCallTimeoutMs: '60000',
}

const STATUS_TONE: Record<McpServerView['status'], TagTone> = {
  connected: 'success',
  connecting: 'warning',
  error: 'danger',
  disabled: 'neutral',
}

function statusKey(status: McpServerView['status']): PhoneMcpLocaleKey {
  switch (status) {
    case 'connected': return 'statusConnected'
    case 'error': return 'statusError'
    case 'disabled': return 'statusDisabled'
    case 'connecting': return 'statusConnecting'
  }
}

/** Render `Header=ENV_VAR` lines without ever including a value. */
export function headersToText(headers: Readonly<Record<string, string>>): string {
  return Object.entries(headers)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([header, env]) => `${header}=${env}`)
    .join('\n')
}

/** Parse form lines into the persisted header→environment-variable map. */
export function textToHeaders(text: string): Record<string, string> {
  const headers: Record<string, string> = {}
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (line.length === 0) continue
    const separator = line.indexOf('=')
    if (separator <= 0) throw new Error('invalid-header-line')
    const header = line.slice(0, separator).trim()
    const envName = line.slice(separator + 1).trim()
    if (header.length === 0 || envName.length === 0) throw new Error('invalid-header-line')
    headers[header] = envName
  }
  return headers
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Roll back a native grant transaction, returning a visible failure if any. */
async function rollbackFailure(grant: NativeMCPGrant | undefined): Promise<string | undefined> {
  try {
    await rollbackNativeMCP(grant?.transaction)
    return undefined
  } catch (error) {
    return `rollback failed: ${errorMessage(error)}`
  }
}

/**
 * A failed update unmounted the old row before the Worker restored its file
 * entry. After the native route is back, remount that old row; a new row has
 * nothing to recover and simply reports not-found.
 */
async function recoverAfterRollback(client: PhoneMcpClient, serverName: string): Promise<void> {
  try {
    await client.reconnect({ serverName })
  } catch {
    // New row, or the Worker already restored it. The original error remains.
  }
}

/**
 * An inconclusive registry read must not leave the transaction in a state where
 * every later list protects it. Mark only this stage ownerless; the next real
 * list or materialized start decides commit/rollback.
 */
async function keepUnknownGrant(grant: NativeMCPGrant | undefined): Promise<void> {
  try {
    await abandonNativeMCP(grant?.transaction)
  } catch {
    // The pagehide/expiry owner remains; never roll back from this path.
  }
}

/** Canonicalize the form URL the same way the Worker's `new URL(...)` does. */
function canonicalMCPURL(raw: string): string {
  try {
    return new URL(raw.trim()).toString()
  } catch {
    return raw.trim()
  }
}

interface FailedUpsertResolution {
  readonly outcome: 'committed' | 'rolled-back' | 'unknown'
  /** The Worker row committed but native old-key cleanup still needs a retry. */
  readonly cleanupPending: boolean
}

/**
 * A thrown `upsert` is not proof that the Worker write failed: the reply can be
 * lost after mcp.json was committed. Query the real registry first and compare
 * canonical endpoints, never raw spelling. A matching URL consumes the native
 * settle verdict as committed; only a confirmed old/absent row rolls back; an
 * unreadable or inconclusive registry keeps the durable staging.
 * @param client - Worker Remote face.
 * @param serverName - row being saved.
 * @param attemptedURL - canonical desired URL returned by the bridge.
 * @param grant - native grant transaction, if any.
 * @returns the resolution and any pending native cleanup.
 */
async function resolveFailedUpsert(
  client: PhoneMcpClient,
  serverName: string,
  attemptedURL: string,
  grant: NativeMCPGrant | undefined,
): Promise<FailedUpsertResolution> {
  let snapshot: McpSnapshot
  try {
    snapshot = await client.list()
  } catch {
    await keepUnknownGrant(grant)
    return { outcome: 'unknown', cleanupPending: false }
  }
  if (snapshot.error !== undefined) {
    await keepUnknownGrant(grant)
    return { outcome: 'unknown', cleanupPending: false }
  }
  const row = snapshot.servers.find(server => server.serverName === serverName)
  const attemptedKey = canonicalMCPEndpoint(attemptedURL)
  const rowKey = row === undefined ? undefined : canonicalMCPEndpoint(row.url)
  if (row !== undefined && attemptedKey !== undefined && rowKey === attemptedKey) {
    // The registry proves the Worker write committed. The grant itself is
    // already the desired one; only the old-account cleanup may still be owed.
    if (grant?.transaction !== undefined) {
      let settle
      try {
        settle = await settleNativeMCP(grant.transaction, row.url)
      } catch {
        await keepUnknownGrant(grant)
        return { outcome: 'unknown', cleanupPending: false }
      }
      if (!settle.committed) {
        await keepUnknownGrant(grant)
        return { outcome: 'unknown', cleanupPending: settle.cleanupPending }
      }
      return {
        outcome: 'committed',
        cleanupPending: settle.cleanupPending || settle.resolved === 'commitPending',
      }
    }
    return { outcome: 'committed', cleanupPending: false }
  }
  if (grant?.transaction !== undefined) {
    let settle
    try {
      settle = await settleNativeMCP(grant.transaction, row?.url)
    } catch {
      await keepUnknownGrant(grant)
      return { outcome: 'unknown', cleanupPending: false }
    }
    if (settle.resolved === 'committed' || settle.resolved === 'commitPending') {
      return { outcome: 'committed', cleanupPending: settle.cleanupPending }
    }
    if (settle.resolved !== 'rolled-back') {
      // Settle could not prove either outcome. Release only this transaction's
      // retry owner so the next real list/sync can resolve the abandoned stage;
      // never roll back a possibly committed Worker row from here.
      await keepUnknownGrant(grant)
      return { outcome: 'unknown', cleanupPending: settle.cleanupPending }
    }
  } else if (grant !== undefined) {
    // A bridge grant without a token cannot be settled; keep its staging.
    return { outcome: 'unknown', cleanupPending: false }
  } else {
    // Desktop: no native transaction exists to roll back.
    return { outcome: 'rolled-back', cleanupPending: false }
  }
  await recoverAfterRollback(client, serverName)
  return { outcome: 'rolled-back', cleanupPending: false }
}

/**
 * Render the MCP management tab.
 * @param props - slot runtime, locale copy, and the Remote face.
 * @returns the tab body.
 */
export function McpSettingsTab(props: McpSettingsTabProps) {
  const { t, client } = props
  const [snapshot, setSnapshot] = useState<McpSnapshot | undefined>()
  const [loadError, setLoadError] = useState<string | undefined>()
  const [actionError, setActionError] = useState<string | undefined>()
  const [actionNotice, setActionNotice] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState<string | undefined>()
  const [form, setForm] = useState<FormState>(EMPTY_FORM)
  const [editing, setEditing] = useState(false)

  const refresh = useCallback(async () => {
    setLoading(true)
    setLoadError(undefined)
    try {
      const next = await client.list()
      setSnapshot(next)
      // A successful list is the authority. The native side revokes grants and
      // Keychain values for rows that were removed elsewhere (or a previous
      // remove whose revoke reply was lost). A corrupt registry is not empty
      // and must never mass-revoke credentials.
      if (next.error === undefined) {
        await syncNativeMCP(next.servers.map(server => ({
          serverName: server.serverName,
          url: server.url,
        })))
      }
    } catch (error) {
      setLoadError(errorMessage(error))
    } finally {
      setLoading(false)
    }
  }, [client])

  useEffect(() => { void refresh() }, [refresh])

  const beginEdit = useCallback((server: McpServerView) => {
    setEditing(true)
    setActionError(undefined)
    setActionNotice(undefined)
    setForm({
      serverName: server.serverName,
      url: server.url,
      headersFromEnv: headersToText(server.headersFromEnv),
      enabled: server.enabled,
      toolCallTimeoutMs: String(server.toolCallTimeoutMs),
    })
  }, [])

  const resetForm = useCallback(() => {
    setEditing(false)
    setActionError(undefined)
    setActionNotice(undefined)
    setForm(EMPTY_FORM)
  }, [])

  const save = useCallback(async () => {
    setActionError(undefined)
    setActionNotice(undefined)
    if (form.serverName.trim().length === 0 || form.url.trim().length === 0) {
      setActionError(t('formInvalid'))
      return
    }
    let headersFromEnv: Record<string, string>
    try {
      headersFromEnv = textToHeaders(form.headersFromEnv)
    } catch {
      setActionError(t('headerLineInvalid'))
      return
    }
    const toolCallTimeoutMs = Number(form.toolCallTimeoutMs)
    if (!Number.isInteger(toolCallTimeoutMs) || toolCallTimeoutMs < 1) {
      setActionError(t('timeoutInvalid'))
      return
    }
    setBusy('save')
    let grant: NativeMCPGrant | undefined
    try {
      // The native grant is a transaction: the exact route is live for the
      // Worker mount, but a failed upsert restores the previous grant and
      // Keychain value. Without the bridge this is undefined and desktop
      // behavior is unchanged (environment headers still apply).
      grant = await grantNativeMCP(
        form.serverName.trim(),
        form.url.trim(),
        headersFromEnv,
      )
      if (grant?.needsValues === true) {
        // A native-only value is still missing. Do not leave the grant
        // committed with no usable credential; open the real native editor
        // with the non-secret fields and let it save key + grant + upsert.
        const rollback = await rollbackFailure(grant)
        if (rollback !== undefined) {
          setActionError(`${t('actionFailed')}: ${rollback}`)
          return
        }
        openNativeMCPSettings({
          serverName: form.serverName.trim(),
          url: grant?.url ?? form.url.trim(),
          headersFromEnv,
          enabled: form.enabled,
          toolCallTimeoutMs,
        })
        resetForm()
        setActionNotice(t('nativeKeyRequired'))
        return
      }
      const desiredURL = grant?.url ?? canonicalMCPURL(form.url)
      try {
        await client.upsert({
          serverName: form.serverName.trim(),
          url: desiredURL,
          headersFromEnv,
          ...(grant === undefined ? {} : { hostManagedHeaders: grant.hostManagedHeaders }),
          enabled: form.enabled,
          toolCallTimeoutMs,
        })
      } catch (error) {
        const resolution = await resolveFailedUpsert(
          client,
          form.serverName.trim(),
          desiredURL,
          grant,
        )
        if (resolution.outcome === 'committed') {
          resetForm()
          setActionNotice(resolution.cleanupPending ? t('upsertCommitPending') : t('upsertCommitted'))
          await refresh()
          return
        }
        if (resolution.outcome === 'unknown') {
          await refresh()
          setActionError(`${t('actionFailed')}: ${errorMessage(error)}; ${t('upsertUnknown')}`)
          return
        }
        throw error
      }
      // The upsert already committed the Worker row. A commit/cleanup failure
      // is a visible pending status; it must not report the save as failed or
      // restore a rollback owner for the committed row.
      let cleanupPending = false
      try {
        cleanupPending = (await commitNativeMCP(grant?.transaction)).cleanupPending
      } catch {
        cleanupPending = true
      }
      resetForm()
      if (cleanupPending) setActionNotice(t('upsertCommitPending'))
      await refresh()
    } catch (error) {
      setActionError(`${t('actionFailed')}: ${errorMessage(error)}`)
      await refresh()
    } finally {
      setBusy(undefined)
    }
  }, [client, form, refresh, resetForm, t])

  const remove = useCallback(async (serverName: string) => {
    setActionError(undefined)
    setBusy(`remove:${serverName}`)
    try {
      await client.remove({ serverName })
      await revokeNativeMCP(serverName)
      await refresh()
    } catch (error) {
      setActionError(`${t('actionFailed')}: ${errorMessage(error)}`)
    } finally {
      setBusy(undefined)
    }
  }, [client, refresh, t])

  const reconnect = useCallback(async (serverName: string) => {
    setActionError(undefined)
    setActionNotice(undefined)
    setBusy(`reconnect:${serverName}`)
    let grant: NativeMCPGrant | undefined
    try {
      const server = snapshot?.servers.find(candidate => candidate.serverName === serverName)
      if (server !== undefined) {
        grant = await grantNativeMCP(server.serverName, server.url, server.headersFromEnv)
        if (grant?.needsValues === true) {
          const rollback = await rollbackFailure(grant)
          if (rollback !== undefined) {
            setActionError(`${t('actionFailed')}: ${rollback}`)
            return
          }
          openNativeMCPSettings({
            serverName: server.serverName,
            url: grant?.url ?? server.url,
            headersFromEnv: server.headersFromEnv,
            enabled: server.enabled,
            toolCallTimeoutMs: server.toolCallTimeoutMs,
          })
          setActionNotice(t('nativeKeyRequired'))
          return
        }
        const desiredURL = grant?.url ?? canonicalMCPURL(server.url)
        try {
          // Rewrite the row so an older environment-header row becomes
          // host-managed on this phone; the same upsert also remounts it.
          await client.upsert({
            serverName: server.serverName,
            url: desiredURL,
            headersFromEnv: server.headersFromEnv,
            ...(grant === undefined ? {} : { hostManagedHeaders: grant.hostManagedHeaders }),
            enabled: server.enabled,
            toolCallTimeoutMs: server.toolCallTimeoutMs,
          })
        } catch (error) {
          const resolution = await resolveFailedUpsert(
            client,
            server.serverName,
            desiredURL,
            grant,
          )
          if (resolution.outcome === 'committed') {
            setActionNotice(resolution.cleanupPending ? t('upsertCommitPending') : t('upsertCommitted'))
            await refresh()
            return
          }
          if (resolution.outcome === 'unknown') {
            await refresh()
            setActionError(`${t('actionFailed')}: ${errorMessage(error)}; ${t('upsertUnknown')}`)
            return
          }
          throw error
        }
        let cleanupPending = false
        try {
          cleanupPending = (await commitNativeMCP(grant?.transaction)).cleanupPending
        } catch {
          cleanupPending = true
        }
        if (cleanupPending) setActionNotice(t('upsertCommitPending'))
      } else {
        await client.reconnect({ serverName })
      }
      await refresh()
    } catch (error) {
      setActionError(`${t('actionFailed')}: ${errorMessage(error)}`)
      await refresh()
    } finally {
      setBusy(undefined)
    }
  }, [client, refresh, t])

  const servers = useMemo(() => snapshot?.servers ?? [], [snapshot])
  const configurationError = loadError ?? snapshot?.error

  return (
    <div className={css.root}>
      <header className={css.header}>
        <div>
          <h2 className={css.title}>{t('title')}</h2>
          <p className={css.description}>{t('description')}</p>
        </div>
        <div className={css.actions}>
          {nativeMCPBridgeAvailable() && (
            <Button variant="outline" size="sm" disabled={busy !== undefined}
              onClick={() => { openNativeMCPSettings() }}>
              {t('nativeSettings')}
            </Button>
          )}
          <Button variant="outline" size="sm" disabled={loading || busy !== undefined}
            onClick={() => { void refresh() }}>
            {t('refresh')}
          </Button>
        </div>
      </header>

      {snapshot !== undefined && (
        <p className={css.file}>{t('configFile')}: <code>{snapshot.file}</code></p>
      )}

      {configurationError !== undefined && (
        <div className={css.error} role="alert">
          <strong>{t('loadFailed')}</strong>
          <span>{configurationError}</span>
        </div>
      )}

      {actionNotice !== undefined && (
        <div className={css.muted} role="status">{actionNotice}</div>
      )}

      {actionError !== undefined && (
        <div className={css.error} role="alert">{actionError}</div>
      )}

      <section className={css.form} aria-label={editing ? t('editServer') : t('addServer')}>
        <h3 className={css.formTitle}>{editing ? t('editServer') : t('addServer')}</h3>
        <label className={css.field}>
          <span>{t('serverName')}</span>
          <Input
            value={form.serverName}
            disabled={editing || busy !== undefined}
            placeholder="github"
            onChange={event => { setForm(current => ({ ...current, serverName: event.target.value })) }}
          />
          <small>{t('serverNameHint')}</small>
        </label>
        <label className={css.field}>
          <span>{t('url')}</span>
          <Input
            value={form.url}
            disabled={busy !== undefined}
            placeholder="https://mcp.example.invalid/mcp"
            onChange={event => { setForm(current => ({ ...current, url: event.target.value })) }}
          />
          <small>{t('urlHint')}</small>
        </label>
        <label className={css.field}>
          <span>{t('headersFromEnv')}</span>
          <textarea
            className={css.textarea}
            value={form.headersFromEnv}
            disabled={busy !== undefined}
            rows={3}
            placeholder={'Authorization=MCP_TOKEN'}
            onChange={event => { setForm(current => ({ ...current, headersFromEnv: event.target.value })) }}
          />
          <small>{t('headersFromEnvHint')}</small>
        </label>
        <div className={css.inline}>
          <label className={css.toggle}>
            <Switch
              checked={form.enabled}
              label={t('enabled')}
              disabled={busy !== undefined}
              onChange={next => { setForm(current => ({ ...current, enabled: next })) }}
            />
            <span>{t('enabled')}</span>
          </label>
          <label className={css.fieldSmall}>
            <span>{t('toolCallTimeoutMs')}</span>
            <Input
              type="number"
              min={1}
              step={1}
              value={form.toolCallTimeoutMs}
              disabled={busy !== undefined}
              onChange={event => { setForm(current => ({ ...current, toolCallTimeoutMs: event.target.value })) }}
            />
          </label>
        </div>
        <div className={css.actions}>
          <Button variant="primary" disabled={busy !== undefined} onClick={() => { void save() }}>
            {busy === 'save' ? t('saving') : t('save')}
          </Button>
          {editing && (
            <Button variant="ghost" disabled={busy !== undefined} onClick={resetForm}>
              {t('cancel')}
            </Button>
          )}
        </div>
      </section>

      {loading && snapshot === undefined && <p className={css.muted}>{t('loading')}</p>}
      {!loading && servers.length === 0 && configurationError === undefined && (
        <p className={css.muted}>{t('empty')}</p>
      )}

      <ul className={css.list}>
        {servers.map(server => (
          <li key={server.serverName} className={css.card}>
            <div className={css.cardHeader}>
              <div className={css.identity}>
                <strong>{server.serverName}</strong>
                <code className={css.url}>{server.url}</code>
              </div>
              <Tag tone={STATUS_TONE[server.status]}>{t(statusKey(server.status))}</Tag>
            </div>

            <p className={css.auth}>
              {server.authentication === 'none'
                ? t('authenticationNone')
                : server.authentication === 'host-managed'
                  ? t('authenticationHostManaged')
                  : t('authenticationHeaders')}
            </p>

            {server.error !== undefined && <p className={css.errorText}>{server.error}</p>}

            <div className={css.tools}>
              <span className={css.toolsLabel}>{t('tools')}</span>
              {server.tools.length === 0
                ? <span className={css.muted}>{t('noTools')}</span>
                : <span className={css.toolList}>{server.tools.map(tool => <code key={tool} className={css.tool}>{tool}</code>)}</span>}
            </div>

            <div className={css.actions}>
              <Button variant="outline" size="sm" disabled={busy !== undefined} onClick={() => { beginEdit(server) }}>
                {t('edit')}
              </Button>
              <Button
                variant="outline"
                size="sm"
                disabled={busy !== undefined || !server.enabled}
                onClick={() => { void reconnect(server.serverName) }}
              >
                {busy === `reconnect:${server.serverName}` ? t('reconnecting') : t('reconnect')}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                disabled={busy !== undefined}
                onClick={() => { void remove(server.serverName) }}
              >
                {busy === `remove:${server.serverName}` ? t('removing') : t('remove')}
              </Button>
            </div>
          </li>
        ))}
      </ul>
    </div>
  )
}
