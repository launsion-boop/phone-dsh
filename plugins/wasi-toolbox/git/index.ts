// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-wasi-toolbox/git` — git over the DSH phone Worker VFS.
 *
 * The program is JavaScript, not WASI: it runs next to the Worker shell, reads
 * and writes the same `node:fs` the runtime backs with its in-memory VFS, and
 * therefore keeps every writing command inside the Worker (PLAN D12). It
 * implements the eight subcommands DSH's `workspace-changes` plugin uses
 * (`rev-parse`, `add --all`, `write-tree`, `ls-tree`, `cat-file`, `diff-tree`,
 * `ls-files`, `check-ignore -z --stdin`) byte-for-byte, plus the porcelain an
 * agent expects (`status`, `log`, `diff`, `add`, `commit` including `--amend`,
 * `restore`, `checkout`, `switch`, `branch`, `tag`, `init`, `clone`, `fetch`,
 * `push`).
 *
 * Dependency note: the plan names isomorphic-git; the maintainers chose the
 * otherwise zero-dependency implementation and only the pure-JavaScript zlib
 * codec comes from `fflate` (MIT), because the Worker runtime's `node:zlib`
 * has no deflate/inflate. See README.md ("Dependencies").
 * @module @phone-dsh/dsh-wasi-toolbox/git
 */
export { runGit, Output } from './cli.ts'
export type { CommandContext, GitRunContext, GitRunResult } from './cli.ts'
export { commandTable, historyCommands, inspectCommands, porcelainCommands, remoteCommands } from './commands.ts'
export { GIT_SUPPORTED_FORMS, GIT_TRIM_FACTS, gitCapability, gitCommands } from './capability.ts'
export type { GitCapability, GitTrimFact } from './capability.ts'
export {
  createGitCommand, createGitToolboxProgram, registerGitCommand, registerGitProgram, runGitForShell, shellEnvironment,
} from './command.ts'
export type { GitCommandOptions, GitCommandRegistry, GitShellCommand, GitShellContext, GitToolboxProgram } from './command.ts'
export { GitFailure, errorFailure, fatal, usage } from './errors.ts'
export { NodeGitFs, compareStrings, decodeText, encodeText, isErrno, resolvePath } from './fs.ts'
export type { GitDirent, GitFs, GitStat } from './fs.ts'
export { EMPTY_INDEX, encodeIndex, parseIndex, readIndex, writeIndex } from './gindex.ts'
export type { GitIndex, IndexEntry } from './gindex.ts'
export { compilePattern, globToRegexBody, isIgnored, loadIgnoreRules } from './ignore.ts'
export type { IgnoreRules } from './ignore.ts'
export { ObjectDatabase, objectId } from './objects.ts'
export type { GitObject, ObjectDirectories } from './objects.ts'
export { applyDelta, buildPack, buildPackIndex, readPackIndex, sha1Hex } from './pack.ts'
export type { PackIndex, PackWriteEntry, PackWriteResult } from './pack.ts'
export { discoverRepository, openRepository, parseCommit, readCommit, readTreeRecursive, resolveRevision } from './repo.ts'
export type { CommitInfo, Repository, Signature, TreeEntry } from './repo.ts'
export { HostHttpTransport, redactUrl, resolveHostHttp } from './http.ts'
export type { HostHttpOptions, HttpRequest, HttpResult, RemoteTransport } from './http.ts'
export { importPack, parsePack, parsePktLines, pktLine } from './remote.ts'
export { diffLines, countDiff, isBinary, splitLines, unifiedHunks } from './textdiff.ts'
export type { DiffCounts, DiffHunk, DiffOp, TextLine } from './textdiff.ts'
export { buildTreeFromIndex, diffFlatTrees, diffTrees, parseMode, readWorktreeBlob } from './tree.ts'
export type { TreeChange } from './tree.ts'
export type { FlatTreeEntry } from './repo.ts'
export { scanWorktree } from './worktree.ts'
export type { WorktreeFile } from './worktree.ts'
