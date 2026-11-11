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
 * ---- the tool-call session rides the same envelope, never argv ----
 * A host tool that has to bind a decision to a DSH session (the `ubuntu`
 * approval gate) cannot take that id from its argv: `phone` is also an ordinary
 * command inside `bash`, so `phone ubuntu run --session <other>` would let the
 * model pick whose approval it spends. The dispatch request therefore has an
 * explicit [AcceleratorRequest.sessionId] field; this module deletes the
 * shell's exported member, writes the trusted value into the request env, and
 * marks the request with `markTrustedToolCallSession` for the transport. The
 * transport deletes the member on every dispatch and re-adds it only from that
 * out-of-band mark, exactly like `XL_IDEMPOTENCY_KEY`, so a script that exports
 * the same name changes nothing. A dispatch that does not set the field (every
 * command built by {@link createAcceleratorCommands}, including a script
 * invoking `phone` directly) carries no session at all, which is what makes the
 * host able to refuse a dispatch the `ubuntu` command did not build.
 *
 * Only names the host advertised in `accelerator:<name>` are registered, so a
 * name outside the caps keeps running Worker-local (just-bash's own `rg`, for
 * example) and never crosses the channel.
 * @module @phone-dsh/dsh-shell-ext/bridge
 */

import { defineCommand } from 'just-bash/browser'
import type { Command } from 'just-bash/browser'
import { currentToolCall, deriveIdemKey } from '@phone-dsh/dsh-exec-bridge'
import { markTrustedToolCallSession } from '@phone-dsh/dsh-exec-bridge/transport'
import { byteStringOutput, byteStringToBytes, bytesToByteString, concatBytes, decodeUtf8 } from './encoding.ts'
import { appendShellTrailer, SHELL_MANIFEST_PATH, SHELL_REASON_EXIT } from './contract.ts'
import { phoneProviderFailure } from './phone-errors.ts'
import type { ExecClient, ExecEvent, ExecRequest, Hello, IdemKeyFacts, ToolCallContext } from '@phone-dsh/dsh-exec-bridge'

/**
 * The EXEC_REQ `env` member that carries the trusted tool-call session.
 *
 * It is an envelope member, not a flag: the `ubuntu` dispatch writes it from
 * its explicit out-of-band session field, and no shell variable of the same
 * name is ever forwarded. The host reads it back from the request's `env` map,
 * so the wire schema of `channel.md` §4.2 does not change.
 */
export const TOOL_CALL_SESSION_ENV = 'PDSH_TOOL_CALL_SESSION'

/** channel.md §6 / D6 identifier shape; a session id follows it. */
const SESSION_ID = /^[A-Za-z0-9._-]{1,64}$/u

/** One accelerator invocation as just-bash sees it. */
export interface AcceleratorRequest {
  /** Command name followed by its arguments. */
  readonly argv: readonly string[]
  readonly cwd: string
  /** Exported environment of the calling shell. */
  readonly env: Readonly<Record<string, string>>
  /**
   * The DSH session that owns this dispatch, when the command building it knows.
   *
   * Out-of-band by construction: it is not an argv word and not a shell
   * variable, so the model cannot choose it. A command that leaves it undefined
   * sends `env` with [TOOL_CALL_SESSION_ENV] deleted, and the host refuses a
   * session-scoped tool dispatch that has no session — that is how a script
   * calling `phone` directly is kept out of the approval lane.
   */
  readonly sessionId?: string | undefined
  /**
   * Standard input as just-bash's latin1-shaped byte string.
   *
   * It stays a byte string end to end: the exec-bridge request carries its
   * bytes base64-encoded, never a UTF-8 re-encoding of a decoded view.
   */
  readonly stdin: string
  readonly signal?: AbortSignal | undefined
  /** Consume large native transfer output without retaining a second copy. */
  readonly onStdout?: ((bytes: Uint8Array) => Promise<void>) | undefined
}

/** One accelerator result. */
export interface AcceleratorResult {
  /** Standard output as a latin1-shaped byte string (bytes, never decoded text). */
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
  readonly signal?: string | null | undefined
  /**
   * Typed terminal error code the host sent (exec.md §2.2), kept so
   * {@link createAcceleratorCommands} can render a phone provider failure as
   * the bounded `{ok:false,error:{…}}` result instead of a backend line.
   */
  readonly providerCode?: string
  /** The host's own message for {@link providerCode}, bounded by the caller. */
  readonly providerMessage?: string
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

/** Stable, call-scoped identity bounded by the host's 64-character exec_id. */
export function acceleratorExecID(idemKey: string, sequence: number): string {
  if (!/^[0-9a-f]{64}$/u.test(idemKey)) throw new Error('accelerator exec_id needs a sha256 idem_key')
  if (!Number.isSafeInteger(sequence) || sequence < 0) throw new Error('accelerator sequence is invalid')
  const suffix = `-a${String(sequence)}`
  return `${idemKey.slice(0, 64 - suffix.length)}${suffix}`
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
      // The session is identity too: a script may export this name, and the
      // value it exports is never the one that reaches the host. Only the
      // explicit out-of-band field survives, and only a D6-shaped value does.
      // A dispatch without one sends no session, which the host refuses for a
      // tool that needs one (so `phone ubuntu run` from a script cannot even
      // reach the approval gate).
      delete env[TOOL_CALL_SESSION_ENV]
      const session = request.sessionId
      const trustedSession = session !== undefined && SESSION_ID.test(session) ? session : undefined
      if (trustedSession !== undefined) env[TOOL_CALL_SESSION_ENV] = trustedSession
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
      // exec.md §2: `exec_id` follows D6 (1..64 chars) and is conventionally
      // `<XL_IDEMPOTENCY_KEY>-<n>`. A process-local sequence restarts at zero
      // on a Worker rebuild, so the persistent identity comes from the sha256
      // idem_key: the result is always exactly 64 D6-safe characters and
      // unrelated calls cannot reuse an exec_id already owned by the host
      // ledger. A plaintext identity key would neither be bounded nor stable.
      const execId = acceleratorExecID(idemKey, sequence++)
      const execRequest: ExecRequest = {
        exec_id: execId,
        argv: [...request.argv],
        cwd: request.cwd,
        env,
        deadline: Date.now() + (options.deadlineMs === undefined && request.argv[0] === 'adb' ? 3_600_000 : options.deadlineMs === undefined && ['ssh', 'scp'].includes(request.argv[0] ?? '') ? 120_000 : deadlineMs),
        grace_ms: graceMs,
        requires_mseq: requiresMseq,
        idem_key: idemKey,
        stdin: request.stdin === ''
          ? { mode: 'ignore' }
          : { mode: 'data', data: Buffer.from(byteStringToBytes(request.stdin)).toString('base64') },
      }
      // The env member is only for the host's wire shape; the transport must
      // not trust argv (a script's `phone ubuntu run` looks identical). The
      // out-of-band mark is the one fact that says this request is the
      // `ubuntu` command's own dispatch, so only this path sets it.
      if (trustedSession !== undefined) markTrustedToolCallSession(execRequest, trustedSession)
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
            if (event.stream === 'stdout' && request.onStdout !== undefined) await request.onStdout(new Uint8Array(bytes))
            else if (event.stream === 'stdout') stdout.push(new Uint8Array(bytes))
            else stderr += decodeUtf8(new Uint8Array(bytes))
          } else if (event.type === 'exit') {
            exit = event
            break
          } else if (event.type === 'error') {
            return hostRefusal(
              request.argv,
              event,
              bytesToByteString(concatBytes(stdout)),
              stderr,
            )
          }
        }
      } catch (error) {
        await options.client.cancel(execId, { signal: 'SIGTERM', grace_ms: graceMs }).catch(() => {})
        if (request.signal?.aborted === true) {
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

/** The accelerator whose *tool* surface the host app owns (`exec.md` §3). */
const PHONE_ACCELERATOR = 'phone'

/** exec.md §3: the host started no execution for this request. */
const HOST_REFUSED = 'unsupported'

/** Longest host sentence the shell repeats back inside one stderr line. */
const HOST_DETAIL_MAX_CHARS = 160

/**
 * Render an argv word inside stderr without letting it forge a trailer line.
 *
 * A tool name is model-supplied: a raw newline plus `pdsh-shell: exit=…` would
 * otherwise be parsed as the contract trailer and suppress the real one, so
 * anything outside the bare-name alphabet is JSON-quoted (which escapes every
 * newline) and bounded.
 * @param word - one argv element.
 * @returns a single-line, trailer-safe spelling.
 */
function stderrWord(word: string): string {
  return /^[A-Za-z0-9._+-]{1,64}$/u.test(word) ? word : JSON.stringify(word.slice(0, 64))
}

/**
 * Collapse a host-supplied message into one stderr line.
 *
 * The text is trusted (the host tool contract forbids argv and file content in
 * it), but a raw newline would still let it start a line that a reader could
 * take for a trailer, so it is flattened and bounded.
 * @param message - the terminal event's message.
 * @returns one line, or `''` when the host said nothing usable.
 */
function hostDetail(message: string): string {
  const text = message
    .replace(/[\r\n\t]+/gu, ' ')
    // The shell already states that nothing ran; a host sentence that ends the
    // same way must not make the line say it twice.
    .replace(/[;,]?\s*nothing executed\.?\s*$/iu, '')
    .trim()
  if (text === '') return ''
  return text.length <= HOST_DETAIL_MAX_CHARS ? text : `${text.slice(0, HOST_DETAIL_MAX_CHARS - 3)}...`
}

/**
 * Turn one terminal `error` event into the result the shell sees.
 *
 * `exec.md` §3 gives `unsupported` exactly one meaning: the host started no
 * execution. For `phone` the refused unit is a single *tool* the host does not
 * provide, so the shell answers the contract's `not-available` kind (exit 127)
 * naming that tool and pointing at the capability manifest — instead of
 * forwarding a backend-shaped code the model cannot act on. The host's own
 * detail is kept: after the ExecBridge fix it says which shape it refused
 * (`only `phone info` is implemented`), and that is the most useful sentence
 * the model can get. Every other accelerator keeps the host's own code and
 * message: those describe a program the Worker does serve.
 * @param argv - the accelerator argv the host answered.
 * @param event - the terminal error event.
 * @param stdout - stdout collected before the event (a latin1 byte string).
 * @param stderr - stderr collected before the event.
 * @returns the shell-visible result.
 */
function hostRefusal(
  argv: readonly string[],
  event: { readonly code: string; readonly message: string },
  stdout: string,
  stderr: string,
): AcceleratorResult {
  if (argv[0] === PHONE_ACCELERATOR && event.code === HOST_REFUSED) {
    const tool = argv[1]
    const subject = tool === undefined
      ? PHONE_ACCELERATOR
      : `${PHONE_ACCELERATOR}: ${stderrWord(tool)}`
    const detail = hostDetail(event.message)
    const what = detail === ''
      ? 'this host does not provide that phone tool'
      : `this host does not provide that phone tool (host: ${detail})`
    const exitCode = SHELL_REASON_EXIT['not-available']
    return {
      stdout,
      stderr: appendShellTrailer(
        `${stderr}${subject}: ${what}; nothing executed\n`,
        {
          exitCode,
          program: PHONE_ACCELERATOR,
          reason: 'not-available',
          hint: `the host app owns the phone tool surface; see ${SHELL_MANIFEST_PATH}`,
        },
      ),
      exitCode,
    }
  }
  // Every other terminal error keeps the host's typed code and message: those
  // describe a provider failure, and `createAcceleratorCommands` turns the
  // phone ones into exec.md §2.2's bounded structured result. The phone
  // `unsupported` branch above deliberately omits them — that refusal never
  // reached a provider.
  return {
    stdout,
    stderr: `${stderr}${event.code}: ${event.message}\n`,
    exitCode: 1,
    providerCode: event.code,
    providerMessage: event.message,
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
      // `phone record` is the one phone tool that reads the Bot's own records.
      // Its caller must be the current tool-call session, host-resolved; the
      // value is an out-of-band field so no shell variable or argv word can
      // choose another session. Other phone tools keep their previous shape.
      const recordSession = name === 'phone' && args[0] === 'record'
        ? currentToolCall()?.sessionId
        : undefined
      const result = await host.exec({
        argv: [name, ...args], cwd: ctx.cwd, env, stdin, signal: ctx.signal,
        ...(recordSession === undefined ? {} : { sessionId: recordSession }),
      })
      // exec.md §2.2: a phone provider failure is a bounded
      // `{ok:false,error:{…}}` result that keeps the original exit code, not a
      // backend line the model cannot act on.
      if (name === 'phone') {
        const failure = phoneProviderFailure(args[0], result)
        if (failure !== undefined) {
          return { ...byteStringOutput(failure), stderr: '', exitCode: result.exitCode }
        }
      }
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
