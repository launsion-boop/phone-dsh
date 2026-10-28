// SPDX-License-Identifier: MIT
/**
 * The phone-shell contract shared by the Host Remote and the Web console.
 *
 * The Host service lives under the existing `phone` Remote namespace, beside
 * the phone management methods, and exposes three endpoints:
 *
 * - `phone/shellCaps` reads the live exec-bridge `hello` (the host's real
 *   xz-shell accelerators and mounts) and never invents a command.
 * - `phone/shellRun` runs one console request through `ctx.subprocess` on the
 *   Worker channel/fetch transports; `node-http` is rejected before spawn.
 * - `phone/shellCancel` cancels the request whose client-generated `execId`
 *   is named.
 *
 * The console is a command console, not a PTY. `command` runs through
 * `bash -c` in the Worker's just-bash/VFS world; `argv` keeps its exact
 * argument vector and reaches a Host xz-shell accelerator only when the host
 * advertised that name in the exec-bridge `hello`.
 * @module @phone-dsh/dsh-phone-shell/contract
 */

/** Remote namespace that owns the console methods (beside `phone/createSchedule`). */
export const PHONE_SHELL_NAMESPACE = 'phone'

/** Wire endpoints of the three console methods. */
export const PHONE_SHELL_ENDPOINTS = Object.freeze({
  caps: `${PHONE_SHELL_NAMESPACE}/shellCaps`,
  run: `${PHONE_SHELL_NAMESPACE}/shellRun`,
  cancel: `${PHONE_SHELL_NAMESPACE}/shellCancel`,
} as const)

/** Right-Sidebar tab kind this package owns. */
export const PHONE_SHELL_TAB_KIND = 'phone-shell'

/** Right-Sidebar implementation id; also the key of the body and chip slots. */
export const PHONE_SHELL_TAB_ID = '@phone-dsh/dsh-phone-shell'

/** Locale namespace owned by the client half. */
export const PHONE_SHELL_LOCALE_NS = 'phone-shell'

/** Default working directory for a console request. */
export const PHONE_SHELL_DEFAULT_CWD = '/dsh/workspace'

/**
 * The Worker VFS roots a console can prove it owns. `command` runs in the
 * Worker's just-bash over the VFS, so its cwd is validated against these real
 * roots rather than against host mounts (which the ordered channel does not
 * publish).
 */
export const PHONE_SHELL_WORKER_VFS_ROOTS = Object.freeze(['/dsh/workspace', '/dsh/home'] as const)

/** Default wall-clock bound for one console request. */
export const PHONE_SHELL_DEFAULT_TIMEOUT_MS = 30_000

/** Largest wall-clock bound a console request may ask for. */
export const PHONE_SHELL_MAX_TIMEOUT_MS = 120_000

/** Default per-stream byte cap the console asks the collector to retain. */
export const PHONE_SHELL_DEFAULT_MAX_OUTPUT_BYTES = 256 * 1024

/** Largest `command` string accepted by the console. */
export const PHONE_SHELL_MAX_COMMAND_BYTES = 64 * 1024

/** Largest number of `argv` entries accepted by the console. */
export const PHONE_SHELL_MAX_ARGV = 256

/** A mount the exec-bridge Host reported in its hello. */
export interface PhoneShellMount {
  readonly hostPath: string
  readonly guestPath: string
  readonly readOnly: boolean
}

/**
 * Bounds the console itself applies to one request (its local Web/Worker
 * policy). These are not the host provider's `hello.limits`.
 */
export interface PhoneShellLimits {
  readonly timeoutMs: number
  readonly maxTimeoutMs: number
  readonly maxOutputBytes: number
  readonly maxCommandBytes: number
  readonly maxArgv: number
}

/**
 * The host provider's advertised limits, present only when the live HELLO
 * actually carried them. The ordered channel HELLO does not, so the field is
 * omitted instead of mirroring local Worker env values.
 */
export interface PhoneShellHostLimits {
  readonly maxConcurrent?: number
  readonly maxOutputBytesPerStream?: number
  readonly maxRequestBytes?: number
  readonly retentionSeconds?: number
}

/**
 * The real host capability facts behind the console.
 *
 * `linked` is true only when the live transport can serve the console
 * (`channel`/`fetch`) and the host advertised at least one accelerator in the
 * exec-bridge hello. An empty list means xz-shell is not linked (or not
 * configured), or the transport is unsupported; the console shows that state
 * and offers no accelerator name.
 */
export interface PhoneShellCaps {
  readonly linked: boolean
  /**
   * True only on the Worker `channel`/`fetch` transports. `node-http` and any
   * unconfirmed route fail closed: the Host would execute every request, so
   * this console cannot run there.
   */
  readonly transportSupported: boolean
  /** Real host provider identity; omitted when the live HELLO has no such fact. */
  readonly provider?: string
  readonly version?: string
  /** Real host-advertised accelerators (the only routing caps the channel carries). */
  readonly accelerators: readonly string[]
  /**
   * Real host guest mounts; omitted when the HELLO does not publish mounts
   * (the ordered channel carries caps only). Never a synthetic `/` mount.
   */
  readonly mounts?: readonly PhoneShellMount[]
  /** Local console limits; always present because the console enforces them. */
  readonly limits: PhoneShellLimits
  /** Host-advertised limits; omitted when the HELLO did not carry them. */
  readonly hostLimits?: PhoneShellHostLimits
  /** Which HELLO shape produced the facts, for honest UI wording. */
  readonly factsSource: 'exec-bridge-hello' | 'channel-caps'
  /** The console executes Worker commands on this shell core. */
  readonly shell: 'just-bash'
  /** The Host accelerator set is read-only by construction. */
  readonly readOnlyAccelerators: true
  /** This surface is not a terminal: no PTY, no terminal emulation, no session protocol. */
  readonly terminal: false
  readonly pty: false
  /** Honest one-line status for clients that do not render the structured facts. */
  readonly note: string
}

/** One console request. Exactly one of `command` and `argv` must be present. */
export interface PhoneShellRunRequest {
  /** Shell source for `bash -c` in the Worker just-bash/VFS. */
  readonly command?: string
  /** Exact argument vector; a Host-advertised `argv[0]` runs on xz-shell. */
  readonly argv?: readonly string[]
  /** Absolute guest working directory; defaults to {@link PHONE_SHELL_DEFAULT_CWD}. */
  readonly cwd?: string
  /** Wall-clock bound; must be a positive integer no greater than {@link PHONE_SHELL_MAX_TIMEOUT_MS}. */
  readonly timeoutMs?: number
  /**
   * Client-generated execution identity, so the console can cancel the run it
   * started. D6 grammar `^[A-Za-z0-9._-]{1,64}$`; this surface caps it at 61
   * characters so the accelerator command path can append its `-aN` suffix.
   * Omit for a generated random id. A running id is never reused.
   */
  readonly execId?: string
}

/** The result of one console request. */
export interface PhoneShellRunResult {
  readonly execId: string
  readonly argv: readonly string[]
  readonly cwd: string
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number | null
  readonly signal: string | null
  /** The console's wall-clock bound expired; `exitCode` is the conventional 124. */
  readonly timedOut: boolean
  /** The client cancelled the run through `phone/shellCancel`. */
  readonly cancelled: boolean
  /** The retained stream was cut by the console/Host output cap. */
  readonly truncated: boolean
  readonly durationMs: number
}

/** Remote failure codes this package can produce. */
export type PhoneShellFailureCode = 'phone-shell/invalid-request' | 'phone-shell/execution-failed'

/** One successful or failed raw Remote result, as the Connection carrier returns it. */
export type PhoneShellRpcResult =
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly error: { readonly code: string; readonly message: string; readonly details?: unknown } }

/** The slice of `ctx.connection.rpc` the client half needs. */
export interface PhoneShellRpc {
  call(channel: string, endpoint: string, payload: unknown, signal?: AbortSignal): Promise<PhoneShellRpcResult>
}

/** Split the console's newline-delimited accelerator arguments without shell parsing. */
export function splitAcceleratorArguments(text: string): string[] {
  return text.split(/\r?\n/u).filter(line => line.length > 0)
}

/**
 * Parse one console request's optional timeout.
 * @param value - raw input from a form field or a request.
 * @param fallback - value used when the request omits the field.
 * @returns a positive integer no greater than {@link PHONE_SHELL_MAX_TIMEOUT_MS}.
 * @throws TypeError when the value is not a positive integer in range.
 */
export function parseConsoleTimeout(value: unknown, fallback: number): number {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value) || !Number.isInteger(value) || value <= 0) {
    throw new TypeError('timeoutMs must be a positive integer')
  }
  if (value > PHONE_SHELL_MAX_TIMEOUT_MS) {
    throw new TypeError(`timeoutMs must not exceed ${String(PHONE_SHELL_MAX_TIMEOUT_MS)} ms`)
  }
  return value
}
