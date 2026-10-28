// SPDX-License-Identifier: MIT
/**
 * Repository discovery, refs, configuration and revision parsing.
 *
 * Discovery follows git's rules for the cases the phone hits: a `.git`
 * directory, a `.git` file (`gitdir: ...`) used by linked worktrees and
 * submodules, `GIT_DIR` / `GIT_WORK_TREE`, and a bare repository. Refs are read
 * from loose files and `packed-refs` in the common directory, and written with
 * git's temp-file-plus-rename discipline. Revision syntax covers what the
 * porcelain needs: `HEAD`, branches, tags, remote-tracking refs, full and
 * abbreviated object ids, `^`/`~` ancestry and `<rev>:<path>`.
 * @module @phone-dsh/dsh-wasi-toolbox/git/repo
 */
import { posix } from 'node:path'
import { fatal } from './errors.ts'
import { decodeText, encodeText, isErrno, resolvePath } from './fs.ts'
import type { GitFs } from './fs.ts'
import { ObjectDatabase } from './objects.ts'
import { readPackIndex } from './pack.ts'
import { toHex } from './pack.ts'

/** A parsed git configuration file. */
export class GitConfig {
  private readonly entries = new Map<string, string>()

  /** Read one key (`section.key` or `section.subsection.key`). */
  get(key: string): string | undefined {
    return this.entries.get(key.toLowerCase())
  }

  /** Read a boolean, git's `true`/`false`/`yes`/`no`/`on`/`off`/`1`/`0` forms. */
  getBoolean(key: string): boolean | undefined {
    const value = this.get(key)
    if (value === undefined) return undefined
    const normalised = value.trim().toLowerCase()
    if (['true', 'yes', 'on', '1'].includes(normalised)) return true
    if (['false', 'no', 'off', '0', ''].includes(normalised)) return false
    return undefined
  }

  /** Read a signed integer. */
  getNumber(key: string): number | undefined {
    const value = this.get(key)
    if (value === undefined) return undefined
    const parsed = Number.parseInt(value.trim(), 10)
    return Number.isFinite(parsed) ? parsed : undefined
  }

  set(key: string, value: string): void {
    this.entries.set(key.toLowerCase(), value)
  }

  /** All keys with the given `section.` or `section.subsection.` prefix. */
  withPrefix(prefix: string): [string, string][] {
    const lower = prefix.toLowerCase()
    return [...this.entries.entries()].filter(([key]) => key.startsWith(lower))
  }
}

/** Parse an INI-shaped git config. */
export function parseConfig(text: string): GitConfig {
  const config = new GitConfig()
  let section = ''
  let subsection: string | undefined
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#') || line.startsWith(';')) continue
    if (line.startsWith('[')) {
      const match = /^\[([A-Za-z0-9.-]+)(?:\s+"((?:[^"\\]|\\.)*)")?\]$/.exec(line)
      if (match === null) continue
      section = (match[1] as string).toLowerCase()
      subsection = match[2]?.replace(/\\(.)/g, '$1')
      continue
    }
    const equals = line.indexOf('=')
    if (equals < 0) continue
    const key = line.slice(0, equals).trim().toLowerCase()
    let value = line.slice(equals + 1).trim()
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) value = value.slice(1, -1)
    const full = subsection === undefined ? `${section}.${key}` : `${section}.${subsection.toLowerCase()}.${key}`
    config.set(full, value)
  }
  return config
}

/** One repository rooted at a git directory. */
export interface Repository {
  readonly fs: GitFs
  /** Working directory of the process (absolute, as the shell gave it). */
  readonly cwd: string
  /** Absolute git directory (the per-worktree one when linked). */
  readonly gitDir: string
  /** Directory holding shared refs and objects (differs for linked worktrees). */
  readonly commonDir: string
  /** Absolute real path of the work tree, or undefined for a bare repository. */
  readonly workTree?: string
  readonly bare: boolean
  readonly config: GitConfig
  /** Process environment (the shell exports, including `GIT_*` behaviour switches). */
  readonly env: Readonly<Record<string, string | undefined>>
  readonly odb: ObjectDatabase
  /** Absolute index path (`GIT_INDEX_FILE` overrides). */
  readonly indexPath: string
}

/** Read a text file, returning undefined when it is missing. */
async function readOptionalText(fs: GitFs, path: string): Promise<string | undefined> {
  try {
    return decodeText(await fs.readFile(path))
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) return undefined
    throw error
  }
}

/** Resolve the `.git` file pointer used by linked worktrees and submodules. */
async function gitDirFromFile(fs: GitFs, file: string): Promise<string> {
  const text = decodeText(await fs.readFile(file))
  const match = /^gitdir:\s*(.+?)\s*$/m.exec(text)
  if (match === null) throw fatal(`invalid gitfile format: ${file}`)
  return resolvePath(posix.dirname(file), match[1] as string)
}

/** Load the shared configuration (system/home/repo) without exposing the host. */
async function loadConfig(
  fs: GitFs,
  gitDir: string,
  workTree: string | undefined,
  env: Readonly<Record<string, string | undefined>>,
): Promise<GitConfig> {
  const config = new GitConfig()
  const home = env.HOME
  if (home !== undefined && home !== '') {
    const globalText = await readOptionalText(fs, `${home}/.gitconfig`)
    if (globalText !== undefined) mergeConfig(config, parseConfig(globalText))
  }
  const repoText = await readOptionalText(fs, `${gitDir}/config`)
  if (repoText !== undefined) mergeConfig(config, parseConfig(repoText))
  if (workTree !== undefined) {
    // core.filemode controls whether the executable bit is trusted; the VFS
    // stores it, so the default is true.
    if (config.get('core.filemode') === undefined) config.set('core.filemode', 'true')
  }
  return config
}

function mergeConfig(target: GitConfig, source: GitConfig): void {
  for (const [key, value] of source.withPrefix('')) target.set(key, value)
}

/** Resolve the directory `git rev-parse --git-path` names. */
export function gitPath(repo: Pick<Repository, 'gitDir' | 'commonDir'>, name: string): string {
  const shared = name === 'objects' || name.startsWith('objects/') || name === 'packed-refs'
    || name === 'refs' || name.startsWith('refs/') || name === 'info/exclude'
    || name === 'info/refs' || name === 'config' || name === 'hooks' || name.startsWith('hooks/')
  return `${shared ? repo.commonDir : repo.gitDir}/${name}`
}

/**
 * Locate the repository that encloses `cwd`.
 * @returns the repository, or undefined when there is none.
 */
export async function discoverRepository(
  fs: GitFs,
  cwd: string,
  env: Readonly<Record<string, string | undefined>> = process.env,
): Promise<Repository | undefined> {
  let gitDir: string | undefined
  let workTree: string | undefined

  if (env.GIT_DIR !== undefined && env.GIT_DIR !== '') {
    gitDir = resolvePath(cwd, env.GIT_DIR)
    workTree = env.GIT_WORK_TREE !== undefined && env.GIT_WORK_TREE !== ''
      ? resolvePath(cwd, env.GIT_WORK_TREE)
      : cwd
  } else {
    let directory = resolvePath(cwd, '.')
    for (;;) {
      const dotGit = `${directory}/.git`
      try {
        const stats = await fs.lstat(dotGit)
        if (stats.isDirectory) {
          gitDir = dotGit
          workTree = directory
          break
        }
        if (stats.isFile) {
          gitDir = await gitDirFromFile(fs, dotGit)
          workTree = directory
          break
        }
      } catch (error) {
        if (!isErrno(error, 'ENOENT', 'ENOTDIR')) throw error
      }
      // A bare repository has HEAD, objects/ and config at its root without a
      // `.git` child. Git discovers it from nested directories too, so check
      // each ancestor after the work-tree marker at that level.
      const bareConfig = await readOptionalText(fs, `${directory}/config`)
      if (bareConfig !== undefined && parseConfig(bareConfig).getBoolean('core.bare') === true) {
        gitDir = directory
        break
      }
      const parent = posix.dirname(directory)
      if (parent === directory) break
      directory = parent
    }
  }

  if (gitDir === undefined) return undefined
  const commonFile = await readOptionalText(fs, `${gitDir}/commondir`)
  const commonDir = commonFile === undefined ? gitDir : resolvePath(gitDir, commonFile.trim())
  const config = await loadConfig(fs, gitDir, workTree, env)
  const bare = config.getBoolean('core.bare') === true
  if (bare) workTree = undefined
  const objectDirectory = env.GIT_OBJECT_DIRECTORY !== undefined && env.GIT_OBJECT_DIRECTORY !== ''
    ? resolvePath(cwd, env.GIT_OBJECT_DIRECTORY)
    : `${commonDir}/objects`
  const alternates = env.GIT_ALTERNATE_OBJECT_DIRECTORIES === undefined
    ? []
    : env.GIT_ALTERNATE_OBJECT_DIRECTORIES.split(':').filter(entry => entry !== '')
      .map(entry => resolvePath(cwd, entry))
  const indexPath = env.GIT_INDEX_FILE !== undefined && env.GIT_INDEX_FILE !== ''
    ? resolvePath(cwd, env.GIT_INDEX_FILE)
    : `${gitDir}/index`
  return {
    fs,
    cwd: resolvePath(cwd, '.'),
    gitDir,
    commonDir,
    ...workTree === undefined ? {} : { workTree },
    bare,
    config,
    env: { ...env },
    odb: new ObjectDatabase(fs, { primary: objectDirectory, alternates }),
    indexPath,
  }
}

/** Discover the repository or fail with git's `fatal:` line (exit 128). */
export async function openRepository(
  fs: GitFs,
  cwd: string,
  env: Readonly<Record<string, string | undefined>> = process.env,
): Promise<Repository> {
  const repository = await discoverRepository(fs, cwd, env)
  if (repository === undefined) throw fatal('not a git repository (or any of the parent directories): .git')
  return repository
}

/** Fail when a command that needs a work tree runs in a bare repository. */
export function requireWorkTree(repository: Repository): string {
  if (repository.workTree === undefined) {
    throw fatal('this operation must be run in a work tree')
  }
  return repository.workTree
}

/** Read one ref's raw content; `<oid>` or `ref: <target>`. */
export async function readRefFile(repository: Repository, name: string): Promise<string | undefined> {
  const path = name === 'HEAD' || name.startsWith('refs/bisect/') ? `${repository.gitDir}/${name}` : `${repository.commonDir}/${name}`
  return await readOptionalText(repository.fs, path)
}

/** Resolve a ref (following symbolic refs) to an object id, or undefined. */
export async function resolveRef(repository: Repository, name: string): Promise<string | undefined> {
  let current = name
  for (let depth = 0; depth < 6; depth += 1) {
    const content = await readRefFile(repository, current)
    if (content === undefined) {
      const packed = await packedRefs(repository)
      return packed.get(current)
    }
    const line = content.split('\n')[0]?.trim() ?? ''
    if (line === '') return undefined
    if (line.startsWith('ref:')) {
      current = line.slice(4).trim()
      continue
    }
    if (/^[0-9a-f]{40}$/i.test(line)) return line.toLowerCase()
    return undefined
  }
  throw fatal(`too many levels of symbolic refs: ${name}`)
}

/** Every ref in `packed-refs`, mapped to its object id. */
export async function packedRefs(repository: Repository): Promise<Map<string, string>> {
  const map = new Map<string, string>()
  const text = await readOptionalText(repository.fs, `${repository.commonDir}/packed-refs`)
  if (text === undefined) return map
  for (const line of text.split('\n')) {
    if (line === '' || line.startsWith('#') || line.startsWith('^')) continue
    const match = /^([0-9a-f]{40}) (.+)$/.exec(line)
    if (match !== null) map.set(match[2] as string, match[1] as string)
  }
  return map
}

/** List every ref under `prefix` (for example `refs/heads/`). */
export async function listRefs(repository: Repository, prefix = 'refs/'): Promise<Map<string, string>> {
  const refs = await packedRefs(repository)
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
        const content = (await readOptionalText(repository.fs, `${directory}/${entry.name}`))?.trim()
        if (content !== undefined && /^[0-9a-f]{40}$/i.test(content)) refs.set(name, content.toLowerCase())
      }
    }
  }
  await walk(`${repository.commonDir}/refs`, '')
  const filtered = new Map<string, string>()
  for (const [name, oid] of refs) if (name.startsWith(prefix)) filtered.set(name, oid)
  return new Map([...filtered.entries()].sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0))
}

/** The ref HEAD points at, or undefined when detached. */
export async function headRef(repository: Repository): Promise<string | undefined> {
  const content = await readRefFile(repository, 'HEAD')
  const line = content?.split('\n')[0]?.trim() ?? ''
  return line.startsWith('ref:') ? line.slice(4).trim() : undefined
}

/** Resolve HEAD to an object id, or undefined on an unborn branch. */
export async function headOid(repository: Repository): Promise<string | undefined> {
  const content = await readRefFile(repository, 'HEAD')
  const line = content?.split('\n')[0]?.trim() ?? ''
  if (line.startsWith('ref:')) return await resolveRef(repository, line.slice(4).trim())
  return /^[0-9a-f]{40}$/i.test(line) ? line.toLowerCase() : undefined
}

/** Write `value` to the ref file behind `name` atomically. */
export async function writeRef(repository: Repository, name: string, value: string): Promise<void> {
  const path = `${repository.commonDir}/${name}`
  await repository.fs.mkdir(posix.dirname(path), true)
  const temporary = `${path}.lock`
  await repository.fs.writeFile(temporary, `${value}\n`)
  await repository.fs.rename(temporary, path)
}

/** Create or update a branch ref; refuses to move an existing one without force. */
export async function writeBranch(
  repository: Repository,
  name: string,
  oid: string,
  options: { readonly force?: boolean } = {},
): Promise<void> {
  const ref = `refs/heads/${name}`
  const existing = await resolveRef(repository, ref)
  if (existing !== undefined && existing !== oid && options.force !== true) {
    throw fatal(`cannot lock ref '${ref}': reference already exists`)
  }
  await writeRef(repository, ref, oid)
}

/** Reject spellings that could escape `refs/` or rewrite something else. */
function assertCanonicalDeleteRef(ref: string): void {
  const parts = ref.split('/')
  const invalid = !ref.startsWith('refs/') || ref.includes('..') || ref.includes('\\')
    || /[\x00-\x20\x7f~^:?*\[\\]/.test(ref)
    || parts.length < 3
    || parts.some(part => part === '' || part === '.' || part === '..' || part.endsWith('.lock'))
  if (invalid) throw fatal(`refusing to delete non-canonical ref '${ref}'`)
}

/**
 * Remove the empty directories a deleted loose ref leaves behind.
 *
 * Git prunes them so a hierarchical name (`release/v1`) cannot keep its
 * namespace alive and block a later parent tag or branch (`release`). The walk
 * stops below `${commonDir}/refs`: git keeps the top-level namespace
 * directories (`refs/tags`, `refs/heads`) even after the last ref is gone.
 */
async function removeEmptyRefParents(repository: Repository, ref: string): Promise<void> {
  const refsRoot = `${repository.commonDir}/refs`
  let directory = posix.dirname(`${repository.commonDir}/${ref}`)
  while (directory !== refsRoot && posix.dirname(directory) !== refsRoot) {
    let entries
    try {
      entries = await repository.fs.readdir(directory)
    } catch (error) {
      if (isErrno(error, 'ENOENT', 'ENOTDIR')) return
      throw error
    }
    if (entries.length > 0) return
    try {
      // The runtime face may not publish `rmdir`; the directory is already
      // proved empty, so the recursive remove only deletes this one entry.
      await repository.fs.rm(directory, { recursive: true })
    } catch (error) {
      if (isErrno(error, 'ENOTEMPTY', 'EEXIST', 'ENOENT', 'ENOTDIR')) return
      throw error
    }
    directory = posix.dirname(directory)
  }
}

/**
 * Delete one ref, whether it is loose, packed, or both.
 *
 * A force-updated packed ref gains a loose file and leaves its old packed
 * entry behind; deleting only the loose file would resurrect the old value.
 * The packed file is edited in place so comments and peeled (`^`) lines for
 * the refs that remain are preserved exactly as git wrote them.
 */
export async function deleteRef(repository: Repository, ref: string): Promise<void> {
  assertCanonicalDeleteRef(ref)
  try {
    await repository.fs.rm(`${repository.commonDir}/${ref}`)
  } catch (error) {
    if (!isErrno(error, 'ENOENT', 'ENOTDIR')) throw error
  }
  await removeEmptyRefParents(repository, ref)
  const path = `${repository.commonDir}/packed-refs`
  const text = await readOptionalText(repository.fs, path)
  if (text === undefined) return
  const lines = text.split('\n')
  const kept: string[] = []
  let found = false
  let skipPeeled = false
  for (const line of lines) {
    if (skipPeeled && line.startsWith('^')) {
      skipPeeled = false
      continue
    }
    skipPeeled = false
    const match = /^([0-9a-f]{40}) (.+)$/.exec(line)
    if (match !== null && match[2] === ref) {
      found = true
      skipPeeled = true
      continue
    }
    kept.push(line)
  }
  if (found) await repository.fs.writeFile(path, kept.join('\n'))
}

/** Delete a local branch. */
export async function deleteBranch(repository: Repository, name: string): Promise<void> {
  await deleteRef(repository, `refs/heads/${name}`)
}

/** One parsed commit. */
export interface CommitInfo {
  readonly oid: string
  readonly tree: string
  readonly parents: readonly string[]
  readonly author: Signature
  readonly committer: Signature
  readonly message: string
}

/** One author/committer line. */
export interface Signature {
  readonly name: string
  readonly email: string
  readonly timestamp: number
  readonly timezone: string
}

/** Parse a commit object. */
export function parseCommit(oid: string, raw: Uint8Array): CommitInfo {
  const text = decodeText(raw)
  const separator = text.indexOf('\n\n')
  const headerText = separator < 0 ? text : text.slice(0, separator)
  const message = separator < 0 ? '' : text.slice(separator + 2)
  let tree = ''
  const parents: string[] = []
  let author: Signature = { name: '', email: '', timestamp: 0, timezone: '+0000' }
  let committer: Signature = author
  for (const line of headerText.split('\n')) {
    if (line.startsWith(' ')) continue
    if (line.startsWith('tree ')) tree = line.slice(5).trim()
    else if (line.startsWith('parent ')) parents.push(line.slice(7).trim())
    else if (line.startsWith('author ')) author = parseSignature(line.slice(7))
    else if (line.startsWith('committer ')) committer = parseSignature(line.slice(10))
  }
  return { oid, tree, parents, author, committer, message }
}

/** Parse `Name <email> 1700000000 +0000`. */
export function parseSignature(text: string): Signature {
  const match = /^(.*?) <([^>]*)> (-?\d+) ([+-]\d{4})$/.exec(text.trim())
  if (match === null) return { name: text.trim(), email: '', timestamp: 0, timezone: '+0000' }
  return {
    name: match[1] as string,
    email: match[2] as string,
    timestamp: Number(match[3]),
    timezone: match[4] as string,
  }
}

/** Read and parse one commit. */
export async function readCommit(repository: Repository, oid: string): Promise<CommitInfo> {
  const object = await repository.odb.read(oid)
  if (object.type !== 'commit') throw fatal(`object ${oid} is a ${object.type}, not a commit`)
  return parseCommit(oid, object.data)
}

/** Resolve an abbreviated object id against loose objects and packs. */
export async function expandOid(repository: Repository, prefix: string): Promise<string | undefined> {
  const lower = prefix.toLowerCase()
  if (!/^[0-9a-f]{4,40}$/.test(lower)) return undefined
  if (lower.length === 40) return await repository.odb.has(lower) ? lower : undefined
  const matches = new Set<string>()
  for (const directory of repository.odb.readDirectories) {
    let entries: Awaited<ReturnType<GitFs['readdir']>>
    try {
      entries = await repository.fs.readdir(`${directory}/${lower.slice(0, 2)}`)
    } catch (error) {
      if (!isErrno(error, 'ENOENT', 'ENOTDIR')) throw error
      entries = []
    }
    for (const entry of entries) {
      if (!entry.isFile) continue
      const candidate = `${lower.slice(0, 2)}${entry.name}`
      if (candidate.startsWith(lower) && candidate.length === 40) matches.add(candidate)
    }
  }
  for (const directory of repository.odb.readDirectories) {
    const packDirectory = `${directory}/pack`
    let entries: Awaited<ReturnType<GitFs['readdir']>>
    try {
      entries = await repository.fs.readdir(packDirectory)
    } catch {
      entries = []
    }
    for (const entry of entries) {
      if (!entry.isFile || !entry.name.endsWith('.idx')) continue
      const index = entry.name
      const candidates = await prefixFromPack(repository, `${packDirectory}/${index}`, lower)
      for (const candidate of candidates) matches.add(candidate)
    }
  }
  if (matches.size === 1) return [...matches][0]
  if (matches.size > 1) throw fatal(`short object ID ${prefix} is ambiguous`)
  return undefined
}

async function prefixFromPack(repository: Repository, indexPath: string, prefix: string): Promise<string[]> {
  const index = await readPackIndex(repository.fs, indexPath)
  return index.ids.filter(oid => oid.startsWith(prefix))
}

/**
 * Resolve a revision expression (`HEAD`, `main`, a tag, an abbreviated oid,
 * `HEAD~2`, `HEAD^`, `main^{tree}`, `HEAD:path`) to an object id.
 */
export async function resolveRevision(repository: Repository, expression: string): Promise<string> {
  if (expression === '') throw fatal('empty revision')
  const colon = expression.indexOf(':')
  const revision = colon < 0 ? expression : expression.slice(0, colon)
  const path = colon < 0 ? undefined : expression.slice(colon + 1)
  let oid = await resolveRevisionPart(repository, revision)
  if (path !== undefined) {
    const tree = await peelToTree(repository, oid)
    if (path === '') {
      oid = tree
    } else {
      const entry = (await readTreeRecursive(repository, tree)).get(path)
      if (entry === undefined) throw fatal(`path '${path}' does not exist in '${expression}'`)
      oid = entry.oid
    }
  }
  return oid
}

/** Split `base^{op}` / `base^2` / `base~3` by trying suffixes right to left. */
async function resolveRevisionPart(repository: Repository, spec: string): Promise<string> {
  if (spec === '') throw fatal('empty revision')
  const candidates: number[] = []
  let depth = 0
  for (let index = spec.length - 1; index >= 0; index -= 1) {
    const char = spec[index] as string
    if (char === '}') depth += 1
    else if (char === '{') depth -= 1
    else if (depth === 0 && (char === '^' || char === '~')) candidates.push(index)
  }
  if (candidates.length === 0) return await resolveBaseRevision(repository, spec)
  let lastError: Error | undefined
  for (const index of candidates) {
    const base = spec.slice(0, index)
    if (base === '') continue
    try {
      const oid = await resolveBaseRevision(repository, base)
      return await applyRevisionOperators(repository, oid, spec.slice(index), spec)
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error))
    }
  }
  if (lastError !== undefined) throw fatal(`ambiguous argument '${spec}': ${lastError.message}`)
  return await resolveBaseRevision(repository, spec)
}

async function applyRevisionOperators(repository: Repository, start: string, operators: string, full: string): Promise<string> {
  let oid = start
  let rest = operators
  while (rest !== '') {
    const match = /^(\^\{[^}]*\}|\^\d*|~\d+)/.exec(rest)
    if (match === null) throw fatal(`unsupported revision syntax '${full}'`)
    const operator = match[1] as string
    rest = rest.slice(operator.length)
    if (operator.startsWith('~')) {
      const count = Number(operator.slice(1) === '' ? 1 : operator.slice(1))
      for (let step = 0; step < count; step += 1) oid = await firstParent(repository, oid)
      continue
    }
    const kind = operator.startsWith('^{') ? operator.slice(1) : undefined
    if (kind === '{}' || kind === '^{object}') {
      if (!(await repository.odb.has(oid))) throw fatal(`bad object ${oid}`)
      continue
    }
    if (kind === '{tree}') {
      oid = await peelToTree(repository, oid)
      continue
    }
    if (kind === '{commit}' || kind === '') {
      oid = await peelToCommit(repository, oid)
      continue
    }
    if (kind === '{tag}') {
      if ((await repository.odb.type(oid)) !== 'tag') throw fatal(`object ${oid} is not a tag`)
      continue
    }
    if (kind !== undefined) throw fatal(`unsupported revision operator ${kind} in '${full}'`)
    const count = operator === '^' ? 1 : Number(operator.slice(1))
    if (count === 0) continue
    const commit = await readCommit(repository, await peelToCommit(repository, oid))
    const parent = commit.parents[count - 1]
    if (parent === undefined) throw fatal(`no parent ${count} for ${oid}`)
    oid = parent
  }
  return oid
}

async function resolveBaseRevision(repository: Repository, spec: string): Promise<string> {
  const name = spec === '' ? 'HEAD' : spec
  if (name === '@') return await requireHead(repository)
  const ref = await resolveRef(repository, name)
  if (ref !== undefined) return ref
  for (const candidate of [`refs/${name}`, `refs/tags/${name}`, `refs/heads/${name}`, `refs/remotes/${name}`, `refs/remotes/${name}/HEAD`]) {
    const oid = await resolveRef(repository, candidate)
    if (oid !== undefined) return oid
  }
  const expanded = await expandOid(repository, name)
  if (expanded !== undefined) return expanded
  throw fatal(`ambiguous argument '${spec}': unknown revision or path not in the working tree.`)
}

async function requireHead(repository: Repository): Promise<string> {
  const oid = await headOid(repository)
  if (oid === undefined) throw fatal('HEAD does not point to a commit')
  return oid
}

async function peelToCommit(repository: Repository, oid: string): Promise<string> {
  let current = oid
  for (let depth = 0; depth < 20; depth += 1) {
    const type = await repository.odb.type(current)
    if (type === 'commit') return current
    if (type === 'tag') {
      const object = await repository.odb.read(current)
      const text = decodeText(object.data)
      const match = /^object ([0-9a-f]{40})$/m.exec(text)
      if (match === null) throw fatal(`bad tag object ${current}`)
      current = match[1] as string
      continue
    }
    throw fatal(`object ${current} is a ${type}, not a commit`)
  }
  throw fatal(`tag chain too long at ${oid}`)
}

async function peelToTree(repository: Repository, oid: string): Promise<string> {
  const type = await repository.odb.type(oid)
  if (type === 'tree') return oid
  return (await readCommit(repository, await peelToCommit(repository, oid))).tree
}

async function firstParent(repository: Repository, oid: string): Promise<string> {
  const commit = await readCommit(repository, oid)
  const parent = commit.parents[0]
  if (parent === undefined) throw fatal(`no parent for ${oid}`)
  return parent
}

/** One tree entry. */
export interface TreeEntry {
  readonly mode: string
  readonly name: string
  readonly oid: string
}

/** Parse one tree object. */
export function parseTree(data: Uint8Array): TreeEntry[] {
  const entries: TreeEntry[] = []
  let offset = 0
  while (offset < data.byteLength) {
    const space = data.indexOf(0x20, offset)
    if (space < 0) break
    const nul = data.indexOf(0, space + 1)
    if (nul < 0) break
    const mode = decodeText(data.subarray(offset, space))
    const name = decodeText(data.subarray(space + 1, nul))
    const oid = toHex(data.subarray(nul + 1, nul + 21))
    entries.push({ mode, name, oid })
    offset = nul + 21
  }
  return entries
}

/** Build a tree object from entries already in git's tree order. */
export function buildTree(entries: readonly TreeEntry[]): Uint8Array {
  const chunks: Uint8Array[] = []
  for (const entry of entries) {
    chunks.push(encodeText(`${entry.mode} ${entry.name}\0`))
    chunks.push(Uint8Array.from(entry.oid.match(/.{2}/g)?.map(byte => Number.parseInt(byte, 16)) ?? []))
  }
  let length = 0
  for (const chunk of chunks) length += chunk.byteLength
  const out = new Uint8Array(length)
  let position = 0
  for (const chunk of chunks) {
    out.set(chunk, position)
    position += chunk.byteLength
  }
  return out
}

/** Every blob/tree below a tree, keyed by slash-separated path. */
export async function readTreeRecursive(repository: Repository, treeOid: string): Promise<Map<string, TreeEntry>> {
  const out = new Map<string, TreeEntry>()
  const walk = async (oid: string, prefix: string): Promise<void> => {
    const object = await repository.odb.read(oid)
    if (object.type !== 'tree') throw fatal(`object ${oid} is a ${object.type}, not a tree`)
    for (const entry of parseTree(object.data)) {
      const path = `${prefix}${entry.name}`
      out.set(path, entry)
      if (entry.mode === '40000') await walk(entry.oid, `${path}/`)
    }
  }
  await walk(treeOid, '')
  return out
}

/** A flat snapshot of a tree: target path → mode/type/oid. */
export interface FlatTreeEntry {
  readonly mode: string
  readonly oid: string
}

/** Flatten a tree into path → mode/oid, blobs and gitlinks only. */
export async function flattenTree(repository: Repository, treeOid: string): Promise<Map<string, FlatTreeEntry>> {
  const flat = new Map<string, FlatTreeEntry>()
  const walk = async (oid: string, prefix: string): Promise<void> => {
    const object = await repository.odb.read(oid)
    for (const entry of parseTree(object.data)) {
      if (entry.mode === '40000') {
        await walk(entry.oid, `${prefix}${entry.name}/`)
      } else {
        flat.set(`${prefix}${entry.name}`, { mode: entry.mode, oid: entry.oid })
      }
    }
  }
  await walk(treeOid, '')
  return flat
}

/** Short object id the way git abbreviates it for a small repository. */
export function shortOid(oid: string, length = 7): string {
  return oid.slice(0, length)
}

/** Oid of a `refs/...` name, with the abbreviated forms a user types. */
export async function resolveBranchOrRef(repository: Repository, name: string): Promise<string | undefined> {
  return await resolveRef(repository, name)
    ?? await resolveRef(repository, `refs/heads/${name}`)
    ?? await resolveRef(repository, `refs/tags/${name}`)
    ?? await resolveRef(repository, `refs/remotes/${name}`)
}
