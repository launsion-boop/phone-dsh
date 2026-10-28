// SPDX-License-Identifier: MIT
/**
 * `curl` shim on the host `/v1/http` egress of phone-dsh-v1.
 *
 * The Worker cannot open sockets, so every request is carried by the page's
 * same-origin `fetch` to the loopback `POST /v1/http` route: the upstream URL
 * and method travel in `X-PDSH-Target-URL` / `X-PDSH-Target-Method`, the bearer is
 * the channel token, and the host decides which origins are allowed (a rejected
 * origin is a `403 forbidden` and is surfaced as a curl failure — the shim has
 * no bypass).
 *
 * Scope is deliberately the common read/write verbs and flags (GET, HEAD, POST,
 * `-H`, `-d`, `-o`, `-s`, `-S`, `-L`, `-f`, `-w`, `--max-time`, `--retry`).
 * Any other method or flag fails with a clear message instead of being
 * silently ignored.
 * @module @phone-dsh/dsh-shell-ext/curl
 */

import { defineCommand } from 'just-bash/browser'
import type { Command, IFileSystem } from 'just-bash/browser'
import { shellFailure } from './contract.ts'

/** Maximum redirects followed by `-L`. */
export const MAX_REDIRECTS = 5

/** Resolved loopback `/v1/http` coordinates. */
export interface HostProxy {
  readonly origin: string
  readonly token: string
}

/** Injection points and limits for the shim. */
export interface CurlOptions {
  /** `fetch` used for the loopback hop; defaults to `globalThis.fetch`. */
  readonly fetch?: typeof fetch | undefined
  /** Loopback origin; defaults to `PDSH_CHANNEL_ORIGIN` / `PDSH_EXEC_BRIDGE_URL` / page origin. */
  readonly origin?: string | undefined
  /** Bearer token; defaults to `PDSH_CHANNEL_TOKEN` / `PDSH_EXEC_BRIDGE_TOKEN`. */
  readonly token?: string | undefined
  /** Extra Worker-side origin allow-list (host still enforces its own). */
  readonly allowHosts?: readonly string[] | undefined
  /** Maximum redirects; defaults to {@link MAX_REDIRECTS}. */
  readonly maxRedirects?: number | undefined
  /** Default request timeout in milliseconds. */
  readonly timeoutMs?: number | undefined
}

/** One curl failure with its exit status. */
class CurlError extends Error {
  readonly exitCode: number

  constructor(exitCode: number, message: string) {
    super(message)
    this.name = 'CurlError'
    this.exitCode = exitCode
  }
}

/** Parsed `curl` invocation. */
interface CurlInvocation {
  url?: string
  method?: string
  head: boolean
  headers: Record<string, string>
  data?: string
  output?: string
  silent: boolean
  showError: boolean
  fail: boolean
  location: boolean
  includeHeaders: boolean
  writeOut?: string
  maxTimeMs?: number
  retries: number
  retryDelayMs: number
}

/** Everything one `curl` call needs from its shell context. */
interface CurlContext {
  readonly cwd: string
  readonly fs: IFileSystem
  readonly signal?: AbortSignal | undefined
}

/**
 * Collect the loopback host route from options and the Worker environment.
 * @param options - shim options.
 * @returns the route, or undefined when this process has no `/v1/http` origin/token.
 */
export function resolveHostProxy(options: CurlOptions = {}): HostProxy | undefined {
  const env = process.env
  const origin = options.origin
    ?? env.PDSH_CHANNEL_ORIGIN
    ?? env.PDSH_EXEC_BRIDGE_URL
    ?? globalThis.location?.origin
  const token = options.token
    ?? env.PDSH_CHANNEL_TOKEN
    ?? env.PDSH_EXEC_BRIDGE_TOKEN
  if (origin === undefined || origin === '' || token === undefined || token === '') return undefined
  return { origin, token }
}

/**
 * True when `host` matches an exact entry, a `.suffix`/`*.suffix` entry, or
 * the `*` wildcard (the same grammar the host gateway accepts).
 */
export function hostAllowed(host: string, allowHosts: readonly string[]): boolean {
  const candidate = host.toLowerCase()
  return allowHosts.some((entry) => {
    const trimmed = entry.trim().toLowerCase()
    if (trimmed === '*') return true
    const allowed = trimmed.replace(/^\*?\./u, '')
    if (allowed === '') return false
    return candidate === allowed || candidate.endsWith(`.${allowed}`)
  })
}

/** One response after redirect handling. */
interface CurlResponse {
  readonly url: string
  readonly status: number
  readonly headers: Headers
  readonly body: Uint8Array
}

/** Split `-abc` into its single-letter flags. */
function shortFlags(argument: string): string[] {
  return [...argument.slice(1)]
}

/** Parse a `-w` / `--write-out` template. */
function renderWriteOut(template: string, response: CurlResponse): string {
  return template
    .replace(/%\{([a-z_]+)\}/gi, (_match, name: string) => {
      switch (name.toLowerCase()) {
        case 'http_code': return String(response.status)
        case 'size_download': return String(response.body.byteLength)
        case 'url_effective': return response.url
        case 'content_type': return response.headers.get('content-type') ?? ''
        default: return ''
      }
    })
    // curl interprets C-style escapes in the -w template.
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\\\\/g, '\\')
}

/** Render response headers the way `curl -I` does. */
function renderHeaders(response: CurlResponse): string {
  const lines = [`HTTP/1.1 ${String(response.status)} ${statusText(response.status)}`]
  response.headers.forEach((value, name) => { lines.push(`${name}: ${value}`) })
  return `${lines.join('\r\n')}\r\n\r\n`
}

/** A minimal reason phrase for the status line. */
function statusText(status: number): string {
  if (status === 200) return 'OK'
  if (status === 201) return 'Created'
  if (status === 204) return 'No Content'
  if (status === 301) return 'Moved Permanently'
  if (status === 302) return 'Found'
  if (status === 303) return 'See Other'
  if (status === 304) return 'Not Modified'
  if (status === 307) return 'Temporary Redirect'
  if (status === 308) return 'Permanent Redirect'
  if (status === 403) return 'Forbidden'
  if (status === 404) return 'Not Found'
  return ''
}

/**
 * Parse one curl argument vector.
 * @param args - arguments after `curl`.
 * @returns the invocation.
 * @throws {CurlError} on an unsupported flag or a missing value.
 */
export function parseCurlArguments(args: readonly string[]): CurlInvocation {
  const invocation: CurlInvocation = {
    head: false,
    headers: {},
    silent: false,
    showError: false,
    fail: false,
    location: false,
    includeHeaders: false,
    retries: 0,
    retryDelayMs: 100,
  }
  const valueOf = (index: number, flag: string): string => {
    const value = args[index + 1]
    if (value === undefined) throw new CurlError(2, `option ${flag} needs a value`)
    return value
  }
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index] as string
    if (argument === '--') {
      const rest = args.slice(index + 1)
      if (rest.length > 0) invocation.url = rest[0]
      break
    }
    if (argument.startsWith('-') && argument.length > 1 && argument !== '-') {
      if (argument.startsWith('--')) {
        switch (argument) {
          case '--silent': invocation.silent = true; break
          case '--show-error': invocation.showError = true; break
          case '--fail': invocation.fail = true; break
          case '--location': invocation.location = true; break
          case '--include': invocation.includeHeaders = true; break
          case '--head': invocation.head = true; break
          case '--data':
          case '--data-raw':
          case '--data-binary': invocation.data = valueOf(index, argument); index += 1; break
          case '--header': {
            const header = valueOf(index, argument)
            index += 1
            const separator = header.indexOf(':')
            if (separator <= 0) throw new CurlError(2, `invalid header ${JSON.stringify(header)}`)
            invocation.headers[header.slice(0, separator).trim()] = header.slice(separator + 1).trim()
            break
          }
          case '--output': invocation.output = valueOf(index, argument); index += 1; break
          case '--request': invocation.method = valueOf(index, argument).toUpperCase(); index += 1; break
          case '--url': invocation.url = valueOf(index, argument); index += 1; break
          case '--write-out': invocation.writeOut = valueOf(index, argument); index += 1; break
          case '--max-time': invocation.maxTimeMs = Math.max(1, Number(valueOf(index, argument)) * 1000); index += 1; break
          case '--retry': invocation.retries = Math.max(0, Math.floor(Number(valueOf(index, argument)))); index += 1; break
          case '--retry-delay': invocation.retryDelayMs = Math.max(0, Number(valueOf(index, argument)) * 1000); index += 1; break
          case '--compressed':
          case '--insecure':
            break
          default:
            throw new CurlError(2, `unsupported option ${argument}`)
        }
        continue
      }
      for (const flag of shortFlags(argument)) {
        switch (flag) {
          case 's': invocation.silent = true; break
          case 'S': invocation.showError = true; break
          case 'f': invocation.fail = true; break
          case 'L': invocation.location = true; break
          case 'i': invocation.includeHeaders = true; break
          case 'I': invocation.head = true; break
          case 'k': break
          case 'H': {
            const header = valueOf(index, '-H')
            index += 1
            const separator = header.indexOf(':')
            if (separator <= 0) throw new CurlError(2, `invalid header ${JSON.stringify(header)}`)
            invocation.headers[header.slice(0, separator).trim()] = header.slice(separator + 1).trim()
            break
          }
          case 'd': invocation.data = valueOf(index, '-d'); index += 1; break
          case 'o': invocation.output = valueOf(index, '-o'); index += 1; break
          case 'X': invocation.method = valueOf(index, '-X').toUpperCase(); index += 1; break
          case 'w': invocation.writeOut = valueOf(index, '-w'); index += 1; break
          case 'm': invocation.maxTimeMs = Math.max(1, Number(valueOf(index, '-m')) * 1000); index += 1; break
          default:
            throw new CurlError(2, `unsupported option -${flag}`)
        }
      }
      continue
    }
    if (invocation.url !== undefined) throw new CurlError(2, 'exactly one URL per invocation is supported')
    invocation.url = argument
  }
  return invocation
}

/**
 * Perform one `/v1/http` request, following redirects when asked.
 * @param target - absolute upstream URL.
 * @param invocation - parsed flags.
 * @param options - shim options.
 * @param context - shell context.
 * @returns the final response.
 */
async function performRequest(
  target: string,
  invocation: CurlInvocation,
  options: CurlOptions,
  context: CurlContext,
): Promise<CurlResponse> {
  const proxy = resolveHostProxy(options)
  if (proxy === undefined) {
    throw new CurlError(2, 'no host /v1/http route (set PDSH_CHANNEL_ORIGIN and PDSH_CHANNEL_TOKEN)')
  }
  const fetchImpl = options.fetch ?? globalThis.fetch
  if (typeof fetchImpl !== 'function') throw new CurlError(2, 'this runtime has no fetch for the /v1/http route')
  const proxyUrl = new URL('/v1/http', proxy.origin)
  const method = (invocation.head ? 'HEAD' : invocation.method ?? (invocation.data === undefined ? 'GET' : 'POST')).toUpperCase()
  if (method !== 'GET' && method !== 'POST' && method !== 'HEAD') {
    throw new CurlError(2, `method ${method} is not allowed by /v1/http (GET, HEAD, POST only)`)
  }
  let url = target
  let currentMethod = method
  let data = invocation.data
  let redirects = 0
  for (;;) {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new CurlError(3, `unsupported URL protocol ${parsed.protocol}`)
    }
    if (options.allowHosts !== undefined && !hostAllowed(parsed.hostname, options.allowHosts)) {
      throw new CurlError(6, `host ${parsed.hostname} is not in the Worker allow-list`)
    }
    const headers = new Headers()
    for (const [name, value] of Object.entries(invocation.headers)) headers.set(name, value)
    if (data !== undefined && !headers.has('content-type')) headers.set('content-type', 'application/x-www-form-urlencoded')
    // The bearer on the loopback hop is the channel token; a caller-supplied
    // upstream Authorization travels in the header the host route expects.
    const upstreamAuthorization = headers.get('authorization')
    if (upstreamAuthorization !== null) {
      headers.delete('authorization')
      headers.set('X-PDSH-Upstream-Authorization', upstreamAuthorization)
    }
    headers.set('X-PDSH-Target-URL', url)
    headers.set('X-PDSH-Target-Method', currentMethod)
    headers.set('Authorization', `Bearer ${proxy.token}`)
    // Combine the shell's cancel signal with --max-time without relying on
    // `AbortSignal.any`/`AbortSignal.timeout` being present in WebKit.
    const controller = new AbortController()
    const onExternalAbort = (): void => { controller.abort(context.signal?.reason) }
    if (context.signal !== undefined) {
      if (context.signal.aborted) controller.abort(context.signal.reason)
      else context.signal.addEventListener('abort', onExternalAbort, { once: true })
    }
    const timer = invocation.maxTimeMs === undefined
      ? undefined
      : setTimeout(() => { controller.abort(new Error('--max-time exceeded')) }, invocation.maxTimeMs)
    timer?.unref?.()
    let response: Response
    try {
      response = await fetchImpl(proxyUrl, {
        method: 'POST',
        headers,
        body: currentMethod === 'GET' || currentMethod === 'HEAD' ? undefined : data,
        redirect: 'manual',
        signal: controller.signal,
      })
    } catch (error) {
      throw new CurlError(7, `failed to connect to ${parsed.host}: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      if (timer !== undefined) clearTimeout(timer)
      context.signal?.removeEventListener('abort', onExternalAbort)
    }
    const body = new Uint8Array(await response.arrayBuffer())
    if (response.status === 403) {
      throw new CurlError(22, `the host allow-list rejected ${url}`)
    }
    const location = response.headers.get('location')
    if (invocation.location && location !== null && response.status >= 300 && response.status < 400) {
      if (redirects >= (options.maxRedirects ?? MAX_REDIRECTS)) throw new CurlError(47, 'too many redirects')
      redirects += 1
      url = new URL(location, url).href
      if (response.status === 303 || ((response.status === 301 || response.status === 302) && currentMethod === 'POST')) {
        currentMethod = 'GET'
        data = undefined
      }
      continue
    }
    return { url, status: response.status, headers: response.headers, body }
  }
}

/** Sleep between retries. */
async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, ms)
    signal?.addEventListener('abort', () => { clearTimeout(timer); reject(signal.reason) }, { once: true })
  })
}

/**
 * Execute one curl invocation against the host route.
 * @param args - arguments after `curl`.
 * @param context - shell cwd, filesystem and cancellation.
 * @param options - shim options.
 * @returns stdout, stderr and exit status.
 */
export async function runCurl(
  args: readonly string[],
  context: CurlContext,
  options: CurlOptions = {},
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  let invocation: CurlInvocation
  try {
    invocation = parseCurlArguments(args)
  } catch (error) {
    const exitCode = error instanceof CurlError ? error.exitCode : 2
    // The option surface is a usage boundary: never silently ignore a flag.
    return shellFailure('curl', `curl: ${error instanceof Error ? error.message : String(error)}`, 'unsupported-option', {
      exitCode,
    })
  }
  if (invocation.url === undefined || invocation.url === '') {
    return shellFailure('curl', 'curl: no URL specified', 'unsupported-option')
  }
  let response: CurlResponse
  try {
    response = await performRequest(invocation.url, invocation, options, context)
    for (let attempt = 0; attempt < invocation.retries && response.status >= 500; attempt += 1) {
      await sleep(invocation.retryDelayMs, context.signal)
      response = await performRequest(invocation.url, invocation, options, context)
    }
  } catch (error) {
    const exitCode = error instanceof CurlError ? error.exitCode : 7
    return shellFailure(
      'curl',
      `curl: (${String(exitCode)}) ${error instanceof Error ? error.message : String(error)}`,
      'network-denied',
      { exitCode, hint: 'the Worker has no sockets; the host /v1/http allow-list is the only egress' },
    )
  }
  const stdoutParts: string[] = []
  if (invocation.includeHeaders || invocation.head) stdoutParts.push(renderHeaders(response))
  if (invocation.fail && response.status >= 400) {
    return shellFailure(
      'curl',
      `curl: (22) The requested URL returned error: ${String(response.status)}`,
      'network-denied',
      { exitCode: 22, stdout: stdoutParts.join('') },
    )
  }
  if (invocation.output !== undefined && invocation.output !== '') {
    const path = context.fs.resolvePath(context.cwd, invocation.output)
    try {
      await context.fs.writeFile(path, response.body)
    } catch (error) {
      return shellFailure(
        'curl',
        `curl: failed to write ${invocation.output}: ${error instanceof Error ? error.message : String(error)}`,
        'command-exited',
        { exitCode: 23, stdout: stdoutParts.join('') },
      )
    }
  } else if (!invocation.head) {
    stdoutParts.push(Buffer.from(response.body).toString('utf8'))
  }
  if (invocation.writeOut !== undefined) stdoutParts.push(renderWriteOut(invocation.writeOut, response))
  return { stdout: stdoutParts.join(''), stderr: '', exitCode: 0 }
}

/**
 * Build the just-bash `curl` command.
 * @param options - host route and limits.
 * @returns the command definition.
 */
export function createCurlCommand(options: CurlOptions = {}): Command {
  return defineCommand('curl', async (args, ctx) => {
    const result = await runCurl(args, { cwd: ctx.cwd, fs: ctx.fs, signal: ctx.signal }, options)
    return result
  })
}
