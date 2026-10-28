// SPDX-License-Identifier: MIT
/**
 * Self-lockout guard for the phone management surface.
 *
 * DSH's plugin manager protects only its own management rows. The phone image
 * reaches the settings tab through a larger chain (webserver, phone surface,
 * Typert gateway/registry, remote access, the browser module/transport rows
 * and the Settings shell). The official inventory projection does not carry
 * the manager's `readOnlyReason`, so this package enforces the policy itself,
 * on the Host as well as in the page.
 *
 * Two layers keep the policy future-proof:
 * - every row from the shipped DSH or phone-dsh namespaces is protected by
 *   default, including packages added to the image later;
 * - {@link TOGGLEABLE_PLUGIN_MODULES} is the explicit allowlist of optional
 *   capabilities whose absence cannot take down the page, its carrier or the
 *   Agent/skill services it manages.
 *
 * A row from another namespace stays toggleable: it is not part of this
 * image's management chain.
 * @module @phone-dsh/dsh-feature-admin/protection
 */

/** One module whose disabled state would make the management page unreachable. */
export interface ProtectedPluginModule {
  readonly moduleName: string
  readonly reason: string
}

/** Rows that keep the page, its carrier, or its managed Agent/skill services reachable. */
export const PROTECTED_PLUGIN_MODULES: readonly ProtectedPluginModule[] = Object.freeze([
  {
    moduleName: '@phone-dsh/dsh-surface-phone',
    reason: 'The phone surface owns /api and the served settings page; disabling it would leave no way to re-enable anything.',
  },
  {
    moduleName: '@deepseek-ai/dsh-host-webserver',
    reason: 'The webserver is the only /api carrier; disabling it would make the settings page unreachable after restart.',
  },
  {
    moduleName: '@phone-dsh/dsh-feature-admin',
    reason: 'This page is the only installed-plugin enable control and cannot disable itself.',
  },
  {
    moduleName: '@deepseek-ai/dsh-host-plugin-inventory',
    reason: 'The inventory feeds this page; disabling it would leave no installed-plugin view after restart.',
  },
  {
    moduleName: '@deepseek-ai/dsh-api-gateway',
    reason: 'The Typert gateway dispatches every /api Remote call, including phone/featureAdmin; disabling it makes the page control path unreachable.',
  },
  {
    moduleName: '@deepseek-ai/dsh-typert-registry',
    reason: 'The Typert registry supplies the Remote descriptors and Agent lookup the gateway dispatches; disabling it breaks the page control path.',
  },
  {
    moduleName: '@deepseek-ai/dsh-api-remote-access',
    reason: 'The gateway requires remote-access for every non-owner call; disabling it prevents the gateway from serving the settings page.',
  },
  {
    moduleName: '@deepseek-ai/dsh-api-remotes',
    reason: 'The Remote event source feeds the shipped settings and session surfaces; disabling it leaves the management page without its live API baseline.',
  },
  {
    moduleName: '@deepseek-ai/dsh-api-session-controller',
    reason: 'The Session controller resolves Agents for preset selection and serves the session API this page uses.',
  },
  {
    moduleName: '@deepseek-ai/dsh-settings',
    reason: 'The live settings service backs the shipped configuration pages this management tab sits beside; disabling it removes their only read/write path.',
  },
  {
    moduleName: '@deepseek-ai/dsh-api-settings-controller',
    reason: 'The settings Remote is the browser-side carrier for the shipped settings forms; disabling it makes that section unavailable after restart.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-modules',
    reason: 'The browser module system serves this page and the shipped client bundles; disabling it would leave no UI after restart.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-connection',
    reason: 'The browser connection row owns the /api RPC transport this tab calls; disabling it leaves the page without a carrier.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-locale',
    reason: 'The locale registry renders every settings label and resolveSlotLabel call; disabling it leaves the page unable to render its own controls.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-ui-renderer',
    reason: 'The slot renderer mounts settings sections and tabs; disabling it leaves no UI into which this page or its controls can render.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-ui-layout',
    reason: 'The layout shell owns the settings route and its navigation; disabling it makes the settings page unreachable after restart.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-ui-settings',
    reason: 'The settings shell defines and mounts settings.section and settings.plugins.tab; disabling it removes the page this plugin registers into.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-ui-settings-plugins',
    reason: 'The Plugins section owns the settings.plugins.tab slot and its navigation row; disabling it leaves no Plugins page for this tab.',
  },
  {
    moduleName: '@deepseek-ai/dsh-client-ui-settings-plugin-inventory',
    reason: 'The official inventory tab is the shipped Plugins section baseline this page extends; disabling it removes the settings view users return through.',
  },
  {
    moduleName: '@deepseek-ai/dsh-agent-preset-registry',
    reason: 'The preset registry is the only real list/read/select roster; disabling it makes the preset section unsupported after restart.',
  },
  {
    moduleName: '@deepseek-ai/dsh-agent',
    reason: 'Preset selection binds the chosen preset to a live or resumable Agent; disabling the Agent service removes that real target.',
  },
  {
    moduleName: '@deepseek-ai/dsh-session',
    reason: 'Session identity and persistence back both the session list and preset target; disabling it leaves the page without a real session.',
  },
  {
    moduleName: '@deepseek-ai/dsh-skill',
    reason: 'The live skills registry is the only slash catalog this page invalidates; disabling it makes skill writes unverifiable and unrecoverable from the page.',
  },
])

/**
 * Optional rows the page may toggle.
 *
 * Each one only removes its own non-management feature. Their packages cannot
 * own /api, the settings shell, the browser module table or the Agent/skill
 * services, so a restart keeps the page and its recovery controls available.
 */
export const TOGGLEABLE_PLUGIN_MODULES: readonly string[] = Object.freeze([
  '@deepseek-ai/dsh-api-job-controller',
  '@deepseek-ai/dsh-api-terminal-controller',
  '@deepseek-ai/dsh-api-workspace-controller',
  '@deepseek-ai/dsh-file-reference-local',
  '@deepseek-ai/dsh-host-directory-picker-browse',
  '@deepseek-ai/dsh-message-feedback',
  '@deepseek-ai/dsh-office-to-pdf',
  '@deepseek-ai/dsh-schedule',
  '@deepseek-ai/dsh-session-reference',
  '@deepseek-ai/dsh-session-stats',
  '@deepseek-ai/dsh-session-turn-outline',
  '@deepseek-ai/dsh-tool-subagent',
  '@deepseek-ai/dsh-workspace-changes',
  '@deepseek-ai/dsh-workspace-files',
])

/** Namespaces whose rows belong to the shipped phone image and stay protected by default. */
const SHIPPED_NAMESPACES = ['@deepseek-ai/', '@phone-dsh/'] as const

/** Applies to a shipped-namespace row without a more specific entry above. */
export const DEFAULT_PROTECTED_REASON =
  'This is a shipped DSH/phone package. The phone image has no recovery console, so unlisted shipped rows stay enabled '
  + 'and cannot be disabled from this page.'

/** Strip a subpath so a row resolving `pkg/subpath` still matches its package. */
function packageRoot(moduleName: string): string {
  const segments = moduleName.split('/')
  return moduleName.startsWith('@') ? segments.slice(0, 2).join('/') : segments[0] ?? moduleName
}

const protectedModules = new Map<string, string>(
  PROTECTED_PLUGIN_MODULES.map(row => [row.moduleName, row.reason] as const),
)
const toggleableModules = new Set<string>(TOGGLEABLE_PLUGIN_MODULES)

/**
 * Reason this module must stay enabled, or undefined when the page may toggle it.
 * @param moduleName - exact Loader module specifier from the official inventory.
 * @returns the protection reason, when present.
 */
export function protectedPluginReason(moduleName: string): string | undefined {
  const root = packageRoot(moduleName)
  if (toggleableModules.has(root)) return undefined
  const explicit = protectedModules.get(root)
  if (explicit !== undefined) return explicit
  return SHIPPED_NAMESPACES.some(prefix => root.startsWith(prefix)) ? DEFAULT_PROTECTED_REASON : undefined
}

/** Whether the page may render an enable/disable switch for one inventory row. */
export interface PluginToggleAvailability {
  readonly available: boolean
  readonly reason?: string
}

/**
 * Resolve the switch decision for one row. The Host projection is
 * authoritative; the local set stays as defense for an older view.
 * @param moduleName - exact Loader module specifier.
 * @param readOnlyReason - reason the Host attached to the row, when any.
 * @returns whether to render a switch and, when not, the reason to show.
 */
export function pluginToggleAvailability(
  moduleName: string,
  readOnlyReason?: string,
): PluginToggleAvailability {
  const reason = readOnlyReason ?? protectedPluginReason(moduleName)
  return reason === undefined ? { available: true } : { available: false, reason }
}
