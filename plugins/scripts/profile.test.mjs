// SPDX-License-Identifier: MIT
// Worker profile patch tests: DSH's own loader must parse the file with its
// `!!js` expressions intact, and every row id must exist in a 0.2.1 roster or
// be declared by this file's insert list.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { readPin } from './dsh-checkout.mjs'
import {
  CLIENT_MODULES_PACKAGE,
  CONNECTION_PACKAGE,
  CONNECTION_ROW,
  DISABLED_ACCOUNT_ROWS,
  PHONE_SURFACE_ROW,
  WORKER_PROFILE_PATCH,
  findRow,
  flattenRows,
  loadWorkerHomePatch,
  packImage,
} from './pack-image.mjs'

const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the 0.2.1 roster is the oracle for row ids'
  : false
const worktree = fileURLToPath(new URL('..', import.meta.url))
const scratch = []

after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

/**
 * Load a patch file through DSH's own patch reader.
 * @param {string} file - absolute patch path.
 * @returns {Promise<object[]>} Loader rows with `!!js` expression markers.
 */
async function loadRows(file) {
  const appBoot = await import(pathToFileURL(join(checkout, 'packages/boot/app-boot/lib/index.js')).href)
  return appBoot.loadOverlayPatches('pdsh-profile-test', file)
}

/**
 * Load the shared profile through the published app-boot when the pinned
 * checkout's build products are not present. The published package is the same
 * 0.2.1-rc.2 parser; this keeps the row/shape checks runnable on Linux.
 * @param file - absolute patch path.
 * @returns Loader rows with `!!js` expression markers.
 */
async function loadRowsForShape(file) {
  const appBoot = checkout === undefined || checkout === ''
    ? await import('@deepseek-ai/dsh-app-boot')
    : await import(pathToFileURL(join(checkout, 'packages/boot/app-boot/lib/index.js')).href)
  return appBoot.loadOverlayPatches('pdsh-profile-test', file)
}

/**
 * Collect every row id, walking insert lists and group row lists.
 * @param {unknown} rows - loader rows.
 * @returns {Set<string>} ids.
 */
function rowIds(rows) {
  const ids = new Set()
  const visit = (list) => {
    if (!Array.isArray(list)) return
    for (const row of list) {
      if (typeof row?.id === 'string') ids.add(row.id)
      visit(row?.insert)
      if (row?.group === true) visit(row?.config)
    }
  }
  visit(rows)
  return ids
}

/** Top-level rows of a patch list. */
function topLevel(rows) {
  return rows.filter(row => !Array.isArray(row.insert))
}

/**
 * Evaluate one loader `!!js` scalar with a synthetic process environment.
 * The profile's provider selection is expressed with `!!js`, so the shape test
 * checks the actual boolean/value the loader will produce instead of comparing
 * source text.
 * @param {unknown} value - literal or `{ __jsExpr }` loader value.
 * @param {Record<string, string>} env - synthetic process.env entries.
 * @returns {unknown} the expression result, or the literal value.
 */
function evaluateLoaderValue(value, env = {}) {
  if (value !== null && typeof value === 'object' && typeof value.__jsExpr === 'string') {
    return Function('process', `return (${value.__jsExpr})`)({ env })
  }
  return value
}

test('every row id exists in a 0.2.1 roster or in the insert list', { skip }, async () => {
  const workerRows = await loadRows(WORKER_PROFILE_PATCH)
  const baseRows = await loadRows(join(checkout, 'packages/bundle/base/cordis.patch.yml'))
  const surfaceRows = await loadRows(join(worktree, 'surface-phone', 'cordis.patch.yml'))
  const inserted = workerRows.flatMap(row => (Array.isArray(row.insert) ? row.insert : []))
  const insertedIds = new Set(inserted.map(row => row.id))
  const allowed = new Set([...rowIds(baseRows), ...rowIds(surfaceRows), ...insertedIds])

  const targets = topLevel(workerRows).map(row => row.id)
  assert.ok(targets.length > 0)
  for (const id of targets) {
    assert.ok(allowed.has(id), `row id ${id} is neither in a 0.2.1 roster nor in the insert list`)
  }

  assert.ok(inserted.length > 0)
  const baseIds = rowIds(baseRows)
  const surfaceById = new Map(
    (function flatten(list) {
      return list.flatMap(row => [row, ...(Array.isArray(row?.insert) ? flatten(row.insert) : [])])
    })(surfaceRows).map(row => [row.id, row]),
  )
  const seen = new Set()
  for (const row of inserted) {
    assert.equal(typeof row.id, 'string')
    assert.equal(typeof row.name, 'string')
    assert.ok(!baseIds.has(row.id), `insert ${row.id} must not shadow a dsh-base row`)
    assert.ok(!seen.has(row.id), `insert ${row.id} is declared twice`)
    seen.add(row.id)
    // The Worker patch folds the surface-phone patch into the image's single
    // home layer; a reused row id must keep the same plugin name.
    const surface = surfaceById.get(row.id)
    if (surface !== undefined) assert.equal(row.name, surface.name)
  }
})

test('the worker patch keeps the six plugin packages and the worker surface rows', { skip }, async () => {
  const rows = await loadRows(WORKER_PROFILE_PATCH)
  const inserted = rows.flatMap(row => (Array.isArray(row.insert) ? row.insert : []))
  const names = new Set(inserted.map(row => row.name).filter(name => typeof name === 'string'))
  for (const name of [
    '@phone-dsh/dsh-exec-bridge',
    '@phone-dsh/dsh-subprocess-xl',
    '@phone-dsh/dsh-llm-bridge',
    '@phone-dsh/dsh-tool-journal',
    '@phone-dsh/dsh-lifecycle-gate',
    '@phone-dsh/dsh-surface-phone',
  ]) {
    assert.ok(names.has(name), `${name} must be inserted by the worker profile`)
  }
  for (const surface of [
    '@deepseek-ai/dsh-host-webserver',
    '@deepseek-ai/dsh-api-remotes',
    '@deepseek-ai/dsh-api-session-controller',
    '@deepseek-ai/dsh-client-file-upload',
    '@deepseek-ai/dsh-workspace',
    '@deepseek-ai/dsh-api-job-controller',
    '@deepseek-ai/dsh-api-workspace-controller',
    '@deepseek-ai/dsh-api-settings-controller',
    '@deepseek-ai/dsh-host-plugin-inventory',
    '@deepseek-ai/dsh-tool-subagent/model-selection-settings',
    '@deepseek-ai/dsh-schedule',
  ]) {
    assert.ok(names.has(surface), `${surface} must be inserted by the worker profile`)
  }
})

test('the worker patch carries the browser roster with a browser-only connection row', { skip }, async () => {
  const rows = await loadRows(WORKER_PROFILE_PATCH)
  const flat = flattenRows(rows)
  const byId = new Map(flat.filter(row => typeof row.id === 'string').map(row => [row.id, row]))

  assert.equal(byId.get('modules')?.name, CLIENT_MODULES_PACKAGE)
  assert.equal(byId.get('modules')?.disabled, undefined)
  assert.equal(byId.get(CONNECTION_ROW)?.name, CONNECTION_PACKAGE)
  assert.deepEqual(byId.get(CONNECTION_ROW)?.inject, ['webStartup'])
  assert.equal(byId.get(CONNECTION_ROW)?.disabled, undefined)
  // app-boot hard-codes the global `connection` id as required; this row must
  // stay off that id so its browser-only host half may remain pending.
  assert.equal(byId.get('connection'), undefined)
  assert.equal(byId.get(PHONE_SURFACE_ROW)?.name, '@phone-dsh/dsh-surface-phone')
  assert.equal(byId.get(PHONE_SURFACE_ROW)?.disabled, undefined)
  for (const id of DISABLED_ACCOUNT_ROWS) assert.equal(byId.get(id)?.disabled, true, `${id} must stay disabled`)
  assert.equal(byId.get('account-controller'), undefined)
  assert.equal(byId.get('web-startup'), undefined)
  assert.equal(flat.some(row => row.name === '@deepseek-ai/dsh-web-app'), false)
})

test('the worker patch mounts the six phone surfaces and the model/search wiring', async () => {
  const rows = await loadRowsForShape(WORKER_PROFILE_PATCH)
  const flat = flattenRows(rows)
  const byId = new Map(flat.filter(row => typeof row.id === 'string').map(row => [row.id, row]))
  for (const name of [
    '@phone-dsh/dsh-phone-model-config',
    '@phone-dsh/dsh-feature-admin',
    '@phone-dsh/dsh-phone-mcp',
    '@phone-dsh/dsh-phone-shell',
    '@phone-dsh/dsh-phone-native-preview',
    '@phone-dsh/dsh-phone-directory-import',
  ]) {
    assert.ok([...byId.values()].some(row => row.name === name && !row.disabled),
              `${name} must be an enabled profile row`)
  }
  assert.equal(byId.get('agent-preset-registry')?.name, '@deepseek-ai/dsh-agent-preset-registry')
  assert.equal(byId.get('agent-preset-registry')?.config?.default, 'standard')
  assert.equal(byId.get('preset-phone')?.name, '@deepseek-ai/dsh-agent-preset')
  const phonePreset = byId.get('preset-phone')?.config?.plugins ?? []
  assert.ok(Array.isArray(phonePreset) && phonePreset.length > 0)
  const phoneIds = new Set(phonePreset.map(row => row.id))
  assert.ok(phoneIds.has('tool-bash'))
  assert.equal(phoneIds.has('workflow-ptc'), false)
  assert.equal(phoneIds.has('tool-workflow'), false)
  const webTool = phonePreset.find(row => row.id === 'tool-web')
  assert.equal(byId.get('agent-default-model')?.config?.provider, 'deepseek-official')
  assert.ok(byId.get('agent-default-model')?.config?.model !== undefined,
            'the default model must come from the host projection')
  assert.ok(byId.get('agent-default-model')?.config?.reasoningEffort !== undefined,
            'the selected reasoning effort must reach the model selection')
  assert.equal(byId.get('web')?.disabled, false)
  assert.equal(byId.get('tool-web')?.disabled, false)
  assert.equal(byId.get('web-fetch-http')?.disabled, true)
  assert.equal(byId.get('ui-settings-web-search')?.disabled, true)

  // The provider rows are mounted only for the mode the native host selected.
  // Evaluate the same loader expressions the Worker evaluates at boot.
  const followEnv = { PDSH_WEB_SEARCH_PROVIDER: 'deepseek-official' }
  const independentEnv = {
    PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
    PDSH_WEB_FETCH_PROVIDER: 'deepseek-fetch-api',
    DEEPSEEK_SEARCH_API_BASE_URL: 'https://search.example/v1/tools',
  }
  const emptyEnv = {}
  const unsupportedEnv = {
    PDSH_WEB_SEARCH_PROVIDER: 'openai-compatible',
    PDSH_WEB_FETCH_PROVIDER: 'deepseek-fetch-api',
  }
  // A fetch id alone must not expose either tool: the independent Search API
  // row registers the fetch provider only for the `deepseek-search-api` pair.
  const fetchOnlyEnv = { PDSH_WEB_FETCH_PROVIDER: 'deepseek-fetch-api' }
  // The search provider alone exposes web_search, but not web_fetch: follow
  // and an incomplete independent environment have no real fetch provider.
  const searchOnlyEnv = {
    PDSH_WEB_SEARCH_PROVIDER: 'deepseek-search-api',
    DEEPSEEK_SEARCH_API_BASE_URL: 'https://search.example/v1/tools',
  }
  const webRow = byId.get('web')
  const messagesRow = byId.get('web-search-deepseek')
  const apiRow = byId.get('web-deepseek-api')
  assert.equal(evaluateLoaderValue(webRow?.config?.searchProvider, emptyEnv), undefined)
  assert.equal(evaluateLoaderValue(messagesRow?.disabled, emptyEnv), true)
  assert.equal(evaluateLoaderValue(apiRow?.disabled, emptyEnv), true)
  assert.equal(evaluateLoaderValue(webRow?.config?.searchProvider, followEnv), 'deepseek-official')
  assert.equal(evaluateLoaderValue(messagesRow?.disabled, followEnv), false)
  assert.equal(evaluateLoaderValue(apiRow?.disabled, followEnv), true)
  assert.equal(evaluateLoaderValue(webRow?.config?.searchProvider, independentEnv), 'deepseek-search-api')
  assert.equal(evaluateLoaderValue(webRow?.config?.fetchProvider, independentEnv), 'deepseek-fetch-api')
  assert.equal(evaluateLoaderValue(messagesRow?.disabled, independentEnv), true)
  assert.equal(evaluateLoaderValue(apiRow?.disabled, independentEnv), false)
  assert.equal(evaluateLoaderValue(apiRow?.config?.apiKeyEnv, independentEnv), 'DEEPSEEK_SEARCH_API_KEY')
  assert.equal(evaluateLoaderValue(apiRow?.config?.baseURL, independentEnv), 'https://search.example/v1/tools')
  assert.equal(evaluateLoaderValue(messagesRow?.disabled, unsupportedEnv), true)
  assert.equal(evaluateLoaderValue(apiRow?.disabled, unsupportedEnv), true)

  // Both tool-web registration sites (top-level Worker row and the phone
  // preset row) expose web_search only for a supported provider id. Empty,
  // unsupported and fetch-only environments expose neither tool.
  for (const row of [byId.get('tool-web'), webTool]) {
    assert.equal(evaluateLoaderValue(row?.config?.search, emptyEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.fetch, emptyEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.search, followEnv), true)
    assert.equal(evaluateLoaderValue(row?.config?.fetch, followEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.search, independentEnv), true)
    assert.equal(evaluateLoaderValue(row?.config?.fetch, independentEnv), true)
    assert.equal(evaluateLoaderValue(row?.config?.search, unsupportedEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.fetch, unsupportedEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.search, searchOnlyEnv), true)
    assert.equal(evaluateLoaderValue(row?.config?.fetch, searchOnlyEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.search, fetchOnlyEnv), false)
    assert.equal(evaluateLoaderValue(row?.config?.fetch, fetchOnlyEnv), false)
  }
  // The native host owns model service configuration and the preview notice
  // is a desktop-Web modal; phone-model-config is the same Worker's model page.
  assert.equal(byId.get('ui-settings-models')?.disabled, true)
  // The official xterm tab has no PTY on iOS; phone-shell is the honest console.
  assert.equal(byId.get('ui-sidebar-terminal')?.disabled, true)
  // First-use creation must not call the desktop Documents lookup inside the
  // Worker; the App's existing durable workspace mount is the document root.
  assert.equal(byId.get('workspace-controller')?.config?.documentsDirectory, '/dsh/workspace')
})

test('standard keeps its Worker workflow rows and ptc keeps its presentation row', { skip }, async () => {
  const appBoot = await import(pathToFileURL(join(checkout, 'packages/boot/app-boot/lib/index.js')).href)
  const rows = loadWorkerHomePatch(appBoot, WORKER_PROFILE_PATCH, checkout)
  const byId = new Map(flattenRows(rows).filter(row => typeof row.id === 'string').map(row => [row.id, row]))
  for (const id of ['preset-standard', 'preset-ptc', 'preset-minimal', 'preset-cordis', 'preset-phone']) {
    assert.equal(byId.get(id)?.name, '@deepseek-ai/dsh-agent-preset', `${id} must remain declared`)
  }
  const standard = byId.get('preset-standard')?.config?.plugins ?? []
  const workflow = findRow(standard, 'workflow-ptc')
  assert.equal(workflow?.name, '@deepseek-ai/dsh-workflow-ptc')
  assert.equal(workflow?.disabled, undefined, 'standard workflow-ptc must be enabled through the Worker bridge')
  assert.equal(workflow?.config?.provider, 'spawn')
  assert.equal(findRow(standard, 'tool-workflow')?.name, '@deepseek-ai/dsh-tool-workflow')

  const ptc = byId.get('preset-ptc')?.config?.plugins ?? []
  const presentation = ptc.find(row => row.id === 'tool-presentation')
  assert.equal(presentation?.name, '@deepseek-ai/dsh-agent-tool-presentation')
  assert.equal(presentation?.config?.mode, 'ptc')
  assert.equal(presentation?.disabled, undefined, 'ptc presentation is served by the native-equivalent shim')

  // The two genuinely unsupported presets stay visible with their own real
  // rows; the default switch must not hide or rewrite them.
  assert.ok((byId.get('preset-minimal')?.config?.plugins ?? []).some(row => row.id === 'persistent-shell'))
  assert.ok((byId.get('preset-cordis')?.config?.plugins ?? []).length > 0)
})

test('the packer appends the four shipped agent-preset declarations from the checkout', async () => {
  const appBoot = await import('@deepseek-ai/dsh-app-boot')
  const root = mkdtempSync(join(tmpdir(), 'pdsh-preset-patch-'))
  scratch.push(root)
  for (const name of ['standard', 'ptc', 'minimal', 'cordis']) {
    const file = join(root, 'packages/bundle/web-app/presets', `${name}.patch.yml`)
    mkdirSync(join(file, '..'), { recursive: true })
    writeFileSync(file, [
      '- insert:',
      `    - id: preset-${name}`,
      "      name: '@deepseek-ai/dsh-agent-preset'",
      '      config: {}',
      '',
    ].join('\n'))
  }
  const rows = loadWorkerHomePatch(appBoot, WORKER_PROFILE_PATCH, root)
  const ids = rows.flatMap(row => Array.isArray(row.insert) ? row.insert : []).map(row => row.id)
  for (const name of ['standard', 'ptc', 'minimal', 'cordis']) {
    assert.ok(ids.includes(`preset-${name}`), `the ${name} preset declaration must be applied`)
  }
})

test('the browser roster names every row the mobile Web UI needs', { skip }, async () => {
  const rows = await loadRows(WORKER_PROFILE_PATCH)
  const inserted = flattenRows(rows).filter(row => typeof row.id === 'string')
  const byId = new Map(inserted.map(row => [row.id, row]))
  const required = [
    ['ui-theme', '@deepseek-ai/dsh-client-ui-theme'],
    ['locale', '@deepseek-ai/dsh-client-locale'],
    ['shortcuts', '@deepseek-ai/dsh-client-shortcuts'],
    ['ui-shortcuts', '@deepseek-ai/dsh-client-ui-shortcuts'],
    ['ui-layout', '@deepseek-ai/dsh-client-ui-layout'],
    ['ui-renderer', '@deepseek-ai/dsh-client-ui-renderer'],
    ['ui-session', '@deepseek-ai/dsh-client-ui-session'],
    ['resources', '@deepseek-ai/dsh-client-resources'],
    ['ui-sidebar', '@deepseek-ai/dsh-client-ui-sidebar'],
    ['ui-sidebar-right', '@deepseek-ai/dsh-client-ui-sidebar-right'],
    ['ui-sidebar-browser', '@deepseek-ai/dsh-client-ui-sidebar-browser'],
    ['ui-sidebar-documentpreview', '@deepseek-ai/dsh-client-ui-sidebar-documentpreview'],
    ['ui-sidebar-files', '@deepseek-ai/dsh-client-ui-sidebar-files'],
    ['ui-directory-picker-browse', '@deepseek-ai/dsh-client-ui-directory-picker-browse'],
    ['ui-settings', '@deepseek-ai/dsh-client-ui-settings'],
    ['ui-settings-general', '@deepseek-ai/dsh-client-ui-settings-general'],
    ['ui-settings-plugin-inventory', '@deepseek-ai/dsh-client-ui-settings-plugin-inventory'],
    ['ui-settings-account', '@deepseek-ai/dsh-client-ui-settings-account'],
    ['ui-settings-session-log', '@deepseek-ai/dsh-client-ui-settings-session-log'],
    ['ui-settings-plugins', '@deepseek-ai/dsh-client-ui-settings-plugins'],
    ['ui-settings-shell', '@deepseek-ai/dsh-client-ui-settings-shell'],
    ['ui-settings-agent-loop', '@deepseek-ai/dsh-client-ui-settings-agent-loop'],
    ['ui-settings-subagent', '@deepseek-ai/dsh-client-ui-settings-subagent'],
    ['ui-conversation', '@deepseek-ai/dsh-client-ui-conversation'],
    ['ui-approval', '@deepseek-ai/dsh-client-ui-approval'],
    ['ui-chat', '@deepseek-ai/dsh-client-ui-chat'],
    ['ui-attachment', '@deepseek-ai/dsh-client-ui-attachment'],
    ['ui-tool', '@deepseek-ai/dsh-client-ui-tool'],
    ['ui-deliverables', '@deepseek-ai/dsh-client-ui-deliverables'],
    ['ui-workspace', '@deepseek-ai/dsh-client-ui-workspace'],
    ['ui-workflow-run', '@deepseek-ai/dsh-client-ui-workflow-run'],
    ['ui-input-trigger', '@deepseek-ai/dsh-client-ui-input-trigger'],
    ['ui-commands', '@deepseek-ai/dsh-client-ui-commands'],
    ['ui-skill', '@deepseek-ai/dsh-client-ui-skill'],
    ['ui-subagent', '@deepseek-ai/dsh-client-ui-subagent'],
    ['ui-reference', '@deepseek-ai/dsh-client-ui-reference'],
    ['ui-secret-mask', '@deepseek-ai/dsh-client-ui-secret-mask'],
    ['ui-jobs', '@deepseek-ai/dsh-client-ui-jobs'],
    ['ui-schedule', '@deepseek-ai/dsh-client-ui-schedule'],
    ['ui-goal', '@deepseek-ai/dsh-client-ui-goal'],
    ['ui-message-feedback', '@deepseek-ai/dsh-client-ui-message-feedback'],
    ['ui-model-selection', '@deepseek-ai/dsh-client-ui-model-selection'],
    ['ui-permission', '@deepseek-ai/dsh-client-ui-permission-presets'],
    ['ui-agent-preset', '@deepseek-ai/dsh-client-ui-agent-preset'],
    ['ui-plan', '@deepseek-ai/dsh-client-ui-plan'],
    ['ui-user-questions', '@deepseek-ai/dsh-client-ui-user-questions'],
    ['ui-trajectory', '@deepseek-ai/dsh-client-ui-trajectory'],
    ['ui-mobile', '@deepseek-ai/dsh-client-ui-mobile'],
  ]
  for (const [id, name] of required) {
    assert.equal(byId.get(id)?.name, name, `${id} must name ${name}`)
    assert.equal(byId.get(id)?.disabled, undefined, `${id} must stay enabled`)
  }
  // iOS has no PTY and this host does not mount ctx.credentials: both would be
  // permanently failing controls, so their rows stay present but disabled.
  for (const id of ['ui-sidebar-terminal', 'ui-settings-web-search', 'ui-settings-models']) {
    assert.equal(byId.get(id)?.disabled, true, `${id} must stay disabled on the phone`)
  }
  for (const name of [
    '@deepseek-ai/dsh-message-feedback',
    '@deepseek-ai/dsh-session-reference',
    '@deepseek-ai/dsh-file-reference-local',
    '@deepseek-ai/dsh-session-stats',
    '@deepseek-ai/dsh-session-turn-outline',
    '@deepseek-ai/dsh-office-to-pdf',
    '@deepseek-ai/dsh-host-directory-picker-browse',
    '@deepseek-ai/dsh-api-terminal-controller',
  ]) {
    assert.ok([...byId.values()].some(row => row.name === name), `${name} must be inserted by the worker profile`)
  }
})

test('the plaintext JSONL row is active and the shipped zstd row is disabled', { skip }, async () => {
  const rows = await loadRows(WORKER_PROFILE_PATCH)
  const flatten = (list) => list.flatMap(row => [row, ...(Array.isArray(row.insert) ? flatten(row.insert) : [])])
  const all = flatten(rows)
  assert.equal(all.find(row => row.id === 'session-persistence-jsonl')?.disabled, true)
  const journaled = all.find(row => row.id === 'session-persistence-journaled')
  assert.equal(journaled?.config?.compression, 'none')
  assert.equal(all.find(row => row.id === 'session-query-sqlite')?.config?.openAt, 'never')
})

test('DSH patch-row conversion preserves !!js expressions in config and insert rows', { skip }, async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-patch-test-'))
  scratch.push(directory)
  const file = join(directory, 'sample.cordis.patch.yml')
  writeFileSync(file, [
    '# SPDX-License-Identifier: MIT',
    '- id: sandbox-policy',
    '  config:',
    "    mode: !!js process.env.PDSH_SANDBOX_MODE ?? 'workspace-write'",
    '    workspaceRoot: !!js process.cwd()',
    '- insert:',
    '    - id: sample',
    "      name: '@scope/sample'",
    '      config:',
    "        root: !!js dshHomePath('sessions')",
    '',
  ].join('\n'))

  const rows = await loadRows(file)
  assert.equal(rows[0].config.mode.__jsExpr, "process.env.PDSH_SANDBOX_MODE ?? 'workspace-write'")
  assert.equal(rows[0].config.workspaceRoot.__jsExpr, 'process.cwd()')
  assert.equal(rows[1].insert[0].config.root.__jsExpr, "dshHomePath('sessions')")
  assert.equal(rows[1].insert[0].name, '@scope/sample')
})

test('the packed image carries every browser bundle and composes __DSH_BOOT__', {
  skip,
  timeout: 300_000,
}, async () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-profile-image-'))
  scratch.push(directory)
  const pin = readPin()
  const result = await packImage({ out: directory, checkout })
  const roster = result.clientRoster

  assert.equal(roster.package, CLIENT_MODULES_PACKAGE)
  assert.equal(roster.connection.row, CONNECTION_ROW)
  assert.equal(roster.connection.host, 'pending')
  assert.equal(roster.connection.phone_surface, PHONE_SURFACE_ROW)
  assert.deepEqual(roster.connection.disabled, [...DISABLED_ACCOUNT_ROWS])
  assert.equal(roster.boot.__DSH_BOOT__, true)
  const bootEntries = new Set(roster.boot.entries)
  for (const packageName of [
    CLIENT_MODULES_PACKAGE,
    CONNECTION_PACKAGE,
    '@deepseek-ai/dsh-client-ui-mobile',
    '@deepseek-ai/dsh-client-ui-sidebar-documentpreview',
    '@deepseek-ai/dsh-client-ui-sidebar-files',
    '@deepseek-ai/dsh-client-ui-sidebar-browser',
    '@deepseek-ai/dsh-client-ui-reference',
    '@phone-dsh/dsh-phone-model-config',
    '@phone-dsh/dsh-feature-admin',
    '@phone-dsh/dsh-phone-mcp',
    '@phone-dsh/dsh-phone-shell',
    '@phone-dsh/dsh-phone-native-preview',
    '@phone-dsh/dsh-phone-directory-import',
    '@deepseek-ai/dsh-client-ui-workspace',
    '@deepseek-ai/dsh-client-ui-chat',
  ]) {
    assert.ok(bootEntries.has(packageName), `${packageName} must be in window.__DSH_BOOT__`)
  }
  for (const row of roster.rows) {
    assert.ok(row.path.startsWith(`node_modules/${row.package}/`), `${row.package} bundle path`)
    assert.ok(row.path.endsWith('/client.js') || /\/client\.[^/]+\.js$/.test(row.path), `${row.package} browser bundle`)
    assert.ok(row.bytes > 0, `${row.package} browser bundle is not empty`)
  }

  const sizes = JSON.parse(readFileSync(join(directory, 'sizes.json'), 'utf8'))
  assert.deepEqual(sizes.client_roster, roster)
  assert.equal(sizes.dsh_commit, result.sizes.dsh_commit)
  assert.equal(sizes.dsh_pin_commit, pin.commit)
  assert.equal(sizes.dsh_checkout, result.checkout)
  assert.equal(sizes.dsh_version, pin.version)
})
