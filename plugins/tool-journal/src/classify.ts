// SPDX-License-Identifier: MIT
/**
 * Tool side-effect classes for crash-only resume.
 * - `read-only`: no external effect; safe to run again.
 * - `idempotent`: running twice leaves the same state as running once.
 * - `non-idempotent`: anything else. Unknown tools are non-idempotent.
 * @module @phone-dsh/dsh-tool-journal/classify
 */

export type ToolClass = 'read-only' | 'idempotent' | 'non-idempotent'

/**
 * Defaults for the DSH 0.1.7 tool names the phone profile mounts. `write` and
 * `edit` stay non-idempotent: a repeated `edit` applies its replacement to
 * already-edited text, and `write` carries an expected-version check that a
 * second run may fail. `bash` is non-idempotent because the command is opaque.
 */
export const DEFAULT_TOOL_CLASSES: Readonly<Record<string, ToolClass>> = {
  read: 'read-only',
  read_image: 'read-only',
  glob: 'read-only',
  grep: 'read-only',
  job_output: 'read-only',
  list_agents: 'read-only',
  todo_write: 'idempotent',
}

/**
 * Build a classifier from exact names and `*`-suffix prefixes (e.g. `mcp__phone__calendar_*`).
 * @param overrides - deployment classes layered over the defaults.
 * @returns name -> class, `non-idempotent` when nothing matches.
 */
export function createClassifier(overrides: Readonly<Record<string, ToolClass>> = {}): (name: string) => ToolClass {
  const exact = new Map<string, ToolClass>()
  const prefixes: Array<[string, ToolClass]> = []
  for (const [pattern, toolClass] of Object.entries({ ...DEFAULT_TOOL_CLASSES, ...overrides })) {
    if (pattern.endsWith('*')) prefixes.push([pattern.slice(0, -1), toolClass])
    else exact.set(pattern, toolClass)
  }
  prefixes.sort((a, b) => b[0].length - a[0].length)
  return (name) => exact.get(name) ?? prefixes.find(([prefix]) => name.startsWith(prefix))?.[1] ?? 'non-idempotent'
}
