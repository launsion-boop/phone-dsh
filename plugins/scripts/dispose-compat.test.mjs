// SPDX-License-Identifier: MIT
// The pinned DSH cleanup listeners call `fiber.dispose().catch(...)`. A Cordis
// fiber returns a Promise on the first disposal but `undefined` after its
// owning scope already disposed it, so the two phone-image call sites are
// normalised with `Promise.resolve`. These tests load the real built DSH
// packages (originals and transformed copies) and drive their actual
// `agent/disposed` listeners with a real Cordis fiber, a rejected disposal and
// a deferred disposal.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { after, test } from 'node:test'

import { Context } from '@deepseek-ai/cordis'
import { createScope } from '@deepseek-ai/dsh-scope'

import { DISPOSE_COMPAT_PACKAGES, rewriteDisposeSite, stageDisposeCompat } from './dispose-compat.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const PLUGIN_ROOT = resolve(HERE, '..')
const requireFromPlugins = createRequire(join(PLUGIN_ROOT, 'package.json'))
const temporaryRoots = []
const checkout = process.env.PDSH_DSH_CHECKOUT
const packerEntry = checkout === undefined || checkout === ''
  ? undefined
  : join(checkout, 'packages/experimental/webworker-packer/lib/index.js')
const packerSkip = packerEntry === undefined || !existsSync(packerEntry)
  ? 'PDSH_DSH_CHECKOUT has no built webworker-packer; the real materialize pass needs the pinned checkout'
  : false

after(() => {
  for (const directory of temporaryRoots) rmSync(directory, { recursive: true, force: true })
})

/** Pinned package directory as installed from the lockfile. */
function installedPackage(packageName) {
  return dirname(requireFromPlugins.resolve(`${packageName}/package.json`))
}

/** Import one built package file from an absolute directory. */
function importBuilt(directory, file = 'lib/index.js') {
  return import(pathToFileURL(join(directory, file)).href)
}

/** Stage transformed copies of the two real installed packages. */
function stageTransformedPackages() {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-dispose-compat-test-'))
  temporaryRoots.push(root)
  return stageDisposeCompat({
    workspaces: new Map(DISPOSE_COMPAT_PACKAGES.map(spec => [spec.package, installedPackage(spec.package)])),
    output: join(root, 'stage'),
    commit: 'test-pinned-commit',
    version: 'test-pinned-version',
  })
}

/** Build a root context with the minimal services the real plugins resolve. */
function serviceContext() {
  const root = new Context()
  const tools = { get: () => undefined, register: () => () => {} }
  const systemPrompt = {
    section: () => {},
    getSectionOrder: () => 0,
    context: () => {},
    getContextOrder: () => 0,
  }
  root.provide('agents', { list: () => [] })
  root.provide('subagents', { getProvider: () => undefined, resolveMaxDepth: () => undefined })
  root.provide('sessionProjections', { register: () => {}, stateOf: () => undefined })
  root.provide('tools', tools)
  root.provide('systemPrompt', systemPrompt)
  root.provide('subagentModelSelection', { current: () => ({ enabled: false }) })
  root.provide('workingDirectory', {})
  return root
}

/**
 * Drive the real tool-subagent standing composition:
 * create a composition scope, mount apply, create a child Agent scope, emit
 * `agent/created`, dispose the Agent scope first, then emit `agent/disposed`.
 * @returns {Error | undefined} the synchronous listener error, if any.
 */
async function disposeToolSubagent(moduleUrl) {
  const { apply } = await import(moduleUrl)
  const root = serviceContext()
  const compositionKey = { name: 'composition' }
  const composition = createScope(root, compositionKey)
  await composition.ctx.plugin({
    name: 'tool-subagent-dispose-compat-test',
    apply,
    inject: ['agents', 'subagents', 'sessionProjections', 'tools', 'systemPrompt'],
  }, { provider: 'spawn', modelSelectionSettings: true })

  const agentKey = { name: 'agent' }
  const agentScope = createScope(composition.ctx, agentKey, { parent: compositionKey })
  const agent = {
    id: 'dispose-compat-agent',
    ctx: agentScope.ctx,
    session: { firstLiveSeq: 1, header: { origin: 'parent' } },
  }
  root.emit('agent/created', { agent })
  await agentScope.dispose()

  let error
  try {
    root.emit('agent/disposed', { agent })
  } catch (reason) {
    error = reason
  }
  await root.fiber.dispose()
  return error
}

/**
 * Drive the real file-reference-local `agent/disposed` listener with one
 * injected prompt fiber.
 * @returns {Promise<{error: Error | undefined, warnings: string[], sizes: {fibers: number, disposals: number}, service: object}>} observed cleanup.
 */
async function disposeFileReference(moduleUrl, fiber, warnings = []) {
  const { default: LocalFileReferenceService } = await import(moduleUrl)
  const root = serviceContext()
  const service = new LocalFileReferenceService(root, {})
  const agent = { id: 'dispose-compat-agent' }
  service.promptFibers.set(agent, fiber)
  service.ctx.logger.warn = (...args) => { warnings.push(args.map(String).join(' ')) }

  let error
  try {
    root.emit('agent/disposed', { agent })
  } catch (reason) {
    error = reason
  }
  await Promise.resolve()
  return {
    error,
    warnings,
    sizes: { fibers: service.promptFibers.size, disposals: service.promptDisposals.size },
    service,
    root,
  }
}

test('the exact pinned call sites rewrite once and fail on drift', () => {
  for (const spec of DISPOSE_COMPAT_PACKAGES) {
    for (const site of spec.sites) {
      const source = readFileSync(join(installedPackage(spec.package), site.file), 'utf8')
      const result = rewriteDisposeSite(source, site, spec.package)
      assert.equal(result.replacements, 1)
      assert.equal(result.source.includes(site.statement), false)
      assert.equal(result.source.includes(site.replacement), true)
      assert.match(result.sourceSha256, /^[0-9a-f]{64}$/u)
      assert.match(result.transformedSha256, /^[0-9a-f]{64}$/u)
      assert.notEqual(result.sourceSha256, result.transformedSha256)

      const drifted = source.replace(site.statement, '')
      assert.throws(
        () => rewriteDisposeSite(drifted, site, spec.package),
        /refuse to transform/u,
        `${spec.package} must fail loudly when the pinned statement is absent`,
      )
    }
  }
})

test('the real tool-subagent agent/disposed listener no longer throws after the Agent scope disposed its fiber', async () => {
  const original = await disposeToolSubagent(pathToFileURL(join(installedPackage('@deepseek-ai/dsh-tool-subagent'), 'lib/index.js')).href)
  assert.ok(original instanceof TypeError, 'the untransformed pinned listener must reproduce the TypeError')
  assert.match(original.message, /catch/u)

  const staged = stageTransformedPackages()
  const directory = staged.workspaces.get('@deepseek-ai/dsh-tool-subagent')
  const error = await disposeToolSubagent(pathToFileURL(join(directory, 'lib/index.js')).href)
  assert.equal(error, undefined, 'the transformed listener must accept a void disposal return')
})

test('the real file-reference-local listener accepts a void disposal, a rejection and a pending cleanup', async () => {
  const originalUrl = pathToFileURL(join(installedPackage('@deepseek-ai/dsh-file-reference-local'), 'lib/index.js')).href
  const originalRoot = serviceContext()
  const originalFiber = originalRoot.inject([], () => {})
  await originalFiber.dispose()
  const original = await disposeFileReference(originalUrl, originalFiber)
  assert.ok(original.error instanceof TypeError, 'the untransformed pinned listener must reproduce the TypeError')
  assert.match(original.error.message, /catch/u)
  assert.equal(original.sizes.fibers, 0, 'the original clears its fiber map before the TypeError')
  await original.root.fiber.dispose()

  const staged = stageTransformedPackages()
  const directory = staged.workspaces.get('@deepseek-ai/dsh-file-reference-local')
  const transformedUrl = pathToFileURL(join(directory, 'lib/index.js')).href

  const voidRoot = serviceContext()
  const voidFiber = voidRoot.inject([], () => {})
  await voidFiber.dispose()
  const voidResult = await disposeFileReference(transformedUrl, voidFiber)
  assert.equal(voidResult.error, undefined, 'a void disposal must not throw')
  assert.equal(voidResult.sizes.fibers, 0, 'the prompt fiber is removed from the pending map')
  assert.deepEqual(voidResult.warnings, [], 'a successful void disposal must not warn')
  await voidResult.root.fiber.dispose()

  const rejectResult = await disposeFileReference(
    transformedUrl,
    { dispose: () => Promise.reject(new Error('prompt cleanup failed')) },
  )
  assert.equal(rejectResult.error, undefined, 'a rejected disposal must reach the listener, not escape the event')
  await new Promise(resolve => setImmediate(resolve))
  assert.match(rejectResult.warnings.join('\n'), /prompt cleanup failed/u)
  assert.equal(rejectResult.sizes.fibers, 0)
  assert.equal(rejectResult.service.promptDisposals.size, 0, 'the rejected cleanup leaves the pending set')
  await rejectResult.root.fiber.dispose()

  let settle
  const pending = new Promise((resolve) => { settle = resolve })
  const pendingResult = await disposeFileReference(transformedUrl, { dispose: () => pending })
  assert.equal(pendingResult.error, undefined)
  assert.equal(pendingResult.sizes.disposals, 1, 'the pending cleanup stays tracked until it settles')
  settle()
  await pending
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(pendingResult.service.promptDisposals.size, 0, 'the pending cleanup leaves the set after settlement')
  await pendingResult.root.fiber.dispose()
})

/** Dependency closure the packer materializes for workspace packages. */
function workspaceClosure(all, roots, excluded) {
  const names = new Set(roots)
  const queue = [...roots]
  while (queue.length > 0) {
    const directory = all.get(queue.shift())
    if (directory === undefined) continue
    const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
    for (const field of ['dependencies', 'peerDependencies']) {
      const dependencies = manifest[field]
      if (typeof dependencies !== 'object' || dependencies === null) continue
      for (const name of Object.keys(dependencies)) {
        if (excluded.has(name) || !all.has(name) || names.has(name)) continue
        names.add(name)
        queue.push(name)
      }
    }
  }
  return names
}

test('the tmpdir staging materializes with the pinned packer and no missing packages', { skip: packerSkip, timeout: 180_000 }, async () => {
  const packer = await import(pathToFileURL(packerEntry).href)
  const all = new Map(packer.indexWorkspacePackages(checkout))
  const roots = DISPOSE_COMPAT_PACKAGES.map(spec => spec.package)
  // These two were reported unresolved from a tmpdir stage. Keep them out of
  // the workspace view so the packer must walk the staged node_modules links,
  // exactly as it did for zod (which is never a workspace).
  const excluded = new Set(['@deepseek-ai/dsh-scope', '@deepseek-ai/dsh-file-reference'])
  const names = workspaceClosure(all, roots, excluded)
  const workspaces = new Map([...names].map(name => [name, all.get(name)]))
  const root = mkdtempSync(join(tmpdir(), 'pdsh-dispose-pack-'))
  temporaryRoots.push(root)
  const staged = stageDisposeCompat({
    workspaces,
    output: join(root, 'stage'),
    commit: 'test-pinned-commit',
    version: 'test-pinned-version',
  })
  for (const [name, directory] of staged.workspaces) workspaces.set(name, directory)

  const result = packer.packVfsImage({
    profile: 'web',
    roster: [...names],
    workspaces,
    resolveFrom: checkout,
    entries: [],
  })
  assert.deepEqual(result.missing, [], 'a tmpdir stage must resolve every declared dependency from the pinned install')
  for (const fact of staged.facts) {
    const bytes = result.files[`node_modules/${fact.package}/${fact.file}`]
    assert.ok(bytes !== undefined, `${fact.package}/${fact.file} must reach the image`)
    const source = Buffer.from(bytes).toString('utf8')
    assert.equal(source.includes(fact.statement), false, `${fact.call_site} must not keep the void-unsafe call`)
    assert.equal(source.includes(fact.replacement), true, `${fact.call_site} must reach the image transformed`)
  }
})
