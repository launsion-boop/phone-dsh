// SPDX-License-Identifier: MIT
/**
 * `defineCommand` bridge for the read-only host accelerators (PLAN D10/D12).
 *
 * Inside `bash -c` an accelerator is an ordinary command name. just-bash calls
 * the async handler; this module turns that call into one exec-bridge request
 * carrying the two phone-dsh-v1 fields the worker must supply itself:
 *
 *   `requires_mseq`  the sink revision when dispatch starts, so the host has
 *                    applied every earlier Worker write before the read;
 *   `idem_key`       the exec.md §1 derivation (the trusted tool-call key,
 *                    canonical argv, cwd, env hash — or the session/turn/step
 *                    fallback).
 *
 * The identity always comes from the ambient tool-call context or an explicit
 * out-of-band option. A shell variable named `XL_IDEMPOTENCY_KEY` is ordinary
 * model/script data: it is never read as the call identity, so a script cannot
 * rewrite the host `exec_id` prefix or the D10 `idem_key`.
 *
 * Only names the host advertised in `accelerator:<name>` are registered, so a
 * name outside the caps keeps running Worker-local (just-bash's own `rg`, for
 * example) and never crosses the channel.
 * @module @phone-dsh/dsh-shell-ext/bridge
 */

import { defineCommand } from 'just-bash/browser'
import type { Command } from 'just-bash/browser'
import { currentToolCall, deriveIdemKey } from '@phone-dsh/dsh-exec-bridge'
import { byteStringOutput, byteStringToBytes, bytesToByteString, concatBytes, decodeUtf8 } from './encoding.ts'
import type { ExecClient, ExecEvent, ExecRequest, Hello, IdemKeyFacts, ToolCallContext } from '@phone-dsh/dsh-exec-bridge'

/** One accelerator invocation as just-bash sees it. */
export interface AcceleratorRequest {
  /** Command name followed by its arguments. */
  readonly argv: readonly string[]
  readonly cwd: string
  /** Exported environment of the calling shell. */
  readonly env: Readonly<Record<string, string>>
  /**
   * Standard input as just-bash's latin1-shaped byte string.
   *
   * It stays a byte string end to end: the exec-bridge request carries its
   * bytes base64-encoded, never a UTF-8 re-encoding of a decoded view.
   */
  readonly stdin: string
  readonly signal?: AbortSignal | undefined
}

/** One accelerator result. */
export interface AcceleratorResult {
  /** Standard output as a latin1-shaped byte string (bytes, never decoded text). */
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
  readonly signal?: string | null | undefined
}

/** The dispatcher the command definitions forward to. */
export interface AcceleratorHost {
  /** Advertised accelerator names (the host HELLO caps). */
  readonly names: readonly string[]
  exec(request: AcceleratorRequest): Promise<AcceleratorResult>
}

/** Options for {@link createExecBridgeAccelerators}. */
export interface ExecBridgeAcceleratorOptions {
  readonly client: Pick<ExecClient, 'exec' | 'cancel'>
  readonly hello: Pick<Hello, 'capabilities'>
  /** Read the current sink revision (the Worker's last assigned mseq). */
  readonly revision: () => bigint | number
  /** Identity source; defaults to the ambient tool-call context. */
  readonly toolCall?: (() => ToolCallContext | undefined) | undefined
  /**
   * Trusted out-of-band identity for a caller outside a model tool call (the
   * phone console's `execId`). It wins over `toolCall` and the ambient context.
   */
  readonly idempotencyKey?: string | undefined
  /** Execution deadline for the host request, in milliseconds from dispatch. */
  readonly deadlineMs?: number | undefined
  /** Grace period for a host-side cancel, in milliseconds. */
  readonly graceMs?: number | undefined
}

/** Parse a host HELLO accelerator list into unique names. */
export function advertisedAccelerators(hello: Pick<Hello, 'capabilities'>): string[] {
  const names = hello.capabilities.accelerators ?? []
  return [...new Set(names.filter((name): name is string => typeof name === 'string' && name !== ''))]
}

/**
 * Build the exec-bridge dispatcher shared by every accelerator command.
 * @param options - client, hello caps, revision source and identity source.
 * @returns the dispatcher.
 */
export function createExecBridgeAccelerators(options: ExecBridgeAcceleratorOptions): AcceleratorHost {
  const names = advertisedAccelerators(options.hello)
  const graceMs = Math.min(60_000, Math.max(1, options.graceMs ?? 10_000))
  const deadlineMs = Math.max(1, Math.ceil(options.deadlineMs ?? graceMs))
  let sequence = 0
  return {
    names,
    async exec(request: AcceleratorRequest): Promise<AcceleratorResult> {
      const explicitKey = options.idempotencyKey
      const facts = explicitKey !== undefined && explicitKey !== ''
        ? { key: explicitKey }
        : (options.toolCall ?? currentToolCall)()
      const env: Record<string, string> = { ...request.env }
      // The shell's exported environment is not an identity source. Replace a
      // script-supplied value with the trusted tool-call key, or drop it when
      // the call only has the session/turn/step fallback.
      delete env.XL_IDEMPOTENCY_KEY
      if (facts?.key !== undefined && facts.key !== '') env.XL_IDEMPOTENCY_KEY = facts.key
      const identity: IdemKeyFacts = facts ?? {}
      let idemKey: string
      try {
        idemKey = deriveIdemKey(request.argv, request.cwd, env, identity)
      } catch (error) {
        throw new Error(
          `accelerator ${JSON.stringify(request.argv[0])} needs a tool-call idem_key (XL_IDEMPOTENCY_KEY or session/turn/step): ${error instanceof Error ? error.message : String(error)}`,
          { cause: error },
        )
      }
      const requiresMseq = Number(options.revision())
      if (!Number.isSafeInteger(requiresMseq) || requiresMseq < 0) {
        throw new Error(`accelerator requires_mseq ${String(requiresMseq)} is outside the JSON safe-integer range`)
      }
      // D6 bounds the host wire id to 64 characters. Keep the `-aN` sequence
      // suffix intact and shorten only the prefix when the identity is long.
      const prefix = identity.key !== undefined && identity.key !== '' ? identity.key : 'xl'
      const suffix = `-a${String(sequence++)}`
      const execId = `${prefix.length + suffix.length <= 64 ? prefix : prefix.slice(0, 64 - suffix.length)}${suffix}`
      const execRequest: ExecRequest = {
        exec_id: execId,
        argv: [...request.argv],
        cwd: request.cwd,
        env,
        deadline: Date.now() + deadlineMs,
        grace_ms: graceMs,
        requires_mseq: requiresMseq,
        idem_key: idemKey,
        stdin: request.stdin === ''
          ? { mode: 'ignore' }
          : { mode: 'data', data: Buffer.from(byteStringToBytes(request.stdin)).toString('base64') },
      }
      let stream
      try {
        stream = await options.client.exec(execRequest, request.signal)
      } catch (error) {
        throw error instanceof Error ? error : new Error(String(error))
      }
      // stdout is the accelerator's byte stream: collect the raw chunks and
      // hand them back as a byte string. stderr is text to just-bash, so each
      // chunk is decoded exactly once with the shared decoder (G2-FIX-43).
      const stdout: Uint8Array[] = []
      let stderr = ''
      let exit: Extract<ExecEvent, { type: 'exit' }> | undefined
      try {
        for await (const event of stream) {
          if (event.type === 'output') {
            const bytes = Buffer.from(event.data, 'base64')
            if (event.stream === 'stdout') stdout.push(new Uint8Array(bytes))
            else stderr += decodeUtf8(new Uint8Array(bytes))
          } else if (event.type === 'exit') {
            exit = event
            break
          } else if (event.type === 'error') {
            return { stdout: bytesToByteString(concatBytes(stdout)), stderr: `${stderr}${event.code}: ${event.message}\n`, exitCode: 1 }
          }
        }
      } catch (error) {
        if (request.signal?.aborted === true) {
          await options.client.cancel(execId, { signal: 'SIGTERM', grace_ms: graceMs }).catch(() => {})
          return { stdout: bytesToByteString(concatBytes(stdout)), stderr: `${stderr}accelerator cancelled\n`, exitCode: 130, signal: 'SIGTERM' }
        }
        throw error instanceof Error ? error : new Error(String(error))
      } finally {
        stream.close()
      }
      if (exit === undefined) {
        return { stdout: bytesToByteString(concatBytes(stdout)), stderr: `${stderr}accelerator stream ended before an exit event\n`, exitCode: 1 }
      }
      return { stdout: bytesToByteString(concatBytes(stdout)), stderr, exitCode: exit.code ?? 1, signal: exit.signal }
    },
  }
}

/**
 * Turn an accelerator dispatcher into just-bash commands. Registering these in
 * `customCommands` overrides the same-named built-in, which is exactly what a
 * host-advertised `rg` must do (D12).
 * @param host - dispatcher built by {@link createExecBridgeAccelerators}.
 * @returns one command per advertised name.
 */
export function createAcceleratorCommands(host: AcceleratorHost): Command[] {
  return host.names.map(name => defineCommand(name, async (args, ctx) => {
    const env: Record<string, string> = ctx.exportedEnv === undefined
      ? Object.fromEntries(ctx.env)
      : { ...ctx.exportedEnv }
    // `ctx.stdin` is just-bash's byte string: forward it verbatim. The
    // accelerator's stdout is likewise bytes, so the result declares its byte
    // shape and a redirection writes the exact bytes the host produced.
    const stdin = ctx.stdin === undefined ? '' : ctx.stdin as unknown as string
    try {
      const result = await host.exec({ argv: [name, ...args], cwd: ctx.cwd, env, stdin, signal: ctx.signal })
      return { ...byteStringOutput(result.stdout), stderr: result.stderr, exitCode: result.exitCode }
    } catch (error) {
      return {
        stdout: '',
        stderr: `${name}: ${error instanceof Error ? error.message : String(error)}\n`,
        exitCode: 1,
      }
    }
  }))
}
