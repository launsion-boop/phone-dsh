// SPDX-License-Identifier: MIT
/**
 * `github` — read and change a GitHub repository without a local clone.
 *
 * Every request is a same-origin `fetch` to the host `POST /v1/http` route,
 * the same egress `curl` and Worker git use. The host allow-list decides
 * whether `api.github.com` may be contacted. This command never accepts, stores
 * or forwards a GitHub token: the loopback `Authorization` header is only the
 * channel bearer, which the gateway strips before it injects the credential
 * stored for `api.github.com` (gateway-security.md §2). An allow-listed host
 * with no stored credential stays anonymous.
 * @module @phone-dsh/dsh-shell-ext/github
 */
import { defineCommand } from 'just-bash/browser'
import type { Command, ExecResult } from 'just-bash/browser'
import { shellFailure } from './contract.ts'
import { resolveHostProxy } from './curl.ts'
import type { CurlOptions } from './curl.ts'

/** Files in one `github commit`. */
export const GITHUB_MAX_FILES = 20
/** Decoded bytes of one committed file. */
export const GITHUB_MAX_FILE_BYTES = 256 * 1024
/** Decoded bytes of one commit, all files together. */
export const GITHUB_MAX_COMMIT_BYTES = 1024 * 1024
/** Tree rows printed before the rest are omitted. */
export const GITHUB_MAX_TREE_ENTRIES = 500
/** Maximum stdout this command may produce; the Worker shell caps at 256 KiB. */
export const GITHUB_MAX_OUTPUT_BYTES = 128 * 1024
/** Directory rows printed before the rest are omitted. */
export const GITHUB_MAX_DIRECTORY_ENTRIES = 500
/** Environment the host sets only when it stores an api.github.com credential. */
export const GITHUB_AUTH_ENV = 'PDSH_GITHUB_AUTH'

const API = 'https://api.github.com'
const USER_AGENT = 'phone-dsh'
const MEDIA = 'application/vnd.github+json'
const API_VERSION = '2022-11-28'

/** What the model reads on the command and in `github --help`. */
export const GITHUB_DESCRIPTION =
  'Read or change a GitHub repo with no local clone (get, tree, search, branch, commit, pr) through the host /v1/http allow-list. '
  + 'Never pass a token: the host credential gateway injects the credential for api.github.com. '
  + 'Public get/tree reads work anonymously; search, branch, commit and pr need a host-stored credential ('
  + GITHUB_AUTH_ENV + '=1) and otherwise fail without sending a request. Keep commits small.'

/** Usage printed by `github` and `github --help`. */
export const GITHUB_USAGE = `usage: github <get|tree|search|branch|commit|pr> <owner>/<repo> [options]

${GITHUB_DESCRIPTION}

  github get <owner>/<repo> <path> [--ref <ref>]
  github tree <owner>/<repo> [--ref <ref>] [--path <prefix>]
  github search <owner>/<repo> <query...>
  github branch <owner>/<repo> <name> --from <ref>
  github commit <owner>/<repo> --branch <name> --message <text> (--file <path> --text <text> | --file <path> --base64 <base64> | --file <path> --delete)...
  github pr <owner>/<repo> --head <branch> --base <branch> --title <text> [--body <text>]

commit may instead read a JSON object from stdin: {"files":[{"path":"a.txt","text":"hi"},{"path":"bin.dat","base64":"AAEC"},{"path":"old.txt","delete":true}]}.
At most ${String(GITHUB_MAX_FILES)} files, ${String(GITHUB_MAX_FILE_BYTES)} bytes each, ${String(GITHUB_MAX_COMMIT_BYTES)} bytes together.
Writes use one GraphQL createCommitOnBranch call. stdout is one JSON object.
`

/** Options shared with the curl shim: loopback route only, never a GitHub token. */
export type GithubOptions = Pick<CurlOptions, 'fetch' | 'origin' | 'token'> & {
  /** True when the host can inject the stored api.github.com credential. */
  readonly authenticated?: boolean | undefined
}

interface Repo {
  readonly owner: string
  readonly name: string
}

interface FileChange {
  readonly path: string
  readonly text?: string
  readonly base64?: string
  readonly delete?: boolean
}

type Request =
  | { readonly kind: 'get'; readonly repo: Repo; readonly path: string; readonly ref?: string }
  | { readonly kind: 'tree'; readonly repo: Repo; readonly ref: string; readonly prefix?: string }
  | { readonly kind: 'search'; readonly repo: Repo; readonly query: string }
  | { readonly kind: 'branch'; readonly repo: Repo; readonly name: string; readonly from: string }
  | { readonly kind: 'commit'; readonly repo: Repo; readonly branch: string; readonly message: string; readonly files: readonly FileChange[] }
  | { readonly kind: 'pr'; readonly repo: Repo; readonly head: string; readonly base: string; readonly title: string; readonly body?: string }

class GithubUsage extends Error {}

interface GithubContext {
  readonly stdin?: string
  readonly signal?: AbortSignal
}

/** One upstream call as the host route will see it. */
interface Upstream {
  readonly method: 'GET' | 'POST'
  readonly url: string
  readonly body?: string
}

interface UpstreamResult {
  readonly status: number
  readonly body: string
}

/** Drop credential-shaped text before it can reach the model. */
export function redactGithubText(text: string, secrets: readonly string[] = []): string {
  let out = text
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/\b(?:ghp_|github_pat_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_]+/g, '[redacted]')
  for (const secret of secrets) {
    if (secret.length >= 8) out = out.split(secret).join('[redacted]')
  }
  return out
}

function authenticated(options: GithubOptions): boolean {
  return options.authenticated ?? process.env[GITHUB_AUTH_ENV] === '1'
}

/** Verbs that need a stored credential; get/tree are anonymous public reads. */
function needsCredential(request: Request): boolean {
  return request.kind === 'search' || request.kind === 'branch' || request.kind === 'commit' || request.kind === 'pr'
}

function fail(message: string, exitCode = 1): ExecResult {
  return shellFailure('github', `github: ${message}`, exitCode === 2 ? 'unsupported-option' : 'command-exited', {
    exitCode,
    hint: 'github talks to api.github.com through the host /v1/http allow-list and never takes a token',
  })
}

function usageResult(message?: string): ExecResult {
  if (message === undefined) return { stdout: GITHUB_USAGE, stderr: '', exitCode: 0 }
  return fail(`${message}\n${GITHUB_USAGE}`, 2)
}

function repoOf(raw: string | undefined): Repo {
  if (raw === undefined || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(raw)) {
    throw new GithubUsage('repository must be owner/repo')
  }
  const [owner, name] = raw.split('/') as [string, string]
  return { owner, name }
}

function safePath(raw: string | undefined): string {
  if (raw === undefined || raw === '' || raw.startsWith('/') || raw.includes('\0') || raw.split('/').some(part => part === '..' || part === '')) {
    throw new GithubUsage('path must be a relative file path with no ".." segment')
  }
  return raw
}

function safeRef(raw: string | undefined, label: string): string {
  if (raw === undefined || raw === '' || raw.startsWith('-') || raw.includes(' ') || raw.includes('..') || /[\0?#]/.test(raw)) {
    throw new GithubUsage(`${label} is missing or not a single ref`)
  }
  return raw
}

function take(args: readonly string[], index: number, flag: string): string {
  const value = args[index]
  if (value === undefined) throw new GithubUsage(`${flag} requires a value`)
  return value
}

/** Parse argv after `github`. Throws {@link GithubUsage} on a bad invocation. */
export function parseGithubArguments(args: readonly string[], stdin = ''): Request | 'help' {
  if (args.length === 0 || args[0] === '--help' || args[0] === '-h' || args[0] === 'help') return 'help'
  const command = args[0]
  const repo = command === 'get' || command === 'tree' || command === 'search' || command === 'branch' || command === 'commit' || command === 'pr'
    ? repoOf(args[1])
    : undefined
  if (repo === undefined) throw new GithubUsage(`unknown command '${command ?? ''}'`)
  const rest = args.slice(2)
  if (command === 'get') {
    const path = safePath(rest[0])
    let ref: string | undefined
    for (let index = 1; index < rest.length; index += 1) {
      const arg = rest[index] as string
      if (arg === '--ref') { ref = safeRef(rest[index + 1], '--ref'); index += 1; continue }
      throw new GithubUsage(`unsupported get option '${arg}'`)
    }
    return { kind: 'get', repo, path, ...ref === undefined ? {} : { ref } }
  }
  if (command === 'tree') {
    let ref = 'HEAD'
    let prefix: string | undefined
    for (let index = 0; index < rest.length; index += 1) {
      const arg = rest[index] as string
      if (arg === '--ref') { ref = safeRef(rest[index + 1], '--ref'); index += 1; continue }
      if (arg === '--path') { prefix = safePath(rest[index + 1]); index += 1; continue }
      throw new GithubUsage(`unsupported tree option '${arg}'`)
    }
    return { kind: 'tree', repo, ref, ...prefix === undefined ? {} : { prefix } }
  }
  if (command === 'search') {
    if (rest.length === 0 || rest.some(arg => arg.startsWith('-'))) throw new GithubUsage('search needs a query and takes no flags')
    return { kind: 'search', repo, query: rest.join(' ') }
  }
  if (command === 'branch') {
    const name = safeRef(rest[0], 'branch name')
    let from: string | undefined
    for (let index = 1; index < rest.length; index += 1) {
      const arg = rest[index] as string
      if (arg === '--from') { from = safeRef(rest[index + 1], '--from'); index += 1; continue }
      throw new GithubUsage(`unsupported branch option '${arg}'`)
    }
    if (from === undefined) throw new GithubUsage('branch needs --from <ref>')
    return { kind: 'branch', repo, name, from }
  }
  if (command === 'commit') return parseCommit(repo, rest, stdin)
  return parsePull(repo, rest)
}

function parseCommit(repo: Repo, args: readonly string[], stdin: string): Request {
  let branch: string | undefined
  let message: string | undefined
  const files: FileChange[] = []
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '--branch') { branch = safeRef(args[index + 1], '--branch'); index += 1; continue }
    if (arg === '--message') { message = take(args, index + 1, '--message'); index += 1; continue }
    if (arg === '--file') {
      const path = safePath(args[index + 1])
      const mode = args[index + 2]
      if (mode === '--delete') {
        files.push({ path, delete: true })
        index += 2
        continue
      }
      if (mode === '--text') {
        files.push({ path, text: take(args, index + 3, '--text') })
        index += 3
        continue
      }
      if (mode === '--base64') {
        files.push({ path, base64: take(args, index + 3, '--base64') })
        index += 3
        continue
      }
      throw new GithubUsage('--file needs --text <text>, --base64 <base64> or --delete')
    }
    throw new GithubUsage(`unsupported commit option '${arg}'`)
  }
  if (branch === undefined || message === undefined || message === '') throw new GithubUsage('commit needs --branch and --message')
  const fromArgs = files.length > 0
  const trimmed = stdin.trim()
  if (fromArgs && trimmed !== '') throw new GithubUsage('commit takes --file or stdin JSON, not both')
  const resolved = fromArgs ? files : parseStdinFiles(trimmed)
  checkFiles(resolved)
  return { kind: 'commit', repo, branch, message, files: resolved }
}

function parseStdinFiles(stdin: string): FileChange[] {
  if (stdin === '') throw new GithubUsage('commit needs --file or a JSON files array on stdin')
  let parsed: unknown
  try {
    parsed = JSON.parse(stdin)
  } catch {
    throw new GithubUsage('commit stdin is not a JSON object')
  }
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray((parsed as { files?: unknown }).files)) {
    throw new GithubUsage('commit stdin must be {"files":[...]}')
  }
  return (parsed as { files: unknown[] }).files.map(entry => {
    if (entry === null || typeof entry !== 'object') throw new GithubUsage('each file entry must be an object')
    const row = entry as { path?: unknown; text?: unknown; base64?: unknown; delete?: unknown }
    const path = safePath(typeof row.path === 'string' ? row.path : undefined)
    if (row.delete === true) return { path, delete: true }
    const hasText = typeof row.text === 'string'
    const hasBase64 = typeof row.base64 === 'string'
    if (hasText && hasBase64) throw new GithubUsage(`file ${path} needs text or base64, not both`)
    if (hasBase64) return { path, base64: row.base64 as string }
    if (!hasText) throw new GithubUsage(`file ${path} needs text, base64 or delete:true`)
    return { path, text: row.text as string }
  })
}

/** Decode a commit file to bytes; base64 is validated here, never at send time. */
function fileBytes(file: FileChange): Uint8Array {
  if (file.base64 === undefined) {
    return new Uint8Array(Buffer.from(file.text ?? '', 'utf8'))
  }
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(file.base64) || file.base64.length % 4 !== 0) {
    throw new GithubUsage(`${file.path} has invalid base64`)
  }
  return new Uint8Array(Buffer.from(file.base64, 'base64'))
}

function checkFiles(files: readonly FileChange[]): void {
  if (files.length === 0) throw new GithubUsage('commit needs at least one file')
  if (files.length > GITHUB_MAX_FILES) throw new GithubUsage(`commit is limited to ${String(GITHUB_MAX_FILES)} files`)
  const seen = new Set<string>()
  let total = 0
  for (const file of files) {
    if (seen.has(file.path)) throw new GithubUsage(`duplicate path ${file.path}`)
    seen.add(file.path)
    if (file.delete === true) continue
    if (file.text !== undefined && file.base64 !== undefined) {
      throw new GithubUsage(`${file.path} needs text or base64, not both`)
    }
    const bytes = fileBytes(file).byteLength
    if (bytes > GITHUB_MAX_FILE_BYTES) throw new GithubUsage(`${file.path} is ${String(bytes)} bytes; the limit is ${String(GITHUB_MAX_FILE_BYTES)}`)
    total += bytes
  }
  if (total > GITHUB_MAX_COMMIT_BYTES) throw new GithubUsage(`commit is ${String(total)} bytes; the limit is ${String(GITHUB_MAX_COMMIT_BYTES)}`)
}

function parsePull(repo: Repo, args: readonly string[]): Request {
  let head: string | undefined
  let base: string | undefined
  let title: string | undefined
  let body: string | undefined
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '--head') { head = safeRef(args[index + 1], '--head'); index += 1; continue }
    if (arg === '--base') { base = safeRef(args[index + 1], '--base'); index += 1; continue }
    if (arg === '--title') { title = take(args, index + 1, '--title'); index += 1; continue }
    if (arg === '--body') { body = take(args, index + 1, '--body'); index += 1; continue }
    throw new GithubUsage(`unsupported pr option '${arg}'`)
  }
  if (head === undefined || base === undefined || title === undefined || title === '') {
    throw new GithubUsage('pr needs --head, --base and --title')
  }
  return { kind: 'pr', repo, head, base, title, ...body === undefined ? {} : { body } }
}

function encodeRef(ref: string): string {
  return ref.split('/').map(part => encodeURIComponent(part)).join('/')
}

function repoPath(repo: Repo, suffix: string): string {
  return `${API}/repos/${encodeURIComponent(repo.owner)}/${encodeURIComponent(repo.name)}${suffix}`
}

/** The upstream calls one invocation makes, with no credential of its own. */
export function githubRequests(request: Request): Upstream[] {
  if (request.kind === 'get') {
    const query = request.ref === undefined ? '' : `?ref=${encodeURIComponent(request.ref)}`
    return [{ method: 'GET', url: `${repoPath(request.repo, `/contents/${request.path.split('/').map(part => encodeURIComponent(part)).join('/')}`)}${query}` }]
  }
  if (request.kind === 'tree') {
    return [{ method: 'GET', url: `${repoPath(request.repo, `/git/trees/${encodeRef(request.ref)}`)}?recursive=1` }]
  }
  if (request.kind === 'search') {
    const q = /\brepo:[^\s]+/.test(request.query) ? request.query : `${request.query} repo:${request.repo.owner}/${request.repo.name}`
    return [{ method: 'GET', url: `${API}/search/code?q=${encodeURIComponent(q)}&per_page=10` }]
  }
  if (request.kind === 'branch') {
    const fromIsOid = /^[0-9a-f]{40}$/i.test(request.from)
    const lookup: Upstream[] = fromIsOid ? [] : [{
      method: 'GET',
      url: repoPath(request.repo, `/git/ref/heads/${encodeRef(request.from)}`),
    }]
    return lookup
  }
  if (request.kind === 'commit') {
    return [{ method: 'GET', url: repoPath(request.repo, `/git/ref/heads/${encodeRef(request.branch)}`) }]
  }
  return [{
    method: 'POST',
    url: repoPath(request.repo, '/pulls'),
    body: JSON.stringify({
      title: request.title,
      head: request.head,
      base: request.base,
      ...request.body === undefined ? {} : { body: request.body },
    }),
  }]
}

async function callUpstream(
  upstream: Upstream,
  options: GithubOptions,
  context: GithubContext,
  channelToken: string,
): Promise<UpstreamResult> {
  const route = resolveHostProxy(options)
  if (route === undefined) {
    throw new Error('no host /v1/http route (set PDSH_CHANNEL_ORIGIN and PDSH_CHANNEL_TOKEN)')
  }
  const headers: Record<string, string> = {
    Authorization: `Bearer ${route.token}`,
    'X-PDSH-Target-URL': upstream.url,
    'X-PDSH-Target-Method': upstream.method,
    Accept: MEDIA,
    'User-Agent': USER_AGENT,
    'X-GitHub-Api-Version': API_VERSION,
    ...upstream.body === undefined ? {} : { 'Content-Type': 'application/json' },
  }
  const fetchImpl = options.fetch ?? globalThis.fetch
  if (typeof fetchImpl !== 'function') throw new Error('this runtime has no fetch for the host /v1/http route')
  const response = await fetchImpl(new URL('/v1/http', route.origin), {
    method: 'POST',
    headers,
    ...upstream.body === undefined ? {} : { body: upstream.body },
    signal: context.signal,
  })
  const body = await response.text()
  // A gateway refusal carries X-PDSH-Proxy-Error. An upstream 401/403 from
  // GitHub itself does not, and must stay GitHub's message.
  const proxyError = response.headers.get('x-pdsh-proxy-error')
  if (proxyError !== null && proxyError !== '') {
    throw new Error(
      `the host /v1/http route refused api.github.com (${redactGithubText(proxyError, [route.token, channelToken])}). `
      + 'The Worker sent no GitHub token; the host credential gateway injects one only when it is stored for that host. '
      + redactGithubText(body.slice(0, 300), [route.token, channelToken]),
    )
  }
  return { status: response.status, body }
}

function asObject(result: UpstreamResult): Record<string, unknown> {
  let parsed: unknown
  try {
    parsed = JSON.parse(result.body)
  } catch {
    throw new Error(`api.github.com returned HTTP ${String(result.status)} that is not JSON`)
  }
  if (parsed === null || typeof parsed !== 'object') throw new Error('api.github.com returned a non-object')
  return parsed as Record<string, unknown>
}

function githubMessage(payload: Record<string, unknown>, status: number): string {
  const message = typeof payload.message === 'string' ? payload.message : `HTTP ${String(status)}`
  return redactGithubText(message)
}

function requireOk(result: UpstreamResult): Record<string, unknown> {
  const payload = asObject(result)
  if (result.status < 200 || result.status >= 300) {
    throw new Error(`api.github.com HTTP ${String(result.status)}: ${githubMessage(payload, result.status)}`)
  }
  return payload
}

function shaOfRef(payload: Record<string, unknown>): string {
  const object = payload.object
  if (object === null || typeof object !== 'object' || typeof (object as { sha?: unknown }).sha !== 'string') {
    throw new Error('the ref response had no object.sha')
  }
  return (object as { sha: string }).sha
}

function jsonOut(value: unknown): ExecResult {
  const stdout = `${JSON.stringify(value, null, 2)}\n`
  if (Buffer.byteLength(stdout) > GITHUB_MAX_OUTPUT_BYTES) {
    throw new Error(`github output would be larger than ${String(GITHUB_MAX_OUTPUT_BYTES)} bytes; narrow the request`)
  }
  return { stdout, stderr: '', exitCode: 0 }
}

/** Keep rows until either the row limit or the output budget is reached. */
function limitRows<T>(rows: readonly T[], limit: number): { rows: T[]; truncated: boolean } {
  const shown: T[] = []
  let bytes = 2
  for (const row of rows) {
    if (shown.length >= limit) break
    const size = Buffer.byteLength(JSON.stringify(row)) + 1
    if (bytes + size > GITHUB_MAX_OUTPUT_BYTES - 512) break
    shown.push(row)
    bytes += size
  }
  return { rows: shown, truncated: shown.length < rows.length }
}

async function runGet(result: UpstreamResult): Promise<ExecResult> {
  const payload = requireOk(result)
  if (Array.isArray(payload)) {
    const rows = payload.map(entry => {
      const row = entry as { path?: unknown; type?: unknown; sha?: unknown }
      return { path: row.path, type: row.type, sha: row.sha }
    })
    const limited = limitRows(rows, GITHUB_MAX_DIRECTORY_ENTRIES)
    return jsonOut({
      type: 'dir',
      count: rows.length,
      ...limited.truncated ? { truncated: true } : {},
      entries: limited.rows,
    })
  }
  if (payload.type !== 'file') return jsonOut({ type: payload.type, path: payload.path, sha: payload.sha })
  if (typeof payload.content !== 'string' || payload.encoding !== 'base64') {
    return jsonOut({
      type: 'file',
      path: payload.path,
      sha: payload.sha,
      size: payload.size,
      note: 'GitHub did not return inline content (the file may be too large for the contents API)',
    })
  }
  const decoded = Buffer.from(payload.content.replace(/\n/g, ''), 'base64')
  const value = decoded.includes(0)
    ? { type: 'file', path: payload.path, sha: payload.sha, encoding: 'base64', content: payload.content.replace(/\n/g, '') }
    : { type: 'file', path: payload.path, sha: payload.sha, encoding: 'utf-8', content: decoded.toString('utf8') }
  if (Buffer.byteLength(JSON.stringify(value, null, 2)) + 1 > GITHUB_MAX_OUTPUT_BYTES) {
    return jsonOut({
      type: 'file',
      path: payload.path,
      sha: payload.sha,
      size: payload.size ?? decoded.byteLength,
      truncated: true,
      note: `the file is ${String(payload.size ?? decoded.byteLength)} bytes; github get returns at most ${String(GITHUB_MAX_OUTPUT_BYTES)} bytes of JSON`,
    })
  }
  return jsonOut(value)
}

async function runTree(request: Extract<Request, { kind: 'tree' }>, result: UpstreamResult): Promise<ExecResult> {
  const payload = requireOk(result)
  const tree = Array.isArray(payload.tree) ? payload.tree : []
  const prefix = request.prefix
  const matched = tree.filter(entry => {
    const path = (entry as { path?: unknown }).path
    if (typeof path !== 'string') return false
    if (prefix === undefined) return true
    return path === prefix || path.startsWith(`${prefix}/`)
  })
  const rows = matched.map(entry => {
    const row = entry as { path?: unknown; type?: unknown; sha?: unknown; size?: unknown }
    return { path: row.path, type: row.type, sha: row.sha, ...typeof row.size === 'number' ? { size: row.size } : {} }
  })
  const limited = limitRows(rows, GITHUB_MAX_TREE_ENTRIES)
  return jsonOut({
    sha: payload.sha,
    truncated: payload.truncated === true || limited.truncated,
    count: matched.length,
    entries: limited.rows,
  })
}

async function runSearch(result: UpstreamResult): Promise<ExecResult> {
  const payload = requireOk(result)
  const items = Array.isArray(payload.items) ? payload.items : []
  const rows = items.map(item => {
    const row = item as { path?: unknown; html_url?: unknown; sha?: unknown }
    return { path: row.path, url: row.html_url, sha: row.sha }
  })
  const limited = limitRows(rows, 10)
  return jsonOut({ total: payload.total_count, ...limited.truncated ? { truncated: true } : {}, items: limited.rows })
}

function commitBody(request: Extract<Request, { kind: 'commit' }>, oid: string): string {
  const newline = request.message.indexOf('\n')
  const headline = newline < 0 ? request.message : request.message.slice(0, newline)
  const body = newline < 0 ? undefined : request.message.slice(newline + 1).replace(/^\n/, '')
  const additions = request.files.filter(file => file.delete !== true).map(file => ({
    path: file.path,
    contents: file.base64 ?? Buffer.from(file.text ?? '', 'utf8').toString('base64'),
  }))
  const deletions = request.files.filter(file => file.delete === true).map(file => ({ path: file.path }))
  return JSON.stringify({
    query: 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }',
    variables: {
      input: {
        branch: { repositoryNameWithOwner: `${request.repo.owner}/${request.repo.name}`, branchName: request.branch },
        message: { headline, ...body === undefined || body === '' ? {} : { body } },
        fileChanges: {
          ...additions.length === 0 ? {} : { additions },
          ...deletions.length === 0 ? {} : { deletions },
        },
        expectedHeadOid: oid,
      },
    },
  })
}

/**
 * Run one `github` invocation.
 * @param args - arguments after the program name.
 * @param context - stdin and cancellation. No filesystem writes.
 * @param options - loopback route. There is no field for a GitHub token.
 */
export async function runGithub(
  args: readonly string[],
  context: GithubContext = {},
  options: GithubOptions = {},
): Promise<ExecResult> {
  let request: Request | 'help'
  try {
    request = parseGithubArguments(args, context.stdin ?? '')
  } catch (error) {
    return usageResult(error instanceof Error ? error.message : String(error))
  }
  if (request === 'help') return usageResult()
  if (!authenticated(options) && needsCredential(request)) {
    return fail(
      'this build has no GitHub credential for api.github.com: only `get` and `tree` work anonymously. '
      + `Writes and code search need the host to store a credential and set ${GITHUB_AUTH_ENV}=1. Nothing was sent.`,
    )
  }
  const route = resolveHostProxy(options)
  const channelToken = route?.token ?? ''
  try {
    if (request.kind === 'branch') {
      const fromIsOid = /^[0-9a-f]{40}$/i.test(request.from)
      let sha = fromIsOid ? request.from : ''
      if (!fromIsOid) {
        const looked = await callUpstream(githubRequests(request)[0] as Upstream, options, context, channelToken)
        sha = shaOfRef(requireOk(looked))
      }
      const created = await callUpstream({
        method: 'POST',
        url: repoPath(request.repo, '/git/refs'),
        body: JSON.stringify({ ref: `refs/heads/${request.name}`, sha }),
      }, options, context, channelToken)
      const payload = requireOk(created)
      return jsonOut({ ref: payload.ref, sha })
    }
    if (request.kind === 'commit') {
      const head = await callUpstream(githubRequests(request)[0] as Upstream, options, context, channelToken)
      const oid = shaOfRef(requireOk(head))
      const committed = await callUpstream({
        method: 'POST',
        url: `${API}/graphql`,
        body: commitBody(request, oid),
      }, options, context, channelToken)
      const payload = requireOk(committed)
      const errors = payload.errors
      if (Array.isArray(errors) && errors.length > 0) {
        const message = errors.map(error => typeof (error as { message?: unknown }).message === 'string'
          ? (error as { message: string }).message
          : 'GraphQL error').join('; ')
        throw new Error(redactGithubText(message, [channelToken]))
      }
      const data = payload.data as { createCommitOnBranch?: { commit?: { oid?: string; url?: string } } } | undefined
      const commit = data?.createCommitOnBranch?.commit
      if (commit?.oid === undefined) throw new Error('createCommitOnBranch returned no commit')
      return jsonOut({ oid: commit.oid, url: commit.url, expectedHeadOid: oid })
    }
    const upstream = githubRequests(request)[0] as Upstream
    const result = await callUpstream(upstream, options, context, channelToken)
    if (request.kind === 'get') return await runGet(result)
    if (request.kind === 'tree') return await runTree(request, result)
    if (request.kind === 'search') return await runSearch(result)
    const payload = requireOk(result)
    return jsonOut({
      number: payload.number,
      url: payload.html_url,
      state: payload.state,
      head: request.head,
      base: request.base,
    })
  } catch (error) {
    const message = redactGithubText(error instanceof Error ? error.message : String(error), [channelToken])
    return fail(message)
  }
}

/** Build the just-bash `github` command. */
export function createGithubCommand(options: GithubOptions = {}): Command {
  return defineCommand('github', async (args, ctx) => {
    return await runGithub(args, {
      stdin: ctx.stdin as unknown as string,
      signal: ctx.signal,
    }, options)
  })
}
