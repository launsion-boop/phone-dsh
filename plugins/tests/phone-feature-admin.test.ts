// SPDX-License-Identifier: MIT
/**
 * Real behaviour checks for @phone-dsh/dsh-feature-admin.
 *
 * The test imports the checkout's own app-boot/plugin-manager TypeScript with
 * Node's type transform, so the profile patch is parsed by the same code DSH
 * boots. No pnpm, network, DSH home or browser is touched.
 */

import assert from 'node:assert/strict'
import { createRequire, registerHooks, stripTypeScriptTypes } from 'node:module'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { test } from 'node:test'
import type { FeatureAdminSessionView } from '../phone-feature-admin/src/contracts.ts'

const HERE = dirname(fileURLToPath(import.meta.url))
const PLUGIN_ROOT = resolve(HERE, '..')
const MODULE_ROOT = join(PLUGIN_ROOT, 'phone-feature-admin')
const CHECKOUT = process.env.PDSH_DSH_CHECKOUT ?? '/dsh-reference'
const APP_BOOT_SOURCE = join(CHECKOUT, 'packages/boot/app-boot/src/index.ts')
const PLUGIN_MANAGER_PATCH = join(CHECKOUT, 'packages/boot/plugin-manager/src/patch.ts')
assert.ok(existsSync(APP_BOOT_SOURCE), `PDSH_DSH_CHECKOUT must contain ${APP_BOOT_SOURCE}`)
assert.ok(existsSync(PLUGIN_MANAGER_PATCH), `PDSH_DSH_CHECKOUT must contain ${PLUGIN_MANAGER_PATCH}`)

/** Resolve DSH runtime packages from this checkout's install, then the host install. */
function dshRequire(): NodeJS.Require {
  const candidates = [
    join(PLUGIN_ROOT, 'package.json'),
    join(CHECKOUT, 'package.json'),
    join(dirname(process.execPath), '..', 'lib', 'node_modules', '@deepseek-ai', 'dsh', 'package.json'),
    ...typeof process.env.PDSH_DSH_INSTALL === 'string' && process.env.PDSH_DSH_INSTALL !== ''
      ? [process.env.PDSH_DSH_INSTALL]
      : [],
  ]
  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue
    try {
      const require = createRequire(candidate)
      require.resolve('@deepseek-ai/cordis')
      return require
    } catch {
      // Try the next installation.
    }
  }
  throw new Error('no installed @deepseek-ai/dsh packages; run the pinned install or use the host installation')
}

const requireFromDsh = dshRequire()
const checkoutUrl = pathToFileURL(CHECKOUT).href
const appBootUrl = pathToFileURL(APP_BOOT_SOURCE).href
const patchUrl = pathToFileURL(PLUGIN_MANAGER_PATCH).href
const bare = (specifier: string): boolean => !specifier.startsWith('.')
  && !specifier.startsWith('/') && !specifier.startsWith('node:') && !specifier.startsWith('file:')

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === '@deepseek-ai/dsh-app-boot') {
      return { url: appBootUrl, shortCircuit: true }
    }
    if (specifier === '@deepseek-ai/dsh-plugin-manager/src/patch.ts') {
      return { url: patchUrl, shortCircuit: true }
    }
    try {
      return nextResolve(specifier, context)
    } catch (error) {
      if (!bare(specifier)) throw error
      try {
        return { url: pathToFileURL(requireFromDsh.resolve(specifier)).href, shortCircuit: true }
      } catch {
        throw error
      }
    }
  },
  load(url, context, nextLoad) {
    if (url.startsWith(checkoutUrl) && url.endsWith('.ts')) {
      const source = readFileSync(fileURLToPath(url), 'utf8')
      return {
        format: 'module',
        source: stripTypeScriptTypes(source, { mode: 'transform' }),
        shortCircuit: true,
      }
    }
    return nextLoad(url, context)
  },
})

const { Context } = await import('@deepseek-ai/cordis')
const { SessionStore } = await import('@deepseek-ai/dsh-session')
const { SkillRegistry } = await import('@deepseek-ai/dsh-skill')
const { remoteMethods } = await import('@deepseek-ai/dsh-typert-protocol')
const { loadOverlayPatches } = await import('@deepseek-ai/dsh-app-boot')
const { applyEntryPatches } = await import('@deepseek-ai/cordis-plugin-include')
const { PhoneFeatureAdmin } = await import(pathToFileURL(join(MODULE_ROOT, 'src', 'service.ts')).href)
const { registerFeatureAdminTab, FEATURE_ADMIN_TAB_ID } = await import(
  pathToFileURL(join(MODULE_ROOT, 'src', 'client', 'register.ts')).href
)
const { callFeatureAdmin } = await import(pathToFileURL(join(MODULE_ROOT, 'src', 'client', 'api.ts')).href)
const { sessionOptionsFromList } = await import(
  pathToFileURL(join(MODULE_ROOT, 'src', 'client', 'session-options.ts')).href
)
const { pluginPhaseLabel, pluginRowCopy } = await import(
  pathToFileURL(join(MODULE_ROOT, 'src', 'client', 'presentation.ts')).href
)
const { en, zh } = await import(
  pathToFileURL(join(MODULE_ROOT, 'src', 'client', 'locales.ts')).href
)
const {
  pluginToggleAvailability,
  protectedPluginReason,
  TOGGLEABLE_PLUGIN_MODULES,
} = await import(pathToFileURL(join(MODULE_ROOT, 'src', 'protection.ts')).href)

const PHONE_PROFILE_PATCH = join(PLUGIN_ROOT, 'profile', 'phone.worker.cordis.patch.yml')
const BASE_BUNDLE_PATCH = join(CHECKOUT, 'packages/bundle/base/cordis.patch.yml')

type Profile = {
  name: string
  dir: string
  patchPath: string
  installAnchor: string
  cwd: string
  home: string
  startedBundles: readonly string[]
  overlays: readonly unknown[]
  telemetryDisabledEnv: string | undefined
}

type Fixture = {
  home: string
  profile: Profile
  patchPath: string
  dispose: () => void
}

/** A real profile directory: one bundle layer plus the editable user patch. */
function profileFixture(
  patchText: string,
  options: { baseRows?: readonly object[]; homePatchText?: string; overlays?: readonly unknown[] } = {},
): Fixture {
  const home = mkdtempSync(join(tmpdir(), 'pdsh-feature-admin-'))
  const dir = join(home, 'profiles', 'web')
  const installAnchor = join(home, 'package.json')
  writeFileSync(installAnchor, '{"name":"installation","version":"1.0.0","dependencies":{}}\n')
  mkdirSync(join(dir, 'node_modules', 'bundle'), { recursive: true })
  writeFileSync(join(dir, 'package.json'), JSON.stringify({
    name: 'web',
    version: '1.0.0',
    dsh: { profile: { bundles: ['bundle'] } },
  }))
  writeFileSync(join(dir, 'node_modules', 'bundle', 'package.json'), JSON.stringify({
    name: 'bundle',
    version: '1.0.0',
    dsh: { bundle: { patch: './cordis.patch.yml' } },
  }))
  writeFileSync(join(dir, 'node_modules', 'bundle', 'cordis.patch.yml'), JSON.stringify([
    { insert: [{ id: 'tool', name: 'package' }, { id: 'other', name: 'other-package' }, ...options.baseRows ?? []] },
  ]))
  const patchPath = join(dir, 'cordis.patch.yml')
  writeFileSync(patchPath, patchText)
  if (options.homePatchText !== undefined) writeFileSync(join(home, 'cordis.patch.yml'), options.homePatchText)
  return {
    home,
    patchPath,
    profile: {
      name: 'web',
      dir,
      patchPath,
      installAnchor,
      cwd: home,
      home,
      startedBundles: ['bundle'],
      overlays: options.overlays ?? [],
      telemetryDisabledEnv: undefined,
    },
    dispose: () => { rmSync(home, { recursive: true, force: true }) },
  }
}

type FakeInventoryRow = { entryId: string; moduleName: string; enabled: boolean; fiberPhase: string | null }

function inventoryOf(entries: readonly FakeInventoryRow[], managementAvailable = true) {
  return {
    async list() {
      return { entries, managementAvailable }
    },
  }
}

/** Create a real Cordis context with only the optional services a test supplies. */
function adminWith(options: {
  profile?: Profile
  inventory?: ReturnType<typeof inventoryOf>
  skills?: object
  agentPresets?: object
  agents?: object
  typert?: object
  skillsRoot?: string
  /** Real attached Sessions created in a real SessionStore for this context. */
  sessionIds?: readonly string[]
  /** Create the subagent rows too; the Host list keeps their real origin. */
  subagentSessionIds?: readonly string[]
  /** Expose the real SessionStore through a Host sessionController catalog. */
  hostSessionCatalog?: boolean
}): { ctx: any; service: any } {
  const ctx = new Context()
  let store: any
  if (options.sessionIds !== undefined || options.subagentSessionIds !== undefined) {
    store = new SessionStore(ctx)
    for (const id of options.sessionIds ?? []) store.create(id)
    for (const id of options.subagentSessionIds ?? []) {
      store.create(id, { meta: { origin: 'subagent', cwd: '/' } })
    }
  }
  if (options.hostSessionCatalog === true && store !== undefined) {
    ctx.provide('sessionController', {
      async list() {
        return {
          items: store.list().map((session: any) => ({
            sessionId: session.id,
            origin: session.header.origin,
            blank: session.seq === 0,
            running: false,
            agentAvailable: false,
            updatedAt: 0,
          })),
        }
      },
    })
  }
  if (options.profile !== undefined) ctx.provide('profileContext', options.profile)
  if (options.inventory !== undefined) ctx.provide('pluginInventory', options.inventory)
  if (options.skills !== undefined) ctx.provide('skills', options.skills)
  if (options.agentPresets !== undefined) ctx.provide('agentPresets', options.agentPresets)
  if (options.agents !== undefined) ctx.provide('agents', options.agents)
  if (options.typert !== undefined) ctx.provide('typert', options.typert)
  const service = new PhoneFeatureAdmin(ctx, options.skillsRoot === undefined ? {} : { skillsRoot: options.skillsRoot })
  return { ctx, service }
}

/** Read the one profile patch row by id through the checkout's parser. */
function loadedPatchRow(patchPath: string, id: string): Record<string, any> {
  const rows = loadOverlayPatches('phone-feature-admin-test', patchPath) as Array<Record<string, any>>
  const row = rows.find(entry => entry.id === id)
  assert.ok(row !== undefined, `patch has no ${id} row`)
  return row
}

/** Bind one real dictionary the same way the shipped locale service binds it. */
function translateWith(dictionary: Readonly<Record<string, string>>) {
  return (key: string, params: Readonly<Record<string, string | number>> = {}): string =>
    (dictionary[key] ?? key).replace(/\{(\w+)\}/gu, (_, name: string) => String(params[name] ?? `{${name}}`))
}

test('pluginSetEnabled writes a real profile patch, preserves comments/!!js, and round-trips', async (t) => {
  const fixture = profileFixture([
    '# phone feature admin fixture',
    '- id: tool',
    '  name: package',
    '  config:',
    '    value: !!js process.platform',
    '  disabled: false # availability',
    '- id: other',
    '  config:',
    '    keep: true',
    '',
  ].join('\n'))
  t.after(fixture.dispose)
  const { ctx, service } = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf([{ entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' }]),
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const disabled = await service.pluginSetEnabled('tool', false)
  assert.equal(disabled.ok, true, JSON.stringify(disabled))
  assert.equal(disabled.value.changed, true)
  assert.equal(disabled.value.restartRequired, true)
  const afterDisable = readFileSync(fixture.patchPath, 'utf8')
  assert.match(afterDisable, /# phone feature admin fixture/)
  assert.match(afterDisable, /!!js process\.platform/)
  assert.match(afterDisable, /# availability/)
  const disabledRow = loadedPatchRow(fixture.patchPath, 'tool')
  assert.equal(disabledRow.disabled, true)
  assert.equal(disabledRow.config.value.__jsExpr, 'process.platform')

  const noop = await service.pluginSetEnabled('tool', false)
  assert.equal(noop.ok, true, JSON.stringify(noop))
  assert.equal(noop.value.changed, false)
  assert.equal(noop.value.restartRequired, false)
  assert.equal(readFileSync(fixture.patchPath, 'utf8'), afterDisable)

  const enabled = await service.pluginSetEnabled('tool', true)
  assert.equal(enabled.ok, true, JSON.stringify(enabled))
  assert.equal(enabled.value.changed, true)
  const enabledRow = loadedPatchRow(fixture.patchPath, 'tool')
  assert.equal(enabledRow.disabled, false)
  assert.equal(enabledRow.config.value.__jsExpr, 'process.platform')
  const afterEnable = readFileSync(fixture.patchPath, 'utf8')
  assert.match(afterEnable, /# phone feature admin fixture/)
  assert.match(afterEnable, /# availability/)

  const disabledAgain = await service.pluginSetEnabled('tool', false)
  assert.equal(disabledAgain.ok, true, JSON.stringify(disabledAgain))
  assert.equal(loadedPatchRow(fixture.patchPath, 'tool').disabled, true)
})

test('concurrent pluginSetEnabled calls serialize on the official profile lock and keep both writes', async (t) => {
  const fixture = profileFixture([
    '# concurrent fixture',
    '- id: tool',
    '  name: package',
    '  config:',
    '    owner: !!js process.platform',
    '- id: other',
    '  name: other-package',
    '  config:',
    '    owner: !!js process.arch',
    '',
  ].join('\n'))
  t.after(fixture.dispose)
  const { ctx, service } = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf([
      { entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' },
      { entryId: 'other', moduleName: 'other-package', enabled: true, fiberPhase: 'active' },
    ]),
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const [tool, other] = await Promise.all([
    service.pluginSetEnabled('tool', false),
    service.pluginSetEnabled('other', false),
  ])
  for (const result of [tool, other]) {
    assert.equal(result.ok, true, JSON.stringify(result))
    assert.equal(result.value.changed, true)
    assert.equal(result.value.restartRequired, true)
    assert.equal(result.value.patchPath, fixture.patchPath)
  }

  assert.equal(loadedPatchRow(fixture.patchPath, 'tool').disabled, true)
  assert.equal(loadedPatchRow(fixture.patchPath, 'other').disabled, true)
  const text = readFileSync(fixture.patchPath, 'utf8')
  assert.match(text, /# concurrent fixture/)
  assert.match(text, /!!js process\.platform/)
  assert.match(text, /!!js process\.arch/)
  assert.equal(existsSync(join(fixture.profile.dir, 'package.json.lock')), false)
})

test('pluginSetEnabled restores both patch layers on a conflicting overlay and keeps a concurrent commit', async (t) => {
  const profileText = [
    '# rollback fixture',
    '- id: tool',
    '  name: package',
    '  config:',
    '    owner: !!js process.platform',
    '- id: other',
    '  name: other-package',
    '',
  ].join('\n')
  const homeText = [
    '# home rollback fixture',
    '- id: keep',
    '  config:',
    '    arch: !!js process.arch',
    '',
  ].join('\n')
  const fixture = profileFixture(profileText, {
    homePatchText: homeText,
    // The launch overlay wins over every persisted layer, so the write can
    // never reach the requested state and must be rolled back.
    overlays: [{ id: 'tool', disabled: true }],
  })
  t.after(fixture.dispose)

  const entries = [
    { entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' },
    { entryId: 'other', moduleName: 'other-package', enabled: true, fiberPhase: 'active' },
  ]
  let firstRead = true
  let otherHasLock!: () => void
  const locked = new Promise<void>((resolve) => { otherHasLock = resolve })
  let releaseOther!: () => void
  const gate = new Promise<void>((resolve) => { releaseOther = resolve })
  const inventory = {
    async list() {
      if (firstRead) {
        // The first toggle is already holding the shared profile lock; let the
        // second enter only after the first patch is committed.
        firstRead = false
        otherHasLock()
        await gate
      }
      return { entries, managementAvailable: true }
    },
  }
  const { ctx, service } = adminWith({ profile: fixture.profile, inventory })
  t.after(async () => { await ctx.fiber.dispose() })

  const otherRun = service.pluginSetEnabled('other', false)
  await locked
  const toolRun = service.pluginSetEnabled('tool', true)
  releaseOther()
  const [other, tool] = await Promise.all([otherRun, toolRun])

  assert.equal(other.ok, true, JSON.stringify(other))
  assert.equal(other.value.changed, true)
  assert.equal(tool.ok, false, JSON.stringify(tool))
  assert.equal(tool.code, 'conflict')
  assert.match(tool.reason, /overlay/)

  // The failed enable restored the home layer byte-for-byte and left the
  // successful concurrent disable untouched in the profile layer.
  assert.equal(readFileSync(join(fixture.home, 'cordis.patch.yml'), 'utf8'), homeText)
  const profileAfter = readFileSync(fixture.patchPath, 'utf8')
  assert.match(profileAfter, /# rollback fixture/)
  assert.match(profileAfter, /!!js process\.platform/)
  assert.equal(loadedPatchRow(fixture.patchPath, 'tool').disabled, undefined)
  assert.equal(loadedPatchRow(fixture.patchPath, 'other').disabled, true)
  assert.equal(existsSync(join(fixture.profile.dir, 'package.json.lock')), false)
})

test('pluginSetEnabled targets the home layer for rows only the home patch introduces', async (t) => {
  const fixture = profileFixture('[]\n', {
    homePatchText: [
      '- insert:',
      '    - id: home-only',
      '      name: home-package',
      '',
    ].join('\n'),
  })
  t.after(fixture.dispose)
  const { ctx, service } = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf([{ entryId: 'home-only', moduleName: 'home-package', enabled: true, fiberPhase: 'active' }]),
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const result = await service.pluginSetEnabled('home-only', false)
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(result.value.patchPath, join(fixture.home, 'cordis.patch.yml'))
  assert.equal(result.value.restartRequired, true)
  const homePatch = join(fixture.home, 'cordis.patch.yml')
  const rows = loadOverlayPatches('phone-feature-admin-test', homePatch)
  const bundle = loadOverlayPatches('phone-feature-admin-test', join(fixture.profile.dir, 'node_modules', 'bundle', 'cordis.patch.yml'))
  const profile = loadOverlayPatches('phone-feature-admin-test', fixture.patchPath)
  const composed = applyEntryPatches([], [...(bundle ?? []), ...(profile ?? []), ...(rows ?? [])], () => {}) as Array<Record<string, any>>
  const composedRow = composed.find(row => row.id === 'home-only')
  assert.equal(composedRow?.disabled, true)
})

test('pluginSetEnabled repairs a same-id profile+home override the official writer would delete', async (t) => {
  const fixture = profileFixture([
    '# profile layer still disables the row',
    '- id: tool',
    '  name: package',
    '  disabled: true',
    '',
  ].join('\n'), {
    homePatchText: [
      '# home layer',
      '- id: tool',
      '  disabled: true',
      '- id: other',
      '  config:',
      '    keep: !!js process.platform',
      '',
    ].join('\n'),
  })
  t.after(fixture.dispose)
  const { ctx, service } = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf([{ entryId: 'tool', moduleName: 'package', enabled: false, fiberPhase: 'inactive' }]),
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const enabled = await service.pluginSetEnabled('tool', true)
  assert.equal(enabled.ok, true, JSON.stringify(enabled))
  assert.equal(enabled.value.changed, true)
  assert.equal(enabled.value.restartRequired, true)
  assert.equal(enabled.value.patchPath, join(fixture.home, 'cordis.patch.yml'))

  const homePatch = join(fixture.home, 'cordis.patch.yml')
  const homeText = readFileSync(homePatch, 'utf8')
  assert.match(homeText, /# home layer/)
  assert.match(homeText, /!!js process\.platform/)
  // The official writer deleted the switch-only override, then the repair
  // path re-added it with the requested literal state and no name key.
  const repairedHomeRow = loadedPatchRow(homePatch, 'tool')
  assert.equal(repairedHomeRow.disabled, false)
  assert.equal(repairedHomeRow.name, undefined)
  assert.equal(loadedPatchRow(fixture.patchPath, 'tool').disabled, true)
  const composed = (): Array<Record<string, any>> => applyEntryPatches([], [
    ...(loadOverlayPatches('phone-feature-admin-test', join(fixture.profile.dir, 'node_modules', 'bundle', 'cordis.patch.yml')) ?? []),
    ...(loadOverlayPatches('phone-feature-admin-test', fixture.patchPath) ?? []),
    ...(loadOverlayPatches('phone-feature-admin-test', homePatch) ?? []),
  ], () => {}) as Array<Record<string, any>>
  assert.equal(composed().findLast(row => row.id === 'tool')?.disabled, false)

  const disabled = await service.pluginSetEnabled('tool', false)
  assert.equal(disabled.ok, true, JSON.stringify(disabled))
  assert.equal(composed().findLast(row => row.id === 'tool')?.disabled, true)
})

test('pluginList marks self-lockout rows read-only and refuses to toggle them', async (t) => {
  const fixture = profileFixture('[]\n')
  t.after(fixture.dispose)
  const protectedRows = [
    { entryId: 'feature-admin', moduleName: '@phone-dsh/dsh-feature-admin', enabled: true, fiberPhase: 'active' },
    { entryId: 'phone-surface', moduleName: '@phone-dsh/dsh-surface-phone', enabled: true, fiberPhase: 'active' },
    { entryId: 'webserver', moduleName: '@deepseek-ai/dsh-host-webserver', enabled: true, fiberPhase: 'active' },
    { entryId: 'plugin-inventory', moduleName: '@deepseek-ai/dsh-host-plugin-inventory', enabled: true, fiberPhase: 'active' },
    { entryId: 'gateway', moduleName: '@deepseek-ai/dsh-api-gateway', enabled: true, fiberPhase: 'active' },
    { entryId: 'typert', moduleName: '@deepseek-ai/dsh-typert-registry', enabled: true, fiberPhase: 'active' },
    { entryId: 'remote-access', moduleName: '@deepseek-ai/dsh-api-remote-access', enabled: true, fiberPhase: 'active' },
    { entryId: 'api-remotes', moduleName: '@deepseek-ai/dsh-api-remotes', enabled: true, fiberPhase: 'active' },
    { entryId: 'session-controller', moduleName: '@deepseek-ai/dsh-api-session-controller', enabled: true, fiberPhase: 'active' },
    { entryId: 'settings', moduleName: '@deepseek-ai/dsh-settings', enabled: true, fiberPhase: 'active' },
    { entryId: 'settings-controller', moduleName: '@deepseek-ai/dsh-api-settings-controller', enabled: true, fiberPhase: 'active' },
    { entryId: 'modules', moduleName: '@deepseek-ai/dsh-client-modules', enabled: true, fiberPhase: 'active' },
    { entryId: 'connection', moduleName: '@deepseek-ai/dsh-client-connection', enabled: true, fiberPhase: 'active' },
    { entryId: 'locale', moduleName: '@deepseek-ai/dsh-client-locale', enabled: true, fiberPhase: 'active' },
    { entryId: 'ui-layout', moduleName: '@deepseek-ai/dsh-client-ui-layout', enabled: true, fiberPhase: 'active' },
    { entryId: 'ui-renderer', moduleName: '@deepseek-ai/dsh-client-ui-renderer', enabled: true, fiberPhase: 'active' },
    { entryId: 'ui-settings', moduleName: '@deepseek-ai/dsh-client-ui-settings', enabled: true, fiberPhase: 'active' },
    { entryId: 'ui-settings-plugins', moduleName: '@deepseek-ai/dsh-client-ui-settings-plugins', enabled: true, fiberPhase: 'active' },
    { entryId: 'ui-settings-inventory', moduleName: '@deepseek-ai/dsh-client-ui-settings-plugin-inventory', enabled: true, fiberPhase: 'active' },
    { entryId: 'agent-presets', moduleName: '@deepseek-ai/dsh-agent-preset-registry', enabled: true, fiberPhase: 'active' },
    { entryId: 'agent', moduleName: '@deepseek-ai/dsh-agent', enabled: true, fiberPhase: 'active' },
    { entryId: 'session', moduleName: '@deepseek-ai/dsh-session', enabled: true, fiberPhase: 'active' },
    { entryId: 'skill', moduleName: '@deepseek-ai/dsh-skill', enabled: true, fiberPhase: 'active' },
  ] as const
  const optionalRows = [
    { entryId: 'office', moduleName: '@deepseek-ai/dsh-office-to-pdf', enabled: true, fiberPhase: 'active' },
    { entryId: 'schedule', moduleName: '@deepseek-ai/dsh-schedule', enabled: true, fiberPhase: 'active' },
    { entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' },
  ] as const
  const { ctx, service } = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf([...protectedRows, ...optionalRows]),
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const listed = await service.pluginList()
  assert.equal(listed.ok, true, JSON.stringify(listed))
  for (const expected of protectedRows) {
    const row = listed.value.entries.find((entry: any) => entry.entryId === expected.entryId)
    assert.ok(row, `missing inventory row ${expected.entryId}`)
    assert.ok(typeof row.readOnlyReason === 'string' && row.readOnlyReason.length > 0, `${expected.entryId} has no protection reason`)
    const availability = pluginToggleAvailability(row.moduleName, row.readOnlyReason)
    assert.equal(availability.available, false, `${expected.entryId} still offers a switch`)
    assert.equal(availability.reason, row.readOnlyReason)
  }
  for (const expected of optionalRows) {
    const row = listed.value.entries.find((entry: any) => entry.entryId === expected.entryId)
    assert.ok(row, `missing inventory row ${expected.entryId}`)
    assert.equal(row.readOnlyReason, undefined, `${expected.entryId} was protected unexpectedly`)
    assert.equal(pluginToggleAvailability(row.moduleName).available, true)
  }
  assert.equal(pluginToggleAvailability('@deepseek-ai/dsh-host-plugin-inventory').available, false)
  assert.equal(pluginToggleAvailability('@deepseek-ai/dsh-client-ui-settings-general').available, false)
  assert.match(protectedPluginReason('@phone-dsh/dsh-surface-phone') ?? '', /surface/)

  for (const expected of protectedRows) {
    const refused = await service.pluginSetEnabled(expected.entryId, false)
    assert.equal(refused.ok, false, `accepted protected row ${expected.entryId}`)
    assert.equal(refused.code, 'conflict')
  }
  assert.equal(readFileSync(fixture.patchPath, 'utf8'), '[]\n')

  const toggled = await service.pluginSetEnabled('tool', false)
  assert.equal(toggled.ok, true, JSON.stringify(toggled))
  assert.equal(loadedPatchRow(fixture.patchPath, 'tool').disabled, true)
})

test('zh-CN plugin row copy localizes protection and phase and keeps the English reason title-only', () => {
  const reason = 'The webserver is the only /api carrier; disabling it would make the settings page unreachable after restart.'
  const row = {
    entryId: 'webserver',
    moduleName: '@deepseek-ai/dsh-host-webserver',
    enabled: true,
    fiberPhase: 'active',
    readOnlyReason: reason,
  }
  const zhT = translateWith(zh)
  const copy = pluginRowCopy(zhT, row as any, { available: true })
  assert.equal(copy.switchable, false)
  assert.equal(copy.stateText, '受保护')
  assert.equal(copy.phaseText, '@deepseek-ai/dsh-host-webserver · 运行状态: 运行中')
  assert.doesNotMatch(copy.phaseText, /active|unobserved/i)
  assert.doesNotMatch(copy.stateText, /webserver|carrier|protected/i)
  assert.equal(copy.reasonTitle, reason)

  const phases = [
    ['pending', '等待加载'],
    ['loading', '加载中'],
    ['active', '运行中'],
    ['failed', '加载失败'],
    ['unloading', '正在卸载'],
    [null, '无运行实例'],
    ['future-phase', '未知'],
  ] as const
  for (const [phase, label] of phases) {
    assert.equal(pluginPhaseLabel(zhT, phase as any), label)
  }

  const unavailable = pluginRowCopy(zhT, {
    ...row,
    moduleName: 'package',
    readOnlyReason: undefined,
    fiberPhase: null,
  } as any, { available: false, reason: 'profileContext is not available in this Host.' })
  assert.equal(unavailable.switchable, false)
  assert.equal(unavailable.stateText, '不可用')
  assert.equal(unavailable.reasonTitle, 'profileContext is not available in this Host.')
  assert.doesNotMatch(unavailable.stateText, /profileContext|Unavailable|Protected/i)
  assert.doesNotMatch(unavailable.phaseText, /unobserved|null/i)

  assert.deepEqual(Object.keys(zh).sort(), Object.keys(en).sort())
})

test('the real phone composition protects the whole settings-page chain by default', () => {
  const base = loadOverlayPatches('phone-feature-admin-test', BASE_BUNDLE_PATCH)
  const phone = loadOverlayPatches('phone-feature-admin-test', PHONE_PROFILE_PATCH)
  assert.ok(Array.isArray(base), 'base bundle patch must be a sequence')
  assert.ok(Array.isArray(phone), 'phone profile patch must be a sequence')
  const composed = applyEntryPatches([], [...base, ...phone], () => {}) as Array<Record<string, any>>
  const names = new Set<string>()
  const collectNames = (rows: readonly Record<string, any>[]): void => {
    for (const row of rows) {
      if (typeof row.name === 'string') names.add(row.name)
      if (row.group && Array.isArray(row.config)) collectNames(row.config)
    }
  }
  collectNames(composed)

  const managementChain = [
    '@deepseek-ai/dsh-api-gateway',
    '@deepseek-ai/dsh-typert-registry',
    '@deepseek-ai/dsh-api-remote-access',
    '@deepseek-ai/dsh-api-remotes',
    '@deepseek-ai/dsh-api-session-controller',
    '@deepseek-ai/dsh-host-webserver',
    '@deepseek-ai/dsh-host-plugin-inventory',
    '@deepseek-ai/dsh-settings',
    '@deepseek-ai/dsh-api-settings-controller',
    '@deepseek-ai/dsh-client-modules',
    '@deepseek-ai/dsh-client-connection',
    '@deepseek-ai/dsh-client-locale',
    '@deepseek-ai/dsh-client-ui-layout',
    '@deepseek-ai/dsh-client-ui-renderer',
    '@deepseek-ai/dsh-client-ui-settings',
    '@deepseek-ai/dsh-client-ui-settings-plugins',
    '@deepseek-ai/dsh-client-ui-settings-plugin-inventory',
    '@deepseek-ai/dsh-agent',
    '@deepseek-ai/dsh-session',
    '@deepseek-ai/dsh-skill',
    '@phone-dsh/dsh-surface-phone',
  ] as const
  for (const moduleName of managementChain) {
    assert.ok(names.has(moduleName), `the real phone composition no longer mounts ${moduleName}`)
    assert.equal(typeof protectedPluginReason(moduleName), 'string', `${moduleName} is toggleable`)
  }

  // These two rows are inserted by final integration; the guard must already
  // cover them before that row exists so it cannot become a lockout on day one.
  for (const moduleName of ['@phone-dsh/dsh-feature-admin', '@deepseek-ai/dsh-agent-preset-registry']) {
    assert.equal(typeof protectedPluginReason(moduleName), 'string', `${moduleName} is toggleable`)
  }

  const toggleable = new Set(TOGGLEABLE_PLUGIN_MODULES)
  const packageRoot = (name: string): string => {
    const segments = name.split('/')
    return name.startsWith('@') ? segments.slice(0, 2).join('/') : segments[0] ?? name
  }
  for (const moduleName of names) {
    if (!moduleName.startsWith('@deepseek-ai/') && !moduleName.startsWith('@phone-dsh/')) continue
    const expectedToggleable = toggleable.has(packageRoot(moduleName))
    assert.equal(
      protectedPluginReason(moduleName) === undefined,
      expectedToggleable,
      `${moduleName} is not classified correctly by the real phone composition`,
    )
  }

  assert.equal(protectedPluginReason('@deepseek-ai/dsh-office-to-pdf'), undefined)
  assert.equal(typeof protectedPluginReason('@deepseek-ai/dsh-client-ui-settings-general'), 'string')
})

test('pluginSetEnabled refuses without profileContext and never invents inventory state', async (t) => {
  const { ctx, service } = adminWith({
    inventory: inventoryOf([{ entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' }]),
  })
  t.after(async () => { await ctx.fiber.dispose() })
  const result = await service.pluginSetEnabled('tool', false)
  assert.equal(result.ok, false)
  assert.equal(result.code, 'unsupported')
  assert.match(result.reason, /profileContext/)
})

test('the Host service exports seven Remote methods under the phone namespace', async (t) => {
  const { ctx, service } = adminWith({})
  t.after(async () => { await ctx.fiber.dispose() })
  assert.equal(service.typertRemote.namespace, 'phone')
  assert.equal(service.typertRemote.serviceKey, 'featureAdmin')
  assert.deepEqual(
    remoteMethods(service).map(marker => marker.exportName ?? marker.method).sort(),
    ['agentPresets', 'pluginList', 'pluginSetEnabled', 'skillsDelete', 'skillsList', 'skillsRead', 'skillsWrite'],
  )
})

test('pluginList comes from the official inventory and states the no-install boundary', async (t) => {
  const fixture = profileFixture('[]\n')
  t.after(fixture.dispose)
  const { ctx, service } = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf([{ entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' }]),
  })
  t.after(async () => { await ctx.fiber.dispose() })
  const result = await service.pluginList()
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(result.value.entries.length, 1)
  assert.equal(result.value.entries[0].entryId, 'tool')
  assert.equal(result.value.platform.canInstallPackages, false)
  assert.match(result.value.platform.installReason, /pnpm/)
  assert.equal(result.value.management.available, true)

  const absent = adminWith({})
  try {
    const unavailable = await absent.service.pluginList()
    assert.equal(unavailable.ok, false)
    assert.equal(unavailable.code, 'unsupported')
  } finally {
    await absent.ctx.fiber.dispose()
  }
})

test('pluginList reports management unavailable when profileContext is absent', async (t) => {
  const { ctx, service } = adminWith({
    inventory: inventoryOf([{ entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' }]),
  })
  t.after(async () => { await ctx.fiber.dispose() })
  const result = await service.pluginList()
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(result.value.management.available, false)
  assert.match(result.value.management.reason ?? '', /profileContext/)

  const fixture = profileFixture('[]\n')
  t.after(fixture.dispose)
  const declared = adminWith({
    profile: fixture.profile,
    inventory: inventoryOf(
      [{ entryId: 'tool', moduleName: 'package', enabled: true, fiberPhase: 'active' }],
      false,
    ),
  })
  t.after(async () => { await declared.ctx.fiber.dispose() })
  const snapshot = await declared.service.pluginList()
  assert.equal(snapshot.ok, true, JSON.stringify(snapshot))
  assert.equal(snapshot.value.management.available, false)
  assert.match(snapshot.value.management.reason ?? '', /persistent/)
})

test('skills write/read/list/delete stay under the root and invalidate the catalog', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'pdsh-feature-skills-'))
  t.after(() => { rmSync(home, { recursive: true, force: true }) })
  const root = join(home, 'skills')
  const outside = join(home, 'outside.md')
  writeFileSync(outside, 'outside must not change\n')
  let invalidations = 0
  const skills = { invalidateCache() { invalidations += 1 } }
  const { ctx, service } = adminWith({ skills, skillsRoot: root })
  t.after(async () => { await ctx.fiber.dispose() })

  const content = '---\nname: my-skill\ndescription: Fixture skill\n---\n\nSay hello.\n'
  const written = await service.skillsWrite('my-skill.md', content)
  assert.equal(written.ok, true, JSON.stringify(written))
  assert.equal(written.value.invalidation, 'catalog')
  assert.equal(invalidations, 1)
  assert.equal(readFileSync(join(root, 'my-skill.md'), 'utf8'), content)

  const listed = await service.skillsList()
  assert.equal(listed.ok, true, JSON.stringify(listed))
  assert.deepEqual(listed.value.map((file: any) => file.name), ['my-skill.md'])
  assert.equal(listed.value[0].skillName, 'my-skill')

  const read = await service.skillsRead('my-skill.md')
  assert.equal(read.ok, true, JSON.stringify(read))
  assert.equal(read.value.content, content)

  const badNames = [
    '../outside.md',
    'nested/../../outside.md',
    '/tmp/escape.md',
    'bad\0.md',
    '..',
    'other.txt',
    'nested/skill.md',
    '',
  ]
  for (const name of badNames) {
    const refused = await service.skillsWrite(name, 'escape\n')
    assert.equal(refused.ok, false, `accepted bad skill name ${JSON.stringify(name)}`)
    assert.equal(refused.code, 'invalid-request')
  }
  assert.equal(readFileSync(outside, 'utf8'), 'outside must not change\n')

  const deleted = await service.skillsDelete('my-skill.md')
  assert.equal(deleted.ok, true, JSON.stringify(deleted))
  assert.equal(deleted.value.deleted, true)
  assert.equal(invalidations, 2)
  assert.equal(existsSync(join(root, 'my-skill.md')), false)
})

test('skills refuse symlinked targets and symlinked roots', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'pdsh-feature-symlink-'))
  t.after(() => { rmSync(home, { recursive: true, force: true }) })
  const root = join(home, 'skills')
  const outsideDir = join(home, 'outside')
  mkdirSync(root, { recursive: true })
  mkdirSync(outsideDir, { recursive: true })
  const outside = join(outsideDir, 'outside.md')
  writeFileSync(outside, 'outside\n')
  symlinkSync(outside, join(root, 'link.md'))
  const { ctx, service } = adminWith({ skills: { invalidateCache() {} }, skillsRoot: root })
  t.after(async () => { await ctx.fiber.dispose() })

  for (const result of [
    await service.skillsRead('link.md'),
    await service.skillsWrite('link.md', 'replace\n'),
    await service.skillsDelete('link.md'),
  ]) {
    assert.equal(result.ok, false)
    assert.equal(result.code, 'conflict')
  }
  assert.equal(readFileSync(outside, 'utf8'), 'outside\n')
  assert.equal(existsSync(join(root, 'link.md')), true)

  const linkedRoot = join(home, 'linked-root')
  symlinkSync(outsideDir, linkedRoot)
  const second = adminWith({ skills: { invalidateCache() {} }, skillsRoot: linkedRoot })
  try {
    const refused = await second.service.skillsList()
    assert.equal(refused.ok, false)
    assert.equal(refused.code, 'conflict')
  } finally {
    await second.ctx.fiber.dispose()
  }
})

test('skills refuse a write/delete when the mounted registry cannot invalidate its catalog', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'pdsh-feature-event-'))
  t.after(() => { rmSync(home, { recursive: true, force: true }) })
  const root = join(home, 'skills')
  mkdirSync(root, { recursive: true })
  let changes = 0
  const ctx = new Context()
  ctx.provide('skills', {})
  ctx.on('skills/change', () => { changes += 1 })
  const service = new PhoneFeatureAdmin(ctx, { skillsRoot: root })
  t.after(async () => { await ctx.fiber.dispose() })

  const written = await service.skillsWrite('event-skill.md', '---\nname: event-skill\ndescription: Event\n---\n\nBody\n')
  assert.equal(written.ok, false, JSON.stringify(written))
  assert.equal(written.code, 'unsupported')
  assert.match(written.reason, /invalidation/)
  assert.equal(existsSync(join(root, 'event-skill.md')), false)
  assert.equal(changes, 0)

  writeFileSync(join(root, 'existing.md'), '---\nname: existing\ndescription: Existing\n---\n\nBody\n')
  const deleted = await service.skillsDelete('existing.md')
  assert.equal(deleted.ok, false, JSON.stringify(deleted))
  assert.equal(deleted.code, 'unsupported')
  assert.equal(existsSync(join(root, 'existing.md')), true)
  assert.equal(changes, 0)
})

test('skills write/delete go through the real SkillRegistry invalidator', async (t) => {
  const home = mkdtempSync(join(tmpdir(), 'pdsh-feature-registry-'))
  t.after(() => { rmSync(home, { recursive: true, force: true }) })
  const root = join(home, 'skills')
  const ctx = new Context()
  new SkillRegistry(ctx)
  const service = new PhoneFeatureAdmin(ctx, { skillsRoot: root })
  t.after(async () => { await ctx.fiber.dispose() })
  assert.equal(typeof (ctx.get('skills') as any)?.invalidateCache, 'function')

  const written = await service.skillsWrite('registry-skill.md', '---\nname: registry-skill\ndescription: Registry\n---\n\nBody\n')
  assert.equal(written.ok, true, JSON.stringify(written))
  assert.equal(written.value.invalidation, 'catalog')
  const listed = await service.skillsList()
  assert.equal(listed.ok, true, JSON.stringify(listed))
  assert.deepEqual(listed.value.map((file: any) => file.name), ['registry-skill.md'])

  const deleted = await service.skillsDelete('registry-skill.md')
  assert.equal(deleted.ok, true, JSON.stringify(deleted))
  assert.equal(deleted.value.invalidation, 'catalog')
  assert.equal(existsSync(join(root, 'registry-skill.md')), false)
})

test('agentPresets reports the missing official service instead of inventing a roster', async (t) => {
  const { ctx, service } = adminWith({})
  t.after(async () => { await ctx.fiber.dispose() })
  for (const request of [
    { action: 'list' },
    { action: 'read', presetId: 'standard' },
    { action: 'select', sessionId: 'session-1', presetId: 'standard' },
  ]) {
    const result = await service.agentPresets(request)
    assert.equal(result.ok, false)
    assert.equal(result.code, 'unsupported')
    assert.match(result.reason, /agentPresets/)
    assert.equal(Object.hasOwn(result, 'value'), false)
  }
})

test('agentPresets proxies the official list/read/select methods and their errors', async (t) => {
  const calls: string[] = []
  const presets = {
    async remoteExportList() {
      calls.push('list')
      return { presets: [{ id: 'standard', isDefault: true }, { id: 'minimal', isDefault: false }] }
    },
    async readDocument(id: string) {
      calls.push(`read:${id}`)
      if (id === 'missing') {
        throw Object.assign(new Error('Unknown agent preset: missing'), { code: 'agent-preset/not-found' })
      }
      return { agentPreset: id, content: '[]\n' }
    },
    async select(agent: { id: string }, id: string) {
      calls.push(`select:${agent.id}:${id}`)
      return id
    },
  }
  const { ctx, service } = adminWith({
    agentPresets: presets,
    agents: { get: (id: string) => id === 'session-1' ? { id } : undefined },
    sessionIds: ['session-1'],
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const listed = await service.agentPresets({ action: 'list' })
  assert.equal(listed.ok, true, JSON.stringify(listed))
  assert.equal(listed.value.action, 'list')
  assert.equal(listed.value.roster.presets.length, 2)

  const read = await service.agentPresets({ action: 'read', presetId: 'standard' })
  assert.equal(read.ok, true, JSON.stringify(read))
  assert.equal(read.value.document.agentPreset, 'standard')

  const selected = await service.agentPresets({ action: 'select', sessionId: 'session-1', presetId: 'minimal' })
  assert.equal(selected.ok, true, JSON.stringify(selected))
  assert.equal(selected.value.presetId, 'minimal')

  const flattened = await service.agentPresets('read', 'minimal')
  assert.equal(flattened.ok, true, JSON.stringify(flattened))
  assert.equal(flattened.value.document.agentPreset, 'minimal')

  const missing = await service.agentPresets({ action: 'read', presetId: 'missing' })
  assert.equal(missing.ok, false)
  assert.equal(missing.code, 'not-found')
  assert.equal(missing.domainCode, 'agent-preset/not-found')

  const noAgent = await service.agentPresets({ action: 'select', sessionId: 'absent', presetId: 'minimal' })
  assert.equal(noAgent.ok, false)
  assert.equal(noAgent.code, 'not-found')
  assert.deepEqual(calls, ['list', 'read:standard', 'select:session-1:minimal', 'read:minimal', 'read:missing'])
})

test('agentPresets select resolves a cold or restarted blank Session through the official agent lookup', async (t) => {
  const calls: string[] = []
  const cold = { id: 'cold-session' }
  const presets = {
    async remoteExportList() {
      return { presets: [{ id: 'minimal', isDefault: true }] }
    },
    async readDocument(id: string) {
      return { agentPreset: id, content: '[]\n' }
    },
    async select(agent: { id: string }, id: string) {
      calls.push(`select:${agent.id}:${id}`)
      return id
    },
  }
  const { ctx, service } = adminWith({
    agentPresets: presets,
    // The live registry is empty: a restarted blank Session has no Agent yet.
    agents: { get: () => undefined },
    sessionIds: ['cold-session', 'gone'],
    typert: {
      lookups: {
        get: (key: string) => key === 'agent'
          ? {
            resolve: async (id: string) => {
              calls.push(`resolve:${id}`)
              if (id === 'gone') throw Object.assign(new Error('session "gone" not found'), { code: 'session/not-found' })
              return cold
            },
          }
          : undefined,
      },
    },
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const selected = await service.agentPresets({ action: 'select', sessionId: 'cold-session', presetId: 'minimal' })
  assert.equal(selected.ok, true, JSON.stringify(selected))
  assert.equal(selected.value.presetId, 'minimal')

  const missing = await service.agentPresets({ action: 'select', sessionId: 'gone', presetId: 'minimal' })
  assert.equal(missing.ok, false)
  assert.equal(missing.code, 'not-found')
  assert.equal(missing.domainCode, 'session/not-found')
  assert.deepEqual(calls, ['resolve:cold-session', 'select:cold-session:minimal', 'resolve:gone'])
})

test('agentPresets select refuses subagent and unlisted ids from the real Host session index', async (t) => {
  const calls: string[] = []
  const presets = {
    async remoteExportList() {
      return { presets: [{ id: 'standard', isDefault: true }] }
    },
    async readDocument(id: string) {
      return { agentPreset: id, content: '[]\n' }
    },
    async select(agent: { id: string }, id: string) {
      calls.push(`select:${agent.id}:${id}`)
      return id
    },
  }
  const { ctx, service } = adminWith({
    agentPresets: presets,
    agents: { get: (id: string) => id === 'main-session' ? { id } : undefined },
    sessionIds: ['main-session'],
    subagentSessionIds: ['child-session'],
    // Use the same Host list source the shipped Web Session list reads.
    hostSessionCatalog: true,
  })
  t.after(async () => { await ctx.fiber.dispose() })

  const selected = await service.agentPresets({ action: 'select', sessionId: 'main-session', presetId: 'standard' })
  assert.equal(selected.ok, true, JSON.stringify(selected))

  const subagent = await service.agentPresets({ action: 'select', sessionId: 'child-session', presetId: 'standard' })
  assert.equal(subagent.ok, false, JSON.stringify(subagent))
  assert.equal(subagent.code, 'not-found')
  assert.equal(subagent.domainCode, 'session/not-found')
  assert.match(subagent.reason, /host-list/)

  const unlisted = await service.agentPresets({ action: 'select', sessionId: 'retained-fallback', presetId: 'standard' })
  assert.equal(unlisted.ok, false, JSON.stringify(unlisted))
  assert.equal(unlisted.code, 'not-found')
  assert.deepEqual(calls, ['select:main-session:standard'])
})

test('session options follow Host ids and exclude subagent/fallback rows', () => {
  const options: readonly FeatureAdminSessionView[] = sessionOptionsFromList({
    ids: ['session-main', 'session-subagent'],
    byId: {
      'session-main': {
        id: 'session-main',
        displayTitle: 'Main session',
        blank: true,
        running: false,
        retainedBy: {},
        updatedAt: 1,
        projectionValues: { agentPreset: 'standard' },
      },
      'session-subagent': {
        id: 'session-subagent',
        displayTitle: 'Child session',
        origin: 'subagent',
        blank: false,
        running: false,
        retainedBy: { mainView: 1 },
        updatedAt: 2,
      },
      'session-fallback': {
        id: 'session-fallback',
        displayTitle: 'Fallback session',
        origin: 'subagent',
        blank: false,
        running: false,
        retainedBy: { mainView: 0 },
        updatedAt: 3,
      },
      'session-unlisted': {
        id: 'session-unlisted',
        displayTitle: 'Unlisted row',
        blank: false,
        running: false,
        retainedBy: { mainView: 0 },
        updatedAt: 4,
      },
    },
    phase: 'ready',
    projectionsBySession: {},
  } as any)
  assert.deepEqual(options.map(option => option.id), ['session-main'])
  assert.equal(options[0]?.agentPreset, 'standard')
  assert.equal(options[0]?.blank, true)
})

test('the browser tab registers into the shipped settings slot with the phone RPC face', async () => {
  const registrations: Array<{ options: any; component: unknown }> = []
  const ctx = {
    effect(fn: () => unknown) { return fn() },
    slots: {
      inject(key: string, callback: () => unknown) {
        assert.equal(key, 'settings.plugins.tab')
        return callback()
      },
      register(options: any, component: unknown) {
        registrations.push({ options, component })
        return () => {}
      },
    },
  }
  const component = () => null
  const dispose = registerFeatureAdminTab(ctx as never, {
    component,
    label: () => 'Phone capabilities',
    injected: () => ({
      call: async () => ({ ok: true, value: [] }),
      sessionOptions: () => [],
      sessions: {
        getSnapshot: () => ({ ids: [], byId: {}, phase: 'ready', projectionsBySession: {} }),
        subscribe: () => () => {},
      },
    }),
  })
  assert.equal(typeof dispose, 'function')
  assert.equal(registrations.length, 1)
  const registration = registrations[0]
  assert.ok(registration, 'the tab registration must be recorded')
  assert.equal(registration.options.name, 'settings.plugins.tab')
  assert.equal(registration.options.id, FEATURE_ADMIN_TAB_ID)
  assert.equal(registration.options.order, 20)
  assert.equal(registration.options.locale, 'settings.phoneFeatureAdmin')
  assert.equal(registration.component, component)
  const injected = registration.options.inject()
  assert.equal(typeof injected.call, 'function')
  assert.deepEqual(injected.sessionOptions(), [])
})

test('the client export resolves to the built page asset the DSH module table serves', () => {
  const manifest = JSON.parse(readFileSync(join(MODULE_ROOT, 'package.json'), 'utf8'))
  assert.equal(manifest.dsh.client.platform, 'web')
  const client = manifest.exports['./client']
  // DSH's clientExportOf accepts either a string or an object with `default`.
  const clientPath = typeof client === 'string' ? client : client.default
  assert.equal(clientPath, './lib/client.js')
  assert.equal(clientPath.endsWith('.ts'), false)
  if (typeof client === 'object') assert.equal(client.types, './src/client/index.ts')
  assert.equal(manifest.exports['./cordis.patch.yml'], './cordis.patch.yml')
  assert.ok(existsSync(join(MODULE_ROOT, 'cordis.patch.yml')))
  assert.equal(manifest.exports['./package.json'], './package.json')
  assert.equal(Object.keys(manifest.exports).some(key => key.includes('*')), false,
    'the image stager copies concrete exports only; a src wildcard would be read as a literal path')
})

test('the browser caller uses the existing /api phone namespace and surfaces carrier failures', async () => {
  const calls: Array<{ channel: string; endpoint: string; payload: unknown }> = []
  const carrier = {
    async call(channel: string, endpoint: string, payload: unknown) {
      calls.push({ channel, endpoint, payload })
      return { ok: true, value: { ok: true, value: [] } }
    },
  }
  const result = await callFeatureAdmin(carrier as never, 'pluginList')
  assert.equal(result.ok, true)
  assert.deepEqual(calls, [{ channel: '/api', endpoint: 'phone/pluginList', payload: { args: {} } }])

  const failed = {
    async call() {
      return { ok: false, error: { code: 'gateway/internal', message: 'transport down', details: {} } }
    },
  }
  await assert.rejects(
    callFeatureAdmin(failed as never, 'skillsList'),
    (error: any) => error.code === 'gateway/internal' && /transport down/.test(error.message),
  )
})
