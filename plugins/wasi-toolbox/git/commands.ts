// SPDX-License-Identifier: MIT
/**
 * The command table the git program dispatches through.
 *
 * Kept in one file so `cli.ts` has a single import and the package can expose
 * the same table to the Worker shell (`createWorkerCommands` appends the `git`
 * custom command; see README). The table is intentionally just a record:
 * adding a subcommand is adding an entry, and an unknown name is a plain
 * "not a git command" rather than a crash.
 * @module @phone-dsh/dsh-wasi-toolbox/git/commands
 */
import type { CommandHandler } from './cli.ts'
import {
  catFile, checkIgnore, diffTree, lsFiles, lsTree, revParse, writeTree,
} from './inspect.ts'
import { add, commit, init, restore, rm, status } from './porcelain.ts'
import { config } from './config.ts'
import { branch, checkout, diff, log, merge, remote, show, switchCommand } from './history.ts'
import { revList } from './revlist.ts'
import { tag } from './tag.ts'
import { clone, fetch, pull, push } from './remote.ts'

/** Subcommands that inspect the object database for DSH's workspace-changes. */
export const inspectCommands: Readonly<Record<string, CommandHandler>> = {
  'rev-parse': revParse,
  'write-tree': writeTree,
  'ls-tree': lsTree,
  'cat-file': catFile,
  'diff-tree': diffTree,
  'ls-files': lsFiles,
  'check-ignore': checkIgnore,
}

/** Subcommands that change the index, the working tree or the repository config. */
export const porcelainCommands: Readonly<Record<string, CommandHandler>> = {
  add,
  status,
  commit,
  restore,
  rm,
  init,
  config,
  tag,
}

/** History and branch porcelain. */
export const historyCommands: Readonly<Record<string, CommandHandler>> = {
  log,
  diff,
  show,
  branch,
  checkout,
  switch: switchCommand,
  merge,
  remote,
  'rev-list': revList,
}

/** Network porcelain. */
export const remoteCommands: Readonly<Record<string, CommandHandler>> = {
  clone,
  fetch,
  pull,
  push,
}

/** Every implemented subcommand. */
export function commandTable(): Readonly<Record<string, CommandHandler>> {
  return { ...inspectCommands, ...porcelainCommands, ...historyCommands, ...remoteCommands }
}
