// SPDX-License-Identifier: MIT
/**
 * Host half of the phone command console.
 *
 * The console never allocates a PTY and never calls `spawnTerminal`. It drives
 * the same `ctx.subprocess` service the Agent's bash tool uses, so:
 *
 * - a `command` string becomes `bash -c` in the Worker's just-bash/VFS and
 *   every write is an ordinary VFS mutation;
 * - an exact `argv` is routed by subprocess-xl: a name the exec-bridge hello
 *   advertised runs on the Host's read-only xz-shell accelerator on the
 *   Worker channel/fetch transports, every other name stays in the Worker
 *   command table.
 *
 * The desktop `node-http` provider is never a phone-console route:
 * subprocess-xl submits every argv verbatim to the Host PC on that transport,
 * so the console rejects every request - command, bare name, path-form name
 * and advertised accelerator - before `normalize`/`spawn`. Any transport that
 * cannot be confirmed as `channel` or `fetch` fails closed the same way. Output
 * is collected per stream with a real byte cap, the exit facts come from the
 * provider, and a deadline or cancellation is reported as such. The service
 * reads the live `hello` for every `caps()` call instead of caching a guessed
 * accelerator list.
 * @module @phone-dsh/dsh-phone-shell
 */

import { randomUUID } from 'node:crypto'
import { posix } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type {
  SubprocessCollectedOutputs,
  SubprocessHandle,
  SubprocessOutcome,
  SubprocessRuntime,
  SubprocessSpawnSpec,
} from '@deepseek-ai/dsh-subprocess'
import { Remote, RemoteError, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import type { ExecTransportKind, XlExecBridge } from '@phone-dsh/dsh-exec-bridge'
import { isAccelerator } from '@phone-dsh/dsh-subprocess-xl'
import { maxOutputBytesFromEnv, shellTimeoutFromEnv } from '@phone-dsh/dsh-shell-ext'
import {
  PHONE_SHELL_DEFAULT_CWD,
  PHONE_SHELL_DEFAULT_TIMEOUT_MS,
  PHONE_SHELL_MAX_ARGV,
  PHONE_SHELL_MAX_COMMAND_BYTES,
  PHONE_SHELL_MAX_TIMEOUT_MS,
  PHONE_SHELL_WORKER_VFS_ROOTS,
  parseConsoleTimeout,
} from './contract.ts'
import type {
  PhoneShellCaps,
  PhoneShellHostLimits,
  PhoneShellLimits,
  PhoneShellMount,
  PhoneShellRunRequest,
  PhoneShellRunResult,
} from './contract.ts'

export type * from './contract.ts'

declare module '@deepseek-ai/dsh-typert-protocol' {
  interface RemoteErrorDetailsMap {
    'phone-shell/invalid-request': { readonly reason: string }
    'phone-shell/execution-failed': { readonly execId: string }
  }
}

/** The optional Worker deadline and out-of-band identity `subprocess-xl` honours. */
interface XlSpawnSpec extends SubprocessSpawnSpec {
  readonly timeoutMs?: number
  readonly idempotencyKey?: string
}

interface RunningConsole {
  readonly handle: SubprocessHandle
  readonly started: number
  timedOut: boolean
  cancelled: boolean
  /** Terminate first, then hard-settle the Remote promise if the provider does not. */
  stop: (reason: 'timeout' | 'cancelled') => void
}

/**
 * D6 `exec_id` grammar. The accelerator command path appends `-aN`, so the
 * client-owned prefix is capped at 61 characters (and has no colon).
 */
const EXEC_ID = /^[A-Za-z0-9._-]{1,61}$/u
/** Delay between the console's deadline and a hard provider termination. */
const DEADLINE_FORCE_GRACE_MS = 250
/** Extra collector room above the shell's own head/tail cap. */
const COLLECTOR_HEADROOM_BYTES = 64 * 1024

/**
 * Read the host's real capability facts from the live exec-bridge hello.
 * @param hello - verified exec-bridge facts (never a guessed caps list).
 * @param limits - local execution bounds displayed beside the facts.
 * @param route - the live exec transport. The console only executes on the
 *   Worker `channel`/`fetch` transports; every other route fails closed and
 *   advertises no accelerator even when the HELLO lists one.
 * @returns the console capability view.
 */
export function capsFromHello(
  hello: XlExecBridge['hello'],
  limits: PhoneShellLimits,
  route: ExecTransportKind | undefined,
): PhoneShellCaps {
  const transportSupported = route === 'channel' || route === 'fetch'
  const accelerators = transportSupported ? [...new Set(hello.capabilities.accelerators ?? [])] : []
  // The ordered channel HELLO publishes caps only. Its provider/mounts/limits
  // members are explicit placeholders, never xz-shell facts, so do not project
  // them into the console. A real HTTP exec-bridge HELLO is the only source
  // that can fill these fields.
  const hostFacts = hello.facts_source !== 'channel-caps'
  const provider = hostFacts && hello.provider.name !== 'unknown' && hello.provider.name !== ''
    ? hello.provider.name
    : undefined
  const mounts: PhoneShellMount[] | undefined = hostFacts
    ? hello.guest.mounts.map(mount => ({
      hostPath: mount.host_path,
      guestPath: mount.guest_path,
      readOnly: mount.read_only === true,
    }))
    : undefined
  const hostLimits = hostFacts ? hostLimitsOf(hello.limits) : undefined
  const linked = transportSupported && accelerators.length > 0
  return {
    linked,
    ...provider === undefined ? {} : { provider },
    ...hostFacts && hello.provider.version !== undefined ? { version: hello.provider.version } : {},
    accelerators,
    ...mounts === undefined ? {} : { mounts },
    limits,
    ...hostLimits === undefined ? {} : { hostLimits },
    factsSource: hostFacts ? 'exec-bridge-hello' : 'channel-caps',
    transportSupported,
    shell: 'just-bash',
    readOnlyAccelerators: true,
    terminal: false,
    pty: false,
    note: !transportSupported
      ? `the ${JSON.stringify(route) ?? String(route)} exec transport does not support the phone console; only the Worker channel/fetch transports can execute a command, so no host accelerator is offered here`
      : linked
        ? hostFacts
          ? 'read-only xz-shell accelerators plus Worker bash over the VFS; not a PTY'
          : 'read-only xz-shell accelerators from the host HELLO caps plus Worker bash over the VFS; host provider/mounts/limits are not published on this channel; not a PTY'
        : 'xz-shell is not linked or not configured; Worker commands still run in the local VFS',
  }
}

/** Project only the limit members the host HELLO actually carried. */
function hostLimitsOf(limits: XlExecBridge['hello']['limits']): PhoneShellHostLimits | undefined {
  const mapped: PhoneShellHostLimits = {
    ...limits.max_concurrent === undefined ? {} : { maxConcurrent: limits.max_concurrent },
    ...limits.max_output_bytes_per_stream === undefined ? {} : { maxOutputBytesPerStream: limits.max_output_bytes_per_stream },
    ...limits.max_request_bytes === undefined ? {} : { maxRequestBytes: limits.max_request_bytes },
    ...limits.retention_seconds === undefined ? {} : { retentionSeconds: limits.retention_seconds },
  }
  return Object.keys(mapped).length === 0 ? undefined : mapped
}

/**
 * Fail closed unless the live exec transport is one the console can route.
 *
 * On the ordered channel and the fetch wire only an advertised accelerator
 * crosses to the Host, so the Worker still owns every other request. The
 * desktop `node-http` transport submits every argv verbatim to the Host PC, so
 * it is never a phone-console route - not even for an advertised bare
 * accelerator name. Capability lists alone cannot distinguish these routes,
 * and an unconfirmable runtime value must not fall back to a Host shell.
 * @param route - live transport kind, or any unknown runtime value.
 * @returns the confirmed `channel`/`fetch` kind.
 * @throws RemoteError invalid-request for node-http or an unconfirmable route.
 */
export function assertConsoleTransport(route: ExecTransportKind | undefined): 'channel' | 'fetch' {
  if (route === 'channel' || route === 'fetch') return route
  if (route === 'node-http') {
    throw invalid('the node-http exec transport is not supported by the phone console: it would execute requests on the desktop Host instead of the Worker')
  }
  throw invalid(`the exec transport ${JSON.stringify(route) ?? String(route)} cannot be confirmed as channel/fetch; the phone console fails closed`)
}

/**
 * Reject every request a console caller could not have meant literally.
 * @param request - the wire request.
 * @param caps - the live console caps; `accelerators` decides whether an argv
 * reaches the Host, and `mounts` is present only when the HELLO published real
 * host mounts (the ordered channel omits it).
 * @param route - the real subprocess provider route. Only `channel`/`fetch`
 * are console routes; `node-http` and every unknown value are rejected before
 * request parsing, cwd attribution or spawn.
 * @returns the exact argv, cwd and deadline the provider will receive.
 * @throws RemoteError with a typed invalid-request reason.
 */
export function normalizeConsoleRequest(
  request: PhoneShellRunRequest,
  caps: Pick<PhoneShellCaps, 'accelerators' | 'mounts'> = { accelerators: [] },
  route: ExecTransportKind | undefined,
): { argv: string[]; cwd: string; timeoutMs: number; execId: string } {
  assertConsoleTransport(route)
  if (request === null || typeof request !== 'object') {
    throw invalid('request must be an object')
  }
  const hasCommand = request.command !== undefined
  const hasArgv = request.argv !== undefined
  if (hasCommand === hasArgv) {
    throw invalid('request must carry exactly one of command or argv')
  }
  let argv: string[]
  if (hasCommand) {
    if (typeof request.command !== 'string' || request.command.length === 0) {
      throw invalid('command must be a non-empty string')
    }
    if (request.command.trim().length === 0) throw invalid('command must not be blank')
    if (request.command.includes('\0')) throw invalid('command must not contain NUL')
    if (Buffer.byteLength(request.command, 'utf8') > PHONE_SHELL_MAX_COMMAND_BYTES) {
      throw invalid(`command must not exceed ${String(PHONE_SHELL_MAX_COMMAND_BYTES)} bytes`)
    }
    argv = ['bash', '-c', request.command]
  } else {
    if (!Array.isArray(request.argv)) throw invalid('argv must be an array of strings')
    if (request.argv.length === 0) throw invalid('argv must name a program')
    if (request.argv.length > PHONE_SHELL_MAX_ARGV) {
      throw invalid(`argv must not exceed ${String(PHONE_SHELL_MAX_ARGV)} entries`)
    }
    for (const [index, argument] of request.argv.entries()) {
      if (typeof argument !== 'string') throw invalid(`argv[${String(index)}] must be a string`)
      if (argument.includes('\0')) throw invalid(`argv[${String(index)}] must not contain NUL`)
      if (index === 0 && argument.length === 0) throw invalid('argv[0] must be a non-empty program name')
    }
    argv = [...request.argv]
  }

  const cwd = request.cwd ?? PHONE_SHELL_DEFAULT_CWD
  if (typeof cwd !== 'string' || cwd.length === 0) throw invalid('cwd must be a non-empty string')
  if (cwd.includes('\0')) throw invalid('cwd must not contain NUL')
  if (!posix.isAbsolute(cwd)) throw invalid('cwd must be absolute')
  if (cwd.split('/').includes('..')) throw invalid('cwd must not contain a .. component')
  // Only the argv subprocess-xl will actually dispatch to a Host accelerator
  // is bounded by host mounts. A Worker `command` and an argv the caps do not
  // advertise stay in the Worker command table, so both use the real Worker
  // VFS roots. On channel/fetch, subprocess-xl resolves a path-form program to
  // its advertised bare identity before the Host dispatch, so the same
  // `isAccelerator` predicate the provider uses decides cwd ownership.
  const advertised = caps.accelerators ?? []
  const program = hasCommand ? undefined : argv[0] as string
  const hostAccelerator = program !== undefined
    && isAccelerator(program, { capabilities: { accelerators: advertised } })
  if (!hostAccelerator) {
    if (!insideAny(cwd, PHONE_SHELL_WORKER_VFS_ROOTS)) {
      throw invalid(`cwd ${JSON.stringify(cwd)} is outside the Worker VFS roots`)
    }
  } else if (caps.mounts === undefined) {
    // The ordered channel HELLO carries caps only. The trusted Native cwd
    // protocol uses the `/dsh/...` guest roots directly, so stay inside them
    // instead of inventing a host mount table.
    if (!insideAny(cwd, PHONE_SHELL_WORKER_VFS_ROOTS)) {
      throw invalid(`cwd ${JSON.stringify(cwd)} is outside the Worker VFS roots (host mounts are not published on this channel)`)
    }
  } else if (caps.mounts.length === 0) {
    // A real HELLO that explicitly published zero mounts cannot cover any
    // host cwd. Never fall back to the Worker roots or an implicit host `/`.
    throw invalid('the exec-bridge Host published no guest mount for this accelerator')
  } else if (!insideAny(cwd, caps.mounts.map(mount => mount.guestPath).filter(root => root !== ''))) {
    throw invalid(`cwd ${JSON.stringify(cwd)} is outside every host guest mount`)
  }

  const timeoutMs = parseConsoleTimeout(request.timeoutMs, PHONE_SHELL_DEFAULT_TIMEOUT_MS)
  const execId = request.execId ?? `phone-shell-${randomUUID()}`
  if (typeof execId !== 'string' || !EXEC_ID.test(execId)) {
    throw invalid('execId must match /^[A-Za-z0-9._-]{1,61}$/ (D6, leaving room for the -aN suffix)')
  }
  return { argv, cwd, timeoutMs, execId }
}

/** Host service backing the console; its methods are the `phone/shell*` Remote endpoints. */
export class PhoneShellRemote extends TypertRemoteService {
  static inject = ['subprocess', 'xlExecBridge']

  private readonly subprocess: SubprocessRuntime
  private readonly bridge: XlExecBridge
  private readonly running = new Map<string, RunningConsole>()

  /**
   * @param ctx - context already carrying the exec bridge and subprocess provider.
   */
  constructor(ctx: Context) {
    super(ctx, 'phoneShell', { namespace: 'phone' })
    this.subprocess = ctx.subprocess
    this.bridge = ctx.xlExecBridge
    ctx.effect(() => () => {
      for (const entry of this.running.values()) entry.handle.terminate()
      this.running.clear()
    }, 'phone-shell running console requests')
  }

  /**
   * Read the live host caps. No accelerator is synthesized when the host
   * advertises none; on a transport the console cannot route (`node-http` or
   * an unconfirmed value) no accelerator is advertised as usable and the
   * returned `terminal`/`pty` facts are always false.
   */
  caps(): PhoneShellCaps {
    const limits = this.limits()
    return capsFromHello(this.bridge.hello, limits, transportKindOf(this.bridge))
  }

  /**
   * Run one request through the shared subprocess provider.
   *
   * The transport gate is the first thing this method does: an unsupported
   * route is rejected before caps parsing, request normalization or `spawn`,
   * so no `node-http` request can ever become a Host process.
   * @param request - command or exact argv, cwd, deadline, and optional client exec id.
   * @param signal - Remote invocation cancellation.
   * @returns bounded output and the provider's exit facts.
   */
  async run(request: PhoneShellRunRequest, signal?: AbortSignal): Promise<PhoneShellRunResult> {
    const transport = assertConsoleTransport(transportKindOf(this.bridge))
    const caps = this.caps()
    const normalized = normalizeConsoleRequest(request, caps, transport)
    if (this.running.has(normalized.execId)) {
      throw invalid(`execId ${JSON.stringify(normalized.execId)} is already running`)
    }
    signal?.throwIfAborted()
    const collectorBytes = caps.limits.maxOutputBytes + COLLECTOR_HEADROOM_BYTES
    const spec: XlSpawnSpec = {
      argv: normalized.argv,
      cwd: normalized.cwd,
      // The short grace bounds a provider-side cancel/force settlement. It is
      // deliberately not the execution deadline: the host EXEC_REQ gets the
      // requested timeout so a slow but legal accelerator is not cut off at 1 s.
      graceMs: Math.min(1_000, normalized.timeoutMs),
      stdio: {
        stdin: 'ignore',
        stdout: { maxBytes: collectorBytes },
        stderr: { maxBytes: collectorBytes },
      },
      timeoutMs: normalized.timeoutMs,
      // Trusted out-of-band identity: a console run is not inside a model tool
      // call, and a shell variable must never choose the host exec_id/idem_key.
      idempotencyKey: normalized.execId,
    }
    const handle = this.subprocess.spawn(spec)
    const forced = Promise.withResolvers<'timeout' | 'cancelled'>()
    let stopReason: 'timeout' | 'cancelled' | undefined
    let forceTimer: ReturnType<typeof setTimeout> | undefined
    const entry: RunningConsole = {
      handle,
      started: Date.now(),
      timedOut: false,
      cancelled: false,
      stop: () => {},
    }
    entry.stop = (reason): void => {
      if (stopReason !== undefined) return
      stopReason = reason
      if (reason === 'timeout') entry.timedOut = true
      else entry.cancelled = true
      // Terminate first; the hard settlement below only bounds a provider
      // (host accelerator, stalled EXEC_EVT stream) that ignores cancel.
      try { entry.handle.terminate() } catch {}
      forceTimer = setTimeout(() => { forced.resolve(reason) }, DEADLINE_FORCE_GRACE_MS)
    }
    this.running.set(normalized.execId, entry)

    const deadline = setTimeout(() => { entry.stop('timeout') }, normalized.timeoutMs)
    const onAbort = (): void => { entry.stop('cancelled') }
    signal?.addEventListener('abort', onAbort, { once: true })
    if (signal?.aborted === true) entry.stop('cancelled')

    // The provider's `done` settles at the exit event; `waitForExit` waits for
    // quiescence. Either can stall, so the whole pair races the hard settlement.
    const settled = (async (): Promise<
      { readonly kind: 'settled'; readonly outcome: SubprocessOutcome }
      | { readonly kind: 'failed'; readonly error: unknown }
    > => {
      try {
        const outcome = await handle.done
        await handle.waitForExit()
        return { kind: 'settled', outcome }
      } catch (error) {
        return { kind: 'failed', error }
      }
    })()

    let outcome: SubprocessOutcome
    try {
      const winner = await Promise.race([
        settled,
        forced.promise.then(reason => ({ kind: 'forced' as const, reason })),
      ])
      if (winner.kind === 'failed') {
        if (stopReason === undefined) {
          throw new RemoteError('phone-shell/execution-failed', String(winner.error), { execId: normalized.execId })
        }
        outcome = stopReason === 'timeout'
          ? { exitCode: 124, signal: null }
          : { exitCode: null, signal: 'SIGTERM' }
      } else if (winner.kind === 'forced') {
        outcome = winner.reason === 'timeout'
          ? { exitCode: 124, signal: null }
          : { exitCode: null, signal: 'SIGTERM' }
      } else {
        outcome = winner.outcome
      }
      const out = readCollected(handle.collected.stdout)
      const err = readCollected(handle.collected.stderr)
      // The provider owns the deadline and may settle at the same instant the
      // console's classification timer would fire; a conventional 124 that
      // settled at or after the bound is the same timeout, whichever callback
      // won the race.
      const timedOut = stopReason === 'timeout'
        || (stopReason === undefined && Date.now() - entry.started >= normalized.timeoutMs && outcome.exitCode === 124 && outcome.signal === null)
      return {
        execId: normalized.execId,
        argv: normalized.argv,
        cwd: normalized.cwd,
        stdout: out.text,
        stderr: err.text,
        exitCode: timedOut ? 124 : outcome.exitCode,
        signal: timedOut ? null : outcome.signal,
        timedOut,
        cancelled: stopReason === 'cancelled' && !timedOut,
        truncated: out.truncated || err.truncated || shellOutputWasTruncated(err.text),
        durationMs: Date.now() - entry.started,
      }
    } finally {
      clearTimeout(deadline)
      if (forceTimer !== undefined) clearTimeout(forceTimer)
      signal?.removeEventListener('abort', onAbort)
      // A forced return never reads the provider again; terminate and release
      // its stream so an ignored cancel cannot leave the handle attached.
      if (stopReason !== undefined) {
        try { entry.handle.terminate() } catch {}
        const close = (entry.handle as { close?: () => void }).close
        if (typeof close === 'function') {
          try { close.call(entry.handle) } catch {}
        }
      }
      this.running.delete(normalized.execId)
    }
  }

  /**
   * Terminate one running console request.
   * @param execId - client-generated identity passed to `run`.
   * @returns true when a live request was found and terminated.
   */
  cancel(execId: string): boolean {
    if (typeof execId !== 'string' || !EXEC_ID.test(execId)) throw invalid('execId is invalid')
    const entry = this.running.get(execId)
    if (entry === undefined) return false
    entry.stop('cancelled')
    return true
  }

  private limits(): PhoneShellLimits {
    const shellTimeout = shellTimeoutFromEnv(process.env)
    return {
      timeoutMs: Math.min(shellTimeout, PHONE_SHELL_MAX_TIMEOUT_MS),
      maxTimeoutMs: PHONE_SHELL_MAX_TIMEOUT_MS,
      maxOutputBytes: maxOutputBytesFromEnv(process.env),
      maxCommandBytes: PHONE_SHELL_MAX_COMMAND_BYTES,
      maxArgv: PHONE_SHELL_MAX_ARGV,
    }
  }
}

/**
 * Read the live transport kind without trusting its static type: a missing or
 * malformed value is `undefined`, which {@link assertConsoleTransport} rejects.
 * @param bridge - the injected exec bridge.
 * @returns the runtime transport kind, or undefined when it cannot be read.
 */
function transportKindOf(bridge: XlExecBridge): ExecTransportKind | undefined {
  const kind: unknown = (bridge.transport as { readonly kind?: unknown } | undefined)?.kind
  return typeof kind === 'string' ? kind as ExecTransportKind : undefined
}

function insideAny(cwd: string, roots: readonly string[]): boolean {
  return roots.some(root => {
    if (root === '/') return true
    const base = root.endsWith('/') ? root.slice(0, -1) : root
    return cwd === base || cwd.startsWith(`${base}/`)
  })
}

function invalid(reason: string): RemoteError {
  return new RemoteError('phone-shell/invalid-request', reason, { reason })
}

function readCollected(reader: SubprocessCollectedOutputs['stdout']): { text: string; truncated: boolean } {
  if (reader === undefined) return { text: '', truncated: false }
  const read = reader.readFrom(0)
  return { text: read.text, truncated: read.lossy }
}

/** The Worker shell's class-contract trailer is the authoritative cut marker. */
function shellOutputWasTruncated(stderr: string): boolean {
  return stderr.split('\n').some(line => /^pdsh-shell: exit=\d+ program=\S+ reason=output-truncated(?: hint=.*)?$/u.test(line))
}

/**
 * Register the console service in the host composition.
 * @param ctx - host context.
 */
export function apply(ctx: Context): void {
  ctx.plugin(PhoneShellRemote)
}

export default PhoneShellRemote

// Node's built-in TypeScript stripping cannot parse decorator syntax, so the
// standard DSH markers are applied with the same explicit decorator call the
// phone surface already uses. Typert reads the resulting prototype markers.
function markRemoteMethod(
  name: 'caps' | 'run' | 'cancel',
  exportName: string,
): void {
  const descriptor = Object.getOwnPropertyDescriptor(PhoneShellRemote.prototype, name)
  if (typeof descriptor?.value !== 'function') throw new TypeError(`phone-shell remote method is missing: ${name}`)
  let initializer: ((this: PhoneShellRemote) => void) | undefined
  const context = {
    name,
    private: false,
    static: false,
    addInitializer(fn: (this: PhoneShellRemote) => void) { initializer = fn },
  } as ClassMethodDecoratorContext<PhoneShellRemote, (this: PhoneShellRemote, ...args: unknown[]) => unknown>
  const applyMarker = Remote({ name: exportName }) as unknown as (
    method: unknown,
    decoratorContext: unknown,
  ) => void
  applyMarker(descriptor.value, context)
  if (initializer === undefined) throw new TypeError(`phone-shell Remote decorator did not initialize: ${name}`)
  initializer.call(Object.create(PhoneShellRemote.prototype) as PhoneShellRemote)
}

markRemoteMethod('caps', 'shellCaps')
markRemoteMethod('run', 'shellRun')
markRemoteMethod('cancel', 'shellCancel')
