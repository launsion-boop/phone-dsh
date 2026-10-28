// SPDX-License-Identifier: MIT
/**
 * `ctx.xlExecBridge`: one authenticated connection to the host app's exec
 * provider (spec/exec-bridge-v1), its verified `hello` facts, and the host ↔
 * guest path mapping. Under the phone-dsh-v1 Worker the same service speaks
 * the ordered channel instead (`globalThis.__PDSH_CHANNEL__`); in a same-origin
 * page it can use the loopback `/v1/exec*` endpoints over `fetch`. The
 * subprocess, sandbox, and lifecycle plugins share it, the same way DSH's SSH
 * providers share `ctx.ssh`.
 * @module @phone-dsh/dsh-exec-bridge
 */

import { readFileSync } from 'node:fs'
import { Context, Service } from '@deepseek-ai/cordis'
import schema from '@deepseek-ai/schemastery'
import type { ChannelClient } from '@phone-dsh/dsh-channel/client'
import { ExecBridgeClient, ExecBridgeError, PROTOCOL } from './client.ts'
import type { ExecClient, Hello } from './client.ts'
import { PathMapper } from './paths.ts'
import {
  ChannelExecTransport, DeferredChannel, ExecTransportError, FetchExecTransport, NodeHttpExecTransport,
  TransportExecClient, acceleratorsFromCaps, isLoopbackHost,
} from './transport.ts'
import type { ExecTransport, ExecTransportKind } from './transport.ts'

export { ExecBridgeClient, ExecBridgeError, PROTOCOL, ndjsonEvents } from './client.ts'
export type { EventStream, ExecClient, ExecEvent, ExecRequest, ExecStatus, ExitStatus, FsStat, Hello, LifecycleState, Mount, StdinSpec } from './client.ts'
export { PathMapper } from './paths.ts'
export type { PathMapperOptions } from './paths.ts'
export { TOOL_CALL_CONTEXT_KEY, currentToolCall, toolCallStorage } from './call-context.ts'
export type { ToolCallContext } from './call-context.ts'
export {
  ChannelExecTransport, DeferredChannel, ExecTransportError, FetchExecTransport, NodeHttpExecTransport,
  TransportExecClient, acceleratorsFromCaps, execRequestJson, isLoopbackHost, jsonSafe, ndjsonStream,
  withPhoneExecFields,
} from './transport.ts'
export type { EventStream as TransportEventStream, ExecTransport, ExecTransportKind } from './transport.ts'
export { canonicalArgv, deriveIdemKey, envHash, idemKeyFromContext, identitySegment, sha256Hex } from './idem.ts'
export type { ExecEnv, IdemKeyFacts } from './idem.ts'

/** Deployment-owned bridge coordinates; no model argument selects these values. */
export interface Config {
  /** Bridge base URL; defaults to `$PDSH_EXEC_BRIDGE_URL`. */
  url?: string
  /**
   * Transport selection: `auto` (URL → node-http, channel global → channel,
   * same-origin page → fetch), or an explicit kind.
   */
  transport?: ExecTransportKind | 'auto'
  /** Environment variable holding the per-boot token. */
  tokenEnv: string
  /** Environment variable naming a 0600 file that holds the token (used when `tokenEnv` is unset). */
  tokenFileEnv: string
  /** Environment variable holding the Worker's loopback bearer token (`PDSH_CHANNEL_TOKEN`). */
  channelTokenEnv?: string
  /** Explicit accelerator allow-list; when empty the current host HELLO caps decide. */
  accelerators?: string[]
  /** How long startup waits for the host to answer `hello`. */
  connectTimeoutMs: number
}

declare module '@deepseek-ai/cordis' {
  interface Context { xlExecBridge: XlExecBridge }
}

const NON_RETRYABLE_HANDSHAKE = new Set(['protocol', 'exec_id_conflict', 'unauthorized', 'forbidden'])

/** Shared exec-provider connection; readiness waits for verified `hello` facts. */
export class XlExecBridge extends Service {
  static Config: schema<Config> = schema.object({
    url: schema.string(),
    transport: schema.union(['auto', 'channel', 'fetch', 'node-http'] as const).default('auto'),
    tokenEnv: schema.string().default('PDSH_EXEC_BRIDGE_TOKEN'),
    tokenFileEnv: schema.string().default('PDSH_EXEC_BRIDGE_TOKEN_FILE'),
    channelTokenEnv: schema.string().default('PDSH_CHANNEL_TOKEN'),
    accelerators: schema.array(String).default([]),
    connectTimeoutMs: schema.number().default(15_000),
  }) as schema<Config>

  /** The selected wire. */
  readonly transport: ExecTransport
  /** Resolves with the verified capability facts. */
  readonly ready: Promise<Hello>
  private facts: Hello | undefined
  private mapper: PathMapper | undefined
  private createdClient: ExecClient | undefined

  constructor(ctx: Context, config: Config) {
    super(ctx, 'xlExecBridge')
    const url = config.url ?? process.env.PDSH_EXEC_BRIDGE_URL
    const channel = typeof globalThis.__PDSH_CHANNEL__ === 'undefined' ? undefined : globalThis.__PDSH_CHANNEL__
    const kind = selectTransport(config.transport ?? 'auto', url, channel)
    const accelerators = configuredAccelerators(config.accelerators ?? [])
    if (kind === 'channel') {
      // Auto selection may run before the Worker entry installs the channel;
      // the deferred reference resolves it at the first frame.
      this.transport = new ChannelExecTransport(channel as ChannelClient ?? new DeferredChannel(), accelerators.length > 0 ? accelerators : undefined, {
        helloTimeoutMs: config.connectTimeoutMs,
      })
      // D12 caps can change on a reconnect; the ready facts must follow the
      // current host HELLO instead of freezing the first accelerator set.
      if (channel !== undefined) {
        const off = channel.onHostHello((hello) => {
          if (this.facts === undefined) return
          this.facts = {
            ...this.facts,
            capabilities: { ...this.facts.capabilities, accelerators: acceleratorsFromCaps(hello.caps) },
          }
        })
        ctx.effect(() => off, 'pdsh-exec-bridge host caps')
      }
    } else if (kind === 'fetch') {
      const base = url
        ?? process.env.PDSH_CHANNEL_ORIGIN
        ?? loopbackHttpOrigin(process.env.PDSH_CHANNEL_URL)
        ?? globalThis.location?.origin
      if (base === undefined) throw new Error('pdsh-exec-bridge: no URL for the fetch transport (set config.url, PDSH_EXEC_BRIDGE_URL or run same-origin)')
      this.transport = new FetchExecTransport({ url: base, token: readToken(config, true), accelerators: accelerators.length > 0 ? accelerators : undefined })
    } else {
      if (url === undefined || url === '') throw new Error('pdsh-exec-bridge: no bridge URL (set config.url or PDSH_EXEC_BRIDGE_URL)')
      const client = new ExecBridgeClient({ url, token: readToken(config, false) })
      this.transport = new NodeHttpExecTransport({ client, accelerators })
    }
    this.ready = this.connect(config.connectTimeoutMs)
    void this.ready.catch(() => {})
    ctx.effect(() => () => { this.transport.destroy() }, 'pdsh-exec-bridge transport')
  }

  /** Hold plugin readiness until the host answered a compatible `hello`. */
  async [Service.init](): Promise<void> { await this.ready }

  /** Verified `hello` facts; `capabilities.accelerators` is always populated. */
  get hello(): Hello {
    if (this.facts === undefined) throw new Error('pdsh-exec-bridge is not ready')
    return this.facts
  }

  /** Host ↔ guest mapping over the published mounts. */
  get paths(): PathMapper {
    if (this.mapper === undefined) throw new Error('pdsh-exec-bridge is not ready')
    return this.mapper
  }

  /** The exec-bridge v1 client for the selected transport (node:http or Worker adapter). */
  get client(): ExecClient {
    if (this.transport instanceof NodeHttpExecTransport) return this.transport.client
    return this.createdClient ??= new TransportExecClient(this.transport)
  }

  /** Highest VFS mseq this worker emitted (0 outside the ordered channel). */
  get lastMseq(): bigint {
    return this.transport.lastMseq()
  }

  /** Monotonic sink revision; a parallel execution re-reads it when its slot opens. */
  get revision(): bigint {
    return this.transport.lastMseq()
  }

  /** Workspace root the execution mutex serializes on. */
  get workspaceRoot(): string {
    if (this.mapper !== undefined) return this.mapper.defaultGuestRoot
    return '/dsh/workspace'
  }

  private async connect(timeoutMs: number): Promise<Hello> {
    const deadline = Date.now() + timeoutMs
    let delay = 50
    for (;;) {
      try {
        const hello = await this.transport.hello(AbortSignal.timeout(Math.max(1, deadline - Date.now())))
        if (hello.protocol !== PROTOCOL) {
          throw new ExecBridgeError(`exec bridge speaks ${JSON.stringify(hello.protocol)}, expected ${PROTOCOL}`, 'protocol')
        }
        // Only the ordered channel HELLO publishes no host mounts (see
        // ChannelExecTransport); its guest paths are the trusted Native cwd
        // protocol (`/dsh/...`), not a host mount table. Represent that
        // honestly with a guest-only mapper: guest paths pass through and
        // `toHost` never maps an arbitrary host path such as `/etc`. There is
        // deliberately no synthetic `host=/ -> guest=/` fallback on any
        // transport. A real HTTP/fetch/node-http HELLO that published zero
        // mounts is malformed for host routing and fails closed.
        const published = hello.guest?.mounts
        const mounts = Array.isArray(published) ? published : []
        if (mounts.length === 0) {
          if (this.transport.kind !== 'channel') {
            throw new ExecBridgeError(
              'exec bridge HELLO published no guest mounts; refusing to synthesize a host root',
              'protocol',
            )
          }
          this.mapper = PathMapper.guestOnly()
        } else {
          this.mapper = new PathMapper(mounts)
        }
        this.facts = {
          ...hello,
          capabilities: {
            ...hello.capabilities,
            accelerators: [...hello.capabilities.accelerators ?? []],
          },
        }
        return this.facts
      } catch (error) {
        // Only an unreachable host is retried; a wrong token, protocol or
        // malformed hello is final.
        const code = error instanceof ExecBridgeError || error instanceof ExecTransportError ? error.code : 'transport'
        const retryable = code === 'transport' && !NON_RETRYABLE_HANDSHAKE.has(code)
        if (!retryable || Date.now() + delay > deadline) throw error
        await new Promise(resolve => setTimeout(resolve, delay))
        delay = Math.min(delay * 2, 1000)
      }
    }
  }
}

/** The loopback HTTP origin of a ws//wss channel URL (or an http URL unchanged). */
function loopbackHttpOrigin(raw: string | undefined): string | undefined {
  if (raw === undefined || raw === '') return undefined
  try {
    const url = new URL(raw)
    if (url.protocol === 'ws:' || url.protocol === 'http:') url.protocol = 'http:'
    else if (url.protocol === 'wss:' || url.protocol === 'https:') url.protocol = 'https:'
    else return undefined
    return url.origin
  } catch {
    return undefined
  }
}

/** Pick the wire from config/env and the globals the Worker installs. */
function selectTransport(requested: ExecTransportKind | 'auto', url: string | undefined, channel: unknown): ExecTransportKind {
  const env = process.env.PDSH_EXEC_TRANSPORT
  const explicit = requested !== 'auto' ? requested : env === 'channel' || env === 'fetch' || env === 'node-http' ? env : 'auto'
  if (explicit !== 'auto') return explicit
  // The Worker entry installs the ordered channel before DSH boots and also
  // exports its coordinates. Prefer it over a possibly inherited desktop URL:
  // in the Worker, node:http is only a structural mock.
  if (channel !== undefined) return 'channel'
  if ((process.env.PDSH_CHANNEL_URL ?? '') !== '' || (process.env.PDSH_CHANNEL_TOKEN ?? '') !== '') return 'channel'
  if (url !== undefined && url !== '') return 'node-http'
  const origin = globalThis.location?.origin
  // A same-origin page is the Worker: use the ordered channel and let the
  // deferred reference resolve it if the entry installs it after boot. The
  // `fetch` wire stays available through explicit config/env.
  if (origin !== undefined && (origin.startsWith('http://') || origin.startsWith('https://'))) return 'channel'
  throw new Error('pdsh-exec-bridge: no transport (set config.transport, PDSH_EXEC_BRIDGE_URL or run inside the phone Worker channel)')
}

/** Config accelerators plus `PDSH_EXEC_ACCELERATORS` (`name,name`), de-duplicated. */
function configuredAccelerators(configured: readonly string[]): string[] {
  const names = new Set(configured)
  for (const name of (process.env.PDSH_EXEC_ACCELERATORS ?? '').split(',')) {
    const trimmed = name.trim()
    if (trimmed !== '') names.add(trimmed)
  }
  return [...names]
}

function readToken(config: Config, channel: boolean): string {
  const direct = process.env[config.tokenEnv]
  if (direct !== undefined && direct !== '') return direct
  if (channel) {
    const loopback = process.env[config.channelTokenEnv ?? 'PDSH_CHANNEL_TOKEN']
    if (loopback !== undefined && loopback !== '') return loopback
  }
  const file = process.env[config.tokenFileEnv]
  if (file !== undefined && file !== '') {
    try {
      return readFileSync(file, 'utf8').trim()
    } catch (error) {
      throw new Error(`pdsh-exec-bridge: cannot read token file ${config.tokenFileEnv}`, { cause: error })
    }
  }
  throw new Error(`pdsh-exec-bridge: no bridge token (set ${config.tokenEnv}${channel ? `, ${config.channelTokenEnv}` : ''} or ${config.tokenFileEnv})`)
}

/** Loopback guard shared by the transports and tests (`http://127.0.0.1:<port>`). */
export function requireLoopbackUrl(value: string): URL {
  const url = new URL(value)
  if (url.protocol !== 'http:' || !isLoopbackHost(url.hostname)) {
    throw new Error(`exec provider URL must be http://127.0.0.1:<port>, got ${url.protocol}//${url.hostname}`)
  }
  return url
}

export default XlExecBridge
