// SPDX-License-Identifier: MIT
/**
 * Read-only isolation for verifier sessions (`pdsh-verifier`).
 *
 * The preset mounts only `read`/`grep`/`glob` and `bash`; this row hides every
 * inherited global tool (the phone MCP surface, web, jobs, memory, Task, …)
 * and leaves the preset's own scope-local registrations intact. The guard is a
 * second, monotonic denial: even if a future preset mounts a wider row, only
 * the whitelist may run, and `bash` must be a read-only command.
 */
import type { Context } from '@deepseek-ai/cordis'
import type { ToolExecution } from '@deepseek-ai/dsh-tools'

export const name = 'phone-verifier-isolation'
export const inject = ['tools']

export const VERIFIER_TOOLS: ReadonlySet<string> = new Set(['read', 'grep', 'glob', 'bash'])

const READ_ONLY_COMMANDS: ReadonlySet<string> = new Set([
  'cat', 'ls', 'grep', 'rg', 'head', 'tail', 'wc', 'pwd', 'stat', 'file', 'diff',
  'cut', 'sha256sum', 'shasum', 'md5', 'md5sum', 'basename', 'dirname', 'sort', 'uniq',
  'comm', 'cmp', 'realpath', 'readlink',
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

export function verifyGuardReason(execution: Readonly<ToolExecution>): string | undefined {
  if (!VERIFIER_TOOLS.has(execution.name)) {
    return 'Verifier sessions are read-only and may only use read, grep, glob and read-only bash.'
  }
  if (execution.name === 'bash') {
    const command = (execution.arguments as { command?: unknown } | undefined)?.command
    if (!isReadOnlyBashCommand(command)) {
      return 'Verifier bash is restricted to read-only commands, including `phone record search|read`.'
    }
  }
  return undefined
}

export function apply(ctx: Context): void {
  // Mask every tool inherited from the global layer. Scope-local rows mounted
  // by the preset survive this filter by design.
  ctx.tools.restrict({ allow: [] })
  ctx.tools.guard(verifyGuardReason)
}
