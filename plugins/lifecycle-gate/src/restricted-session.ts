// SPDX-License-Identifier: MIT
/**
 * One mechanism for host-minted restricted sessions.
 *
 * The S3 read-only verifier (`pdsh-verifier`) and the S3 background memory
 * maintainer (`phone-bot-maintainer`) used to carry two independent guards,
 * two prefix tables and two preset-selection paths. They now share this module:
 *
 * - the App creates the session with the immutable `agentPreset` creation
 *   header and verifies the preset the Worker reports back;
 * - the session id uses the reserved `gb-<kind>-` prefix from
 *   {@link RESTRICTED_SESSIONS};
 * - a global execution-time guard resolves the session to exactly one policy
 *   by creation header (authoritative) or prefix (defense in depth), so a
 *   missed or later-changed preset scope cannot widen it;
 * - each restricted preset row installs the policy's visibility allow-list on
 *   the agent's own scope when that agent is created, plus the same guard.
 *
 * The two kinds differ only in their allow-list and bash rule.
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { ToolExecution } from '@deepseek-ai/dsh-tools'

/** Reserved session namespace for the read-only verifier. */
export const VERIFIER_SESSION_PREFIX = 'gb-verifier-'
/** Frozen preset selected by the immutable verifier creation header. */
export const VERIFIER_AGENT_PRESET = 'pdsh-verifier'
/** Reserved session namespace for the background memory maintainer. */
export const MAINTAINER_SESSION_PREFIX = 'gb-maintainer-'
/** Frozen preset selected by the immutable maintainer creation header. */
export const MAINTAINER_AGENT_PRESET = 'phone-bot-maintainer'

export type RestrictedSessionKind = 'verifier' | 'maintainer'

export interface RestrictedSessionPolicy {
  readonly kind: RestrictedSessionKind
  /** Immutable creation-header preset that identifies the session. */
  readonly agentPreset: string
  /** Reserved session-id prefix minted by the App. */
  readonly sessionPrefix: string
  /** Bare (provider-prefix stripped) tool names that may execute. */
  readonly allowedTools: ReadonlySet<string>
  /** Strip a provider prefix before comparing with {@link allowedTools}. */
  readonly bareToolName: (name: string) => string
  readonly toolDenial: string
  readonly bashAllowed?: (command: string) => boolean
  readonly bashDenial?: string
}

/** The only tools a verifier may execute (S3, spec/bot/v1 §2.8). */
export const VERIFIER_TOOLS: ReadonlySet<string> = new Set(['read', 'grep', 'glob', 'bash'])

const READ_ONLY_COMMANDS: ReadonlySet<string> = new Set([
  'cat', 'ls', 'grep', 'rg', 'head', 'tail', 'wc', 'pwd', 'stat', 'file', 'diff',
  'cut', 'sha256sum', 'shasum', 'md5', 'md5sum', 'basename', 'dirname', 'sort', 'uniq',
  'comm', 'cmp', 'realpath', 'readlink', 'od',
])

const READ_ONLY_GIT: ReadonlySet<string> = new Set([
  'diff', 'status', 'show', 'log', 'ls-files', 'rev-parse', 'cat-file', 'grep', 'blame',
])

/** Reject anything that can chain, substitute or redirect to a write. */
const SHELL_METACHARACTER = /[;&|><`$\\\n\r]/

/**
 * Whether one bash command is safe for a verifier. This is intentionally a
 * conservative positive list: parsing a full shell is not a security boundary,
 * so everything not clearly read-only is denied. `phone record search|read`
 * is the only external command the verifier needs.
 */
export function isReadOnlyBashCommand(raw: unknown): boolean {
  if (typeof raw !== 'string') return false
  const command = raw.trim()
  if (command === '' || SHELL_METACHARACTER.test(command)) return false
  const tokens = command.split(/\s+/)
  const verb = tokens[0]
  if (verb === undefined) return false
  if (verb === 'phone') {
    return tokens[1] === 'record' && (tokens[2] === 'search' || tokens[2] === 'read')
  }
  if (verb === 'git') {
    if (tokens[1] === undefined || !READ_ONLY_GIT.has(tokens[1])) return false
    return !tokens.some(token => token === '--output' || token.startsWith('--output='))
  }
  if (!READ_ONLY_COMMANDS.has(verb)) return false
  return !tokens.some(token => token.startsWith('--output=') || token === '--output')
}

/** Bare names the maintainer may execute (S3, spec/bot/v2 §4.1). */
export const MAINTAINER_ALLOWED_TOOLS: ReadonlySet<string> = new Set([
  'bash',
  'UpdateMemory',
  'ReadMemory',
  'RecallMemory',
])

const PHONE_TOOL_PREFIX = 'mcp__phone__'

export function maintainerBareToolName(name: string): string {
  return name.startsWith(PHONE_TOOL_PREFIX) ? name.slice(PHONE_TOOL_PREFIX.length) : name
}

export function maintainerToolAllowed(name: string): boolean {
  return MAINTAINER_ALLOWED_TOOLS.has(maintainerBareToolName(name))
}

/**
 * The raw-record lookup is the only reason the maintainer keeps `bash`. The
 * phone shell also routes `phone <capability>` and the network commands, so a
 * tool-name allow-list alone would leave device/egress reachable through a
 * shell command. Reject every command that is not one bare record read/search:
 * shell operators, substitutions, redirections and chained commands never
 * match.
 */
const RECORD_COMMAND = /^phone\s+record\s+(?:search|read)\b[^\n;&|`$<>\\]*$/u

export function maintainerBashAllowed(command: string): boolean {
  return RECORD_COMMAND.test(command.trim())
}

/** Names to keep visible, filtered to what is registered at compose time. */
export function maintainerVisibleAllowList(registered: readonly string[]): string[] {
  return registered.filter(maintainerToolAllowed)
}

export const VERIFIER_POLICY: RestrictedSessionPolicy = {
  kind: 'verifier',
  agentPreset: VERIFIER_AGENT_PRESET,
  sessionPrefix: VERIFIER_SESSION_PREFIX,
  allowedTools: VERIFIER_TOOLS,
  bareToolName: name => name,
  toolDenial: 'Verifier sessions are read-only and may only use read, grep, glob and read-only bash.',
  bashAllowed: isReadOnlyBashCommand,
  bashDenial: 'Verifier bash is restricted to read-only commands, including `phone record search|read`.',
}

export const MAINTAINER_POLICY: RestrictedSessionPolicy = {
  kind: 'maintainer',
  agentPreset: MAINTAINER_AGENT_PRESET,
  sessionPrefix: MAINTAINER_SESSION_PREFIX,
  allowedTools: MAINTAINER_ALLOWED_TOOLS,
  bareToolName: maintainerBareToolName,
  toolDenial: 'Maintainer sessions may only read and write memory (and use bash for `phone record`).',
  bashAllowed: maintainerBashAllowed,
  bashDenial: 'Maintainer bash is limited to `phone record search` and `phone record read`.',
}

export const RESTRICTED_SESSION_POLICIES: readonly RestrictedSessionPolicy[] = Object.freeze([
  VERIFIER_POLICY,
  MAINTAINER_POLICY,
])

/** Session id of an Agent; resumed agents may expose the live id. */
export function restrictedSessionId(agent: Agent | undefined): string {
  const subject = agent as (Agent & { session?: { id?: unknown } }) | undefined
  const sessionId = subject?.session?.id
  if (typeof sessionId === 'string' && sessionId !== '') return sessionId
  return typeof subject?.id === 'string' ? subject.id : ''
}

/** Immutable creation-header preset of an Agent (empty when absent). */
export function restrictedHeaderPreset(agent: Agent | undefined): string {
  const header = (agent?.session as { header?: { agentPreset?: unknown } } | undefined)
    ?.header?.agentPreset
  return typeof header === 'string' ? header.trim() : ''
}

/**
 * Resolve the one policy that owns a session. The immutable creation header is
 * authoritative; the reserved prefix is the defense-in-depth fallback for a
 * transport that dropped the header.
 */
export function restrictedPolicyFor(
  agent: Agent | undefined,
  policies: readonly RestrictedSessionPolicy[] = RESTRICTED_SESSION_POLICIES,
): RestrictedSessionPolicy | undefined {
  const header = restrictedHeaderPreset(agent)
  if (header !== '') {
    const byHeader = policies.find(policy => policy.agentPreset === header)
    if (byHeader !== undefined) return byHeader
  }
  const sessionId = restrictedSessionId(agent)
  if (sessionId !== '') {
    return policies.find(policy => sessionId.startsWith(policy.sessionPrefix))
  }
  return undefined
}

/**
 * Resolve only the immutable creation-header policy. Ordinary sessions also
 * carry a `header.agentPreset` (the configured default, e.g. `standard`), so
 * the preset selection path must skip only the restricted headers, never every
 * header.
 */
export function restrictedPolicyForHeader(
  agent: Agent | undefined,
  policies: readonly RestrictedSessionPolicy[] = RESTRICTED_SESSION_POLICIES,
): RestrictedSessionPolicy | undefined {
  const header = restrictedHeaderPreset(agent)
  if (header === '') return undefined
  return policies.find(policy => policy.agentPreset === header)
}

/** Whether this Agent is one of the host-minted restricted sessions. */
export function isRestrictedAgent(
  agent: Agent | undefined,
  policies: readonly RestrictedSessionPolicy[] = RESTRICTED_SESSION_POLICIES,
): boolean {
  return restrictedPolicyFor(agent, policies) !== undefined
}

/** The preset a host-minted restricted session id must select. */
export function restrictedPresetForSessionId(sessionId: string): string | undefined {
  return RESTRICTED_SESSION_POLICIES.find(policy => sessionId.startsWith(policy.sessionPrefix))
    ?.agentPreset
}

function bashCommand(argumentsValue: unknown): string {
  if (typeof argumentsValue !== 'object' || argumentsValue === null) return ''
  const command = (argumentsValue as { command?: unknown }).command
  return typeof command === 'string' ? command : ''
}

/** One policy's execution-time rule; shared by every mount point. */
export function restrictedGuardReason(
  execution: Readonly<ToolExecution>,
  policy: RestrictedSessionPolicy,
): string | undefined {
  const bare = policy.bareToolName(execution.name)
  if (!policy.allowedTools.has(bare)) return policy.toolDenial
  if (bare === 'bash' && policy.bashAllowed !== undefined
      && !policy.bashAllowed(bashCommand(execution.arguments))) {
    return policy.bashDenial
  }
  return undefined
}

/**
 * The single global guard implementation. It resolves the session to its
 * policy and applies that policy's rule; an ordinary Bot/workbench session
 * falls through untouched.
 */
export function applyRestrictedGuard(
  ctx: Context,
  policies: readonly RestrictedSessionPolicy[] = RESTRICTED_SESSION_POLICIES,
): void {
  ctx.tools.guard(execution => {
    const policy = restrictedPolicyFor(execution.agent, policies)
    return policy === undefined ? undefined : restrictedGuardReason(execution, policy)
  })
}

/**
 * Install one policy's visibility allow-list on one agent's own scope.
 *
 * The restriction must live on the agent scope, not on the shared preset
 * scope. DSH exempts the *viewing* scope's own registrations from its own
 * filter but applies an ancestor scope's filter to the ancestor's own
 * registrations too, so a filter installed on the preset hides the preset's
 * own `read`/`grep`/`glob`/`bash` from every agent parented to it (the empty
 * verifier surface this fixes). Per-agent installation hides every inherited
 * tool outside the allow-list while leaving the preset's contract tools
 * visible; an allow-list also hides tools registered after it, so a late MCP
 * reconnect stays hidden without a deny convergence pass.
 *
 * The filter is installed only once every policy tool is registered:
 * `tools.restrict({allow})` rejects names it cannot resolve, and the
 * maintainer's memory tools arrive from the phone MCP client after compose.
 * A partial allow-list is never installed.
 */
export function applyRestrictedVisibility(agent: Agent, policy: RestrictedSessionPolicy): void {
  const agentCtx = (agent as Agent & { readonly ctx?: Context }).ctx
  if (agentCtx === undefined || agentCtx.tools === undefined) return
  const tools = agentCtx.tools
  let restriction: (() => void) | undefined
  const syncVisibility = (): void => {
    if (restriction !== undefined) return
    const visible = tools.definitions(agent).map(definition => definition.name)
    const allow = visible.filter(name => policy.allowedTools.has(policy.bareToolName(name)))
    const complete = [...policy.allowedTools].every(required =>
      allow.some(name => policy.bareToolName(name) === required))
    if (!complete) return
    try {
      restriction = tools.restrict({ allow })
    } catch {
      // The named tools disappeared while the registry was changing; the next
      // tools/change retries.
    }
  }
  syncVisibility()
  agentCtx.on('tools/change', () => { syncVisibility() })
}

/**
 * Preset row install: the same guard plus the policy's visibility allow-list,
 * applied to every agent this preset revision is joined by. The preset
 * generation is shared by the agent that created it and any child the host
 * parents to it, so the filter is keyed by the resolved policy rather than by
 * this row's context.
 */
export function applyRestrictedScope(ctx: Context, policy: RestrictedSessionPolicy): void {
  ctx.on('agent/created', ({ agent }) => {
    if (restrictedPolicyFor(agent)?.kind !== policy.kind) return undefined
    applyRestrictedVisibility(agent, policy)
    return undefined
  })
  ctx.tools.guard(execution => restrictedGuardReason(execution, policy))
}
