// SPDX-License-Identifier: MIT
/**
 * Phone capability settings tab.
 *
 * The component uses the shipped Web client's React instance and Settings slot
 * renderer. Every control calls the live `phone/featureAdmin` Remote; there is
 * no local inventory, invented preset or install path.
 */

import {
  createElement as h,
  useCallback,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type ReactNode,
} from 'react'
import type {
  InjectFace,
  PropsLocale,
  PropsRuntime,
} from '@deepseek-ai/dsh-client-ui-slots'
import {
  NO_PACKAGE_INSTALL_REASON,
  type AgentPresetsValue,
  type FeatureAdminResult,
  type PluginListView,
  type PluginToggleView,
  type SkillDocumentView,
  type SkillFileView,
  type SkillMutationView,
} from '../contracts.ts'
import type { FeatureAdminTabInjected } from './register.ts'
import { sessionOptionsFromList } from './session-options.ts'
import { pluginRowCopy, type Translate } from './presentation.ts'

/** Props the shipped Settings renderer assembles for this tab. */
export type FeatureAdminSettingsProps =
  PropsRuntime<'settings.plugins.tab'>
  & PropsLocale<'settings.phoneFeatureAdmin'>
  & InjectFace<FeatureAdminTabInjected>

type InventoryRow = PluginListView['entries'][number]
type PresetRoster = Extract<AgentPresetsValue, { action: 'list' }>['roster']
type Preset = PresetRoster['presets'][number]
type PresetDocument = Extract<AgentPresetsValue, { action: 'read' }>['document']

const styles: Record<string, CSSProperties> = {
  root: { display: 'flex', flexDirection: 'column', gap: 18, padding: '4px 0 24px' },
  section: { display: 'flex', flexDirection: 'column', gap: 10, padding: 14, border: '1px solid var(--dsh-border, rgba(127,127,127,.28))', borderRadius: 12 },
  heading: { margin: 0, fontSize: 15, fontWeight: 650 },
  note: { margin: 0, fontSize: 12, lineHeight: 1.45, opacity: 0.72 },
  row: { display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderTop: '1px solid var(--dsh-border, rgba(127,127,127,.18))' },
  grow: { display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0, flex: 1 },
  mono: { fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 11, opacity: 0.66, overflowWrap: 'anywhere' },
  button: { appearance: 'none', border: '1px solid var(--dsh-border, rgba(127,127,127,.35))', background: 'var(--dsh-surface, transparent)', color: 'inherit', borderRadius: 8, padding: '6px 10px', font: 'inherit', cursor: 'pointer' },
  primary: { appearance: 'none', border: '1px solid transparent', background: 'var(--dsh-accent, #3b82f6)', color: '#fff', borderRadius: 8, padding: '6px 12px', font: 'inherit', cursor: 'pointer' },
  danger: { appearance: 'none', border: '1px solid rgba(220,38,38,.45)', background: 'transparent', color: '#dc2626', borderRadius: 8, padding: '6px 10px', font: 'inherit', cursor: 'pointer' },
  input: { width: '100%', boxSizing: 'border-box', border: '1px solid var(--dsh-border, rgba(127,127,127,.35))', background: 'transparent', color: 'inherit', borderRadius: 8, padding: '7px 9px', font: 'inherit' },
  textarea: { width: '100%', boxSizing: 'border-box', minHeight: 220, resize: 'vertical', border: '1px solid var(--dsh-border, rgba(127,127,127,.35))', background: 'transparent', color: 'inherit', borderRadius: 8, padding: 10, font: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 12, lineHeight: 1.5 },
  list: { listStyle: 'none', margin: 0, padding: 0, display: 'flex', flexDirection: 'column' },
  pill: { fontSize: 11, borderRadius: 999, padding: '1px 7px', border: '1px solid var(--dsh-border, rgba(127,127,127,.35))', opacity: 0.8 },
  error: { margin: 0, padding: 10, borderRadius: 8, background: 'rgba(220,38,38,.10)', color: '#dc2626', fontSize: 12, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
  ok: { margin: 0, padding: 10, borderRadius: 8, background: 'rgba(22,163,74,.10)', color: '#16a34a', fontSize: 12, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
  split: { display: 'grid', gridTemplateColumns: 'minmax(120px, 180px) minmax(0, 1fr)', gap: 12, alignItems: 'start' },
  pre: { margin: 0, padding: 10, borderRadius: 8, background: 'rgba(127,127,127,.10)', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 11, lineHeight: 1.45, whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
  actions: { display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center' },
}

/** Technical fallback title without hiding the full module name in the subtitle. */
function shortModule(moduleName: string): string {
  const unscoped = moduleName.startsWith('@') ? moduleName.slice(moduleName.indexOf('/') + 1) : moduleName
  return unscoped.replace(/^cordis:/, '').replace(/^dsh-(?:host-|client-)?/, '')
}

/** Render an error from the carrier or an unexpected local failure. */
function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** One installed row with a real toggle backed by the profile patch writer. */
function PluginRow({
  row, management, busy, t, onToggle,
}: {
  readonly row: InventoryRow
  readonly management: PluginListView['management']
  readonly busy: boolean
  readonly t: Translate
  readonly onToggle: (row: InventoryRow) => void
}): ReactNode {
  const copy = pluginRowCopy(t, row, management)
  return h('li', { style: styles.row, 'data-plugin-entry': row.entryId, 'data-enabled': row.enabled ? 'true' : 'false' },
    h('div', { style: styles.grow },
      h('strong', { title: row.moduleName }, shortModule(row.moduleName)),
      h('span', { style: styles.mono, title: String(row.entryId) }, String(row.entryId)),
      h('span', { style: styles.mono }, copy.phaseText),
    ),
    h('span', { style: styles.pill }, row.enabled ? t('pluginEnabled') : t('pluginDisabled')),
    copy.switchable
      ? h('button', {
        type: 'button',
        role: 'switch',
        'aria-checked': row.enabled,
        disabled: busy,
        style: styles.button,
        onClick: () => { onToggle(row) },
      }, row.enabled ? t('pluginDisable') : t('pluginEnable'))
      : h('span', {
        style: styles.pill,
        title: copy.reasonTitle,
        'data-read-only': 'true',
      }, copy.stateText),
  )
}

/** Render the settings tab. */
export function FeatureAdminSettings(props: FeatureAdminSettingsProps): ReactNode {
  const { call, sessions: sessionSource, t } = props
  const sessionState = useSyncExternalStore(sessionSource.subscribe, sessionSource.getSnapshot)
  const sessionOptions = useMemo(() => sessionOptionsFromList(sessionState), [sessionState])
  const [inventory, setInventory] = useState<PluginListView | undefined>()
  const [inventoryError, setInventoryError] = useState<string | undefined>()
  const [skills, setSkills] = useState<readonly SkillFileView[]>([])
  const [skillError, setSkillError] = useState<string | undefined>()
  const [skillName, setSkillName] = useState('')
  const [skillContent, setSkillContent] = useState('')
  const [editingExisting, setEditingExisting] = useState(false)
  const [presets, setPresets] = useState<PresetRoster | undefined>()
  const [presetError, setPresetError] = useState<string | undefined>()
  const [presetId, setPresetId] = useState('')
  const [sessionId, setSessionId] = useState('')
  const [composition, setComposition] = useState<PresetDocument | undefined>()
  const [notice, setNotice] = useState<string | undefined>()
  const [error, setError] = useState<string | undefined>()
  const [busy, setBusy] = useState(false)

  const invoke = useCallback(async <Value,>(
    method: Parameters<FeatureAdminTabInjected['call']>[0],
    args: Readonly<Record<string, unknown>> = {},
  ): Promise<FeatureAdminResult<Value> | undefined> => {
    setBusy(true)
    setError(undefined)
    try {
      return await call<Value>(method, args)
    } catch (failure) {
      setError(errorText(failure))
      return undefined
    } finally {
      setBusy(false)
    }
  }, [call])

  const loadInventory = useCallback(async (): Promise<void> => {
    setInventoryError(undefined)
    const result = await invoke<PluginListView>('pluginList')
    if (result === undefined) return
    if (!result.ok) { setInventoryError(`${result.code}: ${result.reason}`); return }
    setInventory(result.value)
    setPresetId((current) => current === '' ? result.value.agentPresets?.find?.(preset => preset.isDefault)?.id ?? '' : current)
  }, [invoke])

  const loadSkills = useCallback(async (): Promise<void> => {
    setSkillError(undefined)
    const result = await invoke<readonly SkillFileView[]>('skillsList')
    if (result === undefined) return
    if (!result.ok) { setSkillError(`${result.code}: ${result.reason}`); return }
    setSkills(result.value)
  }, [invoke])

  const loadPresets = useCallback(async (): Promise<void> => {
    setPresetError(undefined)
    const result = await invoke<AgentPresetsValue>('agentPresets', { request: { action: 'list' } })
    if (result === undefined) return
    if (!result.ok) {
      setPresetError(`${result.code}: ${result.reason}`)
      setPresets(undefined)
      return
    }
    if (result.value.action !== 'list') return
    setPresets(result.value.roster)
    setPresetId((current) => current !== '' ? current : result.value.action === 'list'
      ? result.value.roster.presets.find(preset => preset.isDefault)?.id ?? result.value.roster.presets[0]?.id ?? ''
      : '')
  }, [invoke])

  useEffect(() => {
    void loadInventory()
    void loadSkills()
    void loadPresets()
  }, [loadInventory, loadSkills, loadPresets])

  const togglePlugin = useCallback(async (row: InventoryRow): Promise<void> => {
    setNotice(undefined)
    const result = await invoke<PluginToggleView>('pluginSetEnabled', {
      entryId: row.entryId,
      enabled: !row.enabled,
    })
    if (result === undefined) return
    if (!result.ok) { setError(`${result.code}: ${result.reason}`); return }
    const changed = result.value
    setInventory((current) => current === undefined ? current : {
      ...current,
      entries: current.entries.map(entry => entry.entryId === changed.entryId
        ? { ...entry, enabled: changed.enabled }
        : entry),
    })
    setNotice(changed.changed
      ? t('pluginChanged', { name: shortModule(changed.moduleName) })
      : t('pluginUnchanged', { name: shortModule(changed.moduleName) }))
  }, [invoke, t])

  const selectSkill = useCallback(async (file: SkillFileView): Promise<void> => {
    setEditingExisting(true)
    setSkillName(file.name)
    setSkillError(undefined)
    const result = await invoke<SkillDocumentView>('skillsRead', { name: file.name })
    if (result === undefined) return
    if (!result.ok) { setSkillError(`${result.code}: ${result.reason}`); return }
    setSkillContent(result.value.content)
  }, [invoke])

  const startNewSkill = useCallback((): void => {
    setEditingExisting(false)
    setSkillName('')
    setSkillContent('')
    setSkillError(undefined)
  }, [])

  const saveSkill = useCallback(async (): Promise<void> => {
    setSkillError(undefined)
    const result = await invoke<SkillMutationView>('skillsWrite', { name: skillName, content: skillContent })
    if (result === undefined) return
    if (!result.ok) { setSkillError(`${result.code}: ${result.reason}`); return }
    setNotice(t('skillSaved', { name: result.value.name }))
    setEditingExisting(true)
    await loadSkills()
  }, [invoke, loadSkills, skillContent, skillName, t])

  const deleteSkill = useCallback(async (): Promise<void> => {
    setSkillError(undefined)
    const result = await invoke<SkillMutationView>('skillsDelete', { name: skillName })
    if (result === undefined) return
    if (!result.ok) { setSkillError(`${result.code}: ${result.reason}`); return }
    setNotice(t('skillDeleted', { name: result.value.name }))
    startNewSkill()
    await loadSkills()
  }, [invoke, loadSkills, skillName, startNewSkill, t])

  const readPreset = useCallback(async (preset: Preset): Promise<void> => {
    setComposition(undefined)
    const result = await invoke<AgentPresetsValue>('agentPresets', { request: { action: 'read', presetId: preset.id } })
    if (result === undefined) return
    if (!result.ok) { setPresetError(`${result.code}: ${result.reason}`); return }
    if (result.value.action === 'read') setComposition(result.value.document)
  }, [invoke])

  const sessions = sessionOptions
  const targetSession = sessionId !== ''
    ? sessions.find(session => session.id === sessionId)
    : sessions.find(session => session.blank) ?? sessions[0]
  const applyPreset = useCallback(async (): Promise<void> => {
    setPresetError(undefined)
    if (targetSession === undefined) { setPresetError(t('presetNoSessions')); return }
    const chosen = presetId !== '' ? presetId : presets?.presets.find(preset => preset.isDefault)?.id
    if (chosen === undefined) { setPresetError(t('presetNoPresets')); return }
    const result = await invoke<AgentPresetsValue>('agentPresets', {
      request: { action: 'select', sessionId: targetSession.id, presetId: chosen },
    })
    if (result === undefined) return
    if (!result.ok) { setPresetError(`${result.code}: ${result.reason}`); return }
    if (result.value.action === 'select') setNotice(t('presetApplied', { preset: result.value.presetId }))
  }, [invoke, presetId, presets, t, targetSession])

  const rows = inventory?.entries ?? []
  const restart = inventory?.platform.restartRequiredForPluginChanges ?? true
  const installReason = inventory?.platform.installReason ?? NO_PACKAGE_INSTALL_REASON
  const management = inventory?.management ?? { available: true }

  // App-level actions the DSH page cannot perform itself. They post to the
  // native settings bridge the same way the model tab's directory button does;
  // no second transport or settings store exists here.
  const postNativeAction = (action: string): void => {
    const handler = (globalThis as {
      webkit?: { messageHandlers?: Record<string, { postMessage: (body: unknown) => void }> }
    }).webkit?.messageHandlers?.pdshOpenModelSettings
    handler?.postMessage({ v: 1, action })
  }

  return h('div', { style: styles.root },
    h('section', { style: styles.section },
      h('h2', { style: styles.heading }, t('device')),
      h('p', { style: styles.note }, t('deviceHint')),
      h('div', { style: styles.actions },
        h('button', {
          type: 'button',
          style: styles.button,
          onClick: () => postNativeAction('open-search-settings'),
        }, t('deviceSearch')),
        h('button', {
          type: 'button',
          style: styles.button,
          onClick: () => postNativeAction('enter-native-recovery'),
        }, t('deviceNative')),
      ),
    ),

    h('section', { style: styles.section },
      h('h2', { style: styles.heading }, t('title')),
      h('p', { style: styles.note }, t('intro')),
      restart ? h('p', { style: styles.note }, t('restartNotice')) : null,
      h('p', { style: styles.note, title: installReason }, t('platformBoundary')),
      h('div', { style: styles.actions },
        h('button', { type: 'button', style: styles.button, disabled: busy, onClick: () => { void loadInventory() } }, busy ? t('busy') : t('refresh')),
      ),
      error === undefined ? null : h('p', { style: styles.error, role: 'alert' }, `${t('error')}: ${error}`),
      notice === undefined ? null : h('p', { style: styles.ok, role: 'status' }, notice),
      inventoryError === undefined ? null : h('p', { style: styles.error, role: 'status' }, inventoryError),
    ),

    h('section', { style: styles.section },
      h('h2', { style: styles.heading }, t('plugins')),
      management.available
        ? null
        : h('p', { style: styles.note, title: management.reason }, t('managementUnavailable')),
      rows.length === 0
        ? h('p', { style: styles.note }, t('loading'))
        : h('ul', { style: styles.list }, rows.map(row => h(PluginRow, {
          key: String(row.entryId),
          row,
          management,
          busy,
          t,
          onToggle: (target: InventoryRow) => { void togglePlugin(target) },
        }))),
    ),

    h('section', { style: styles.section },
      h('h2', { style: styles.heading }, t('skills')),
      h('p', { style: styles.note }, t('skillsRoot', { root: inventory?.platform.skillsRoot ?? '/dsh/home/skills' })),
      h('p', { style: styles.note }, t('skillsHint')),
      skillError === undefined ? null : h('p', { style: styles.error, role: 'status' }, skillError),
      h('div', { style: styles.split },
        h('div', { style: styles.actions },
          skills.length === 0 ? h('p', { style: styles.note }, t('skillEmpty')) : null,
          h('div', { style: { display: 'flex', flexDirection: 'column', gap: 4, width: '100%' } },
            skills.map(file => h('button', {
              key: file.name,
              type: 'button',
              style: editingExisting && skillName === file.name ? styles.primary : styles.button,
              disabled: busy,
              onClick: () => { void selectSkill(file) },
            }, file.skillName)),
            h('button', { type: 'button', style: styles.button, disabled: busy, onClick: startNewSkill }, t('skillNew')),
          ),
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: 8, minWidth: 0 } },
          h('label', { style: styles.note }, t('skillName'),
            h('input', {
              style: styles.input,
              value: skillName,
              disabled: busy || editingExisting,
              placeholder: 'my-skill.md',
              onChange: (event: { target: { value: string } }) => { setSkillName(event.target.value) },
            }),
          ),
          h('label', { style: styles.note }, t('skillContent'),
            h('textarea', {
              style: styles.textarea,
              value: skillContent,
              disabled: busy,
              placeholder: t('skillTemplate', { name: skillName === '' ? 'my-skill' : skillName.replace(/\.md$/u, '') }),
              onChange: (event: { target: { value: string } }) => { setSkillContent(event.target.value) },
            }),
          ),
          h('div', { style: styles.actions },
            h('button', { type: 'button', style: styles.primary, disabled: busy || skillName === '', onClick: () => { void saveSkill() } }, t('skillSave')),
            editingExisting ? h('button', { type: 'button', style: styles.danger, disabled: busy, onClick: () => { void deleteSkill() } }, t('skillDelete')) : null,
          ),
        ),
      ),
    ),

    h('section', { style: styles.section },
      h('h2', { style: styles.heading }, t('presets')),
      presetError === undefined ? null : h('p', { style: styles.error, role: 'status' }, t('presetUnavailable', { reason: presetError })),
      presets === undefined
        ? h('p', { style: styles.note }, presetError === undefined ? t('loading') : t('presetNoPresets'))
        : h('div', { style: { display: 'flex', flexDirection: 'column', gap: 6 } },
          h('ul', { style: styles.list }, presets.presets.map(preset => h('li', { key: preset.id, style: styles.row },
            h('div', { style: styles.grow },
              h('strong', {}, preset.name ?? preset.id),
              h('span', { style: styles.mono }, preset.id),
              preset.broken === undefined ? null : h('span', { style: styles.error }, `${t('presetBroken')}: ${preset.broken}`),
            ),
            preset.isDefault ? h('span', { style: styles.pill }, t('presetDefault')) : null,
            h('button', { type: 'button', style: styles.button, disabled: busy, onClick: () => { void readPreset(preset) } }, t('presetView')),
          ))),
          sessions.length === 0
            ? h('p', { style: styles.note }, t('presetNoSessions'))
            : h('div', { style: styles.actions },
              h('select', {
                style: styles.input,
                value: targetSession?.id ?? '',
                disabled: busy,
                'aria-label': t('presetSessions'),
                onChange: (event: { target: { value: string } }) => { setSessionId(event.target.value) },
              }, sessions.map(session => h('option', { key: session.id, value: session.id },
                `${session.title} · ${session.blank ? t('sessionBlank') : t('sessionStarted')}`))),
              h('select', {
                style: styles.input,
                value: presetId,
                disabled: busy,
                'aria-label': t('presets'),
                onChange: (event: { target: { value: string } }) => { setPresetId(event.target.value) },
              }, presets.presets.map(preset => h('option', { key: preset.id, value: preset.id }, preset.name ?? preset.id))),
              h('button', { type: 'button', style: styles.primary, disabled: busy, onClick: () => { void applyPreset() } }, t('presetApply')),
            ),
          composition === undefined ? null : h('div', { style: { display: 'flex', flexDirection: 'column', gap: 6 } },
            h('strong', { style: styles.heading }, `${t('composition')}: ${composition.agentPreset}`),
            h('pre', { style: styles.pre }, composition.content),
          ),
        ),
    ),
  )
}
