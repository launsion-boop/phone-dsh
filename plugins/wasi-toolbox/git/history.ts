// SPDX-License-Identifier: MIT
/**
 * History and branch porcelain: `log`, `diff`, `show`, `branch`, `checkout`,
 * `switch` and fast-forward `merge`.
 *
 * Output formats follow the system git closely enough for an agent (and for
 * the golden tests) to rely on: `log --oneline`, the medium commit header,
 * unified diffs with rename detection, and `--stat`/`--numstat` forms. Nothing
 * here rewrites history; a merge that would need three-way conflict resolution
 * fails with a clear limitation message instead of producing a half-merged
 * index.
 * @module @phone-dsh/dsh-wasi-toolbox/git/history
 */
import { GitFailure, errorFailure, fatal } from './errors.ts'
import { compareBytes, compareStrings, concatBytes, decodeText, encodeText, isErrno } from './fs.ts'
import { statEntry, writeIndex } from './gindex.ts'
import type { IndexEntry } from './gindex.ts'
import { hashBlob } from './objects.ts'
import {
  flattenTree, headOid, headRef, listRefs, parseSignature, readCommit, readRefFile, requireWorkTree,
  resolveBranchOrRef, resolveRef, resolveRevision, shortOid, writeBranch, writeRef, deleteBranch,
} from './repo.ts'
import type { CommitInfo, Repository, Signature } from './repo.ts'
import { diffFlatTrees, parseMode, readWorktreeBlob } from './tree.ts'
import type { TreeChange } from './tree.ts'
import { countDiff, isBinary, splitLines, unifiedHunks, formatRange, renderHunkBody } from './textdiff.ts'
import { ensureParent, removeWorktreePath, scanWorktree } from './worktree.ts'
import type { CommandContext } from './cli.ts'
import { loadIndex, parsePathspec, pathspecSelector, quotePath, selectedByPathspecs } from './inspect.ts'
import type { Pathspec } from './inspect.ts'
import { currentBranchName, headTree, restoreWorktreePaths } from './porcelain.ts'
import { wildmatchBytes } from './wildmatch.ts'

/** One tree snapshot used by diff/show. */
interface Snapshot {
  readonly mode: string
  readonly oid: string
}

/** Built-in `git log` pretty styles this program renders. */
type LogStyle = 'oneline' | 'short' | 'medium' | 'full' | 'fuller' | 'raw'

/** Date rendering requested by `git log --date=<format>`. */
type LogDateFormat = 'default' | 'short'

/** One parsed `--pretty=` / `--format=` request. */
type LogPretty =
  | { readonly kind: 'style'; readonly style: LogStyle; readonly abbreviated?: boolean }
  | { readonly kind: 'custom'; readonly spec: string; readonly terminated: boolean }

/** Options shared by `log` and `show`. */
interface LogOptions {
  pretty: LogPretty
  maxCount: number
  noPatch: boolean
  stat: boolean
  nameOnly: boolean
  nameStatus: boolean
  all: boolean
  firstParent: boolean
  reverse: boolean
  date: LogDateFormat
}

/** Usage line for `git log -h`, git's own answer to a help request. */
const LOG_USAGE = `usage: git log [<options>] [<revision>...]

    -n <count>, -<count>   limit the number of commits
    --oneline              one line per commit
    --format=<format>      printf-style format, or short/medium/full/fuller/raw
    --pretty=<format>      synonym for --format
    --date=short           short (YYYY-MM-DD) dates in the header, %ad and %cd
    --reverse              reverse the commit order after limiting
    --stat, --name-only, --name-status, -p/--patch, -s/--no-patch
    --all, --first-parent
`

/** Styles the Worker git renders natively. */
const LOG_STYLES: ReadonlySet<string> = new Set(['oneline', 'short', 'medium', 'full', 'fuller', 'raw'])

/** Styles git has but the Worker git does not render; requesting one is loud. */
const LOG_UNSUPPORTED_STYLES: ReadonlySet<string> = new Set(['email', 'reference'])

/**
 * Parse one `--pretty=` / `--format=` value.
 *
 * A value without `format:`/`tformat:` that contains a `%` is git's
 * `tformat:` shorthand. Anything else that is not a style this program
 * renders fails loud: a log request must never silently fall back to the
 * default format.
 */
function parsePretty(value: string): LogPretty {
  if (value.startsWith('tformat:')) return { kind: 'custom', spec: value.slice('tformat:'.length), terminated: true }
  if (value.startsWith('format:')) return { kind: 'custom', spec: value.slice('format:'.length), terminated: false }
  if (LOG_STYLES.has(value)) return { kind: 'style', style: value as LogStyle }
  if (LOG_UNSUPPORTED_STYLES.has(value)) {
    throw fatal(
      `unsupported --pretty format '${value}' inside the Worker. `
      + 'Supported styles: oneline, short, medium, full, fuller, raw and format:<string>. Nothing was printed.',
      129,
    )
  }
  if (value.includes('%')) return { kind: 'custom', spec: value, terminated: true }
  throw fatal(`invalid --pretty format: ${value}`, 128)
}

/** Parse `-n` / `--max-count` values, rejecting anything git would not accept. */
function parseMaxCount(raw: string | undefined, option: string): number {
  if (raw === undefined || !/^\d+$/.test(raw)) {
    throw fatal(`${option}: invalid number: '${raw ?? ''}'`, 129)
  }
  return Number(raw)
}

/**
 * Parse a `--date=<format>` value. Only `short` is rendered; every other
 * format is loud instead of printing the default date as if it had applied.
 */
function parseDateFormat(value: string): 'short' {
  if (value === 'short') return 'short'
  throw fatal(
    `unsupported --date format '${value}': the Worker git only renders --date=short. Nothing was printed.`,
    129,
  )
}

/** `git log`. */
export async function log(context: CommandContext): Promise<number> {
  const options: LogOptions = {
    pretty: { kind: 'style', style: 'medium' }, maxCount: Number.POSITIVE_INFINITY, noPatch: true,
    stat: false, nameOnly: false, nameStatus: false, all: false, firstParent: false,
    reverse: false, date: 'default',
  }
  const revisions: string[] = []
  const pathArgs: string[] = []
  let afterSeparator = false
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    if (afterSeparator) {
      pathArgs.push(arg)
      continue
    }
    if (arg === '--') {
      afterSeparator = true
      continue
    }
    if (arg === '-h') {
      // git's parse-options prints the usage on stdout and exits 129 for -h.
      context.output.stdout(LOG_USAGE)
      return 129
    }
    if (arg === '--oneline') options.pretty = { kind: 'style', style: 'oneline', abbreviated: true }
    else if (arg === '--no-patch' || arg === '-s') options.noPatch = true
    else if (arg === '--stat') options.stat = true
    else if (arg === '--name-only') options.nameOnly = true
    else if (arg === '--name-status') options.nameStatus = true
    else if (arg === '--all') options.all = true
    else if (arg === '--first-parent') options.firstParent = true
    else if (arg === '--reverse') options.reverse = true
    else if (arg === '--date') {
      const value = context.args[index + 1]
      if (value === undefined) {
        throw fatal('option --date requires a value; the Worker git only renders --date=short', 129)
      }
      options.date = parseDateFormat(value)
      index += 1
    } else if (arg.startsWith('--date=')) options.date = parseDateFormat(arg.slice('--date='.length))
    else if (arg === '--no-decorate' || arg === '--decorate=no' || arg === '--color=never' || arg === '--no-color') continue
    else if (arg === '--graph' || arg === '--decorate' || arg.startsWith('--decorate=')) {
      // These change the bytes of the log. Refusing is the only honest answer
      // until the Worker git draws graphs and decorations itself.
      throw fatal(
        `unsupported log option '${arg}': the Worker git does not render commit graphs or ref decorations, `
        + 'so it will not print a log that differs from the request. Nothing was printed.',
        129,
      )
    } else if (arg === '-n' || arg === '--max-count') {
      options.maxCount = parseMaxCount(context.args[index + 1], arg)
      index += 1
    } else if (/^-n\d+$/.test(arg)) options.maxCount = parseMaxCount(arg.slice(2), '-n')
    else if (/^-\d+$/.test(arg)) options.maxCount = Number(arg.slice(1))
    else if (arg.startsWith('--max-count=')) options.maxCount = parseMaxCount(arg.slice('--max-count='.length), '--max-count')
    // `--pretty` alone is git's request for the default medium style (its
    // argument is optional). `--format` takes its value with `=`; a bare
    // `--format` is git's "unrecognized argument" (exit 128), never a synonym
    // for medium, so it must not print a default-format log.
    else if (arg === '--pretty') options.pretty = { kind: 'style', style: 'medium' }
    else if (arg === '--format') throw fatal('unrecognized argument: --format')
    else if (arg.startsWith('--pretty=')) options.pretty = parsePretty(arg.slice('--pretty='.length))
    else if (arg.startsWith('--format=')) options.pretty = parsePretty(arg.slice('--format='.length))
    else if (arg === '-p' || arg === '--patch') options.noPatch = false
    else if (arg.startsWith('-')) throw fatal(`unsupported log option '${arg}'`, 129)
    else revisions.push(arg)
  }
  const repository = await context.repository()
  const tips = await logTips(repository, revisions, options.all)
  if (tips.length === 0 && revisions.length === 0) {
    const branch = await currentBranchName(repository)
    throw fatal(`your current branch '${branch ?? 'HEAD'}' does not have any commits yet`)
  }
  const specs = pathArgs.map(path => parsePathspec(repository, context.cwd, path))
  const commits = specs.length === 0
    ? await walkCommits(repository, tips, options.maxCount, options.firstParent)
    : await selectCommitsForPaths(repository, tips, specs, options.maxCount, options.firstParent)
  // `--reverse` reverses the already limited list, exactly like git: the
  // newest N commits are selected first and then printed oldest-first.
  if (options.reverse) commits.reverse()
  const showContent = options.stat || options.nameOnly || options.nameStatus || !options.noPatch
  for (const [index, commit] of commits.entries()) {
    const pretty = options.pretty
    const oneline = pretty.kind === 'style' && pretty.style === 'oneline'
    if (oneline) {
      // `--oneline` abbreviates; `--pretty=oneline` / `--format=oneline` keep
      // the full object id, exactly like git.
      const hash = pretty.kind === 'style' && pretty.abbreviated === true
        ? shortOid(commit.oid)
        : commit.oid
      context.output.stdout(`${hash} ${subject(commit.message)}\n`)
    } else if (pretty.kind === 'style') {
      context.output.stdout(renderStyleHeader(commit, pretty.style, options.date))
    } else {
      const rendered = expandCustomFormat(pretty.spec, commit, options.date)
      context.output.stdout(pretty.terminated ? `${rendered}\n` : rendered)
    }
    // Git's default log does not print a patch/stat/name list for a merge:
    // the combined diff requires `--cc` (or `-m`), and the merge header alone
    // is the answer to a plain `log --name-status -- <path>`. `--first-parent`
    // is different: it compares the merge with its first parent like a normal
    // commit, so its content must still be shown.
    const mergeContent = commit.parents.length > 1 && !options.firstParent
    if (showContent && !mergeContent) {
      // One blank line between a commit header and its patch/stat, except for
      // `--oneline`, which git runs straight into the diff.
      if (!oneline) context.output.stdout('\n')
      const before = commit.parents.length > 0
        ? await flattenTree(repository, (await readCommit(repository, commit.parents[0] as string)).tree)
        : new Map<string, Snapshot>()
      const after = await flattenTree(repository, commit.tree)
      // Restrict both snapshots before rename detection: git walks the trees
      // with the pathspec, so selecting only one side of a rename reports that
      // side as a deletion or addition rather than pairing it with the other.
      const changes = await diffFlatTrees(repository, before, after, {
        renames: true,
        select: pathspecSelector(specs),
      })
      if (options.stat) await renderStat(context, repository, changes)
      else if (options.nameOnly) for (const change of changes) context.output.stdout(`${change.path}\n`)
      else if (options.nameStatus) {
        for (const change of changes) {
          const code = change.status === 'R' ? `R${String(change.score ?? 100).padStart(3, '0')}` : change.status
          context.output.stdout(`${code}\t${change.oldPath === undefined ? change.path : `${change.oldPath}\t${change.path}`}\n`)
        }
      } else {
        for (const change of changes) await renderFileDiff(context, repository, change, 3)
      }
    }
    if (index < commits.length - 1) {
      if (oneline) continue
      if (pretty.kind === 'style') context.output.stdout('\n')
      else if (!pretty.terminated) context.output.stdout('\n')
    }
  }
  return 0
}

/**
 * Select commits whose path history touches one of the pathspecs.
 *
 * This is git's default history simplification for the pathspec subset: a
 * linear commit is selected when it differs from its parent, a merge that is
 * TREESAME to a parent is not selected and only the first TREESAME parent is
 * walked (git never follows the later ones), and a merge that differs from
 * every parent is selected. With `--first-parent` the comparison and the walk
 * use the first parent only.
 * The walk stops as soon as `maxCount` commits are selected, so an older merge
 * outside the requested range can never fail the command.
 */
async function selectCommitsForPaths(
  repository: Repository,
  tips: readonly string[],
  specs: readonly Pathspec[],
  maxCount: number,
  firstParent: boolean,
): Promise<CommitInfo[]> {
  const cache = new Map<string, Map<string, Snapshot>>()
  const flattened = async (tree: string): Promise<Map<string, Snapshot>> => {
    let entries = cache.get(tree)
    if (entries === undefined) {
      entries = await flattenTree(repository, tree)
      cache.set(tree, entries)
    }
    return entries
  }
  /** True when the pathspec-selected paths differ between a commit and its parent. */
  const changedAgainst = async (commit: CommitInfo, parent: string | undefined): Promise<boolean> => {
    const before = parent === undefined
      ? new Map<string, Snapshot>()
      : await flattened((await readCommit(repository, parent)).tree)
    const after = await flattened(commit.tree)
    for (const [path, entry] of after) {
      const previous = before.get(path)
      if (previous !== undefined && previous.oid === entry.oid && previous.mode === entry.mode) continue
      if (selectedByPathspecs(specs, path)) return true
    }
    for (const path of before.keys()) {
      if (!after.has(path) && selectedByPathspecs(specs, path)) return true
    }
    return false
  }
  const seen = new Set<string>()
  const queue: CommitInfo[] = []
  const enqueue = async (oid: string): Promise<void> => {
    if (seen.has(oid)) return
    seen.add(oid)
    queue.push(await readCommit(repository, oid))
  }
  for (const tip of tips) await enqueue(tip)
  const selected: CommitInfo[] = []
  while (queue.length > 0 && selected.length < maxCount) {
    queue.sort((left, right) => right.committer.timestamp - left.committer.timestamp
      || (left.oid < right.oid ? 1 : left.oid > right.oid ? -1 : 0))
    const commit = queue.shift() as CommitInfo
    if (firstParent) {
      const parent = commit.parents[0]
      if (await changedAgainst(commit, parent)) selected.push(commit)
      if (parent !== undefined) await enqueue(parent)
      continue
    }
    if (commit.parents.length > 1) {
      const treessame: string[] = []
      for (const parent of commit.parents) {
        if (!(await changedAgainst(commit, parent))) treessame.push(parent)
      }
      // TREESAME to a parent: the merge adds nothing for these paths, so it is
      // simplified away. Git's default simplification follows only the first
      // TREESAME parent, even when several parents match; walking the others
      // would add their (identically changed) history to the result.
      if (treessame.length === 0) selected.push(commit)
      for (const parent of treessame.length === 0 ? commit.parents : treessame.slice(0, 1)) await enqueue(parent)
      continue
    }
    const parent = commit.parents[0]
    if (await changedAgainst(commit, parent)) selected.push(commit)
    if (parent !== undefined) await enqueue(parent)
  }
  return selected
}

/** Indent a commit message the way git's pretty printers do. */
function indentCommitMessage(message: string): string {
  const lines: string[] = []
  for (const line of message.replace(/\n+$/, '').split('\n')) {
    lines.push(`    ${line}\n`)
  }
  return lines.join('')
}

/** One signature rendered as `Name <email>`. */
function signatureIdentity(signature: Signature): string {
  return `${signature.name} <${signature.email}>`
}

/** The signature timestamp shifted into the signature's own timezone. */
function signatureDate(signature: Signature): Date {
  const sign = signature.timezone.startsWith('-') ? -1 : 1
  const hours = Number(signature.timezone.slice(1, 3))
  const minutes = Number(signature.timezone.slice(3, 5))
  return new Date((signature.timestamp + sign * (hours * 60 + minutes) * 60) * 1000)
}

/** `YYYY-MM-DD`, git's `--date=short` shape. */
function shortDate(signature: Signature): string {
  const date = signatureDate(signature)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${String(date.getUTCFullYear()).padStart(4, '0')}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`
}

/** `YYYY-MM-DD HH:MM:SS +TZ`, git's `%ai` shape. */
function isoDate(signature: Signature): string {
  const date = signatureDate(signature)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${shortDate(signature)} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} ${signature.timezone}`
}

/**
 * `YYYY-MM-DDTHH:MM:SS+TZ:00`, git's `%aI` shape.
 *
 * Git 2.45 changed the strict-ISO spelling of a UTC time from `+00:00` to the
 * canonical `Z` suffix (Documentation/RelNotes/2.45.0.txt: "The output format
 * for dates \"iso-strict\" has been tweaked to show a time in the Zulu
 * timezone with \"Z\" suffix, instead of \"+00:00\""). A stored negative
 * zero offset is normalised to the same UTC spelling.
 */
function strictIsoDate(signature: Signature): string {
  const iso = isoDate(signature)
  const dateTime = iso.slice(0, 19).replace(' ', 'T')
  const zone = iso.slice(-5)
  if (zone === '+0000' || zone === '-0000') return `${dateTime}Z`
  return `${dateTime}${zone.slice(0, 3)}:${zone.slice(3)}`
}

/** `Tue, 14 Nov 2023 22:13:20 +0000`, git's `%aD` shape. */
function rfcDate(signature: Signature): string {
  const date = signatureDate(signature)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${DAYS[date.getUTCDay()]}, ${String(date.getUTCDate()).padStart(2)} ${MONTHS[date.getUTCMonth()]} `
    + `${String(date.getUTCFullYear()).padStart(4, '0')} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:`
    + `${pad(date.getUTCSeconds())} ${signature.timezone}`
}

/** `%B` minus the subject line: everything after the first blank line. */
function commitBody(message: string): string {
  const newline = message.indexOf('\n')
  if (newline < 0) return ''
  const rest = message.slice(newline + 1)
  return rest.startsWith('\n') ? rest.slice(1) : rest
}

/**
 * Expand one `format:<string>` / `tformat:<string>` spec for a commit.
 *
 * The placeholder set is the one the porcelain and models actually use for
 * machine-readable logs. An unknown placeholder fails loud instead of leaking
 * a literal `%q` into output that the caller believes is formatted.
 */
function expandCustomFormat(spec: string, commit: CommitInfo, dateFormat: LogDateFormat = 'default'): string {
  let result = ''
  let index = 0
  while (index < spec.length) {
    const character = spec[index] as string
    index += 1
    if (character !== '%') {
      result += character
      continue
    }
    // Two-character placeholders first: `%an` must not be read as `%a` + `n`.
    const pair = spec.slice(index, index + 2)
    switch (pair) {
      case 'an': result += commit.author.name; index += 2; continue
      case 'ae': result += commit.author.email; index += 2; continue
      case 'at': result += String(commit.author.timestamp); index += 2; continue
      case 'ad': result += formatSignatureFor(dateFormat, commit.author); index += 2; continue
      case 'ai': result += isoDate(commit.author); index += 2; continue
      case 'aI': result += strictIsoDate(commit.author); index += 2; continue
      case 'as': result += shortDate(commit.author); index += 2; continue
      case 'aD': result += rfcDate(commit.author); index += 2; continue
      case 'cn': result += commit.committer.name; index += 2; continue
      case 'ce': result += commit.committer.email; index += 2; continue
      case 'ct': result += String(commit.committer.timestamp); index += 2; continue
      case 'cd': result += formatSignatureFor(dateFormat, commit.committer); index += 2; continue
      case 'ci': result += isoDate(commit.committer); index += 2; continue
      case 'cI': result += strictIsoDate(commit.committer); index += 2; continue
      case 'cs': result += shortDate(commit.committer); index += 2; continue
      case 'cD': result += rfcDate(commit.committer); index += 2; continue
      default: break
    }
    const code = spec[index]
    if (code === undefined) throw fatal('invalid --format string: trailing %')
    index += 1
    switch (code) {
      case '%': result += '%'; continue
      case 'n': result += '\n'; continue
      case 'x': {
        const hex = spec.slice(index, index + 2)
        if (!/^[0-9a-fA-F]{2}$/.test(hex)) throw fatal('invalid --format string: %x needs two hex digits')
        result += String.fromCharCode(Number.parseInt(hex, 16))
        index += 2
        continue
      }
      case 'H': result += commit.oid; continue
      case 'h': result += shortOid(commit.oid); continue
      case 'T': result += commit.tree; continue
      case 't': result += shortOid(commit.tree); continue
      case 'P': result += commit.parents.join(' '); continue
      case 'p': result += commit.parents.map(parent => shortOid(parent)).join(' '); continue
      case 's': result += subject(commit.message); continue
      case 'b': result += commitBody(commit.message); continue
      case 'B': result += commit.message; continue
      default:
        throw fatal(
          `unsupported --format placeholder '%${code}'. The Worker git supports `
          + '%H %h %T %t %P %p %an %ae %ad %at %ai %aI %as %aD %cn %ce %cd %ct %ci %cI %cs %cD %s %b %B %n %%; '
          + 'nothing was printed.',
          129,
        )
    }
  }
  return result
}

/** Render one commit header for a built-in pretty style. */
function renderStyleHeader(commit: CommitInfo, style: LogStyle, dateFormat: LogDateFormat = 'default'): string {
  switch (style) {
    case 'medium':
      return renderCommitHeader(commit, dateFormat)
    case 'oneline':
      return `${commit.oid} ${subject(commit.message)}`
    case 'short':
      // git's `short` style prints the subject only, not the body.
      return `commit ${commit.oid}\nAuthor: ${signatureIdentity(commit.author)}\n\n    ${subject(commit.message)}\n`
    case 'full':
      return `commit ${commit.oid}\nAuthor: ${signatureIdentity(commit.author)}\n`
        + `Commit: ${signatureIdentity(commit.committer)}\n\n${indentCommitMessage(commit.message)}`
    case 'fuller':
      return `commit ${commit.oid}\n`
        + `Author:     ${signatureIdentity(commit.author)}\n`
        + `AuthorDate: ${formatSignatureFor(dateFormat, commit.author)}\n`
        + `Commit:     ${signatureIdentity(commit.committer)}\n`
        + `CommitDate: ${formatSignatureFor(dateFormat, commit.committer)}\n\n`
        + indentCommitMessage(commit.message)
    case 'raw': {
      const lines = [`commit ${commit.oid}\n`, `tree ${commit.tree}\n`]
      for (const parent of commit.parents) lines.push(`parent ${parent}\n`)
      lines.push(`author ${signatureIdentity(commit.author)} ${commit.author.timestamp} ${commit.author.timezone}\n`)
      lines.push(`committer ${signatureIdentity(commit.committer)} ${commit.committer.timestamp} ${commit.committer.timezone}\n\n`)
      lines.push(indentCommitMessage(commit.message))
      return lines.join('')
    }
  }
}

async function peelToCommitish(repository: Repository, oid: string): Promise<string> {
  let current = oid
  for (let depth = 0; depth < 10; depth += 1) {
    const type = await repository.odb.type(current)
    if (type === 'commit') return current
    if (type !== 'tag') return current
    const text = new TextDecoder().decode((await repository.odb.read(current)).data)
    const match = /^object ([0-9a-f]{40})$/m.exec(text)
    if (match === null) return current
    current = match[1] as string
  }
  return current
}

async function logTips(repository: Repository, revisions: readonly string[], all: boolean): Promise<string[]> {
  if (revisions.length > 0) {
    const tips: string[] = []
    for (const revision of revisions) tips.push(await resolveRevision(repository, revision))
    return tips
  }
  if (all) {
    const refs = await listRefs(repository, 'refs/')
    const peeled: string[] = []
    for (const oid of new Set(refs.values())) peeled.push(await peelToCommitish(repository, oid))
    return [...new Set(peeled)]
  }
  const head = await headOid(repository)
  return head === undefined ? [] : [head]
}

/** Walk commits newest-first; the limit is applied after deduplication. */
export async function walkCommits(
  repository: Repository,
  tips: readonly string[],
  limit = Number.POSITIVE_INFINITY,
  firstParent = false,
): Promise<CommitInfo[]> {
  const seen = new Set<string>()
  const queue: CommitInfo[] = []
  for (const tip of tips) {
    if (seen.has(tip)) continue
    seen.add(tip)
    queue.push(await readCommit(repository, tip))
  }
  const ordered: CommitInfo[] = []
  while (queue.length > 0 && ordered.length < limit) {
    queue.sort((left, right) => right.committer.timestamp - left.committer.timestamp
      || (left.oid < right.oid ? 1 : left.oid > right.oid ? -1 : 0))
    const commit = queue.shift() as CommitInfo
    ordered.push(commit)
    const parents = firstParent ? commit.parents.slice(0, 1) : commit.parents
    for (const parent of parents) {
      if (seen.has(parent)) continue
      seen.add(parent)
      queue.push(await readCommit(repository, parent))
    }
  }
  return ordered
}

function subject(message: string): string {
  return message.split('\n')[0] ?? ''
}

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** Format one signature the way git's medium log does. */
export function formatSignatureDate(signature: Signature): string {
  const date = signatureDate(signature)
  const pad = (value: number): string => String(value).padStart(2, '0')
  return `${DAYS[date.getUTCDay()]} ${MONTHS[date.getUTCMonth()]} ${String(date.getUTCDate()).padStart(2)} `
    + `${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} `
    + `${date.getUTCFullYear()} ${signature.timezone}`
}

/** Format one signature in the selected log date style. */
function formatSignatureFor(dateFormat: LogDateFormat, signature: Signature): string {
  return dateFormat === 'short' ? shortDate(signature) : formatSignatureDate(signature)
}

/** Render the default `git log` commit header. */
export function renderCommitHeader(commit: CommitInfo, dateFormat: LogDateFormat = 'default'): string {
  const lines: string[] = [`commit ${commit.oid}\n`]
  if (commit.parents.length > 1) lines.push(`Merge: ${commit.parents.map(parent => shortOid(parent)).join(' ')}\n`)
  lines.push(`Author: ${commit.author.name} <${commit.author.email}>\n`)
  lines.push(`Date:   ${formatSignatureFor(dateFormat, commit.author)}\n\n`)
  for (const line of commit.message.replace(/\n+$/, '').split('\n')) {
    // git indents blank message lines too ("    \n"), not as an empty line.
    lines.push(`    ${line}\n`)
  }
  return lines.join('')
}

/** True when `--no-index` is an option, i.e. it appears before `--`. */
function hasNoIndexOption(args: readonly string[]): boolean {
  for (const arg of args) {
    if (arg === '--') return false
    if (arg === '--no-index') return true
  }
  return false
}

/** `git diff`. */
export async function diff(context: CommandContext): Promise<number> {
  // `--no-index` compares two ordinary files and must work outside a
  // repository, so it is routed before `context.repository()` is touched.
  // Only an option counts: after `--` a path may itself be named
  // `--no-index`, and it must not change the command route.
  if (hasNoIndexOption(context.args)) return await diffNoIndex(context)
  let cached = false
  let stat = false
  let numstat = false
  let nameOnly = false
  let nameStatus = false
  let nul = false
  let contextLines = 3
  let renames = true
  const revisions: string[] = []
  const pathspecArgs: string[] = []
  let afterSeparator = false
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    if (afterSeparator) { pathspecArgs.push(arg); continue }
    if (arg === '--') { afterSeparator = true; continue }
    if (arg === '--cached' || arg === '--staged') cached = true
    else if (arg === '--stat') stat = true
    else if (arg === '--numstat') numstat = true
    else if (arg === '--name-only') nameOnly = true
    else if (arg === '--name-status') nameStatus = true
    else if (arg === '-z') nul = true
    else if (arg === '--no-renames') renames = false
    else if (arg === '-M' || arg === '--find-renames') renames = true
    else if (/^-M\d+%?$/.test(arg)) { renames = true }
    else if (/^-U\d+$/.test(arg)) contextLines = Number(arg.slice(2))
    else if (arg === '--no-patch' || arg === '-s') { stat = false; numstat = false }
    else if (arg === '--no-color' || arg === '--color=never') continue
    else if (arg === '--binary' || arg === '--text') {
      // Both change the diff bytes; a plain diff would not be the requested one.
      throw fatal(`unsupported diff option '${arg}': the Worker git does not implement it. Nothing was printed.`, 129)
    }
    else if (arg.startsWith('-')) throw fatal(`unsupported diff option '${arg}'`, 129)
    else revisions.push(arg)
  }
  const repository = await context.repository()
  const specs = pathspecArgs.map(path => parsePathspec(repository, context.cwd, path))
  const changes = await computeDiffChanges(repository, revisions, cached, renames, pathspecSelector(specs))
  if (nameOnly || nameStatus) {
    const terminator = nul ? '\0' : '\n'
    for (const change of changes) {
      if (nameOnly) {
        context.output.stdout(`${change.path}${terminator}`)
      } else {
        const code = change.status === 'R' ? `R${String(change.score ?? 100).padStart(3, '0')}` : change.status
        context.output.stdout(`${code}\t${change.oldPath === undefined ? change.path : `${change.oldPath}\t${change.path}`}${terminator}`)
      }
    }
    return 0
  }
  if (numstat) {
    for (const change of changes) {
      const stats = await numstatOf(repository, change)
      if (change.oldPath !== undefined) context.output.stdout(`${stats.added}\t${stats.deleted}\t${change.oldPath} => ${change.path}\n`)
      else context.output.stdout(`${stats.added}\t${stats.deleted}\t${change.path}\n`)
    }
    return 0
  }
  if (stat) {
    await renderStat(context, repository, changes)
    return 0
  }
  for (const change of changes) {
    await renderFileDiff(context, repository, change, contextLines)
  }
  return 0
}

/** One path read by `git diff --no-index`. */
interface NoIndexFile {
  readonly data: Uint8Array
  /** `100644`, `100755` or `120000` for a symbolic link. */
  readonly mode: string
  /** `file` or `symlink`; mixing the shapes is outside this implementation. */
  readonly kind: 'file' | 'symlink'
  /** Path as git places it below `a/` / `b/` (absolute leading `/` removed). */
  readonly display: string
}

/**
 * Read one `--no-index` path. A missing path keeps git's `error:` line and
 * exit 1; directories are a shape this program does not render, so they fail
 * loud with 129 instead of producing a half-correct diff.
 *
 * `lstat` (not `stat`) is deliberate: a symbolic link is a `120000` object
 * whose contents are the link target string, exactly as git compares it.
 * Following the link would silently diff the target as a `100644` file.
 */
async function readNoIndexFile(context: CommandContext, path: string): Promise<NoIndexFile> {
  const absolute = context.absolute(path)
  let stats
  try {
    stats = await context.fs.lstat(absolute)
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) {
      throw errorFailure(`Could not access '${path}'`, 1)
    }
    throw error
  }
  if (stats.isDirectory) {
    throw fatal(
      'git diff --no-index: comparing directories is not implemented in the Worker git. Nothing was printed.',
      129,
    )
  }
  const display = path.replace(/^\/+/, '')
  if (stats.isSymbolicLink) {
    const target = await context.fs.readlink?.(absolute)
    if (target === undefined) {
      throw fatal(
        `git diff --no-index: the filesystem cannot read the symbolic link '${path}'. Nothing was printed.`,
        129,
      )
    }
    return { data: encodeText(target), mode: '120000', kind: 'symlink', display }
  }
  if (!stats.isFile) {
    throw fatal(`git diff --no-index: '${path}' is not a regular file; that shape is not implemented. Nothing was printed.`, 129)
  }
  const data = await context.fs.readFile(absolute)
  const mode = (stats.mode & 0o100) === 0 ? '100644' : '100755'
  return { data, mode, kind: 'file', display }
}

/**
 * Render one `---`/`+++` path the way git's `diff.c` does: quote the complete
 * path and append a literal tab when the raw path contains a space, so the
 * timestamp-free header stays parseable. The `diff --git` line does not get
 * this tab, and neither do rename or binary-file lines.
 */
function fileHeaderPath(prefix: 'a' | 'b', path: string): string {
  return `${quotePath(`${prefix}/${path}`)}${path.includes(' ') ? '\t' : ''}`
}

/** Render the `--no-index` header/mode/index lines every file pair shares. */
function noIndexHeader(
  oldFile: NoIndexFile,
  newFile: NoIndexFile,
  oldOid: string,
  newOid: string,
  sameContent: boolean,
): string {
  const oldPath = quotePath(`a/${oldFile.display}`)
  const newPath = quotePath(`b/${newFile.display}`)
  const lines = [`diff --git ${oldPath} ${newPath}\n`]
  const modeChanged = oldFile.mode !== newFile.mode
  if (modeChanged) {
    lines.push(`old mode ${oldFile.mode}\n`)
    lines.push(`new mode ${newFile.mode}\n`)
  }
  if (!sameContent) {
    lines.push(`index ${shortOid(oldOid)}..${shortOid(newOid)}${modeChanged ? '' : ` ${oldFile.mode}`}\n`)
  }
  return lines.join('')
}

/**
 * `git diff --no-index <old> <new>` for two ordinary files.
 *
 * The bytes are compared directly and the header uses the argv path with a
 * leading `/` stripped, matching git for relative, absolute and Unicode
 * names. Equal content and mode produce no output and exit 0; any difference
 * exits 1, including a mode-only change.
 */
async function diffNoIndex(context: CommandContext): Promise<number> {
  let contextLines = 3
  const paths: string[] = []
  let afterSeparator = false
  for (const arg of context.args) {
    if (afterSeparator) { paths.push(arg); continue }
    if (arg === '--no-index') continue
    if (arg === '--') { afterSeparator = true; continue }
    if (arg === '--no-color' || arg === '--color=never') continue
    if (/^-U\d+$/.test(arg)) { contextLines = Number(arg.slice(2)); continue }
    if (arg.startsWith('-')) {
      throw fatal(
        `unsupported diff --no-index option '${arg}': the Worker git only compares two regular files. Nothing was printed.`,
        129,
      )
    }
    paths.push(arg)
  }
  if (paths.length !== 2) {
    throw fatal('git diff --no-index needs exactly two file paths. Nothing was printed.', 129)
  }
  const oldFile = await readNoIndexFile(context, paths[0] as string)
  const newFile = await readNoIndexFile(context, paths[1] as string)
  if (oldFile.kind !== newFile.kind) {
    // Real git renders this shape as a deletion of the old object plus an
    // addition of the new one. Refuse loudly instead of following a link and
    // printing a 100644 diff for its target.
    throw fatal(
      'git diff --no-index: comparing a symbolic link with a regular file is not implemented in the Worker git. Nothing was printed.',
      129,
    )
  }
  const oldOid = hashBlob(oldFile.data)
  const newOid = hashBlob(newFile.data)
  const sameContent = compareBytes(oldFile.data, newFile.data) === 0
  if (sameContent && oldFile.mode === newFile.mode) return 0
  context.output.stdout(noIndexHeader(oldFile, newFile, oldOid, newOid, sameContent))
  if (sameContent) return 1
  if (isBinary(oldFile.data) || isBinary(newFile.data)) {
    context.output.stdout(
      `Binary files ${quotePath(`a/${oldFile.display}`)} and ${quotePath(`b/${newFile.display}`)} differ\n`,
    )
    return 1
  }
  context.output.stdout(`--- ${fileHeaderPath('a', oldFile.display)}\n`)
  context.output.stdout(`+++ ${fileHeaderPath('b', newFile.display)}\n`)
  const oldLines = splitLines(oldFile.data)
  const hunks = unifiedHunks(oldLines, splitLines(newFile.data), contextLines)
  for (const hunk of hunks) {
    const functionName = functionContextLine(oldLines, hunk)
    context.output.stdout(`@@ -${formatRange(hunk.oldStart, hunk.oldCount)} +${formatRange(hunk.newStart, hunk.newCount)} @@${functionName === undefined ? '' : ` ${functionName}`}\n`)
    context.output.stdout(renderHunkBody(hunk))
  }
  return 1
}

/** Compute the change list for one `git diff` invocation. */
export async function computeDiffChanges(
  repository: Repository,
  revisions: readonly string[],
  cached: boolean,
  renames: boolean,
  select?: (path: string) => boolean,
): Promise<TreeChange[]> {
  if (revisions.length >= 2) {
    const before = await flattenTree(repository, await peelCommitTree(repository, revisions[0] as string))
    const after = await flattenTree(repository, await peelCommitTree(repository, revisions[1] as string))
    return await diffFlatTrees(repository, before, after, { renames, select })
  }
  if (cached) {
    const before = await headTree(repository)
    const index = await loadIndex(repository)
    const after = new Map<string, Snapshot>()
    for (const entry of index.entries) if (entry.stage === 0) after.set(entry.path, { mode: entry.mode.toString(8), oid: entry.oid })
    return await diffFlatTrees(repository, before, after, { renames, select })
  }
  if (revisions.length === 1) {
    const before = await flattenTree(repository, await peelCommitTree(repository, revisions[0] as string))
    const index = await loadIndex(repository)
    const workTree = requireWorkTree(repository)
    const after = new Map<string, Snapshot>()
    const content = new Map<string, Uint8Array>()
    for (const entry of index.entries) {
      if (entry.stage !== 0) continue
      const blob = await readWorktreeBlob(repository.fs, repository, workTree, entry.path)
      if (blob === undefined) continue
      after.set(entry.path, { mode: blob.mode, oid: blob.oid })
      content.set(blob.oid, blob.data)
    }
    const changes = await diffFlatTrees(repository, before, after, { renames, select })
    return changes.map(change => attachData(repository, change, content))
  }
  const index = await loadIndex(repository)
  const workTree = requireWorkTree(repository)
  const before = new Map<string, Snapshot>()
  const after = new Map<string, Snapshot>()
  const content = new Map<string, Uint8Array>()
  for (const entry of index.entries) {
    if (entry.stage !== 0) continue
    before.set(entry.path, { mode: entry.mode.toString(8), oid: entry.oid })
    const blob = await readWorktreeBlob(repository.fs, repository, workTree, entry.path)
    if (blob !== undefined) {
      after.set(entry.path, { mode: blob.mode, oid: blob.oid })
      content.set(blob.oid, blob.data)
    }
  }
  const changes = await diffFlatTrees(repository, before, after, { renames, select })
  return changes.map(change => attachData(repository, change, content))
}

async function peelCommitTree(repository: Repository, revision: string): Promise<string> {
  const oid = await resolveRevision(repository, revision)
  const type = await repository.odb.type(oid)
  if (type === 'tree') return oid
  return (await readCommit(repository, oid)).tree
}

function attachData(repository: Repository, change: TreeChange, content: ReadonlyMap<string, Uint8Array>): TreeChange {
  void repository
  return {
    ...change,
    ...change.oldOid !== undefined && content.has(change.oldOid) ? { oldData: content.get(change.oldOid) as Uint8Array } : {},
    ...change.newOid !== undefined && content.has(change.newOid) ? { newData: content.get(change.newOid) as Uint8Array } : {},
  }
}

async function blobOrEmpty(repository: Repository, oid: string | undefined, inline?: Uint8Array): Promise<Uint8Array> {
  if (inline !== undefined) return inline
  if (oid === undefined) return new Uint8Array(0)
  try {
    return (await repository.odb.read(oid)).data
  } catch {
    return new Uint8Array(0)
  }
}

async function numstatOf(repository: Repository, change: TreeChange): Promise<{ added: string; deleted: string }> {
  const oldData = await blobOrEmpty(repository, change.oldOid, change.oldData)
  const newData = await blobOrEmpty(repository, change.newOid, change.newData)
  if (isBinary(oldData) || isBinary(newData)) return { added: '-', deleted: '-' }
  const counts = countDiff(splitLines(oldData), splitLines(newData))
  return { added: String(counts.added), deleted: String(counts.deleted) }
}

async function renderStat(context: CommandContext, repository: Repository, changes: readonly TreeChange[]): Promise<void> {
  const rows: { path: string; added: number; deleted: number; binary: boolean; oldSize: number; newSize: number }[] = []
  let insertions = 0
  let deletions = 0
  for (const change of changes) {
    const stats = await numstatOf(repository, change)
    const binary = stats.added === '-'
    const added = binary ? 0 : Number(stats.added)
    const deleted = binary ? 0 : Number(stats.deleted)
    insertions += added
    deletions += deleted
    rows.push({
      path: change.oldPath === undefined ? change.path : `${change.oldPath} => ${change.path}`,
      added,
      deleted,
      binary,
      oldSize: (await blobOrEmpty(repository, change.oldOid, change.oldData)).byteLength,
      newSize: (await blobOrEmpty(repository, change.newOid, change.newData)).byteLength,
    })
  }
  const width = rows.reduce((max, row) => Math.max(max, row.path.length), 0)
  const numberWidth = rows.reduce((max, row) => Math.max(max, row.binary ? 3 : String(row.added + row.deleted).length), 1)
  for (const row of rows) {
    const total = row.added + row.deleted
    const bar = '+'.repeat(row.added) + '-'.repeat(row.deleted)
    const measure = row.binary
      ? `Bin ${row.oldSize} -> ${row.newSize} bytes`
      : `${String(total).padStart(numberWidth)}${bar === '' ? '' : ` ${bar}`}`
    context.output.stdout(` ${row.path.padEnd(width)} | ${measure}\n`)
  }
  const parts = [` ${changes.length} file${changes.length === 1 ? '' : 's'} changed`]
  if (insertions > 0) parts.push(`${insertions} insertion${insertions === 1 ? '' : 's'}(+)`)
  if (deletions > 0) parts.push(`${deletions} deletion${deletions === 1 ? '' : 's'}(-)`)
  context.output.stdout(`${parts.join(', ')}\n`)
}

/**
 * Git's default hunk function name: search backwards from the line before the
 * hunk for the nearest line starting with an ASCII letter, `_` or `$`. Git
 * looks past arbitrary distances, so a change far below its enclosing function
 * still gets `@@ ... @@ static int foo(void)`. The `\r` of a CRLF file is not part of
 * the function name in the hunk header.
 */
function functionContextLine(
  lines: readonly { readonly bytes: Uint8Array }[],
  hunk: { readonly oldStart: number; readonly oldCount: number },
): string | undefined {
  // Git starts from the line immediately before the hunk. A zero-length old
  // range is a pure insertion, so `oldStart` is already the number of old
  // lines before the insertion point and the previous line is `oldStart - 1`.
  const from = hunk.oldCount === 0 ? hunk.oldStart - 1 : hunk.oldStart - 2
  for (let index = from; index >= 0; index -= 1) {
    const line = lines[index]
    if (line === undefined) continue
    const text = decodeText(line.bytes).replace(/\r?\n$/, '')
    if (/^[A-Za-z_$]/.test(text)) return text
  }
  return undefined
}

async function renderFileDiff(
  context: CommandContext,
  repository: Repository,
  change: TreeChange,
  contextLines: number,
): Promise<void> {
  const oldPath = change.oldPath ?? change.path
  const newPath = change.path
  // Git quotes the complete path including its a/ or b/ prefix. Quoting only
  // the filename puts those prefixes outside the quoted string for non-ASCII
  // paths, which differs from git's core.quotePath output.
  context.output.stdout(`diff --git ${quotePath(`a/${oldPath}`)} ${quotePath(`b/${newPath}`)}\n`)
  if (change.status === 'A') context.output.stdout(`new file mode ${(change.newMode ?? '100644').padStart(6, '0')}\n`)
  if (change.status === 'D') context.output.stdout(`deleted file mode ${(change.oldMode ?? '100644').padStart(6, '0')}\n`)
  if (change.status === 'R') {
    context.output.stdout(`similarity index ${change.score ?? 100}%\n`)
    context.output.stdout(`rename from ${quotePath(oldPath)}\n`)
    context.output.stdout(`rename to ${quotePath(newPath)}\n`)
  }
  if (change.oldMode !== undefined && change.newMode !== undefined && change.oldMode !== change.newMode
    && change.status === 'M') {
    context.output.stdout(`old mode ${change.oldMode.padStart(6, '0')}\n`)
    context.output.stdout(`new mode ${change.newMode.padStart(6, '0')}\n`)
  }
  const oldData = await blobOrEmpty(repository, change.oldOid, change.oldData)
  const newData = await blobOrEmpty(repository, change.newOid, change.newData)
  const contentChanged = change.oldOid !== change.newOid
  if (contentChanged) {
    const oldShort = change.oldOid === undefined ? '0000000' : shortOid(change.oldOid)
    const newShort = change.newOid === undefined ? '0000000' : shortOid(change.newOid)
    const mode = change.newMode ?? change.oldMode
    context.output.stdout(`index ${oldShort}..${newShort}${change.status === 'A' || change.status === 'D' ? '' : ` ${mode?.padStart(6, '0')}`}\n`)
  }
  if (!contentChanged) return
  if (isBinary(oldData) || isBinary(newData)) {
    const from = change.status === 'A' ? '/dev/null' : quotePath(`a/${oldPath}`)
    const to = change.status === 'D' ? '/dev/null' : quotePath(`b/${newPath}`)
    context.output.stdout(`Binary files ${from} and ${to} differ\n`)
    return
  }
  context.output.stdout(`${change.status === 'A' ? '--- /dev/null' : `--- ${fileHeaderPath('a', oldPath)}`}\n`)
  context.output.stdout(`${change.status === 'D' ? '+++ /dev/null' : `+++ ${fileHeaderPath('b', newPath)}`}\n`)
  const oldLines = splitLines(oldData)
  const hunks = unifiedHunks(oldLines, splitLines(newData), contextLines)
  for (const hunk of hunks) {
    const functionName = functionContextLine(oldLines, hunk)
    context.output.stdout(`@@ -${formatRange(hunk.oldStart, hunk.oldCount)} +${formatRange(hunk.newStart, hunk.newCount)} @@${functionName === undefined ? '' : ` ${functionName}`}\n`)
    context.output.stdout(renderHunkBody(hunk))
  }
}

/** One raw tree entry: the name stays as bytes so `show` can copy it verbatim. */
interface RawTreeEntry {
  readonly directory: boolean
  readonly name: Uint8Array
}

/** Parse mode/NUL/name records from a tree object without decoding the name. */
function parseRawTree(data: Uint8Array): RawTreeEntry[] {
  const entries: RawTreeEntry[] = []
  let offset = 0
  while (offset < data.byteLength) {
    const space = data.indexOf(0x20, offset)
    if (space < 0) break
    const nul = data.indexOf(0, space + 1)
    if (nul < 0) break
    const mode = decodeText(data.subarray(offset, space))
    entries.push({
      directory: mode === '40000' || mode === '040000',
      name: data.subarray(space + 1, nul),
    })
    offset = nul + 21
  }
  return entries
}

/**
 * Rewrite `resolveRevision`'s `<rev>:<path>` miss into the exact fatal line
 * git prints: the message names the revision, not the whole expression.
 */
function normaliseShowPathError(expression: string, error: unknown): unknown {
  if (!(error instanceof GitFailure)) return error
  const colon = expression.indexOf(':')
  if (colon < 0) return error
  if (!/^fatal: path '.*' does not exist in '.*'\n$/.test(error.stderr)) return error
  const revision = expression.slice(0, colon)
  const path = expression.slice(colon + 1)
  return fatal(`path '${path}' does not exist in '${revision}'`)
}

/** One parsed annotated tag object. */
interface ParsedTag {
  readonly target?: string | undefined
  readonly name?: string | undefined
  readonly tagger?: Signature | undefined
  /** Raw message bytes: git writes them unchanged, so no decoder round-trip. */
  readonly message: Uint8Array
}

/** Find the `\n\n` that separates a tag object's headers from its message. */
function tagHeaderEnd(data: Uint8Array): number {
  for (let index = 0; index + 1 < data.byteLength; index += 1) {
    if (data[index] === 0x0a && data[index + 1] === 0x0a) return index
  }
  return -1
}

/** Parse the header fields of an annotated tag; the message stays raw bytes. */
function parseTagObject(data: Uint8Array): ParsedTag {
  const separator = tagHeaderEnd(data)
  const header = decodeText(separator < 0 ? data : data.subarray(0, separator))
  let target: string | undefined
  let name: string | undefined
  let tagger: Signature | undefined
  for (const line of header.split('\n')) {
    if (line.startsWith('object ')) target = line.slice('object '.length).trim()
    else if (line.startsWith('tag ')) name = line.slice('tag '.length)
    else if (line.startsWith('tagger ')) tagger = parseSignature(line.slice('tagger '.length))
  }
  return {
    target,
    name,
    tagger,
    message: separator < 0 ? new Uint8Array() : data.subarray(separator + 2),
  }
}

/**
 * Render `git show <annotated-tag>`'s tag header: `tag <name>`, the tagger and
 * date (unless `--oneline` suppresses them, as git does), a blank line and the
 * raw tag message. The caller adds the separator newline git puts between the
 * tag and a non-blob target.
 */
function renderTagHeader(tag: ParsedTag, oneline: boolean): Uint8Array {
  const chunks: Uint8Array[] = [encodeText(`tag ${tag.name ?? ''}\n`)]
  if (!oneline && tag.tagger !== undefined) {
    chunks.push(encodeText(`Tagger: ${signatureIdentity(tag.tagger)}\n`))
    chunks.push(encodeText(`Date:   ${formatSignatureDate(tag.tagger)}\n`))
  }
  chunks.push(encodeText('\n'))
  chunks.push(tag.message)
  return concatBytes(...chunks)
}

/** `git show`. */
export async function show(context: CommandContext): Promise<number> {
  let stat = false
  let noPatch = false
  let oneline = false
  let nameOnly = false
  let nameStatus = false
  const revisions: string[] = []
  for (const arg of context.args) {
    if (arg === '--stat') stat = true
    else if (arg === '-s' || arg === '--no-patch') noPatch = true
    else if (arg === '--oneline') oneline = true
    else if (arg === '--name-only') nameOnly = true
    else if (arg === '--name-status') nameStatus = true
    // The patch is `show`'s default; an explicit request is not a different mode.
    else if (arg === '-p' || arg === '--patch') noPatch = false
    else if (arg.startsWith('-')) throw fatal(`unsupported show option '${arg}'`, 129)
    else revisions.push(arg)
  }
  const repository = await context.repository()
  const expression = revisions[0] ?? 'HEAD'
  let oid: string
  try {
    oid = await resolveRevision(repository, expression)
  } catch (error) {
    throw normaliseShowPathError(expression, error)
  }
  // An annotated tag prints its own header and then the object it peels to.
  // A tag chain therefore prints every tag header before the commit/blob/tree,
  // exactly like git; a bare `peelToCommitish` would silently drop that text.
  let current = oid
  const tagChunks: Uint8Array[] = []
  for (let depth = 0; depth < 20; depth += 1) {
    if ((await repository.odb.type(current)) !== 'tag') break
    const tag = parseTagObject((await repository.odb.read(current)).data)
    if (tag.target === undefined) throw fatal(`bad tag object ${current}`)
    tagChunks.push(renderTagHeader(tag, oneline))
    current = tag.target
    // Git separates a tag's message from a following tag/tree header by one
    // newline. A commit header gets that separator only in the default style
    // (`--oneline` writes its one-line form immediately), and a blob's raw
    // bytes are always written with no separator at all.
    const nextType = await repository.odb.type(current)
    if (nextType === 'tag' || nextType === 'tree' || (!oneline && nextType === 'commit')) {
      tagChunks.push(encodeText('\n'))
    }
  }
  if (tagChunks.length > 0) context.output.stdout(concatBytes(...tagChunks))
  const type = await repository.odb.type(current)
  if (type === 'blob') {
    // Raw bytes only: no decoder, no re-encoder and no added newline, so a
    // binary or non-UTF-8 blob is reproduced byte-for-byte.
    context.output.stdout((await repository.odb.read(current)).data)
    return 0
  }
  if (type === 'tree') {
    // Tree entry names are raw bytes. Decoding them as UTF-8 would replace an
    // invalid byte (for example 0xff) with U+FFFD and corrupt the output, so
    // parse the mode/NUL/name framing directly and copy the name bytes.
    const chunks: Uint8Array[] = [encodeText(`tree ${expression}\n\n`)]
    for (const entry of parseRawTree((await repository.odb.read(current)).data)) {
      chunks.push(entry.name)
      if (entry.directory) chunks.push(encodeText('/'))
      chunks.push(encodeText('\n'))
    }
    context.output.stdout(concatBytes(...chunks))
    return 0
  }
  const commit = await readCommit(repository, current)
  if (oneline) context.output.stdout(`${shortOid(commit.oid)} ${subject(commit.message)}\n`)
  // The blank line separates the header from a patch/stat/name list; with
  // `-s` git ends at the header's own newline and must not add a second one.
  else context.output.stdout(noPatch ? renderCommitHeader(commit) : `${renderCommitHeader(commit)}\n`)
  if (noPatch) return 0
  const before = commit.parents.length > 0
    ? await flattenTree(repository, (await readCommit(repository, commit.parents[0] as string)).tree)
    : new Map<string, Snapshot>()
  const after = await flattenTree(repository, commit.tree)
  const changes = await diffFlatTrees(repository, before, after, { renames: true })
  if (nameOnly || nameStatus) {
    for (const change of changes) {
      if (nameOnly) {
        context.output.stdout(`${change.path}\n`)
      } else {
        const code = change.status === 'R' ? `R${String(change.score ?? 100).padStart(3, '0')}` : change.status
        context.output.stdout(`${code}\t${change.oldPath === undefined ? change.path : `${change.oldPath}\t${change.path}`}\n`)
      }
    }
    return 0
  }
  if (stat) {
    await renderStat(context, repository, changes)
    return 0
  }
  for (const change of changes) await renderFileDiff(context, repository, change, 3)
  return 0
}

/** One row `git branch` will print. */
interface BranchRow {
  /** Name used for `--list` pattern matching and as the default display. */
  readonly name: string
  /** Printed name when it differs from the pattern name (detached HEAD). */
  readonly display?: string | undefined
  readonly oid?: string | undefined
  readonly remote: boolean
  readonly current: boolean
  /** Set for a symbolic remote ref such as `origin/HEAD -> origin/main`. */
  readonly target?: string | undefined
  /** Synthetic `(HEAD detached at <oid>)` row; it has no upstream config. */
  readonly detached?: boolean | undefined
}

/** One configured upstream of a local branch. */
interface BranchUpstream {
  readonly display: string
  readonly oid?: string | undefined
}

/**
 * Terminal columns occupied by one ref name.
 *
 * `git branch` pads its oid column by `utf8_strwidth`: a CJK ideograph is one
 * code point (two UTF-16 code units) but two terminal columns, while combining
 * marks and format characters occupy none. Covering the EastAsianWidth
 * wide/fullwidth blocks keeps common CJK branch names aligned; this is not a
 * complete Unicode wcwidth table.
 */
function displayWidth(text: string): number {
  let width = 0
  for (const char of text) {
    const code = char.codePointAt(0) as number
    if (code === 0 || /[\p{Mn}\p{Me}\p{Cf}]/u.test(char)) continue
    width += isWideCodePoint(code) ? 2 : 1
  }
  return width
}

/** True for code points Unicode's EastAsianWidth marks wide or fullwidth. */
function isWideCodePoint(code: number): boolean {
  return (code >= 0x1100 && code <= 0x115f)
    || code === 0x2329 || code === 0x232a
    || (code >= 0x2e80 && code <= 0x303e)
    || (code >= 0x3041 && code <= 0x33ff)
    || (code >= 0x3400 && code <= 0x4dbf)
    || (code >= 0x4e00 && code <= 0x9fff)
    || (code >= 0xa000 && code <= 0xa4cf)
    || (code >= 0xa960 && code <= 0xa97f)
    || (code >= 0xac00 && code <= 0xd7a3)
    || (code >= 0xf900 && code <= 0xfaff)
    || (code >= 0xfe10 && code <= 0xfe19)
    || (code >= 0xfe30 && code <= 0xfe6f)
    || (code >= 0xff00 && code <= 0xff60)
    || (code >= 0xffe0 && code <= 0xffe6)
    || (code >= 0x1b000 && code <= 0x1b001)
    || (code >= 0x1f200 && code <= 0x1f251)
    || (code >= 0x1f300 && code <= 0x1f64f)
    || (code >= 0x1f900 && code <= 0x1f9ff)
    || (code >= 0x20000 && code <= 0x2fffd)
    || (code >= 0x30000 && code <= 0x3fffd)
}

/** Pad a ref name with spaces until it occupies `width` terminal columns. */
function padDisplay(text: string, width: number): string {
  return text + ' '.repeat(Math.max(0, width - displayWidth(text)))
}

/** `git branch`. */
export async function branch(context: CommandContext): Promise<number> {
  let listMode = true
  let explicitListMode = false
  let showCurrent = false
  let deleteMode = false
  let forceDelete = false
  let force = false
  /** Last scope flag wins, matching `git branch -ar` vs `-ra`. */
  let scope: 'local' | 'remote' | 'all' = 'local'
  /** `-v` is 1, `-vv` (or repeated `-v`) is 2. */
  let verbose = 0
  const rest: string[] = []
  for (const arg of context.args) {
    if (arg === '--show-current') showCurrent = true
    else if (arg === '--all') scope = 'all'
    else if (arg === '--remotes') scope = 'remote'
    else if (arg === '--verbose') verbose = Math.min(2, verbose + 1)
    else if (arg === '--force') force = true
    else if (arg === '--no-color' || arg === '--color=never') continue
    else if (arg === '--list') { listMode = true; explicitListMode = true }
    else if (arg === '--') { /* the rest are patterns/branch names */ }
    else if (arg.startsWith('--')) throw fatal(`unsupported branch option '${arg}'`, 129)
    else if (arg.startsWith('-') && arg !== '-') {
      // Combined short options: `-avv`, `-va`, `-ar`, ... are character
      // groups, not one opaque string.
      let valid = true
      for (const character of arg.slice(1)) {
        if (character === 'a') scope = 'all'
        else if (character === 'r') scope = 'remote'
        else if (character === 'v') verbose = Math.min(2, verbose + 1)
        else if (character === 'l') { listMode = true; explicitListMode = true }
        else if (character === 'd') { deleteMode = true; listMode = false }
        else if (character === 'D') { deleteMode = true; forceDelete = true; listMode = false }
        else if (character === 'f') force = true
        else { valid = false; break }
      }
      if (!valid) throw fatal(`unsupported branch option '${arg}'`, 129)
    } else { rest.push(arg); if (!deleteMode && !explicitListMode) listMode = false }
  }
  const repository = await context.repository()
  if (showCurrent) {
    const current = await currentBranchName(repository)
    if (current !== undefined) context.output.stdout(`${current}\n`)
    return 0
  }
  if (deleteMode) {
    for (const name of rest) {
      const oid = await resolveRef(repository, `refs/heads/${name}`)
      if (oid === undefined) throw fatal(`branch '${name}' not found`)
      if (!forceDelete) {
        const head = await headOid(repository)
        if (head !== undefined && !(await isAncestor(repository, oid, head))) {
          throw new GitFailure(1, `error: the branch '${name}' is not fully merged\n`)
        }
      }
      await deleteBranch(repository, name)
      context.output.stdout(`Deleted branch ${name} (was ${shortOid(oid)}).\n`)
    }
    return 0
  }
  if (!listMode) {
    const name = rest[0] as string
    const start = rest[1] === undefined ? await headOid(repository) : await resolveRevision(repository, rest[1] as string)
    if (start === undefined) throw fatal('cannot create a branch before the first commit')
    await writeBranch(repository, name, start, { force })
    return 0
  }
  const patterns = explicitListMode ? rest : []
  const current = await currentBranchName(repository)
  const head = await headOid(repository)
  const rows: BranchRow[] = []
  if (scope !== 'remote' && current === undefined && head !== undefined) {
    // Git lists detached HEAD as a synthetic current row whose pattern name is
    // `HEAD`; it participates in `--list`, width alignment and verbose output.
    const name = 'HEAD'
    if (patterns.length === 0 || patterns.some(pattern => matchesBranchPattern(pattern, name))) {
      rows.push({
        name,
        display: `(HEAD detached at ${shortOid(head)})`,
        oid: head,
        remote: false,
        current: true,
        detached: true,
      })
    }
  }
  if (scope !== 'remote') {
    for (const [ref, oid] of await listRefs(repository, 'refs/heads/')) {
      const name = ref.slice('refs/heads/'.length)
      if (patterns.length > 0 && !patterns.some(pattern => matchesBranchPattern(pattern, name))) continue
      rows.push({ name, oid, remote: false, current: name === current })
    }
  }
  if (scope !== 'local') {
    const remoteRows: BranchRow[] = []
    for (const [ref, oid] of await listRefs(repository, 'refs/remotes/')) {
      const abbreviated = ref.slice('refs/remotes/'.length)
      // Patterns match the abbreviation (`origin/main`) in both `-a` and `-r`;
      // only the printed name keeps the `remotes/` prefix for `-a`.
      if (patterns.length > 0 && !patterns.some(pattern => matchesBranchPattern(pattern, abbreviated))) continue
      const name = scope === 'all' ? `remotes/${abbreviated}` : abbreviated
      remoteRows.push({ name, oid, remote: true, current: false })
    }
    // A normal clone stores `refs/remotes/origin/HEAD` as a symbolic ref.
    // listRefs only returns refs whose file holds an object id, so enumerate
    // the symbolic ones here and render git's `name -> target` shape.
    for (const [ref, target] of await listSymbolicRefs(repository, 'refs/remotes/')) {
      const abbreviated = ref.slice('refs/remotes/'.length)
      if (patterns.length > 0 && !patterns.some(pattern => matchesBranchPattern(pattern, abbreviated))) continue
      const name = scope === 'all' ? `remotes/${abbreviated}` : abbreviated
      remoteRows.push({ name, remote: true, current: false, target: displayRefTarget(target) })
    }
    remoteRows.sort((left, right) => compareStrings(left.name, right.name))
    rows.push(...remoteRows)
  }
  const displayName = (row: BranchRow): string => row.display ?? row.name
  const width = rows.reduce((maximum, row) => Math.max(maximum, displayWidth(displayName(row))), 0)
  for (const row of rows) {
    const marker = row.current ? '*' : ' '
    const name = displayName(row)
    if (row.target !== undefined) {
      // Symbolic remote refs have no oid, so verbose mode pads the name and
      // appends the target without a `*` marker, exactly like git.
      const suffix = ` -> ${row.target}`
      const padded = verbose === 0 ? name : padDisplay(name, width)
      context.output.stdout(`${marker} ${padded}${suffix}\n`)
      continue
    }
    if (verbose === 0) {
      context.output.stdout(`${marker} ${name}\n`)
      continue
    }
    const oid = row.oid as string
    let line = `${marker} ${padDisplay(name, width)} ${shortOid(oid)}`
    if (!row.remote && row.detached !== true) {
      const upstream = await branchUpstream(repository, row.name)
      if (upstream !== undefined) {
        if (upstream.oid === undefined) {
          line += verbose >= 2 ? ` [${upstream.display}: gone]` : ' [gone]'
        } else {
          const divergence = await aheadBehind(repository, oid, upstream.oid)
          const tracking = divergenceText(divergence)
          if (verbose >= 2) line += ` [${upstream.display}${tracking === '' ? '' : `: ${tracking}`}]`
          else if (tracking !== '') line += ` [${tracking}]`
        }
      }
    }
    const commit = await readCommit(repository, oid)
    context.output.stdout(`${line} ${subject(commit.message)}\n`)
  }
  return 0
}

/** Symbolic refs below a prefix, keyed by full ref name and mapped to the target ref. */
async function listSymbolicRefs(repository: Repository, prefix: string): Promise<Map<string, string>> {
  const refs = new Map<string, string>()
  const walk = async (directory: string, relative: string): Promise<void> => {
    let entries
    try {
      entries = await repository.fs.readdir(directory)
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return
      throw error
    }
    for (const entry of entries) {
      if (entry.isDirectory) {
        await walk(`${directory}/${entry.name}`, `${relative}${entry.name}/`)
      } else if (entry.isFile) {
        const name = `refs/${relative}${entry.name}`
        if (!name.startsWith(prefix)) continue
        const content = (await readRefFile(repository, name))?.split('\n')[0]?.trim() ?? ''
        if (content.startsWith('ref:')) refs.set(name, content.slice(4).trim())
      }
    }
  }
  await walk(`${repository.commonDir}/refs`, '')
  return new Map([...refs.entries()].sort(([left], [right]) => compareStrings(left, right)))
}

/** Shorten a symbolic ref target the way `git branch` does. */
function displayRefTarget(target: string): string {
  if (target.startsWith('refs/remotes/')) return target.slice('refs/remotes/'.length)
  if (target.startsWith('refs/heads/')) return target.slice('refs/heads/'.length)
  return target
}

/** Map one fetch refspec's source to its destination, or undefined on no match. */
function mapFetchRefspec(refspec: string, source: string): string | undefined {
  let spec = refspec.trim()
  if (spec.startsWith('+')) spec = spec.slice(1)
  if (spec.startsWith('^')) return undefined
  const colon = spec.indexOf(':')
  if (colon < 0) return undefined
  const from = spec.slice(0, colon)
  const to = spec.slice(colon + 1)
  if (from === source) return to
  const star = from.indexOf('*')
  if (star < 0 || !to.includes('*')) return undefined
  const prefix = from.slice(0, star)
  const suffix = from.slice(star + 1)
  if (!source.startsWith(prefix) || !source.endsWith(suffix) || source.length < prefix.length + suffix.length) {
    return undefined
  }
  const middle = source.slice(prefix.length, source.length - suffix.length)
  return to.replace('*', middle)
}

/**
 * Read `branch.<name>.remote`/`.merge` when git would treat it as upstream.
 *
 * Git derives the upstream ref from the remote's fetch refspec. A remote with
 * only `remote.<name>.url` (no refspec) creates no remote-tracking ref and is
 * therefore not an upstream: printing `[origin/main]`/`[origin/main: gone]`
 * there would be a wrong answer, not a shorthand. The special `.` remote reads
 * a local branch and needs no remote config.
 */
async function branchUpstream(repository: Repository, name: string): Promise<BranchUpstream | undefined> {
  const remote = repository.config.get(`branch.${name}.remote`)
  const merge = repository.config.get(`branch.${name}.merge`)
  if (remote === undefined || merge === undefined) return undefined
  if (remote === '.') {
    const branch = merge.startsWith('refs/heads/') ? merge.slice('refs/heads/'.length) : merge
    return { display: branch, oid: await resolveRef(repository, `refs/heads/${branch}`) }
  }
  const refspec = repository.config.get(`remote.${remote}.fetch`)
  if (refspec === undefined) return undefined
  const ref = mapFetchRefspec(refspec, merge)
  if (ref === undefined) return undefined
  const display = ref.startsWith('refs/remotes/')
    ? ref.slice('refs/remotes/'.length)
    : ref.startsWith('refs/heads/') ? ref.slice('refs/heads/'.length) : ref
  return { display, oid: await resolveRef(repository, ref) }
}

/** Every commit reachable from one tip (the tip included). */
async function reachableCommits(repository: Repository, tip: string): Promise<Set<string>> {
  const seen = new Set<string>()
  const queue = [tip]
  while (queue.length > 0) {
    const oid = queue.pop() as string
    if (seen.has(oid)) continue
    seen.add(oid)
    queue.push(...(await readCommit(repository, oid)).parents)
  }
  return seen
}

/** Count commits unique to each side of a local/upstream pair. */
async function aheadBehind(repository: Repository, local: string, upstream: string): Promise<{ ahead: number; behind: number }> {
  if (local === upstream) return { ahead: 0, behind: 0 }
  const localSet = await reachableCommits(repository, local)
  const upstreamSet = await reachableCommits(repository, upstream)
  let ahead = 0
  for (const oid of localSet) if (!upstreamSet.has(oid)) ahead += 1
  let behind = 0
  for (const oid of upstreamSet) if (!localSet.has(oid)) behind += 1
  return { ahead, behind }
}

/** `[ahead N, behind M]` text without the brackets (empty when in sync). */
function divergenceText(divergence: { ahead: number; behind: number }): string {
  const parts: string[] = []
  if (divergence.ahead > 0) parts.push(`ahead ${divergence.ahead}`)
  if (divergence.behind > 0) parts.push(`behind ${divergence.behind}`)
  return parts.join(', ')
}

/**
 * Match one `git branch --list` glob.
 *
 * Git matches ref names with byte-oriented `wildmatch` (flags 0), the same
 * matcher `tag -l` uses; a UTF-16 `RegExp` misread `?` on CJK names and threw
 * a `SyntaxError` for malformed or descending bracket expressions.
 */
function matchesBranchPattern(pattern: string, name: string): boolean {
  return wildmatchBytes(encodeText(pattern), encodeText(name))
}

export async function isAncestor(repository: Repository, ancestor: string, descendant: string): Promise<boolean> {
  const seen = new Set<string>()
  let queue = [descendant]
  while (queue.length > 0) {
    const next: string[] = []
    for (const oid of queue) {
      if (oid === ancestor) return true
      if (seen.has(oid)) continue
      seen.add(oid)
      const commit = await readCommit(repository, oid)
      next.push(...commit.parents)
    }
    queue = next
  }
  return false
}

interface SwitchTarget {
  /** Commit the work tree should match; undefined for an unborn branch. */
  readonly commit?: string | undefined
  /** Branch ref to point HEAD at. */
  readonly branch?: string | undefined
  readonly create?: boolean
  /** `-B`/`-C`: reset an existing branch instead of failing on it. */
  readonly reset?: boolean
  readonly detach?: boolean
  readonly force?: boolean
  /** Do not print git's success lines (`checkout -q` / `switch -q`). */
  readonly quiet?: boolean
  /** Do not print git's `HEAD is now at` line (merge fast-forward). */
  readonly quietHead?: boolean
  /** Leave HEAD alone; the caller moves the current branch (merge/pull). */
  readonly keepHead?: boolean
}

/** `git checkout` and `git switch` share this implementation. */
export async function switchTo(context: CommandContext, target: SwitchTarget): Promise<number> {
  const repository = await context.repository()
  const workTree = requireWorkTree(repository)
  const index = await loadIndex(repository)
  const indexByPath = new Map<string, { mode: number; oid: string }>()
  for (const entry of index.entries) if (entry.stage === 0) indexByPath.set(entry.path, { mode: entry.mode, oid: entry.oid })
  const targetTree: Map<string, Snapshot> = target.commit === undefined
    ? new Map()
    : await flattenTree(repository, (await readCommit(repository, target.commit)).tree)
  const files = await scanWorktree(repository)
  // Refuse to overwrite work that is not recoverable: a target path that
  // differs from the index is a conflict when the path is dirty or untracked.
  const conflicts: string[] = []
  for (const [path, entry] of targetTree) {
    const current = indexByPath.get(path)
    const unchangedInTarget = current !== undefined && current.oid === entry.oid && current.mode.toString(8) === entry.mode
    if (unchangedInTarget) continue
    const info = files.get(path)
    if (current === undefined && info !== undefined) {
      conflicts.push(path)
      continue
    }
    if (current !== undefined) {
      const blob = await readWorktreeBlob(context.fs, repository, workTree, path)
      if (blob === undefined || blob.oid !== current.oid) conflicts.push(path)
    }
  }
  for (const [path, entry] of indexByPath) {
    if (targetTree.has(path)) continue
    const blob = await readWorktreeBlob(context.fs, repository, workTree, path)
    if (blob === undefined) continue
    if (blob.oid !== entry.oid) conflicts.push(path)
  }
  if (conflicts.length > 0 && target.force !== true) {
    const unique = [...new Set(conflicts)].sort(compareStrings)
    throw new GitFailure(
      1,
      `${unique.map(path => `error: Your local changes to the following files would be overwritten by checkout:\n\t${path}`).join('\n')}\n`
      + 'Please commit your changes or stash them before you switch branches.\n',
    )
  }
  // Materialize the target tree.
  for (const [path, entry] of targetTree) {
    const current = indexByPath.get(path)
    const unchangedInTarget = current !== undefined && current.oid === entry.oid && current.mode.toString(8) === entry.mode
    if (unchangedInTarget) continue
    const data = (await repository.odb.read(entry.oid)).data
    await ensureParent(context.fs, workTree, path)
    await removeWorktreePath(context.fs, workTree, path)
    await context.fs.writeFile(`${workTree}/${path}`, data, parseMode(entry.mode))
  }
  for (const path of indexByPath.keys()) {
    if (targetTree.has(path)) continue
    await removeWorktreePath(context.fs, workTree, path)
  }
  // Rebuild the index from the target tree. A path whose content is identical
  // between the two branches keeps its previous index entry (stat cache and
  // all): refreshing its stat would make the system git mistake a preserved
  // local edit for a clean file.
  const previousEntries = new Map<string, IndexEntry>()
  for (const entry of index.entries) if (entry.stage === 0) previousEntries.set(entry.path, entry)
  const entries: IndexEntry[] = []
  for (const [path, entry] of [...targetTree.entries()].sort(([left], [right]) => compareStrings(left, right))) {
    const previous = previousEntries.get(path)
    if (previous !== undefined && previous.oid === entry.oid && previous.mode.toString(8) === entry.mode) {
      entries.push(previous)
    } else {
      entries.push(await statEntry(context.fs, workTree, path, entry.oid, parseMode(entry.mode)))
    }
  }
  await writeIndex(context.fs, repository.indexPath, { version: 2, entries })
  if (target.keepHead === true) return 0
  if (target.branch !== undefined) {
    const branchExisted = await resolveRef(repository, `refs/heads/${target.branch}`) !== undefined
    const previousBranch = await currentBranchName(repository)
    if (target.create === true && target.commit !== undefined) {
      await writeBranch(repository, target.branch, target.commit, { force: target.reset === true })
    }
    await writeRef(repository, 'HEAD', `ref: refs/heads/${target.branch}\n`)
    if (target.quiet !== true) {
      context.output.stderr(target.create === true
        ? target.reset === true && branchExisted
          ? previousBranch === target.branch
            ? `Reset branch '${target.branch}'\n`
            : `Switched to and reset branch '${target.branch}'\n`
          : `Switched to a new branch '${target.branch}'\n`
        : `Switched to branch '${target.branch}'\n`)
    }
  } else if (target.commit !== undefined) {
    await writeRef(repository, 'HEAD', `${target.commit}\n`)
    if (target.quiet !== true && target.quietHead !== true) {
      const commit = await readCommit(repository, target.commit)
      context.output.stderr(`HEAD is now at ${shortOid(target.commit)} ${subject(commit.message)}\n`)
    }
  }
  return 0
}

/** `git checkout`. */
export async function checkout(context: CommandContext): Promise<number> {
  let create = false
  let reset = false
  let force = false
  let detached = false
  let pathMode = false
  let quiet = false
  const rest: string[] = []
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    if (arg === '-b' || arg === '-B' || arg === '--orphan') {
      create = true
      if (arg === '-B') reset = true
      const value = context.args[index + 1]
      if (value === undefined) throw fatal('checkout: -b requires a branch name', 129)
      rest.unshift(value)
      index += 1
    } else if (arg === '-f' || arg === '--force') force = true
    else if (arg === '--detach') detached = true
    else if (arg === '--') pathMode = true
    else if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg.startsWith('-')) throw fatal(`unsupported checkout option '${arg}'`, 129)
    else rest.push(arg)
  }
  const repository = await context.repository()
  if (pathMode || rest.length === 0) {
    if (rest.length === 0) throw fatal('you must specify path(s) to restore', 129)
    return await restoreWorktreePaths(context, repository, rest)
  }
  const targetName = rest[0] as string
  if (create) {
    if (!reset && await resolveRef(repository, `refs/heads/${targetName}`) !== undefined) {
      throw fatal(`a branch named '${targetName}' already exists`)
    }
    const start = rest[1] === undefined ? await headOid(repository) : await resolveRevision(repository, rest[1] as string)
    if (start === undefined) throw fatal('cannot create a branch before the first commit')
    return await switchTo(context, { commit: start, branch: targetName, create: true, reset, force, quiet })
  }
  const branchOid = await resolveBranchOrRef(repository, targetName)
  if (branchOid !== undefined && !detached) {
    return await switchTo(context, { commit: branchOid, branch: targetName, force, quiet })
  }
  const oid = await resolveRevision(repository, targetName)
  return await switchTo(context, { commit: oid, detach: true, force, quiet })
}

/** `git switch`. */
export async function switchCommand(context: CommandContext): Promise<number> {
  let create = false
  let reset = false
  let detach = false
  let force = false
  let quiet = false
  const rest: string[] = []
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    if (arg === '-c' || arg === '--create' || arg === '-C' || arg === '--force-create') {
      create = true
      if (arg === '-C' || arg === '--force-create') reset = true
      const value = context.args[index + 1]
      if (value === undefined) throw fatal('switch: -c requires a branch name', 129)
      rest.unshift(value)
      index += 1
    } else if (arg === '-d' || arg === '--detach') detach = true
    else if (arg === '-f' || arg === '--force' || arg === '--discard-changes') force = true
    else if (arg === '-q' || arg === '--quiet') quiet = true
    else if (arg.startsWith('-')) throw fatal(`unsupported switch option '${arg}'`, 129)
    else rest.push(arg)
  }
  const repository = await context.repository()
  const targetName = rest[0]
  if (targetName === undefined) throw fatal('switch: missing branch name', 129)
  if (create) {
    if (!reset && await resolveRef(repository, `refs/heads/${targetName}`) !== undefined) {
      throw fatal(`a branch named '${targetName}' already exists`)
    }
    const start = rest[1] === undefined ? await headOid(repository) : await resolveRevision(repository, rest[1] as string)
    if (start === undefined) throw fatal('cannot create a branch before the first commit')
    return await switchTo(context, { commit: start, branch: targetName, create: true, reset, force, quiet })
  }
  if (detach) {
    const oid = await resolveRevision(repository, targetName)
    return await switchTo(context, { commit: oid, detach: true, force, quiet })
  }
  const oid = await resolveBranchOrRef(repository, targetName)
  if (oid === undefined) throw fatal(`invalid reference: ${targetName}`)
  return await switchTo(context, { commit: oid, branch: targetName, force, quiet })
}

/** Move the current branch (or detached HEAD) to a fast-forwarded commit. */
export async function fastForwardHead(repository: Repository, oid: string): Promise<void> {
  const symbolic = await headRef(repository)
  if (symbolic === undefined) await writeRef(repository, 'HEAD', oid)
  else await writeRef(repository, symbolic, oid)
}

/** `git merge`, fast-forward only. */
export async function merge(context: CommandContext): Promise<number> {
  let noFf = false
  let message: string | undefined
  const rest: string[] = []
  for (let index = 0; index < context.args.length; index += 1) {
    const arg = context.args[index] as string
    if (arg === '--no-ff') noFf = true
    else if (arg === '-m') { message = context.args[index + 1]; index += 1 }
    else if (arg === '--ff-only') continue
    else if (arg.startsWith('-')) throw fatal(`unsupported merge option '${arg}'`, 129)
    else rest.push(arg)
  }
  const target = rest[0]
  if (target === undefined) throw fatal('merge: missing branch', 129)
  const repository = await context.repository()
  const head = await headOid(repository)
  if (head === undefined) throw fatal('merge: HEAD has no commits')
  const other = await resolveRevision(repository, target)
  if (await isAncestor(repository, other, head)) {
    context.output.stdout('Already up to date.\n')
    return 0
  }
  const canFastForward = await isAncestor(repository, head, other)
  if (!canFastForward || noFf) {
    throw fatal(
      `git merge ${target}: a non-fast-forward merge needs three-way conflict resolution, which the Worker git does not do. `
      + 'Nothing was changed.',
    )
  }
  const tree = (await readCommit(repository, other)).tree
  const before = await headTree(repository)
  const after = await flattenTree(repository, tree)
  const changes = await diffFlatTrees(repository, before, after, { renames: true })
  await switchTo(context, { commit: other, quietHead: true, keepHead: true })
  await fastForwardHead(repository, other)
  context.output.stdout(`Updating ${shortOid(head)}..${shortOid(other)}\nFast-forward\n`)
  await renderStat(context, repository, changes)
  void message
  return 0
}

/** `git remote -v` (clone/fetch/push read the same config). */
export async function remote(context: CommandContext): Promise<number> {
  let verbose = false
  for (const arg of context.args) {
    if (arg === '-v' || arg === '--verbose') verbose = true
    else if (arg === '--no-color' || arg === '--color=never') continue
    else {
      // `remote add/set-url/remove/...` write configuration. Listing a remote
      // table after ignoring the action would claim an add happened.
      throw fatal(
        `unsupported remote argument '${arg}': the Worker git only lists remotes (git remote [-v]). `
        + 'Use git config remote.<name>.url <url> to provide a URL. Nothing was changed.',
        129,
      )
    }
  }
  const repository = await context.repository()
  const remotes = repository.config.withPrefix('remote.')
  const names = [...new Set(remotes.map(([key]) => key.split('.')[1] ?? '').filter(name => name !== ''))]
  if (verbose) {
    for (const name of names.sort()) {
      const url = repository.config.get(`remote.${name}.url`) ?? ''
      context.output.stdout(`${name}\t${url} (fetch)\n${name}\t${url} (push)\n`)
    }
    return 0
  }
  for (const name of names.sort()) context.output.stdout(`${name}\n`)
  return 0
}
