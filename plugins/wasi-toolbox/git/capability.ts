// SPDX-License-Identifier: MIT
/**
 * The Worker git capability disclosure: the real subcommand table and the
 * revision forms it does not implement.
 *
 * One owner: the command list is derived from {@link commandTable}, so a new
 * subcommand appears in the boot manifest the moment it is implemented, and a
 * removed one disappears. The trim facts are deliberately narrow: they record
 * only behaviour that is not implemented today. `<rev>:<path>` is a
 * *supported* form (blob content for `git show <rev>:<path>` and
 * `git rev-parse <rev>:<path>`), so it belongs under `supported_forms`, never
 * under `trimmed`.
 * @module @phone-dsh/dsh-wasi-toolbox/git/capability
 */
import { commandTable } from './commands.ts'

/** One real gap between the Worker git and full git. */
export interface GitTrimFact {
  /** Stable id a test and the model can refer to. */
  readonly id: string
  /** What the Worker git does not do. */
  readonly note: string
  /** The closest supported spelling. */
  readonly alternative: string
}

/** The git surface the boot capability manifest publishes. */
export interface GitCapability {
  /** Every implemented subcommand, sorted (derived from `commandTable()`). */
  readonly commands: readonly string[]
  /** Revision and invocation forms the implementation really serves. */
  readonly supported_forms: readonly string[]
  /** Real gaps; every alternative is itself a supported command form. */
  readonly trimmed: readonly GitTrimFact[]
}

/** Revision and invocation forms the implementation serves. */
export const GIT_SUPPORTED_FORMS: readonly string[] = Object.freeze([
  '`<rev>:<path>` (file content, `git show <rev>:<path>`)',
  'one revision per `git show`; `git diff A B` for two',
])

/** The gaps a model must know before it writes a git-dependent script. */
export const GIT_TRIM_FACTS: readonly GitTrimFact[] = Object.freeze([
  Object.freeze({
    id: 'GIT-REVISION-RANGE',
    note: '`A..B`/`A...B` ranges are not parsed by log/show/diff',
    alternative: 'use `git diff A B`, or `git log --oneline` plus one `git show` per commit',
  }),
  Object.freeze({
    id: 'GIT-SHOW-REF',
    note: '`show-ref` is not a subcommand (exit 1)',
    alternative: 'use `git branch`, `git rev-parse <ref>` or `git log --all --oneline`',
  }),
  Object.freeze({
    id: 'GIT-SHOW-ONE-REVISION',
    note: '`git show` uses only the first revision',
    alternative: 'one `git show` per revision, or `git diff A B`',
  }),
  Object.freeze({
    id: 'GIT-LOG-GRAPH-DECORATE',
    note: '`--graph`/`--decorate` exit 129',
    alternative: 'use `git log --oneline`; the Worker git draws no graph or decorations',
  }),
])

/**
 * The implemented subcommands, sorted. `commandTable()` is the single source:
 * this function never carries its own copy of the list.
 * @returns sorted subcommand names.
 */
export function gitCommands(): string[] {
  return Object.keys(commandTable()).sort()
}

/**
 * Build the git capability block the boot manifest publishes.
 * @returns the real subcommands plus the static supported/trimmed forms.
 */
export function gitCapability(): GitCapability {
  return {
    commands: gitCommands(),
    supported_forms: [...GIT_SUPPORTED_FORMS],
    trimmed: [...GIT_TRIM_FACTS],
  }
}
