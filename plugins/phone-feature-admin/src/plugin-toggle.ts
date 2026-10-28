// SPDX-License-Identifier: MIT
/**
 * Installed-plugin inventory and profile enablement.
 *
 * The inventory is DSH's own `pluginInventory.list()` projection. A toggle is
 * DSH's own `writePluginEnabled()` over the live `ProfileContext`, so comments,
 * `!!js` expressions and unrelated overrides survive the atomic write. The
 * official writer compares only the bundle layers with the file it edits, so a
 * same-id override in an earlier profile layer can make its "implied" decision
 * wrong. The write is therefore followed by a full bundle+profile+home+overlay
 * composition check and, when needed, an explicit home-layer switch. Every
 * read-modify-write cycle holds the official profile writer lock
 * (`<profile.dir>/package.json.lock`) so concurrent toggles cannot lose one
 * another's patch. Before either layer is touched the two patch files are
 * snapshotted; a failed repair or effective-state verification atomically
 * restores those exact bytes, so a reported failure cannot change the next
 * boot while another toggle's committed row stays intact.
 * @module @phone-dsh/dsh-feature-admin/plugin-toggle
 */

import { randomUUID } from 'node:crypto'
import { readFile, rename, rm, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { withFileLock, writeFileAtomic } from '@deepseek-ai/dsh-atomic-write'
import { isMap, isSeq, parseDocument } from 'yaml'
import { flatten, writePluginEnabled } from '@deepseek-ai/dsh-plugin-manager/src/patch.ts'
import {
  composeEntries,
  loadOptionalPatches,
  PROFILE_PATCH_FILENAME,
  readBundlePatches,
  type ProfileContext,
} from '@deepseek-ai/dsh-app-boot'
import type { PluginInventoryEntry, PluginInventorySnapshot } from '@deepseek-ai/dsh-host-plugin-inventory/types'
import {
  PLATFORM_LIMITS,
  type PluginListEntry,
  type PluginListView,
  type PluginToggleView,
} from './contracts.ts'
import { FeatureAdminError, invalidRequest, notFound, unsupported } from './errors.ts'
import { protectedPluginReason } from './protection.ts'

/** The part of DSH's PluginInventoryGateway this plugin uses. */
export interface PluginInventoryService {
  list(): Promise<PluginInventorySnapshot>
}

declare module '@deepseek-ai/cordis' {
  interface Context {
    /** Optional Host inventory service; absent compositions refuse instead of inventing rows. */
    pluginInventory?: PluginInventoryService
  }
}

/** Attach the phone protection reason without changing the official row. */
function projectEntry(entry: PluginInventoryEntry): PluginListEntry {
  const reason = protectedPluginReason(entry.moduleName)
  return reason === undefined ? entry : { ...entry, readOnlyReason: reason }
}

/** Projects the official inventory and states the platform boundary. */
export async function listInstalledPlugins(
  inventory: PluginInventoryService | undefined,
  profile: ProfileContext | undefined,
): Promise<PluginListView> {
  if (inventory === undefined) {
    throw unsupported('pluginInventory is not mounted in this profile, so no installed-plugin inventory can be read.')
  }
  const snapshot = await inventory.list()
  const management = profile === undefined
    ? {
      available: false,
      reason: 'profileContext is not available in this Host, so plugin enablement has no persistent profile patch to write.',
    }
    : snapshot.managementAvailable === false
      ? { available: false, reason: 'The Host reports no persistent current-profile management surface.' }
      : { available: true }
  return {
    ...snapshot,
    entries: snapshot.entries.map(projectEntry),
    platform: PLATFORM_LIMITS,
    management,
  }
}

/**
 * Pick the layer that can actually change this entry.
 *
 * DSH applies the profile patch before the home patch. A row inserted by the
 * home patch therefore has no profile target at all: a profile override would
 * be skipped as an unknown id. When the home layer names the entry, edit that
 * layer; otherwise use the launcher-provided profile patch exactly as DSH's
 * plugin manager does.
 * @param profile - live profile context.
 * @param entryId - Loader entry id being changed.
 * @returns the context whose `patchPath` should receive the write.
 */
export function patchTargetForEntry(profile: ProfileContext, entryId: string): ProfileContext {
  const homePatch = join(profile.home, PROFILE_PATCH_FILENAME)
  if (homePatch === profile.patchPath) return profile
  const rows = loadOptionalPatches('dsh', homePatch)
  if (rows === undefined) return profile
  const targetsEntry = rows.some((row) => {
    if (row === null || typeof row !== 'object') return false
    if (row.id === entryId) return true
    return Array.isArray(row.insert) && row.insert.some(entry => entry?.id === entryId)
  })
  return targetsEntry ? { ...profile, patchPath: homePatch } : profile
}

/** Find the exact inventory row a patch may target. */
export function findInventoryEntry(
  snapshot: PluginInventorySnapshot,
  entryId: string,
): PluginInventoryEntry {
  if (typeof entryId !== 'string' || entryId === '') throw invalidRequest('entryId must be a non-empty string')
  const row = snapshot.entries.find(entry => entry.entryId === entryId)
  if (row === undefined) throw notFound(`No installed plugin entry has id ${JSON.stringify(entryId)}`)
  return row
}

/**
 * Compose every layer the next boot applies and read the effective row.
 * @param profile - live profile context, before any patchPath substitution.
 * @param entryId - Loader entry id to look up.
 * @returns the effective entry, or undefined when no layer names it.
 */
function effectiveEntry(profile: ProfileContext, entryId: string) {
  const homePatch = join(profile.home, PROFILE_PATCH_FILENAME)
  const layers = [
    ...readBundlePatches('dsh', profile),
    ...(loadOptionalPatches('dsh', profile.patchPath) ?? []),
    ...(homePatch === profile.patchPath ? [] : loadOptionalPatches('dsh', homePatch) ?? []),
    ...profile.overlays,
  ]
  return flatten(composeEntries([layers])).findLast(entry => entry.id === entryId)
}

/**
 * Write one explicit home-layer switch, preserving every other key, comment
 * and `!!js` expression. Used only when the official writer's bundle-only
 * implied check would remove a home override that a profile layer still
 * contradicts.
 * @param profile - live profile context.
 * @param id - Loader entry id.
 * @param name - module name used to match a name-qualified override.
 * @param enabled - desired state.
 * @returns whether the home patch file changed.
 */
async function writeExplicitHomeSwitch(
  profile: ProfileContext,
  id: string,
  name: string,
  enabled: boolean,
): Promise<boolean> {
  const filename = join(profile.home, PROFILE_PATCH_FILENAME)
  let text: string
  try {
    text = await readFile(filename, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    text = '[]\n'
  }
  const document = parseDocument(text, {
    customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: (value: string) => value }],
  })
  const parseError = document.errors[0]
  if (parseError !== undefined) throw parseError
  if (!isSeq(document.contents)) throw new Error('Home patch must be a YAML sequence')
  const items = document.contents.items
  const target = items.findLast((item, index) => {
    if (!isMap(item) || document.getIn([index, 'id']) !== id || item.has('insert')) return false
    const expectedName = document.getIn([index, 'name'])
    return !expectedName || expectedName === name
  })
  const desired = !enabled
  if (isMap(target)) {
    const index = items.indexOf(target)
    if (document.getIn([index, 'disabled']) === desired) return false
    document.setIn([index, 'disabled'], desired)
  } else {
    document.add({ id, disabled: desired })
  }
  const temporary = `${filename}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, String(document), { mode: 0o600, flag: 'wx' })
    await rename(temporary, filename)
  } catch (error) {
    await unlink(temporary).catch(() => {})
    throw error
  }
  return true
}

/** Exact bytes of one patch file before this transaction, or `undefined` when it did not exist. */
interface PatchSnapshot {
  readonly path: string
  readonly text: string | undefined
}

/** Read one patch file without creating it. */
async function snapshotPatch(path: string): Promise<PatchSnapshot> {
  try {
    return { path, text: await readFile(path, 'utf8') }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { path, text: undefined }
    throw error
  }
}

/** Put one patch file back exactly as snapshotted; a new file is removed. */
async function restorePatch(snapshot: PatchSnapshot): Promise<void> {
  if (snapshot.text === undefined) {
    await rm(snapshot.path, { force: true })
    return
  }
  await writeFileAtomic(snapshot.path, snapshot.text, { mode: 0o600 })
}

/** Restore every layer this transaction may have touched, reporting per-file failures. */
async function rollbackPatches(snapshots: readonly PatchSnapshot[]): Promise<string[]> {
  const failures: string[] = []
  for (const snapshot of snapshots) {
    try {
      await restorePatch(snapshot)
    } catch (error) {
      failures.push(`${snapshot.path}: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
  return failures
}

/**
 * Atomic `disable`/`enable` patch through DSH's plugin manager.
 *
 * The two patch layers this call can edit are snapshotted after the official
 * lock is held. A repair write, composition read or final verification failure
 * restores those exact bytes before the refusal leaves the Remote, so a failed
 * call cannot change the next boot and cannot erase a row another toggle
 * committed while waiting for the same lock.
 * @param profile - live profile the Worker booted from.
 * @param inventory - official inventory projection.
 * @param entryId - Loader entry id shown by the settings tab.
 * @param enabled - desired state.
 * @returns write outcome and the restart boundary.
 */
export async function setInstalledPluginEnabled(
  profile: ProfileContext | undefined,
  inventory: PluginInventoryService | undefined,
  entryId: string,
  enabled: boolean,
): Promise<PluginToggleView> {
  if (profile === undefined) {
    throw unsupported(
      'profileContext is not available in this Host, so plugin enablement cannot be written to the current home profile patch.',
    )
  }
  if (inventory === undefined) {
    throw unsupported('pluginInventory is not mounted in this profile, so the installed entry cannot be resolved.')
  }
  if (typeof enabled !== 'boolean') throw invalidRequest('enabled must be a boolean')
  // The official plugin manager and config editor serialize every profile
  // patch mutation on this same lock file. Holding it across the inventory
  // read, layer choice, official write, repair and verification is what keeps
  // two independent toggles from both reading the old patch and losing one
  // another's write.
  return withFileLock(join(profile.dir, 'package.json'), async () => {
    const homePatchPath = join(profile.home, PROFILE_PATCH_FILENAME)
    const snapshots = await Promise.all(
      [...new Set([profile.patchPath, homePatchPath])].map(snapshotPatch),
    )
    // Set immediately before a writer runs: a throw from writePluginEnabled or
    // the repair path then restores both snapshotted layers, while a failure
    // before any mutation (inventory, protection, layer choice) leaves them
    // untouched.
    let mutationAttempted = false
    try {
      const snapshot = await inventory.list()
      const row = findInventoryEntry(snapshot, entryId)
      const protectedReason = protectedPluginReason(row.moduleName)
      if (protectedReason !== undefined) throw new FeatureAdminError('conflict', protectedReason)
      const target = patchTargetForEntry(profile, row.entryId)
      let patchPath = target.patchPath
      mutationAttempted = true
      let changed = await writePluginEnabled(target, row.entryId, row.moduleName, enabled)
      if ((effectiveEntry(profile, row.entryId)?.disabled ?? false) !== !enabled) {
        mutationAttempted = true
        const repaired = await writeExplicitHomeSwitch(profile, row.entryId, row.moduleName, enabled)
        if (repaired) patchPath = homePatchPath
        changed = repaired || changed
      }
      const effective = effectiveEntry(profile, row.entryId)
      if ((effective?.disabled ?? false) !== !enabled) {
        throw new FeatureAdminError(
          'conflict',
          `The profile patch write left ${JSON.stringify(row.entryId)} ${enabled ? 'disabled' : 'enabled'}; `
          + 'a launch overlay may override the home layer.',
        )
      }
      return {
        entryId: row.entryId,
        moduleName: row.moduleName,
        enabled,
        changed,
        restartRequired: changed,
        patchPath,
      }
    } catch (error) {
      if (!mutationAttempted) throw error
      const failures = await rollbackPatches(snapshots)
      if (failures.length === 0) throw error
      const reason = error instanceof Error ? error.message : String(error)
      throw new FeatureAdminError(
        'io-error',
        `Plugin toggle failed (${reason}) and restoring the profile patches also failed (${failures.join('; ')}).`,
      )
    }
  })
}
