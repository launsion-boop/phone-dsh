// SPDX-License-Identifier: MIT
/**
 * Tool surface for the memory maintainer (S3, spec/bot/v2 §4.1).
 *
 * A maintainer session may only read/write memory and look up its own raw
 * records. `tools.restrict` hides every other global tool from the model; the
 * guard is the hard, execution-time backstop because scoped registrations and
 * MCP tools can be added after the preset composes.
 */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-tools'

export const name = 'phone-memory-maintainer-scope'
export const inject = ['tools']

/** Session prefix the host mints for one Bot's maintenance session. */
export const MAINTAINER_SESSION_PREFIX = 'gb-maintainer-'

/** Bare names the maintainer may execute. */
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

const DENIAL = 'Maintainer sessions may only read and write memory (and use bash for `phone record`).'
const BASH_DENIAL = 'Maintainer bash is limited to `phone record search` and `phone record read`.'

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

function bashCommand(argumentsValue: unknown): string {
  if (typeof argumentsValue !== 'object' || argumentsValue === null) return ''
  const command = (argumentsValue as { command?: unknown }).command
  return typeof command === 'string' ? command : ''
}

export function apply(ctx: Context): void {
  let restriction: (() => void) | undefined
  // `bash` is registered by the preset itself; MCP memory tools arrive from the
  // global phone MCP client. If a name is missing (no phone MCP endpoint), it
  // is simply never visible. A filter with no allowed registered name would be
  // rejected by tools.restrict, so keep only present names.
  //
  // The registry can still be warming up when this preset composes. Do not
  // install a partial allow-list that would hide the memory tools forever
  // (restrictions are append-only); wait for `tools/change` and install the
  // full set once the MCP client has published them. The execution guard below
  // is the hard boundary in every case, and the global `maintainer-guard` row
  // enforces the same allow-list even when a pre-existing session runs another
  // preset.
  const syncVisibility = (): void => {
    if (restriction !== undefined) return
    const visible = ctx.tools.definitions().map(definition => definition.name)
    const allow = maintainerVisibleAllowList(visible)
    // Install the restriction only once the whole frozen surface is present:
    // restrictions are append-only, so a partial set would hide a sibling that
    // registers a moment later.
    const complete = [...MAINTAINER_ALLOWED_TOOLS].every(required =>
      allow.some(name => maintainerBareToolName(name) === required))
    if (!complete) return
    try {
      restriction = ctx.tools.restrict({ allow })
    } catch {
      // The named tools disappeared while the registry was changing; the next
      // tools/change retries.
    }
  }
  // Batch the registrations of one synchronous publish (the MCP client
  // registers its tools in a loop) before inspecting the registry.
  let scheduled = false
  const scheduleSync = (): void => {
    if (scheduled || restriction !== undefined) return
    scheduled = true
    queueMicrotask(() => {
      scheduled = false
      syncVisibility()
    })
  }
  scheduleSync()
  ctx.on('tools/change', scheduleSync)
  ctx.tools.guard(execution => {
    if (!maintainerToolAllowed(execution.name)) return DENIAL
    if (maintainerBareToolName(execution.name) === 'bash'
        && !maintainerBashAllowed(bashCommand(execution.arguments))) {
      return BASH_DENIAL
    }
    return undefined
  })
}
