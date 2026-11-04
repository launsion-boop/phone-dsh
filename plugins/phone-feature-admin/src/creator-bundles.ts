// SPDX-License-Identifier: MIT
/** Offline preset bundles: real profile files and the official Loader, no pnpm. */
import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs'
import { rm } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import {
  composeEntries, loadOverlayPatches, loadProfileDirectory, readProfileManifest, readProfilePatches,
  recomposeProfile, type ProfileManifest,
} from '@deepseek-ai/dsh-app-boot'
import { entryListProblem } from '@deepseek-ai/dsh-agent-preset-registry'
import { withFileLock, writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'
import type { ChangeResult } from '@deepseek-ai/dsh-plugin-manager'
import type {} from '@deepseek-ai/dsh-agent-preset-registry'

const PATCH = 'cordis.patch.yml'
const MAX_FILE_BYTES = 512 * 1024
const PACKAGE_NAME = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/u
const PRESET_ID = /^[a-z0-9][a-z0-9-]{0,63}$/u

type Row = Record<string, unknown>
interface Bundle {
  name: string
  manifest: ProfileManifest
  manifestText: string
  patchText: string
  ids: string[]
}

function object(value: unknown): Row {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Row : {}
}

function optionalFile(file: string): string | undefined {
  try {
    const stat = lstatSync(file)
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('A saved preset file must be regular, not a symlink.')
    return readFileSync(file, 'utf8')
  }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error }
}

function safeDestination(profile: string, directory: string): void {
  let current = profile
  for (const part of relative(profile, directory).split('/')) {
    current = join(current, part)
    try {
      const stat = lstatSync(current)
      if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('The preset destination must not traverse symlinks or non-directories.')
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
}

function plainFile(file: string): string {
  const stat = lstatSync(file)
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_FILE_BYTES) {
    throw new Error('A phone preset bundle needs regular package.json and cordis.patch.yml files, at most 512 KiB each.')
  }
  return new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(file))
}

function noExpressions(value: unknown): void {
  if (value === null || typeof value !== 'object') return
  if (Object.hasOwn(value, '__jsExpr')) throw new Error('Phone preset bundles are declarative; !!js expressions are not supported.')
  for (const child of Object.values(value)) noExpressions(child)
}

function pluginNames(rows: unknown, into: Set<string>): void {
  if (!Array.isArray(rows)) return
  for (const value of rows) {
    const row = object(value)
    if (typeof row.name === 'string' && row.name !== 'cordis:group') into.add(row.name)
    if (row.group === true) pluginNames(row.config, into)
  }
}

/** Existing, mounted preset declarations are the catalog of supported scoped modules. */
function availablePresetModules(ctx: Context): Set<string> {
  const result = new Set<string>()
  const rows = composeEntries([readProfilePatches('phone-creator', ctx.profileContext)])
  for (const row of rows) {
    if (row.name === '@deepseek-ai/dsh-agent-preset') pluginNames(object(row.config).plugins, result)
  }
  return result
}

function checkPlugins(rows: unknown[], available: Set<string>): void {
  for (const value of rows) {
    const row = object(value)
    if (row.name === 'cordis:group' && row.group === true && Array.isArray(row.config)) {
      checkPlugins(row.config, available)
    } else if (typeof row.name !== 'string' || !available.has(row.name)) {
      throw new Error(`Preset module ${JSON.stringify(row.name)} is not in this Worker's shipped preset catalog. Inspect available Config/Tool providers; npm, Git and new JavaScript packages require desktop DSH.`)
    }
  }
}

function readBundle(directory: string, available: Set<string>): Bundle {
  const manifestText = plainFile(join(directory, 'package.json'))
  const manifest = JSON.parse(manifestText) as ProfileManifest
  const name = manifest.name
  if (typeof name !== 'string' || !PACKAGE_NAME.test(name)
      || name.startsWith('@deepseek-ai/') || name.startsWith('@phone-dsh/')) {
    throw new Error('Use a local bundle package name such as @local/dsh-review-preset; shipped namespaces cannot be replaced.')
  }
  for (const field of ['scripts', 'dependencies', 'optionalDependencies', 'devDependencies', 'peerDependencies'] as const) {
    const value = object(manifest)[field]
    if (value !== undefined && (value === null || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 0)) {
      throw new Error('Phone preset bundles cannot install dependencies or run lifecycle scripts. Use packages from the shipped preset catalog.')
    }
  }
  if (![PATCH, `./${PATCH}`].includes(String(manifest.dsh?.bundle?.patch))) {
    throw new Error('A phone preset bundle must declare dsh.bundle.patch as ./cordis.patch.yml.')
  }
  const patchText = plainFile(join(directory, PATCH))
  const patches = loadOverlayPatches('phone-creator', join(directory, PATCH))
  noExpressions(patches)
  const ids: string[] = []
  for (const value of patches) {
    const patch = object(value)
    if (Object.keys(patch).some(key => key !== 'insert') || !Array.isArray(patch.insert)) {
      throw new Error('Phone local bundles may insert Agent preset declarations only; overriding Host or shipped rows is not supported.')
    }
    for (const value of patch.insert) {
      const row = object(value)
      const config = object(row.config)
      if (row.name !== '@deepseek-ai/dsh-agent-preset' || typeof config.id !== 'string'
          || !PRESET_ID.test(config.id) || row.id !== `preset-${config.id}` || row.disabled === true
          || !Array.isArray(config.plugins)) {
        throw new Error('Each declaration needs id: preset-<id>, name: @deepseek-ai/dsh-agent-preset and config.id/plugins.')
      }
      const problem = entryListProblem(config.plugins)
      if (problem !== undefined) throw new Error(problem)
      checkPlugins(config.plugins, available)
      if (ids.includes(config.id)) throw new Error(`Preset ${config.id} is declared twice.`)
      ids.push(config.id)
    }
  }
  if (ids.length === 0) throw new Error('The bundle declares no Agent preset.')
  return { name, manifest, manifestText, patchText, ids }
}

/** Existing management envelope; never fabricate a pnpm packageResult. */
export function refusedBundle(target: string, diagnostic: string, stage: ChangeResult['stage'] = 'install'): ChangeResult {
  return { changed: false, application: 'failed', stage, target, error: { code: 'operation-error', diagnostic } }
}

/** Persistent, application-owned local bundle storage over the same profile. */
export class LocalPresetBundles {
  private readonly ctx: Context
  constructor(ctx: Context) { this.ctx = ctx }

  private directory(name: string): string { return join(this.ctx.profileContext.dir, 'node_modules', name) }
  private dependency(name: string): string { return `file:./node_modules/${name}` }

  owns(name: string): boolean {
    const dependencies = readProfileManifest('phone-creator', this.ctx.profileContext.dir).dependencies ?? {}
    return PACKAGE_NAME.test(name)
      && Object.hasOwn(dependencies, name) && dependencies[name] === this.dependency(name)
  }

  /** Copy the two validated files, publish the manifest, then verify real activation. */
  async install(source: string, enabled: boolean, signal: AbortSignal, applying: () => void): Promise<ChangeResult> {
    const profile = this.ctx.profileContext
    const workspace = realpathSync(profile.cwd)
    const directory = realpathSync(resolve(workspace, source))
    const traversal = relative(workspace, directory)
    if (traversal === '..' || traversal.startsWith('../') || traversal.startsWith('/')) {
      return refusedBundle(source, 'The preset bundle must be a real directory inside the phone workspace.')
    }
    const bundle = readBundle(directory, availablePresetModules(this.ctx))
    return this.change(bundle.name, 'install', signal, applying, async () => {
      const manifest = readProfileManifest('phone-creator', profile.dir)
      if (Object.hasOwn(manifest.dependencies ?? {}, bundle.name) && !this.owns(bundle.name)) {
        throw new Error('An installation with this package name already exists and is not owned by the phone preset installer.')
      }
      const destination = this.directory(bundle.name)
      if (existsSync(destination) && !this.owns(bundle.name)) throw new Error('The destination already exists; it was not overwritten.')
      const oldIds = this.owns(bundle.name) ? readBundle(destination, availablePresetModules(this.ctx)).ids : []
      const roster = await this.ctx.agentPresets.remoteExportList()
      for (const id of bundle.ids) {
        if (!oldIds.includes(id) && roster.presets.some(row => row.id === id)) throw new Error(`Preset ${id} already belongs to another declaration.`)
      }
      signal.throwIfAborted()
      await writeFileAtomic(join(destination, 'package.json'), bundle.manifestText, { mode: 0o600, dirMode: 0o700 })
      await writeFileAtomic(join(destination, PATCH), bundle.patchText, { mode: 0o600, dirMode: 0o700 })
      const selected = manifest.dsh?.profile?.bundles ?? []
      const next = selected.filter(name => name !== bundle.name)
      if (enabled) next.push(bundle.name)
      manifest.dependencies = { ...manifest.dependencies, [bundle.name]: this.dependency(bundle.name) }
      manifest.dsh = { ...manifest.dsh, profile: { ...manifest.dsh?.profile, bundles: next } }
      return { manifest, ids: enabled ? bundle.ids : [], bundle }
    })
  }

  async select(name: string, enabled: boolean, signal: AbortSignal): Promise<ChangeResult> {
    return this.change(name, 'enable', signal, () => {}, async () => {
      if (!this.owns(name)) throw new Error('This is not a phone-owned preset bundle.')
      const manifest = readProfileManifest('phone-creator', this.ctx.profileContext.dir)
      const bundle = readBundle(this.directory(name), availablePresetModules(this.ctx))
      const next = (manifest.dsh?.profile?.bundles ?? []).filter(item => item !== name)
      if (enabled) next.push(name)
      manifest.dsh = { ...manifest.dsh, profile: { ...manifest.dsh?.profile, bundles: next } }
      return { manifest, ids: enabled ? bundle.ids : [], bundle }
    })
  }

  private async change(
    name: string, stage: ChangeResult['stage'], signal: AbortSignal, applying: () => void,
    prepare: () => Promise<{ manifest: ProfileManifest; ids: string[]; bundle: Bundle }>,
  ): Promise<ChangeResult> {
    const profile = this.ctx.profileContext
    const manifestPath = join(profile.dir, 'package.json')
    const destination = this.directory(name)
    safeDestination(profile.dir, destination)
    return withFileLock(manifestPath, async () => {
      const before = readFileSync(manifestPath, 'utf8')
      const files = ['package.json', PATCH].map(file => [join(destination, file), optionalFile(join(destination, file))] as const)
      try {
        signal.throwIfAborted()
        const prepared = await prepare()
        signal.throwIfAborted()
        applying()
        await writeFileAtomic(manifestPath, `${JSON.stringify(prepared.manifest, null, 2)}\n`, { mode: 0o600 })
        const loaded = loadProfileDirectory('phone-creator', profile.dir, profile.installAnchor)
        const skipped = loaded.skippedBundles.find(bundle => bundle.packageName === name)
        if (skipped !== undefined) throw new Error(skipped.reason)
        const applied = await recomposeProfile(this.ctx.root, readProfilePatches('phone-creator', profile), 'phone-creator')
        if (applied.restartReason !== undefined) throw new Error(`Profile activation requires restart: ${applied.restartReason}`)
        for (const id of prepared.ids) {
          const row = (await this.ctx.agentPresets.remoteExportList()).presets.find(row => row.id === id)
          if (row === undefined || row.broken !== undefined) throw new Error(`Preset ${id} did not activate: ${row?.broken ?? 'declaration absent'}`)
          await this.ctx.agentPresets.resolve(id)
        }
        const changed = before !== readFileSync(manifestPath, 'utf8')
          || files.some(([file, contents]) => contents !== optionalFile(file))
        this.ctx.emit('plugin-manager/changed', { reason: stage === 'install' ? 'install' : 'bundle' })
        return { changed, application: 'applied', stage, target: name, bundle: name,
          enabled: prepared.manifest.dsh?.profile?.bundles?.includes(name) === true,
          ...prepared.bundle.manifest.version === undefined ? {} : { version: prepared.bundle.manifest.version },
          warnings: applied.warnings }
      } catch (error) {
        await writeFileAtomic(manifestPath, before, { mode: 0o600 })
        for (const [file, contents] of files) {
          if (contents === undefined) await rm(file, { force: true })
          else await writeFileAtomic(file, contents, { mode: 0o600 })
        }
        await recomposeProfile(this.ctx.root, readProfilePatches('phone-creator', profile), 'phone-creator-rollback')
        if (signal.aborted) return { changed: false, application: 'cancelled', stage, target: name }
        return refusedBundle(name, error instanceof Error ? error.message : String(error), stage)
      }
    })
  }
}
