// SPDX-License-Identifier: MIT
/**
 * Live HTTP-SSE MCP registry. Each enabled row owns one official
 * `@deepseek-ai/dsh-mcp-client` child fiber; mounting awaits the real initial
 * connection and tool synchronization, and unmounting disposes that fiber so
 * its tools leave the global ToolRuntime. No tool list is synthesized here.
 *
 * @module @phone-dsh/dsh-phone-mcp/manager
 */

import type { Context, Fiber, LoggerService } from '@deepseek-ai/cordis'
import { apply as applyMcpClient, inject as mcpClientInject } from '@deepseek-ai/dsh-mcp-client'
import type { Config as McpClientConfig } from '@deepseek-ai/dsh-mcp-client'
import type { ToolDefinition } from '@deepseek-ai/dsh-tools'
import type {
  McpServerConfig,
  McpServerState,
  McpServerUpsertRequest,
  McpServerView,
  McpSnapshot,
} from './protocol.ts'
import {
  McpError,
  defaultConfigPath,
  readConfigFile,
  resolveHeaders,
  validateServerInput,
  writeConfigFile,
} from './schema.ts'

/** Construction inputs for {@link PhoneMcpManager}. */
export interface PhoneMcpManagerOptions {
  /** Absolute `mcp.json` path; defaults to `/dsh/home/mcp.json` (or `DSH_HOME`). */
  readonly file?: string
  /** Environment read for header values; tests may pass an isolated object. */
  readonly env?: NodeJS.ProcessEnv
}

/** One live mcp-client child fiber and the exact registrations it owns. */
interface Mount {
  readonly fiber: Fiber
  /** Live names registered by this mount in the global ToolRuntime. */
  readonly tools: Set<string>
}

/** Construction input for the wrapper plugin around the official client. */
interface McpMountConfig {
  readonly client: McpClientConfig
  /** Shared with the mount record; wrappers add/remove names with the registrations. */
  readonly tools: Set<string>
  /** Official-client logger shadow that redacts resolved header values. */
  readonly logger: LoggerService
  /** Resolved header values to redact from the error Cordis logs for this fiber. */
  readonly secrets: readonly string[]
  /** Host-managed rows never include the raw upstream error/response body. */
  readonly withholdErrors: boolean
}

/**
 * Mount the official client behind a tool-registration recorder. The official
 * client uses server-qualified names, but a server name may itself contain the
 * `__` separator (`a` and `a__b` are both legal), so filtering the global
 * registry by `mcp__<server>__` would attribute another mount's tools to this
 * one. Recording the exact disposers the official client receives keeps the
 * projection per-mount and follows later `tools/list` re-synchronization.
 */
const MCP_CLIENT_PLUGIN = Object.freeze({
  name: 'phone-mcp-client',
  inject: mcpClientInject,
  async apply(ctx: Context, config: McpMountConfig): Promise<void> {
    const actual = ctx.tools
    const tracked = new Proxy(actual, {
      get(target, property, receiver) {
        if (property === 'register') {
          return (definition: ToolDefinition): (() => void) => {
            const dispose = target.register(definition)
            config.tools.add(definition.name)
            let active = true
            return () => {
              if (!active) return
              active = false
              config.tools.delete(definition.name)
              dispose()
            }
          }
        }
        return Reflect.get(target, property, receiver)
      },
    })
    // The official package only calls `ctx.tools.register`; the shadow keeps
    // every other service and effect on the mount's own fiber. Its own
    // connection/tool diagnostics run before this manager's catch, so the
    // logger shadow must redact the same resolved header values as well.
    try {
      await applyMcpClient(ctx.extend({ tools: tracked, logger: config.logger }), config.client)
    } catch (error) {
      // Cordis logs the error thrown by this apply on its own fiber logger
      // before `await fiber` rejects here. Strip the raw transport cause and
      // redact the body in the value that crosses that boundary.
      if (config.withholdErrors) {
        // The real host-injected header is not present in this process, so no
        // redactor here can know an upstream echo. Keep only the status class.
        throw new McpError(
          error instanceof McpError ? error.code : 'MCP_CONNECT_FAILED',
          `MCP server "${config.client.serverName}" failed to connect; response detail withheld because the native host injects credentials`,
        )
      }
      if (error instanceof McpError) throw new McpError(error.code, safeMessage(error, config.secrets))
      throw new McpError(
        'MCP_CONNECT_FAILED',
        `MCP server "${config.client.serverName}" failed to connect: ${safeMessage(error, config.secrets)}`,
      )
    }
  },
})

/** Largest diagnostic retained in a row, a log, or a thrown error. */
const MAX_DIAGNOSTIC_LENGTH = 1024

/**
 * Join the visible error and its `cause` chain. The official mcp-client wraps
 * the transport failure, so the outer message alone would hide a duplicate
 * serverName or a 401. The result is redacted and bounded before it is stored
 * or logged; the raw cause chain is never attached to a mapped error.
 */
function messageOf(error: unknown): string {
  const parts: string[] = []
  const seen = new Set<unknown>()
  let current: unknown = error
  while (current !== undefined && current !== null && parts.length < 6 && !seen.has(current)) {
    seen.add(current)
    const message = current instanceof Error ? current.message : String(current)
    if (message.length > 0 && !parts.includes(message)) parts.push(message)
    current = current instanceof Error ? (current as { cause?: unknown }).cause : undefined
  }
  return parts.join(': ')
}

/** Keep resolved header values out of every diagnostic this manager emits. */
function redact(message: string, secrets: readonly string[]): string {
  let text = message
  for (const secret of secrets) {
    if (secret.length > 0) text = text.split(secret).join('[redacted]')
  }
  return text
}

function bound(message: string): string {
  return message.length <= MAX_DIAGNOSTIC_LENGTH
    ? message
    : `${message.slice(0, MAX_DIAGNOSTIC_LENGTH)}...`
}

/** Resolve already-configured header values for redaction without failing the caller. */
function headerSecrets(config: Pick<McpServerConfig, 'headersFromEnv' | 'hostManagedHeaders'> | undefined, env: NodeJS.ProcessEnv): string[] {
  if (config === undefined) return []
  const secrets: string[] = []
  for (const envName of Object.values(config.headersFromEnv)) {
    const value = env[envName]
    if (typeof value === 'string' && value.length > 0) secrets.push(value)
  }
  return secrets
}

function sanitizeLogValue(value: unknown, secrets: readonly string[]): unknown {
  if (typeof value === 'string') return redact(value, secrets)
  if (value instanceof Error) {
    const safe = new Error(redact(value.message, secrets))
    safe.name = redact(value.name, secrets)
    if (value.stack !== undefined) safe.stack = redact(value.stack, secrets)
    return safe
  }
  return value
}

type LogMethods = Pick<LoggerService, 'error' | 'info' | 'warn' | 'debug'>

function sanitizedLogMethods(logger: LogMethods, secrets: readonly string[]): LogMethods {
  const wrap = (method: LogMethods['error']) => (format: unknown, ...params: unknown[]) => {
    method(redact(String(format), secrets), ...params.map(value => sanitizeLogValue(value, secrets)))
  }
  return {
    error: wrap(logger.error.bind(logger)),
    info: wrap(logger.info.bind(logger)),
    warn: wrap(logger.warn.bind(logger)),
    debug: wrap(logger.debug.bind(logger)),
  }
}

/** Shadow the official client's logger so connection and registration errors are redacted before they reach an exporter. */
function createRedactingLogger(logger: LoggerService, secrets: readonly string[]): LoggerService {
  const shadow = Object.assign(
    (name?: string) => sanitizedLogMethods(logger(name), secrets),
    sanitizedLogMethods(logger, secrets),
  )
  return shadow as LoggerService
}

/**
 * A host-managed row's real value is injected after the Worker has already
 * sent the placeholder, so this process cannot redact an upstream echo from the
 * official client's own log line. Keep only a fixed status line: the native
 * manager/bridge expose the controlled diagnostic elsewhere.
 */
function createOpaqueLogger(logger: LoggerService): LoggerService {
  const emit = (method: LogMethods['error']) =>
    (_format: unknown, ..._params: unknown[]) => {
      method('phone-mcp: host-managed MCP diagnostic withheld')
    }
  const methods: LogMethods = {
    error: emit(logger.error.bind(logger)),
    info: emit(logger.info.bind(logger)),
    warn: emit(logger.warn.bind(logger)),
    debug: emit(logger.debug.bind(logger)),
  }
  const shadow = Object.assign((_name?: string) => methods, methods)
  return shadow as LoggerService
}

/** One safe, bounded diagnostic for logs, snapshots, and thrown errors. */
function safeMessage(error: unknown, secrets: readonly string[]): string {
  const message = error instanceof McpError ? error.message : messageOf(error)
  return bound(redact(message, secrets))
}

function asMcpError(code: string, prefix: string, error: unknown, secrets: readonly string[]): McpError {
  if (error instanceof McpError) return new McpError(error.code, safeMessage(error, secrets))
  return new McpError(code, bound(redact(`${prefix}: ${safeMessage(error, secrets)}`, secrets)))
}

/**
 * A host-managed row's real value never reaches this process, so the manager
 * cannot redact it from an upstream body. Keep only a controlled status-level
 * diagnostic instead of copying a 401 body that may echo the injected header.
 */
function hostManagedFailure(
  config: Pick<McpServerConfig, 'serverName' | 'hostManagedHeaders'>,
  action: 'connect' | 'reconnect',
): McpError {
  return new McpError(
    'MCP_CONNECT_FAILED',
    `MCP server "${config.serverName}" failed to ${action}; response detail withheld because the native host injects credentials for this exact URL`,
  )
}

/**
 * Owns the persisted registry and the live child fibers for one Host process.
 * Public methods are also the bodies behind the `phone/mcp*` Remote methods.
 */
export class PhoneMcpManager {
  private readonly ctx: Context
  private readonly env: NodeJS.ProcessEnv
  private readonly file: string
  private entries: McpServerConfig[] = []
  private readonly mounts = new Map<string, Mount>()
  private readonly errors = new Map<string, string>()
  private loadError: string | undefined
  private started = false
  private disposed = false
  /** Tail of the single-writer queue that serializes every state change. */
  private lock: Promise<void> = Promise.resolve()

  constructor(ctx: Context, options: PhoneMcpManagerOptions = {}) {
    this.ctx = ctx
    this.env = options.env ?? process.env
    this.file = options.file ?? defaultConfigPath(this.env)
  }

  /** Absolute path this manager reads and writes. */
  get configFile(): string {
    return this.file
  }

  /**
   * Read `mcp.json`, then mount every enabled row in order. A read/schema
   * failure is retained as a snapshot error instead of killing the plugin, so
   * the Settings tab can still replace a corrupt file. A failed connection for
   * one row is retained as that row's error and does not stop later rows.
   */
  async start(): Promise<void> {
    await this.exclusive(async () => {
      if (this.started) return
      this.started = true
      this.assertUsable()
      let document
      try {
        document = await readConfigFile(this.file)
      } catch (error) {
        if (this.disposed) throw new McpError('MCP_DISPOSED', 'phone-mcp manager is disposed')
        this.loadError = safeMessage(error, [])
        this.ctx.logger.warn(`phone-mcp: ${this.loadError}`)
        return
      }
      // The load and every mount happen under the same lock as the CRUD
      // methods: a command that arrives while startup is connecting waits for
      // the committed registry instead of racing it.
      this.entries = [...document.servers]
      this.loadError = undefined
      for (const config of this.entries) {
        if (!config.enabled || this.mounts.has(config.serverName)) continue
        try {
          this.mounts.set(config.serverName, await this.mount(config))
        } catch (error) {
          if (this.disposed) return
          const message = safeMessage(error, headerSecrets(config, this.env))
          this.errors.set(config.serverName, message)
          this.ctx.logger.warn(`phone-mcp: ${message}`)
        }
      }
    })
  }

  /** Snapshot every persisted row with its live mount state and real tools. */
  list(): McpSnapshot {
    const servers = [...this.entries]
      .sort((a, b) => a.serverName.localeCompare(b.serverName))
      .map(config => this.view(config))
    return {
      file: this.file,
      servers,
      ...this.loadError === undefined ? {} : { error: this.loadError },
    }
  }

  /**
   * Create or replace one row. The new mount is proven before the file changes;
   * a failure leaves both the previous mount and the previous file intact.
   */
  async upsert(input: McpServerUpsertRequest): Promise<McpServerView> {
    return this.exclusive(async () => {
      this.assertUsable()
      const config = validateServerInput(input)
      // Resolve now so a missing environment variable refuses the write instead
      // of persisting a row that cannot ever connect from this process.
      if (config.enabled) resolveHeaders(config, this.env)

      // No await before this read: it observes the previous operation's
      // committed rows, so two concurrent adds cannot each start from `[]`.
      const index = this.entries.findIndex(row => row.serverName === config.serverName)
      const previousConfig = index < 0 ? undefined : this.entries[index]
      const previousMount = this.mounts.get(config.serverName)

      let nextMount: Mount | undefined
      try {
        if (previousMount !== undefined) await this.unmount(config.serverName)
        this.assertUsable()
        if (config.enabled) {
          nextMount = await this.mount(config)
          this.assertUsable()
        }
      } catch (error) {
        if (nextMount !== undefined) {
          await nextMount.fiber.dispose().catch(() => {})
          nextMount = undefined
        }
        if (this.disposed) throw error
        await this.restore(previousConfig, config.serverName)
        throw asMcpError(
          'MCP_CONNECT_FAILED',
          `MCP server "${config.serverName}" failed to connect`,
          error,
          headerSecrets(config, this.env),
        )
      }

      const nextEntries = [...this.entries]
      if (index < 0) nextEntries.push(config)
      else nextEntries[index] = config

      try {
        await writeConfigFile(this.file, nextEntries)
      } catch (error) {
        if (nextMount !== undefined) await nextMount.fiber.dispose().catch(() => {})
        if (this.disposed) throw new McpError('MCP_DISPOSED', 'phone-mcp manager is disposed')
        await this.restore(previousConfig, config.serverName)
        throw asMcpError(
          'MCP_CONFIG_WRITE_FAILED',
          `MCP server "${config.serverName}" could not be saved`,
          error,
          headerSecrets(config, this.env),
        )
      }

      // Publish the file's new state even if disposal raced the write; dispose
      // waits on this lock and will unmount whatever this transaction mounted.
      this.entries = nextEntries
      this.loadError = undefined
      if (nextMount === undefined) {
        this.mounts.delete(config.serverName)
        this.errors.delete(config.serverName)
      } else {
        this.mounts.set(config.serverName, nextMount)
        this.errors.delete(config.serverName)
      }
      this.assertUsable()
      return this.view(config)
    })
  }

  /** Remove one row and dispose its live tools before the file changes. */
  async remove(serverName: string): Promise<{ serverName: string; removed: true }> {
    return this.exclusive(async () => {
      this.assertUsable()
      const index = this.entries.findIndex(row => row.serverName === serverName)
      if (index < 0) throw new McpError('MCP_NOT_FOUND', `MCP server "${serverName}" is not configured`)
      const previousConfig = this.entries[index]
      const previousError = this.errors.get(serverName)
      if (this.mounts.has(serverName)) await this.unmount(serverName)
      this.assertUsable()
      const nextEntries = this.entries.filter(row => row.serverName !== serverName)
      try {
        await writeConfigFile(this.file, nextEntries)
      } catch (error) {
        if (this.disposed) throw new McpError('MCP_DISPOSED', 'phone-mcp manager is disposed')
        await this.restore(previousConfig, serverName)
        if (previousError !== undefined) this.errors.set(serverName, previousError)
        throw asMcpError(
          'MCP_CONFIG_WRITE_FAILED',
          `MCP server "${serverName}" could not be removed`,
          error,
          headerSecrets(previousConfig, this.env),
        )
      }
      this.entries = nextEntries
      this.errors.delete(serverName)
      this.mounts.delete(serverName)
      this.assertUsable()
      return { serverName, removed: true }
    })
  }

  /**
   * Re-establish one enabled row with a fresh transport. The environment is
   * resolved again here, so a rotated value takes effect without editing JSON.
   * A failed attempt is recorded on the row and reported; the file is unchanged.
   */
  async reconnect(serverName: string): Promise<McpServerView> {
    return this.exclusive(async () => {
      this.assertUsable()
      const config = this.entries.find(row => row.serverName === serverName)
      if (config === undefined) throw new McpError('MCP_NOT_FOUND', `MCP server "${serverName}" is not configured`)
      if (!config.enabled) throw new McpError('MCP_DISABLED', `MCP server "${serverName}" is disabled`)
      resolveHeaders(config, this.env)

      if (this.mounts.has(serverName)) await this.unmount(serverName)
      this.assertUsable()
      let mount: Mount
      try {
        mount = await this.mount(config)
        this.assertUsable()
      } catch (error) {
        if (this.disposed) throw error
        const failure = config.hostManagedHeaders.length > 0
          ? hostManagedFailure(config, 'reconnect')
          : asMcpError(
              'MCP_CONNECT_FAILED',
              `MCP server "${serverName}" failed to reconnect`,
              error,
              headerSecrets(config, this.env),
            )
        this.errors.set(serverName, failure.message)
        this.ctx.logger.warn(`phone-mcp: ${failure.message}`)
        throw failure
      }
      this.mounts.set(serverName, mount)
      this.errors.delete(serverName)
      return this.view(config)
    })
  }

  /** Dispose every child fiber; idempotent and safe during Host unload. */
  async dispose(): Promise<void> {
    if (this.disposed) return
    this.disposed = true
    // Wait for the in-flight transaction to observe `disposed` and release the
    // lock, then unmount the committed state it may have left behind.
    await this.exclusive(async () => {
      const names = [...this.mounts.keys()]
      await Promise.all(names.map(async name => { await this.unmount(name) }))
    })
  }

  /**
   * Run one registry operation as the only writer. `start`, `upsert`, `remove`,
   * `reconnect`, and `dispose` all share this queue: entries, mounts and the
   * file are therefore committed as one transaction, and a slow connect can no
   * longer interleave with another caller's read/modify/write.
   */
  private async exclusive<T>(work: () => Promise<T>): Promise<T> {
    const previous = this.lock
    let release!: () => void
    this.lock = new Promise<void>(resolve => { release = resolve })
    await previous
    try {
      return await work()
    } finally {
      release()
    }
  }

  private assertUsable(): void {
    if (this.disposed) throw new McpError('MCP_DISPOSED', 'phone-mcp manager is disposed')
  }

  private view(config: McpServerConfig): McpServerView {
    const error = this.errors.get(config.serverName)
    let status: McpServerState
    if (!config.enabled) status = 'disabled'
    else if (this.mounts.has(config.serverName)) status = 'connected'
    else if (error !== undefined) status = 'error'
    else status = 'connecting'
    return {
      ...config,
      headersFromEnv: { ...config.headersFromEnv },
      hostManagedHeaders: [...config.hostManagedHeaders],
      status,
      ...error === undefined ? {} : { error },
      tools: this.toolsOf(config.serverName),
      authentication: Object.keys(config.headersFromEnv).length === 0
        ? 'none'
        : config.hostManagedHeaders.length > 0
          ? 'host-managed'
          : 'headers-env',
    }
  }

  private toolsOf(serverName: string): string[] {
    const mount = this.mounts.get(serverName)
    return mount === undefined ? [] : [...mount.tools].sort()
  }

  private async mount(config: McpServerConfig): Promise<Mount> {
    this.assertUsable()
    const headers = resolveHeaders(config, this.env)
    const secrets = Object.values(headers)
    const ownedTools = new Set<string>()
    const clientConfig: McpClientConfig = {
      transport: 'streamable-http',
      serverName: config.serverName,
      url: config.url,
      headers,
      toolCallTimeoutMs: config.toolCallTimeoutMs,
      // Await the initial connection and tool sync so a failed mount is
      // returned to the caller instead of leaving a silent background retry.
      failOnStartupError: true,
      reconnect: { enabled: true },
    }
    let fiber: Fiber | undefined
    try {
      fiber = this.ctx.plugin(MCP_CLIENT_PLUGIN, {
        client: clientConfig,
        tools: ownedTools,
        logger: config.hostManagedHeaders.length > 0
          ? createOpaqueLogger(this.ctx.logger)
          : createRedactingLogger(this.ctx.logger, secrets),
        secrets,
        withholdErrors: config.hostManagedHeaders.length > 0,
      })
      await fiber
      // Disposal may have begun while the handshake was in flight. Drop the
      // just-created fiber instead of publishing tools that outlive the Host.
      this.assertUsable()
    } catch (error) {
      await fiber?.dispose().catch(() => {})
      ownedTools.clear()
      if (config.hostManagedHeaders.length > 0) {
        throw hostManagedFailure(config, 'connect')
      }
      if (error instanceof McpError) throw new McpError(error.code, safeMessage(error, secrets))
      const detail = safeMessage(error, secrets)
      throw new McpError('MCP_CONNECT_FAILED', `MCP server "${config.serverName}" failed to connect: ${detail}`)
    }
    if (fiber === undefined) {
      throw new McpError('MCP_CONNECT_FAILED', `MCP server "${config.serverName}" did not mount`)
    }
    return { fiber, tools: ownedTools }
  }

  private async unmount(serverName: string): Promise<void> {
    const mount = this.mounts.get(serverName)
    if (mount === undefined) return
    this.mounts.delete(serverName)
    await mount.fiber.dispose()
  }

  private async restore(previousConfig: McpServerConfig | undefined, serverName: string): Promise<void> {
    if (this.disposed || previousConfig === undefined || !previousConfig.enabled) return
    try {
      const mount = await this.mount(previousConfig)
      this.mounts.set(serverName, mount)
      this.errors.delete(serverName)
    } catch (error) {
      if (this.disposed) return
      const message = safeMessage(error, headerSecrets(previousConfig, this.env))
      this.errors.set(serverName, message)
      this.ctx.logger.warn(`phone-mcp: could not restore "${serverName}" after a failed update: ${message}`)
    }
  }
}
