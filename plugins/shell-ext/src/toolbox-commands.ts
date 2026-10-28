// SPDX-License-Identifier: MIT
/**
 * The WASI toolbox's programs, exposed to just-bash (`PLAN` D12).
 *
 * The toolbox already owns the routing table: `WasiToolbox.run()` picks the
 * program, attaches the VFS proxy and streams stdout/stderr. This module is the
 * only bridge between that table and the Worker shell — one just-bash command
 * per registered program and alias, whose whole body is a `toolbox.run()` call.
 * There is no second implementation of `python3` or any other WASI program in
 * the shell.
 *
 * The shell works with host VFS paths (`/dsh/workspace/...`) and byte strings;
 * the toolbox works with guest paths (`/workspace/...`) and byte arrays. The
 * adapter maps the cwd through the toolbox preopens and converts the streams,
 * so the guest sees the directory the shell is in.
 * @module @phone-dsh/dsh-shell-ext/toolbox-commands
 */

import { defineCommand } from 'just-bash/browser'
import type { Command } from 'just-bash/browser'
import type { WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import type { OutputAccounting, StreamTruncation } from './output.ts'
import { shellFailure, withCommandExit, withShellTrailer } from './contract.ts'
import { byteStringOutput, byteStringToBytes, bytesToByteString, concatBytes, decodeUtf8, encodeUtf8 } from './encoding.ts'
import { DEFAULT_MAX_OUTPUT_BYTES, truncationMarker, withOutputAccounting } from './output.ts'
import { BoundedByteStream, engineStreamLimit } from './stream-budget.ts'

/**
 * Aliases the Worker declares at the toolbox registration boundary.
 *
 * The tombstoned `python` name is the one a model reaches for first; the
 * toolbox registers the interpreter as `python3`, so `python` must be the same
 * command rather than a 127. Declaring it here keeps the alias next to the
 * program registration instead of adding a second implementation.
 */
const TOOLBOX_ALIASES: Readonly<Record<string, readonly string[]>> = Object.freeze({
  python3: Object.freeze(['python']),
})

/**
 * Program name the jq WASI engine registers on the toolbox.
 *
 * The shell also exposes it directly as `jq-wasi` (and its `jaq` alias); those
 * direct commands use the same per-stream safety ceiling as the `jq` command,
 * so the engine cannot bypass the bound through the toolbox command table.
 */
export const JQ_ENGINE_PROGRAM = 'jq-wasi'

/** Every shell name one toolbox program is registered under. */
export function toolboxCommandNames(summary: { readonly program: string; readonly aliases?: readonly string[] | undefined }): string[] {
  const names = [summary.program, ...summary.aliases ?? []]
  for (const alias of TOOLBOX_ALIASES[summary.program] ?? []) {
    if (!names.includes(alias)) names.push(alias)
  }
  return names
}

/**
 * Translate a Worker VFS cwd into the toolbox guest namespace.
 *
 * The longest matching preopen wins, so `/workspace` is chosen over `/` when
 * both are mapped. A cwd the shell already spells in the guest namespace is
 * passed through: `cd /tmp` keeps the virtual `/tmp` spelling even though the
 * Worker filesystem resolves it to the host `/dsh/tmp` root (PLAN D4/D15), and
 * the toolbox preopen table maps that same `/tmp` guest root. Anything else
 * outside every preopen returns undefined, which leaves the program's
 * configured default cwd in place — the shell never invents a guest path the
 * host did not map.
 * @param toolbox - toolbox whose preopens describe the mapping.
 * @param hostCwd - absolute Worker VFS directory (or a guest-spelled cwd).
 * @returns the guest path, or undefined when no preopen covers the cwd.
 */
export function guestCwdFor(toolbox: WorkerToolbox, hostCwd: string): string | undefined {
  const preopens = toolbox.preopenTable ?? []
  let best: { readonly hostPath: string; readonly guestPath: string } | undefined
  for (const preopen of preopens) {
    const hostPath = preopen.hostPath.replace(/\/+$/, '') || '/'
    const covered = hostPath === '/' ? hostCwd.startsWith('/') : hostCwd === hostPath || hostCwd.startsWith(`${hostPath}/`)
    if (!covered) continue
    if (best === undefined || hostPath.length > best.hostPath.length) best = { hostPath, guestPath: preopen.guestPath }
  }
  if (best === undefined) {
    for (const preopen of preopens) {
      const guestPath = preopen.guestPath.replace(/\/+$/, '') || '/'
      // A guest root preopen maps every guest path; it cannot tell whether an
      // uncovered host cwd is already a guest spelling, so it is no evidence.
      if (guestPath === '/') continue
      if (hostCwd === guestPath || hostCwd.startsWith(`${guestPath}/`)) return hostCwd
    }
    return undefined
  }
  const rest = hostCwd.slice(best.hostPath.length)
  const guest = `${best.guestPath.replace(/\/+$/, '')}${rest}`
  return guest === '' ? '/' : guest
}

/**
 * One fixed-size collector for a toolbox program's stream.
 *
 * `createToolboxCommands` is also the command a nested `bash -c 'python3 ...'`
 * reaches. A program can write far more than the shell's visible cap — and the
 * engine only accounts the command result after `toolbox.run()` returns — so
 * retaining every callback chunk before concatenating would let one command
 * exhaust the Worker heap. The collector reserves a fixed head and tail within
 * the per-stream cap and drops only the middle, keeping the total retained
 * bytes bounded even under a runtime that ignores cancellation.
 *
 * A truncated stream carries the usual head/tail marker with the exact number
 * of elided bytes, so the shell's normal output discipline sees an over-limit
 * stream, reports `stdout_truncated`/`stderr_truncated` and refuses to present
 * the partial page as a clean success.
 *
 * `limit` is the shell's actual visible cap, marker included. The payload is
 * trimmed so head + marker + tail never exceeds it; the shell's later
 * `boundOutput` pass is then a no-op and cannot shorten the marker's numbers.
 */
class BoundedChunkCollector {
  private readonly limit: number
  private readonly tailLimit: number
  private readonly head: Uint8Array
  private readonly tail: Uint8Array
  private headBytes: number
  private tailStart: number
  private tailBytes: number
  private bytes: number
  private result: Uint8Array | undefined
  private droppedBytes: number
  private markerBytes: number

  /** @param limit - maximum visible bytes for this stream, truncation marker included. */
  constructor(limit = DEFAULT_MAX_OUTPUT_BYTES) {
    this.limit = Number.isFinite(limit) && limit > 0
      ? Math.max(1, Math.floor(limit))
      : DEFAULT_MAX_OUTPUT_BYTES
    const head = Math.max(1, Math.floor(this.limit * 0.6))
    this.tailLimit = Math.max(0, this.limit - head)
    this.head = new Uint8Array(head)
    this.headBytes = 0
    this.tail = new Uint8Array(this.tailLimit)
    this.tailStart = 0
    this.tailBytes = 0
    this.bytes = 0
    this.result = undefined
    this.droppedBytes = 0
    this.markerBytes = 0
  }

  /** @param chunk - one toolbox callback chunk. */
  push(chunk: Uint8Array): void {
    const bytes = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk)
    this.bytes += bytes.byteLength
    let offset = 0
    if (this.headBytes < this.head.byteLength) {
      const take = Math.min(this.head.byteLength - this.headBytes, bytes.byteLength)
      if (take > 0) {
        this.head.set(bytes.subarray(0, take), this.headBytes)
        this.headBytes += take
        offset += take
      }
    }
    if (offset < bytes.byteLength) this.appendTail(bytes.subarray(offset))
  }

  /** Keep the newest `tailLimit` bytes without growing with the stream. */
  appendTail(bytes: Uint8Array): void {
    if (this.tailLimit === 0 || bytes.byteLength === 0) return
    if (bytes.byteLength >= this.tailLimit) {
      this.tail.set(bytes.subarray(bytes.byteLength - this.tailLimit))
      this.tailStart = 0
      this.tailBytes = this.tailLimit
      return
    }
    const overflow = this.tailBytes + bytes.byteLength - this.tailLimit
    if (overflow > 0) {
      this.tailStart = (this.tailStart + overflow) % this.tailLimit
      this.tailBytes -= overflow
    }
    const write = (this.tailStart + this.tailBytes) % this.tailLimit
    const first = Math.min(bytes.byteLength, this.tailLimit - write)
    this.tail.set(bytes.subarray(0, first), write)
    if (first < bytes.byteLength) this.tail.set(bytes.subarray(first), 0)
    this.tailBytes += bytes.byteLength
  }

  /** The tail in stream order, as at most two contiguous slices. */
  tailSlices(): Uint8Array[] {
    if (this.tailBytes === 0) return []
    if (this.tailBytes < this.tailLimit) {
      return [this.tail.subarray(this.tailStart, this.tailStart + this.tailBytes)]
    }
    return [this.tail.subarray(this.tailStart), this.tail.subarray(0, this.tailStart)]
  }

  /** The newest `count` bytes of the tail, in stream order. */
  tailLast(count: number): Uint8Array[] {
    if (count <= 0 || this.tailBytes === 0) return []
    if (count >= this.tailBytes) return this.tailSlices()
    let skip = this.tailBytes - count
    const slices: Uint8Array[] = []
    for (const slice of this.tailSlices()) {
      if (skip >= slice.byteLength) {
        skip -= slice.byteLength
        continue
      }
      slices.push(slice.subarray(skip))
      skip = 0
    }
    return slices
  }

  /**
   * Take at most `budget` retained bytes, keeping a proportional head and the
   * newest tail. The returned payload length is `head + tail`.
   */
  retainedWithin(budget: number): { head: Uint8Array, tail: Uint8Array[], count: number } {
    const retained = this.headBytes + this.tailBytes
    if (budget >= retained) {
      return {
        head: this.head.subarray(0, this.headBytes),
        tail: this.tailSlices(),
        count: retained,
      }
    }
    if (budget <= 0) return { head: this.head.subarray(0, 0), tail: [], count: 0 }
    let headTake = Math.min(this.headBytes, Math.floor((budget * this.headBytes) / retained))
    if (this.headBytes > 0 && headTake === 0) headTake = 1
    let tailTake = Math.min(this.tailBytes, budget - headTake)
    let spare = budget - headTake - tailTake
    if (spare > 0) {
      const extraHead = Math.min(this.headBytes - headTake, spare)
      headTake += extraHead
      spare -= extraHead
    }
    if (spare > 0) tailTake = Math.min(this.tailBytes, tailTake + spare)
    return {
      head: this.head.subarray(0, headTake),
      tail: this.tailLast(tailTake),
      count: headTake + tailTake,
    }
  }

  /** The bounded bytes plus the truncation marker, if any. */
  finish(): Uint8Array {
    if (this.result !== undefined) return this.result
    const retained = this.headBytes + this.tailBytes
    if (this.bytes <= retained) {
      const full = concatBytes([this.head.subarray(0, this.headBytes), ...this.tailSlices()])
      if (full.byteLength <= this.limit) {
        this.result = full
        this.droppedBytes = 0
        this.markerBytes = 0
        return this.result
      }
    }
    // Leave room for the marker inside the visible cap. The exact marker text
    // depends on the dropped/total numbers, whose widths change as the payload
    // shrinks; iterate rather than assuming one fixed reserve.
    let budget = this.limit
    let lastMarker: Uint8Array | undefined
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const chosen = this.retainedWithin(budget)
      const dropped = this.bytes - chosen.count
      const marker = encodeUtf8(truncationMarker(dropped, this.bytes))
      lastMarker = marker
      if (chosen.count + marker.byteLength <= this.limit) {
        this.result = concatBytes([chosen.head, marker, ...chosen.tail])
        this.droppedBytes = dropped
        this.markerBytes = marker.byteLength
        return this.result
      }
      const over = chosen.count + marker.byteLength - this.limit
      if (budget === 0) break
      budget = Math.max(0, budget - over)
    }
    // A cap too small to hold even the marker cannot describe the stream
    // truthfully; it still must not exceed the cap or retain unbounded data.
    if (lastMarker !== undefined && lastMarker.byteLength <= this.limit) {
      this.result = lastMarker
    } else {
      const marker = lastMarker ?? encodeUtf8(truncationMarker(this.bytes, this.bytes))
      this.result = marker.subarray(0, this.limit)
    }
    this.droppedBytes = this.bytes
    this.markerBytes = this.result.byteLength
    return this.result
  }

  /**
   * The producer-owned truncation facts for this stream, if it was cut.
   * @returns dropped bytes and the marker's own bytes, or undefined.
   */
  truncation(): StreamTruncation | undefined {
    this.finish()
    return this.droppedBytes === 0
      ? undefined
      : { dropped: this.droppedBytes, markerBytes: this.markerBytes }
  }
}

/** Setter a shell uses to bind a toolbox command to its real output cap. */
export interface ToolboxOutputLimit {
  set(limit: number): void
}

interface ToolboxOutputLimitState extends ToolboxOutputLimit {
  value: number
}

/**
 * Hidden per-command hook that lets a {@link WorkerShell} pass its actual
 * `maxOutputBytes` to collectors created by `createWorkerCommands`, without
 * changing that table's public options. A shell with a configured cap above
 * the default therefore cannot silently keep the old 256 KiB collector and
 * report a clean, untruncated success.
 */
export const TOOLBOX_OUTPUT_LIMIT: unique symbol = Symbol('phone-dsh.toolbox-output-limit')

/** Environment one just-bash context exports. */
function shellEnvironment(context: {
  readonly env?: ReadonlyMap<string, string> | Readonly<Record<string, string>>
  readonly exportedEnv?: Readonly<Record<string, string>>
}): Record<string, string> {
  if (context.exportedEnv !== undefined) return { ...context.exportedEnv }
  const env = context.env
  if (env === undefined) return {}
  if (typeof (env as ReadonlyMap<string, string>).get === 'function') {
    return Object.fromEntries(env as ReadonlyMap<string, string>)
  }
  return { ...(env as Readonly<Record<string, string>>) }
}

/**
 * Build the just-bash commands for every program in a toolbox.
 * @param toolbox - the toolbox to dispatch to; usually `getWorkerToolbox()`.
 * @param options - optional initial output cap; a `WorkerShell` overwrites it
 *   with its real `maxOutputBytes` through {@link TOOLBOX_OUTPUT_LIMIT}.
 * @returns one command per program and alias.
 */
export function createToolboxCommands(
  toolbox: WorkerToolbox,
  options: { readonly maxOutputBytes?: number | undefined } = {},
): Command[] {
  const commands: Command[] = []
  const initialLimit = options.maxOutputBytes ?? DEFAULT_MAX_OUTPUT_BYTES
  for (const summary of toolbox.list()) {
    const jqEngine = summary.program === JQ_ENGINE_PROGRAM
      || summary.program === 'jaq'
      || summary.aliases?.includes(JQ_ENGINE_PROGRAM) === true
    for (const name of toolboxCommandNames(summary)) {
      const limit: ToolboxOutputLimitState = {
        value: initialLimit,
        set(next) {
          this.value = Number.isFinite(next) && next > 0
            ? Math.max(1, Math.floor(next))
            : DEFAULT_MAX_OUTPUT_BYTES
        },
      }
      const command = defineCommand(name, async (args, ctx) => {
        const cwd = guestCwdFor(toolbox, ctx.cwd)
        const env = shellEnvironment(ctx)
        // `ctx.stdin` is just-bash's ByteString: heredoc text, pipeline bytes
        // and `stdio.stdin` data all reach the interpreter as the exact same
        // bytes. An empty string is a delivered empty stream (EOF), not
        // "absent stdin", so a script that drains stdin still terminates.
        const stdin = typeof ctx.stdin === 'string' ? byteStringToBytes(ctx.stdin) : undefined
        // stdout is a byte stream (a Python program may print arbitrary bytes)
        // and keeps its byte shape through the pipeline/redirection layers.
        // stderr is text to just-bash, so decode it exactly once here — the
        // engine's `2>` writer picks UTF-8 for non-ASCII text and therefore
        // stores the bytes the program wrote (G2-FIX-43).
        const stdout = new BoundedChunkCollector(limit.value)
        const stderr = new BoundedChunkCollector(limit.value)
        // The collector owns the only trustworthy byte facts for this command.
        // They travel on the result object as a symbol, never as marker text:
        // user output that happens to look like a marker cannot claim them.
        const outputAccounting = (): OutputAccounting | undefined => {
          const out = stdout.truncation()
          const err = stderr.truncation()
          return out === undefined && err === undefined
            ? undefined
            : {
                ...out === undefined ? {} : { stdout: out },
                ...err === undefined ? {} : { stderr: err },
              }
        }
        if (cwd !== undefined) env.PWD = cwd
        // A jq engine is a general-purpose output generator; a direct
        // `jq-wasi`/`jaq` invocation must not bypass the ceiling the `jq`
        // command applies. Other toolbox programs keep their historical
        // streaming shape.
        const streamLimit = jqEngine ? engineStreamLimit() : undefined
        const outBudget = streamLimit === undefined ? undefined : new BoundedByteStream(streamLimit)
        const errBudget = streamLimit === undefined ? undefined : new BoundedByteStream(streamLimit)
        const controller = streamLimit === undefined ? undefined : new AbortController()
        const external = ctx.signal
        const relayAbort = (): void => { controller?.abort(external?.reason) }
        if (controller !== undefined) {
          if (external?.aborted === true) relayAbort()
          else external?.addEventListener('abort', relayAbort, { once: true })
        }
        const stopForLimit = (): void => {
          if (controller !== undefined && !controller.signal.aborted) {
            controller.abort(new Error(
              `${name}: ${JQ_ENGINE_PROGRAM} exceeded its ${String(streamLimit)}-byte stream cap`,
            ))
          }
        }
        const collect = (budget: BoundedByteStream | undefined, chunk: Uint8Array): void => {
          if (budget !== undefined && budget.push(chunk)) stopForLimit()
        }
        try {
          const result = await toolbox.run({
            program: summary.program,
            argv: [...args],
            env,
            ...cwd === undefined ? {} : { cwd },
            ...stdin === undefined ? {} : { stdin },
            ...controller !== undefined
              ? { signal: controller.signal }
              : ctx.signal === undefined ? {} : { signal: ctx.signal },
            ...streamLimit === undefined ? {} : { maxStdoutBytes: streamLimit, maxStderrBytes: streamLimit },
            onStdout: chunk => {
              stdout.push(chunk)
              collect(outBudget, chunk)
            },
            onStderr: chunk => {
              stderr.push(chunk)
              collect(errBudget, chunk)
            },
          })
          const overflow = streamLimit !== undefined
            && (result.failureCode === 'E_OUTPUT_LIMIT'
              || outBudget?.truncated === true
              || errBudget?.truncated === true)
          let stderrText = decodeUtf8(stderr.finish())
          if (overflow) {
            const which = result.stdoutTruncated === true || outBudget?.truncated === true
              ? 'stdout'
              : 'stderr'
            // The toolbox counts guest-produced bytes; the host cap
            // diagnostic is not part of either counter.
            const produced = which === 'stdout' ? result.stdoutBytes ?? 0 : result.stderrBytes ?? 0
            stderrText += `${name}: ${which} exceeded the ${String(streamLimit)}-byte stream cap `
              + `(${String(produced)} bytes produced); the WASI engine was stopped [E_OUTPUT_LIMIT]\n`
          }
          const output = {
            ...byteStringOutput(bytesToByteString(stdout.finish())),
            stderr: stderrText,
            exitCode: overflow ? 1 : result.exitCode,
          }
          // A guest that explained its own non-zero status keeps its stderr
          // byte for byte; a bare non-zero status (the silent-failure shape)
          // gets the contract trailer. The bridge's own throw is handled below.
          return withOutputAccounting(
            result.exitCode === 0 || overflow || output.stderr !== ''
              ? output
              : withCommandExit(output, name),
            outputAccounting(),
          )
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error)
          const partialStderr = decodeUtf8(stderr.finish())
          if (streamLimit !== undefined && (outBudget?.truncated === true || errBudget?.truncated === true)) {
            const which = outBudget?.truncated === true ? 'stdout' : 'stderr'
            const produced = which === 'stdout' ? outBudget?.produced ?? 0 : errBudget?.produced ?? 0
            return withOutputAccounting({
              ...byteStringOutput(bytesToByteString(stdout.finish())),
              stderr: `${partialStderr}${name}: ${which} exceeded the ${String(streamLimit)}-byte stream cap `
                + `(${String(produced)} bytes produced); the WASI engine was stopped [E_OUTPUT_LIMIT]\n`,
              exitCode: 1,
            }, outputAccounting())
          }
          const failure = shellFailure(name, `${partialStderr}${name}: ${message}`, 'backend-failed')
          // Partial stdout is still the guest's raw bytes: keep its shape so a
          // failure after some output does not re-encode what was printed.
          return withOutputAccounting(
            { ...failure, ...byteStringOutput(bytesToByteString(stdout.finish())) },
            outputAccounting(),
          )
        } finally {
          if (controller !== undefined) external?.removeEventListener('abort', relayAbort)
        }
      })
      commands.push(Object.assign(command, { [TOOLBOX_OUTPUT_LIMIT]: limit }))
    }
  }
  return commands
}
