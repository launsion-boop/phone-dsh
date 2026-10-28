// SPDX-License-Identifier: MIT
/**
 * Client for the xl exec-bridge v1 loopback protocol (spec/exec-bridge-v1).
 * Built on node:http only: the phone runtime runs under `--jitless`, where
 * WebAssembly (and therefore undici's fetch) is unavailable.
 * @module @phone-dsh/dsh-exec-bridge/client
 */

import http from 'node:http'
import type { IncomingMessage } from 'node:http'

export const PROTOCOL = 'pdsh-exec-bridge/1'

export interface Mount {
  host_path: string
  guest_path: string
  read_only?: boolean
}

export interface Hello {
  protocol: string
  /**
   * Where the non-capability facts came from. The ordered channel HELLO only
   * carries `caps`; its provider/mounts/limits are not host facts and the
   * console must render them as unknown (see `phone-shell`). HTTP exec-bridge
   * HELLOs omit this field and are real host facts.
   */
  facts_source?: 'exec-bridge-hello' | 'channel-caps'
  /** Host provider identity; `unknown` on the channel (it publishes caps only). */
  provider: { name: string; version?: string }
  guest: { platform: 'posix'; default_shell?: string; path_env?: string; mounts: Mount[] }
  capabilities: {
    exec: true
    stdin_pipe?: boolean
    fs?: boolean
    http_proxy?: boolean
    lifecycle?: boolean
    process_group?: boolean
    confine?: Array<'read-only' | 'workspace-write'>
    /** Read-only accelerators the provider serves (phone-dsh-v1 host HELLO caps). */
    accelerators?: string[]
  }
  limits: {
    max_concurrent?: number
    max_output_bytes_per_stream?: number
    max_request_bytes?: number
    retention_seconds?: number
  }
}

export type StdinSpec = { mode: 'ignore' } | { mode: 'data'; data: string } | { mode: 'pipe' }

export interface ExecRequest {
  exec_id: string
  argv: string[]
  cwd: string
  env?: Record<string, string | null>
  deadline?: number
  grace_ms?: number
  stdin?: StdinSpec
  tier?: 'interactive' | 'session' | 'batch'
  confine?: { mode: 'read-only' | 'workspace-write'; workspace_root: string }
  /** phone-dsh-v1 EXEC_REQ readiness fence: apply VFS through this mseq first. */
  requires_mseq?: number
  /** phone-dsh-v1 EXEC_REQ idempotency key: 64 lowercase hex (exec.md §1). */
  idem_key?: string
}

export type ExitStatus = 'exited' | 'signaled' | 'cancelled' | 'timed_out' | 'rejected' | 'failed'

export type ExecEvent =
  | { type: 'start'; exec_id: string; seq: number; pid?: number; replayed?: boolean }
  | { type: 'output'; exec_id: string; seq: number; stream: 'stdout' | 'stderr'; data: string }
  | {
    type: 'exit'; exec_id: string; seq: number; code: number | null; signal: string | null
    status: ExitStatus; quiescent: boolean; error?: string
  }
  | { type: 'quiescent'; exec_id: string; seq: number }
  | { type: 'error'; exec_id: string; seq: number; code: string; message: string }

export interface ExecStatus {
  exec_id: string
  state: 'running' | 'exited'
  started_at?: number
  exit?: { code: number | null; signal: string | null; status: ExitStatus; quiescent: boolean }
}

export interface LifecycleState {
  rev: number
  state: 'run' | 'pause' | 'stop'
  reason?: string
  budget_ms?: number
}

export interface FsStat { type: 'file' | 'dir' | 'symlink' | 'other'; size: number; mtime_ms: number; mode?: number }

/** A structured failure answered by the bridge (or the transport). */
export class ExecBridgeError extends Error {
  readonly code: string
  readonly status: number | undefined

  constructor(message: string, code: string, status?: number, options?: ErrorOptions) {
    super(message, options)
    this.name = 'ExecBridgeError'
    this.code = code
    this.status = status
  }
}

export interface ExecBridgeClientOptions {
  /** Base URL, e.g. `http://127.0.0.1:47321`. Must be loopback. */
  url: string
  /** Per-boot bearer token. */
  token: string
  /** Socket keep-alive agent; one is created when omitted. */
  agent?: http.Agent
}

const LOOPBACK = new Set(['127.0.0.1', '::1', '[::1]', 'localhost'])

/** One open NDJSON event stream. */
export interface EventStream extends AsyncIterable<ExecEvent> {
  /** Stop reading; the execution itself keeps running (detach semantics). */
  close(): void
}

/**
 * The exec-bridge v1 client face every deployment exposes.
 *
 * The desktop transport returns the node:http {@link ExecBridgeClient}; the
 * Worker transports (`channel`, `fetch`) return an adapter over the same
 * transport the service itself uses, so providers written against
 * `ctx.xlExecBridge.client` (subprocess-xl, lifecycle-gate) work on every wire
 * instead of throwing "no node:http client".
 */
export interface ExecClient {
  hello(signal?: AbortSignal): Promise<Hello>
  exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream>
  events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream>
  cancel(execId: string, body?: { signal?: string; grace_ms?: number }, signal?: AbortSignal): Promise<void>
  stdin(execId: string, body?: { data?: string; eof?: boolean }, signal?: AbortSignal): Promise<void>
  lifecycle(since: number | undefined, waitMs: number, signal?: AbortSignal): Promise<LifecycleState>
  destroy(): void
}

export class ExecBridgeClient {
  readonly url: URL
  private readonly token: string
  private readonly agent: http.Agent

  constructor(options: ExecBridgeClientOptions) {
    const url = new URL(options.url)
    if (url.protocol !== 'http:') throw new Error(`exec bridge URL must be http://127.0.0.1:<port>, got ${url.protocol}`)
    if (!LOOPBACK.has(url.hostname)) throw new Error(`exec bridge URL must be a loopback address, got ${url.hostname}`)
    if (options.token.length < 16) throw new Error('exec bridge token is missing or shorter than 16 characters')
    this.url = url
    this.token = options.token
    this.agent = options.agent ?? new http.Agent({ keepAlive: true, maxSockets: 32 })
  }

  /** Close idle keep-alive sockets. */
  destroy(): void {
    this.agent.destroy()
  }

  hello(signal?: AbortSignal): Promise<Hello> {
    return this.json<Hello>('GET', '/v1/hello', undefined, signal)
  }

  /** Start or idempotently re-attach to an execution; resolves once the stream is open. */
  exec(request: ExecRequest, signal?: AbortSignal): Promise<EventStream> {
    return this.stream('POST', '/v1/exec', request, signal)
  }

  /** Re-attach to a retained execution, replaying events with `seq > afterSeq`. */
  events(execId: string, afterSeq: number, signal?: AbortSignal): Promise<EventStream> {
    return this.stream('GET', `/v1/exec/${encodeURIComponent(execId)}/events?after_seq=${afterSeq}`, undefined, signal)
  }

  status(execId: string, signal?: AbortSignal): Promise<ExecStatus> {
    return this.json<ExecStatus>('GET', `/v1/exec/${encodeURIComponent(execId)}`, undefined, signal)
  }

  async cancel(execId: string, body: { signal?: string; grace_ms?: number } = {}, signal?: AbortSignal): Promise<void> {
    await this.json<unknown>('POST', `/v1/exec/${encodeURIComponent(execId)}/cancel`, body, signal)
  }

  async stdin(execId: string, body: { data?: string; eof?: boolean }, signal?: AbortSignal): Promise<void> {
    await this.json<unknown>('POST', `/v1/exec/${encodeURIComponent(execId)}/stdin`, body, signal)
  }

  lifecycle(since: number | undefined, waitMs: number, signal?: AbortSignal): Promise<LifecycleState> {
    const query = `?wait_ms=${Math.max(0, Math.floor(waitMs))}${since === undefined ? '' : `&since=${since}`}`
    return this.json<LifecycleState>('GET', `/v1/lifecycle${query}`, undefined, signal)
  }

  fsStat(path: string, signal?: AbortSignal): Promise<FsStat> {
    return this.json<FsStat>('POST', '/v1/fs/stat', { path }, signal)
  }

  fsRead(path: string, range: { offset?: number; length?: number } = {}, signal?: AbortSignal): Promise<{ data: string; eof: boolean; size: number }> {
    return this.json('POST', '/v1/fs/read', { path, ...range }, signal)
  }

  fsWrite(path: string, data: string, mode: 'truncate' | 'append' | 'create' = 'truncate', signal?: AbortSignal): Promise<{ size: number; mtime_ms: number }> {
    return this.json('POST', '/v1/fs/write', { path, data, mode }, signal)
  }

  fsList(path: string, signal?: AbortSignal): Promise<{ entries: Array<{ name: string; type: FsStat['type'] }> }> {
    return this.json('POST', '/v1/fs/list', { path }, signal)
  }

  private open(method: string, path: string, body: unknown, signal: AbortSignal | undefined): Promise<IncomingMessage> {
    return new Promise<IncomingMessage>((resolve, reject) => {
      if (signal?.aborted) { reject(signal.reason); return }
      const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body))
      const request = http.request(new URL(path, this.url), {
        method,
        agent: this.agent,
        headers: {
          'authorization': `Bearer ${this.token}`,
          'accept': 'application/json, application/x-ndjson',
          ...payload === undefined ? {} : { 'content-type': 'application/json', 'content-length': payload.length },
        },
      })
      const onAbort = (): void => { request.destroy(signal?.reason instanceof Error ? signal.reason : new Error('aborted')) }
      signal?.addEventListener('abort', onAbort, { once: true })
      request.once('response', (response) => {
        signal?.removeEventListener('abort', onAbort)
        resolve(response)
      })
      request.once('error', (error) => {
        signal?.removeEventListener('abort', onAbort)
        reject(signal?.aborted ? signal.reason : new ExecBridgeError(`exec bridge unreachable: ${error.message}`, 'transport', undefined, { cause: error }))
      })
      request.end(payload)
    })
  }

  private async json<T>(method: string, path: string, body: unknown, signal: AbortSignal | undefined): Promise<T> {
    const response = await this.open(method, path, body, signal)
    const text = await readAll(response)
    const status = response.statusCode ?? 0
    if (status >= 400) throw errorFrom(status, text)
    if (status === 204 || text.length === 0) return undefined as T
    return JSON.parse(text) as T
  }

  private async stream(method: string, path: string, body: unknown, signal: AbortSignal | undefined): Promise<EventStream> {
    const response = await this.open(method, path, body, signal)
    const status = response.statusCode ?? 0
    if (status >= 400) throw errorFrom(status, await readAll(response))
    return ndjsonEvents(response)
  }
}

function readAll(response: IncomingMessage): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = []
    response.on('data', (chunk: Buffer) => { chunks.push(chunk) })
    response.once('end', () => { resolve(Buffer.concat(chunks).toString('utf8')) })
    response.once('error', reject)
  })
}

function errorFrom(status: number, text: string): ExecBridgeError {
  try {
    const parsed = JSON.parse(text) as { error?: { code?: string; message?: string } }
    if (parsed.error?.code !== undefined) {
      return new ExecBridgeError(parsed.error.message ?? parsed.error.code, parsed.error.code, status)
    }
  } catch {
    // Non-JSON error body: report the HTTP status.
  }
  return new ExecBridgeError(`exec bridge answered HTTP ${status}${text ? `: ${text.slice(0, 200)}` : ''}`, `http_${status}`, status)
}

/** Parse an NDJSON response into events; a torn final line is a transport error. */
export function ndjsonEvents(response: IncomingMessage): EventStream {
  let closed = false
  const iterator = async function* (): AsyncGenerator<ExecEvent> {
    let buffered = ''
    try {
      for await (const chunk of response) {
        buffered += (chunk as Buffer).toString('utf8')
        let newline = buffered.indexOf('\n')
        while (newline >= 0) {
          const line = buffered.slice(0, newline).trim()
          buffered = buffered.slice(newline + 1)
          if (line.length > 0) yield JSON.parse(line) as ExecEvent
          newline = buffered.indexOf('\n')
        }
      }
    } catch (error) {
      if (closed) return
      throw new ExecBridgeError('exec bridge event stream broke', 'transport', undefined, { cause: error })
    }
    if (buffered.trim().length > 0 && !closed) {
      throw new ExecBridgeError('exec bridge event stream ended inside a line', 'transport')
    }
  }
  const generator = iterator()
  return {
    [Symbol.asyncIterator]: () => generator,
    close: () => {
      closed = true
      response.destroy()
    },
  }
}
