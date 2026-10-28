// SPDX-License-Identifier: MIT
/**
 * Wire contract shared by the Host Remote and the browser settings tab.
 *
 * The methods live in the existing `phone` Remote namespace. They only manage
 * capabilities the running image already has; nothing here installs, removes
 * or invents a package, a skill or an agent preset.
 * @module @phone-dsh/dsh-feature-admin/contracts
 */

import type { PluginInventoryEntry, PluginInventorySnapshot } from '@deepseek-ai/dsh-host-plugin-inventory/types'
import type { AgentPresetDocument, AgentPresetRoster } from '@deepseek-ai/dsh-agent-preset-registry/types'

/** Host Remote namespace used by the phone carrier. */
export const FEATURE_ADMIN_NAMESPACE = 'phone'

/** The one directory the Host edits for user skills. */
export const SKILLS_ROOT = '/dsh/home/skills'

/** Plain reason the page shows instead of offering an install control. */
export const NO_PACKAGE_INSTALL_REASON =
  'This iPhone host manages capabilities already packed into the running DSH image. '
  + 'Installing or removing plugin packages needs pnpm and a new profile package set, which this platform does not provide.'

/** Host facts the settings tab renders next to the controls. */
export interface PlatformLimits {
  readonly canInstallPackages: false
  readonly installReason: string
  readonly restartRequiredForPluginChanges: true
  readonly skillsRoot: string
}

/** Fixed platform boundary; the phone image has no package manager. */
export const PLATFORM_LIMITS: PlatformLimits = Object.freeze({
  canInstallPackages: false,
  installReason: NO_PACKAGE_INSTALL_REASON,
  restartRequiredForPluginChanges: true,
  skillsRoot: SKILLS_ROOT,
})

/** Failure vocabulary the page can act on without parsing prose. */
export type FeatureAdminFailureCode =
  | 'unsupported'
  | 'invalid-request'
  | 'not-found'
  | 'conflict'
  | 'io-error'
  | 'internal'

/** Structured result returned by every Feature Admin method. */
export type FeatureAdminResult<Value> =
  | { readonly ok: true; readonly value: Value }
  | {
    readonly ok: false
    readonly code: FeatureAdminFailureCode
    readonly reason: string
    /** Original domain code when a DSH service refused the request. */
    readonly domainCode?: string
  }

/** One official inventory row projected with the phone self-lockout guard. */
export interface PluginListEntry extends PluginInventoryEntry {
  /** Why the page must not render a switch for this row; absent when writable. */
  readonly readOnlyReason?: string
}

/** Inventory plus the platform limits the page must display. */
export interface PluginListView extends PluginInventorySnapshot {
  /** Official rows, each carrying the minimal phone read-only reason when protected. */
  readonly entries: readonly PluginListEntry[]
  readonly platform: PlatformLimits
  /** Host service the page may call to toggle one listed row. */
  readonly management: {
    readonly available: boolean
    readonly reason?: string
  }
}

/** One successful profile-patch write. */
export interface PluginToggleView {
  readonly entryId: string
  readonly moduleName: string
  readonly enabled: boolean
  /** Whether the atomic profile edit changed the file. */
  readonly changed: boolean
  /** A changed patch takes effect on the next DSH boot. */
  readonly restartRequired: boolean
  /** Profile patch file the atomic write targeted (profile layer or home layer). */
  readonly patchPath: string
}

/** One flat Markdown skill under {@link SKILLS_ROOT}. */
export interface SkillFileView {
  /** File name (kebab-case plus `.md`). */
  readonly name: string
  /** Skill name without the `.md` suffix. */
  readonly skillName: string
  readonly bytes: number
  readonly modifiedAt: string
}

/** One skill body read from disk. */
export interface SkillDocumentView {
  readonly name: string
  readonly content: string
}

/** Result of one skill mutation. */
export interface SkillMutationView {
  readonly name: string
  readonly deleted?: boolean
  /** The live registry catalog cache was explicitly invalidated. */
  readonly invalidation: 'catalog'
}

/** One selectable live session for a preset switch. */
export interface FeatureAdminSessionView {
  readonly id: string
  readonly title: string
  readonly blank: boolean
  readonly agentPreset?: string
}

/** Agent-preset request handled by the existing `ctx.agentPresets` service. */
export type AgentPresetsRequest =
  | { readonly action: 'list' }
  | { readonly action: 'read'; readonly presetId: string }
  | { readonly action: 'select'; readonly sessionId: string; readonly presetId: string }

/** Action names the one `agentPresets` endpoint dispatches. */
export type AgentPresetsAction = AgentPresetsRequest['action']

/** Agent-preset result, proxied from the official Remote methods. */
export type AgentPresetsValue =
  | { readonly action: 'list'; readonly roster: AgentPresetRoster }
  | { readonly action: 'read'; readonly document: AgentPresetDocument }
  | { readonly action: 'select'; readonly presetId: string }

/** Host constructor options; the final profile row may pin the skills root. */
export interface FeatureAdminConfig {
  readonly skillsRoot?: string
}
