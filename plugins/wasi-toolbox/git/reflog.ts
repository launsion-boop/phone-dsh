// SPDX-License-Identifier: MIT
/**
 * Reflog bookkeeping for the ref-moving porcelain: `commit`, `branch`,
 * `switch` and `checkout`.
 *
 * The individual command implementations only move files under `refs/` and
 * `HEAD`; none of them owns `.git/logs`. This module is called at the `cli.ts`
 * dispatch boundary, captures HEAD and `refs/heads/*` before the command, reads
 * them again afterwards, and appends the entries the system git would have
 * written. Keeping it at the boundary means the command bodies stay unchanged
 * and every successful path is covered by one implementation.
 *
 * The entry format and the messages follow git: `<old-oid> <new-oid>
 * <name> <email> <epoch-seconds> <tz>\t<message>\n`, appended below
 * `<git-dir>/logs/HEAD` and `<common-dir>/logs/refs/heads/<name>`. A write
 * failure is not swallowed: the command fails loud instead of losing the audit
 * trail.
 * @module @phone-dsh/dsh-wasi-toolbox/git/reflog
 */
import { posix } from 'node:path'
import { isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import { parseGitDate } from './porcelain.ts'
import {
  discoverRepository, headOid, listRefs, readCommit, readRefFile,
} from './repo.ts'
import type { Repository, Signature } from './repo.ts'

/** All-zero object id git uses as the old value of a new ref. */
export const ZERO_OID = '0000000000000000000000000000000000000000'

/** The subcommands whose successful run can move a ref. */
export const REFLOG_COMMANDS: ReadonlySet<string> = new Set(['commit', 'branch', 'switch', 'checkout'])

/** HEAD and branch state captured before one command runs. */
export interface ReflogState {
  readonly repository: Repository
  readonly headOid?: string | undefined
  readonly headRef?: string | undefined
  readonly branches: ReadonlyMap<string, string>
}

/** How git treats a missing reflog for this repository. */
type LogMode = 'normal' | 'none'

/** Read HEAD and every local branch. */
async function stateOf(repository: Repository): Promise<ReflogState> {
  const headText = await readRefFile(repository, 'HEAD')
  const headLine = headText?.split('\n')[0]?.trim() ?? ''
  const symbolic = headLine.startsWith('ref:') ? headLine.slice(4).trim() : undefined
  const oid = await headOid(repository)
  const branches = await listRefs(repository, 'refs/heads/')
  return {
    repository,
    ...oid === undefined ? {} : { headOid: oid },
    ...symbolic === undefined ? {} : { headRef: symbolic },
    branches,
  }
}

/**
 * Capture the state a ref-moving command is about to change.
 *
 * Discovery failure is not this module's error: the command will report git's
 * ordinary "not a git repository" message. An existing repository with a
 * malformed HEAD is reported here, because otherwise the audit trail would be
 * skipped silently.
 */
export async function captureReflogState(
  fs: GitFs,
  cwd: string,
  env: Readonly<Record<string, string | undefined>>,
  configOverrides: readonly string[],
): Promise<ReflogState | undefined> {
  const repository = await discoverRepository(fs, cwd, env)
  if (repository === undefined) return undefined
  for (const override of configOverrides) {
    const equals = override.indexOf('=')
    if (equals > 0) repository.config.set(override.slice(0, equals).trim(), override.slice(equals + 1).trim())
  }
  return await stateOf(repository)
}

/** Read the post-command state. */
async function afterOf(state: ReflogState): Promise<ReflogState> {
  return await stateOf(state.repository)
}

/** The branch short name of a symbolic HEAD, else `HEAD`. */
function branchLabel(state: ReflogState): string {
  const ref = state.headRef
  if (ref !== undefined && ref.startsWith('refs/heads/')) return ref.slice('refs/heads/'.length)
  return 'HEAD'
}

/** The label git puts in `checkout: moving from ...`: branch or full oid. */
function checkoutLabel(state: ReflogState): string {
  const ref = state.headRef
  if (ref !== undefined && ref.startsWith('refs/heads/')) return ref.slice('refs/heads/'.length)
  return state.headOid ?? 'HEAD'
}

/** `core.logAllRefUpdates` as the two states this module acts on. */
function logMode(repository: Repository): LogMode {
  const raw = repository.config.get('core.logallrefupdates')?.trim().toLowerCase()
  if (raw === undefined) return repository.bare ? 'none' : 'normal'
  if (raw === 'always') return 'normal'
  if (['true', 'yes', 'on', '1'].includes(raw)) return 'normal'
  if (['false', 'no', 'off', '0', ''].includes(raw)) return 'none'
  return repository.bare ? 'none' : 'normal'
}

/** Reflog path for HEAD or a local branch. */
function reflogPath(repository: Repository, ref: string): string {
  return ref === 'HEAD'
    ? `${repository.gitDir}/logs/HEAD`
    : `${repository.commonDir}/logs/${ref}`
}

/** Format one committer identity exactly as git stores it in a reflog line. */
function formatSignature(signature: Signature): string {
  return `${signature.name} <${signature.email}> ${signature.timestamp} ${signature.timezone}`
}

/** Current committer identity for branch/checkout entries. */
function currentCommitter(repository: Repository, env: Readonly<Record<string, string | undefined>>): Signature {
  const name = env.GIT_COMMITTER_NAME ?? repository.config.get('user.name')
  const email = env.GIT_COMMITTER_EMAIL ?? repository.config.get('user.email')
  const date = parseGitDate(env.GIT_COMMITTER_DATE, Math.floor(Date.now() / 1000))
  return {
    name: name ?? 'unknown',
    email: email ?? 'unknown',
    timestamp: date.timestamp,
    timezone: date.timezone,
  }
}

/**
 * Append one reflog entry.
 *
 * `core.logAllRefUpdates=false` (and an unset value in a bare repository) stops
 * git from *creating* a reflog, but an existing log is still appended to;
 * that documented behaviour is reproduced here. A missing log under `none` is
 * simply not created, not an error.
 */
async function appendEntry(
  repository: Repository,
  ref: string,
  oldOid: string,
  newOid: string,
  signature: Signature,
  message: string,
  mode: LogMode,
): Promise<void> {
  const path = reflogPath(repository, ref)
  const exists = await repository.fs.exists(path)
  if (!exists && mode === 'none') return
  if (!exists) await repository.fs.mkdir(posix.dirname(path), true)
  // Reflog messages are one line: callers pass a subject, and a stray newline
  // would corrupt the record. Git replaces them with spaces; do the same.
  const oneLine = message.replace(/[\r\n]+/g, ' ')
  await repository.fs.appendFile(
    path,
    `${oldOid} ${newOid} ${formatSignature(signature)}\t${oneLine}\n`,
  )
}

/** One reflog line this module may append. */
interface ReflogEntry {
  readonly ref: string
  readonly oldOid: string
  readonly newOid: string
  readonly message: string
}

/**
 * Whether {@link appendEntry} would actually write this ref.
 *
 * A missing log under `none` is not created, so asking first keeps identity and
 * date parsing lazy: a read-only command or a disabled-log checkout must not
 * fail on `GIT_COMMITTER_DATE` when there is nothing to append.
 */
async function entryWouldAppend(repository: Repository, ref: string, mode: LogMode): Promise<boolean> {
  if (mode === 'normal') return true
  return await repository.fs.exists(reflogPath(repository, ref))
}

/** Keep only the entries that will be written, in their original order. */
async function writableEntries(
  repository: Repository,
  entries: readonly ReflogEntry[],
  mode: LogMode,
): Promise<ReflogEntry[]> {
  const writable: ReflogEntry[] = []
  for (const entry of entries) {
    if (await entryWouldAppend(repository, entry.ref, mode)) writable.push(entry)
  }
  return writable
}

/** Delete a branch's reflog file, whether or not logging is enabled. */
async function deleteBranchLog(repository: Repository, ref: string): Promise<void> {
  try {
    await repository.fs.rm(`${repository.commonDir}/logs/${ref}`)
  } catch (error) {
    if (!isErrno(error, 'ENOENT', 'ENOTDIR')) throw error
  }
}

/** Every branch that exists in `after` but not in `before`. */
function addedBranches(before: ReflogState, after: ReflogState): string[] {
  return [...after.branches.keys()].filter(name => !before.branches.has(name))
}

/** Every branch that disappeared between the two states. */
function deletedBranches(before: ReflogState, after: ReflogState): string[] {
  return [...before.branches.keys()].filter(name => !after.branches.has(name))
}

/** Branch refs whose object id moved. */
function movedBranches(before: ReflogState, after: ReflogState): string[] {
  return [...after.branches.entries()]
    .filter(([name, oid]) => before.branches.has(name) && before.branches.get(name) !== oid)
    .map(([name]) => name)
}

/** Parse the parts of `checkout` this module needs; undefined on path mode. */
function parseCheckout(args: readonly string[]): {
  readonly create: boolean
  readonly reset: boolean
  readonly pathMode: boolean
  readonly target?: string | undefined
  readonly start?: string | undefined
} | undefined {
  let create = false
  let reset = false
  let pathMode = false
  const rest: string[] = []
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '-b' || arg === '-B' || arg === '--orphan') {
      create = true
      if (arg === '-B') reset = true
      const value = args[index + 1]
      if (value === undefined) return undefined
      rest.unshift(value)
      index += 1
    } else if (arg === '--') {
      pathMode = true
    } else if (arg === '-f' || arg === '--force' || arg === '--detach'
      || arg === '-q' || arg === '--quiet') {
      continue
    } else if (arg.startsWith('-')) {
      // An unsupported flag makes the command fail; there is no successful run
      // to bookkeep.
      return undefined
    } else {
      rest.push(arg)
    }
  }
  return {
    create,
    reset,
    pathMode,
    ...rest[0] === undefined ? {} : { target: rest[0] },
    ...rest[1] === undefined ? {} : { start: rest[1] },
  }
}

/** Parse the parts of `switch` this module needs. */
function parseSwitch(args: readonly string[]): {
  readonly create: boolean
  readonly reset: boolean
  readonly pathMode: boolean
  readonly target?: string | undefined
  readonly start?: string | undefined
} | undefined {
  let create = false
  let reset = false
  const rest: string[] = []
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '-c' || arg === '--create' || arg === '-C' || arg === '--force-create') {
      create = true
      if (arg === '-C' || arg === '--force-create') reset = true
      const value = args[index + 1]
      if (value === undefined) return undefined
      rest.unshift(value)
      index += 1
    } else if (arg === '-d' || arg === '--detach' || arg === '-f' || arg === '--force'
      || arg === '--discard-changes' || arg === '-q' || arg === '--quiet') {
      continue
    } else if (arg.startsWith('-')) {
      return undefined
    } else {
      rest.push(arg)
    }
  }
  return {
    create,
    reset,
    pathMode: false,
    ...rest[0] === undefined ? {} : { target: rest[0] },
    ...rest[1] === undefined ? {} : { start: rest[1] },
  }
}

/** The start label for a branch created without an explicit start. */
function defaultStart(state: ReflogState): string {
  return branchLabel(state)
}

/** `commit`: the new commit's committer writes both HEAD and its branch. */
async function recordCommit(before: ReflogState, after: ReflogState, args: readonly string[]): Promise<void> {
  const repository = before.repository
  const newOid = after.headOid
  if (newOid === undefined) return
  const commit = await readCommit(repository, newOid)
  const subject = commit.message.split('\n')[0] ?? ''
  const amend = args.includes('--amend')
  const initial = before.headOid === undefined
  const message = amend
    ? `commit (amend): ${subject}`
    : `commit${initial ? ' (initial)' : ''}: ${subject}`
  const signature = commit.committer
  const mode = logMode(repository)
  const oldHead = before.headOid ?? ZERO_OID
  // A same-oid amend still moves HEAD's reflog in git even though the branch
  // ref itself is left untouched; append HEAD first, then only a branch whose
  // value actually changed.
  const branchRef = before.headRef
  if (branchRef !== undefined && branchRef.startsWith('refs/heads/')) {
    const oldBranch = before.branches.get(branchRef) ?? ZERO_OID
    const newBranch = after.branches.get(branchRef)
    if (newBranch !== undefined && newBranch !== oldBranch) {
      await appendEntry(repository, branchRef, oldBranch, newBranch, signature, message, mode)
    }
  }
  await appendEntry(repository, 'HEAD', oldHead, newOid, signature, message, mode)
}

/** `branch`: create/reset entries, plus reflog deletion for `-d`/`-D`. */
async function recordBranch(
  before: ReflogState,
  after: ReflogState,
  args: readonly string[],
  succeeded: boolean,
): Promise<void> {
  const repository = before.repository
  // `git branch -D a1 missing` deletes a1 and then exits non-zero. Git still
  // removes a1's log, so deletion is not gated on the command's exit status;
  // creating or resetting a ref remains gated and is handled below.
  for (const ref of deletedBranches(before, after)) await deleteBranchLog(repository, ref)
  if (!succeeded) return
  const positional = args.filter(arg => !arg.startsWith('-'))
  const explicitStart = positional[1]
  const start = explicitStart ?? defaultStart(before)
  const mode = logMode(repository)
  const entries: ReflogEntry[] = []
  for (const ref of addedBranches(before, after)) {
    entries.push({
      ref,
      oldOid: ZERO_OID,
      newOid: after.branches.get(ref) as string,
      message: `branch: Created from ${start}`,
    })
  }
  for (const ref of movedBranches(before, after)) {
    entries.push({
      ref,
      oldOid: before.branches.get(ref) as string,
      newOid: after.branches.get(ref) as string,
      message: `branch: Reset to ${start}`,
    })
  }
  // Read-only invocations (`git branch`, `--show-current`) produce no entries,
  // and a disabled log with no existing file produces none either. Resolve the
  // committer only after that decision so those commands never parse a date.
  const writable = await writableEntries(repository, entries, mode)
  if (writable.length === 0) return
  const signature = currentCommitter(repository, repository.env)
  for (const entry of writable) {
    await appendEntry(repository, entry.ref, entry.oldOid, entry.newOid, signature, entry.message, mode)
  }
}

/** `switch` / `checkout`: branch creation first, then the HEAD move. */
async function recordCheckout(
  before: ReflogState,
  after: ReflogState,
  args: readonly string[],
  kind: 'switch' | 'checkout',
): Promise<void> {
  const parsed = kind === 'checkout' ? parseCheckout(args) : parseSwitch(args)
  if (parsed === undefined || parsed.pathMode === true) return
  if (parsed.target === undefined) return
  const repository = before.repository
  // Git does not append a HEAD reflog record for a detached checkout that
  // already points at the same commit (`git checkout --detach HEAD` while
  // detached). The ref does not move and there is no audit entry to add.
  if (before.headRef === undefined && after.headRef === undefined && before.headOid === after.headOid) return
  const mode = logMode(repository)
  const entries: ReflogEntry[] = []
  // A reset of the current branch moves HEAD before the checkout record, so
  // that record's old value is the post-reset oid, not the pre-command one.
  let checkoutOldOid = before.headOid ?? ZERO_OID
  for (const ref of addedBranches(before, after)) {
    entries.push({
      ref,
      oldOid: ZERO_OID,
      newOid: after.branches.get(ref) as string,
      message: `branch: Created from ${parsed.start ?? 'HEAD'}`,
    })
  }
  if (parsed.create && parsed.reset && parsed.target !== undefined) {
    // `-B`/`-C` force-resets an existing branch. Git logs the move as
    // `branch: Reset to <start>` on the branch ref, but only when the oid
    // actually changes. When the target is HEAD's current branch it also
    // appends the same reset record to HEAD, even for an unchanged oid; a
    // branch log that did not move keeps only its previous entries.
    const ref = `refs/heads/${parsed.target}`
    const resetMessage = `branch: Reset to ${parsed.start ?? 'HEAD'}`
    const oldOid = before.branches.get(ref)
    const newOid = after.branches.get(ref)
    if (oldOid !== undefined && newOid !== undefined && oldOid !== newOid) {
      entries.push({ ref, oldOid, newOid, message: resetMessage })
    }
    if (before.headRef === ref && newOid !== undefined) {
      entries.push({
        ref: 'HEAD',
        oldOid: before.headOid ?? ZERO_OID,
        newOid: after.headOid ?? ZERO_OID,
        message: resetMessage,
      })
      checkoutOldOid = newOid
    }
  }
  entries.push({
    ref: 'HEAD',
    oldOid: checkoutOldOid,
    newOid: after.headOid ?? ZERO_OID,
    message: `checkout: moving from ${checkoutLabel(before)} to ${parsed.target}`,
  })
  // With logging disabled and no logs to append to, this is a ref-only move;
  // do not fail the successful switch because the committer date is unparseable.
  const writable = await writableEntries(repository, entries, mode)
  if (writable.length === 0) return
  const signature = currentCommitter(repository, repository.env)
  for (const entry of writable) {
    await appendEntry(repository, entry.ref, entry.oldOid, entry.newOid, signature, entry.message, mode)
  }
}

/**
 * Append or remove the reflog entries one command produced.
 *
 * Branch deletion is reconciled even when the command exits non-zero: git may
 * have removed some refs before failing on another. Appends remain gated on a
 * successful command.
 *
 * @param command - the dispatched subcommand name.
 * @param args - its arguments (global options already removed).
 * @param before - state captured by {@link captureReflogState}.
 * @param succeeded - whether the command exited 0.
 * @throws when the reflog cannot be written or removed; the caller turns that
 *   into a `fatal:` and a non-zero exit rather than dropping the audit entry.
 */
export async function recordReflog(
  command: string,
  args: readonly string[],
  before: ReflogState,
  succeeded: boolean,
): Promise<void> {
  if (command === 'branch') {
    await recordBranch(before, await afterOf(before), args, succeeded)
    return
  }
  if (!succeeded) return
  if (command === 'commit') {
    await recordCommit(before, await afterOf(before), args)
  } else if (command === 'switch' || command === 'checkout') {
    await recordCheckout(before, await afterOf(before), args, command)
  }
}
