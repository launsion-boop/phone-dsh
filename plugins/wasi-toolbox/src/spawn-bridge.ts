// SPDX-License-Identifier: MIT
/**
 * The subprocess bridge of the CPython-on-WASI package.
 *
 * WASI preview1 has no process model: `fork`/`exec` do not exist, so stock
 * CPython's `subprocess.Popen` can only raise `OSError(ENOTSUP)`. The toolbox
 * cannot add a syscall to the wasm build, but it owns the WASI host and the
 * interpreter instance, so it adds the one mechanism preview1 can carry: a
 * private control file (`/__xl__/spawn`) served by this host. The Python shim
 * mounted in the read-only layer writes one framed request to that fd and both
 * ends run inside the same tool worker, so a nested interpreter is a fresh
 * `HotInstance` run over the *same* synchronous VFS proxy and preopen table as
 * the shell's `python3` dispatch — there is no second filesystem path and no
 * host-side process.
 *
 * Wire format (little-endian, both directions):
 *
 * ```
 * request  = u32 header_len | u32 stdin_len | header JSON | stdin bytes
 * response = u32 header_len | header JSON | stdout bytes | stderr bytes
 * ```
 *
 * The request header carries `{op, argv, env, cwd, stdinBytes}`. Python
 * subprocess timeouts are explicitly refused because this synchronous
 * same-thread mechanism cannot preempt a nested interpreter;
 * `{op:"programs"}` asks for the spawn table the shim resolves argv[0]
 * against. The response header carries `{code, stdoutBytes, stderrBytes}` or
 * `{error:{kind,message}}`. Binary frames keep arbitrary stdin/stdout bytes
 * out of JSON and out of base64.
 * @module @phone-dsh/dsh-wasi-toolbox/spawn-bridge
 */

/** Guest root the host intercepts for the control file. */
export const PDSH_SPAWN_GUEST_ROOT = '/__xl__'
/** Exact guest path of the control file; the Python shim hard-codes it. */
export const PDSH_SPAWN_GUEST_PATH = '/__xl__/spawn'
/**
 * Host-side spelling of {@link PDSH_SPAWN_GUEST_ROOT}. The path must be absolute
 * for the preopen table; the WASI host intercepts every request under it
 * before it reaches the VFS, so nothing is ever read from or written to it.
 */
export const PDSH_SPAWN_HOST_ROOT = '/pdsh-spawn'
/** Bytes before the JSON header in both directions. */
export const SPAWN_FRAME_PREFIX_BYTES = 8
/** Largest JSON header the host accepts; a malformed peer must not allocate. */
export const MAX_SPAWN_HEADER_BYTES = 1024 * 1024
/** Largest single request frame (header + stdin) the host accepts. */
export const MAX_SPAWN_FRAME_BYTES = 16 * 1024 * 1024
/** Largest combined stdout+stderr the host buffers for one nested command. */
export const MAX_SPAWN_STDIO_BYTES = 16 * 1024 * 1024
/**
 * How deeply a nested interpreter may spawn another one.
 *
 * A nested `python3 -c 'import subprocess; ...'` is a distinct wasm instance
 * on the same JS stack; each level costs one interpreter start. The cap turns
 * an accidental fork bomb into one loud error instead of a dead tool worker.
 */
export const MAX_SPAWN_DEPTH = 8

const encoder = new TextEncoder()
const decoder = new TextDecoder()

/** Names the shim may resolve argv[0] against. */
export interface SpawnProgramTable {
  /** Canonical program name of the interpreter the shim patches. */
  readonly interpreter: string
  /** Extra names the same interpreter answers to (`python`, ...). */
  readonly aliases: readonly string[]
  /** Every program the Worker toolbox can dispatch, for the loud failure. */
  readonly toolboxPrograms: readonly string[]
}

/** One nested command the Python shim asked the host to run. */
export interface SpawnExecRequest {
  /** Arguments after the interpreter program name. */
  readonly argv: readonly string[]
  readonly env: Readonly<Record<string, string>>
  /** Guest cwd; the shim always sends an absolute one. */
  readonly cwd?: string
  readonly stdin: Uint8Array
}

/** Result of one nested command. */
export interface SpawnExecResult {
  readonly exitCode: number
  readonly stdout: Uint8Array
  readonly stderr: Uint8Array
}

/** Stable failure classes the shim maps onto Python exceptions. */
export type SpawnErrorKind = 'protocol' | 'depth' | 'cwd' | 'output-limit' | 'internal'

/** A failure the shim must see instead of a fabricated result. */
export class SpawnBridgeError extends Error {
  readonly kind: SpawnErrorKind

  constructor(kind: SpawnErrorKind, message: string) {
    super(message)
    this.name = 'SpawnBridgeError'
    this.kind = kind
  }
}

/** Construction inputs of {@link createSpawnBridge}. */
export interface SpawnBridgeOptions {
  readonly table: SpawnProgramTable
  /**
   * Run one nested interpreter instance with piped stdio. The implementation
   * is the tool worker's `HotInstance` run, so the child's file I/O uses the
   * same `WasiVfs` object (and therefore the same VFS proxy, sink and
   * durability fence) as the parent command.
   */
  run(request: SpawnExecRequest): SpawnExecResult
}

/** The control-file face `WasiPreview1` serves. */
export interface SpawnBridge {
  /** Guest root of the control file; every other path below it is ENOENT. */
  readonly guestRoot: string
  /** Exact guest path of the control file. */
  readonly guestPath: string
  /** Serve one complete request frame and return the response frame. */
  dispatch(request: Uint8Array): Uint8Array
}

/**
 * Build the dispatcher the WASI host calls when the guest opens and writes the
 * control file. Every failure is encoded in the response header; the bridge
 * never pretends a child ran.
 * @param options - spawn table and the nested-execution callback.
 * @returns the bridge face installed on one `WasiPreview1`.
 */
export function createSpawnBridge(options: SpawnBridgeOptions): SpawnBridge {
  return {
    guestRoot: PDSH_SPAWN_GUEST_ROOT,
    guestPath: PDSH_SPAWN_GUEST_PATH,
    dispatch(request: Uint8Array): Uint8Array {
      try {
        const frame = decodeSpawnRequest(request)
        const op = frame.header.op
        if (op === 'programs') {
          return encodeSpawnResponse({
            op: 'programs',
            interpreter: options.table.interpreter,
            aliases: [...options.table.aliases],
            programs: uniqueNames(options.table.interpreter, options.table.aliases),
            toolboxPrograms: [...options.table.toolboxPrograms],
          }, new Uint8Array(0), new Uint8Array(0))
        }
        if (op !== 'exec') {
          throw new SpawnBridgeError('protocol', `unknown spawn bridge operation ${JSON.stringify(String(op))}`)
        }
        const exec = readExecRequest(frame)
        const result = options.run(exec)
        const stdout = result.stdout instanceof Uint8Array ? result.stdout : new Uint8Array(result.stdout)
        const stderr = result.stderr instanceof Uint8Array ? result.stderr : new Uint8Array(result.stderr)
        if (stdout.byteLength + stderr.byteLength > MAX_SPAWN_STDIO_BYTES) {
          throw new SpawnBridgeError(
            'output-limit',
            `the nested command produced ${stdout.byteLength + stderr.byteLength} bytes of stdout/stderr; `
            + `the WASI subprocess limit is ${MAX_SPAWN_STDIO_BYTES} bytes`,
          )
        }
        return encodeSpawnResponse({
          code: result.exitCode,
        }, stdout, stderr)
      } catch (error) {
        const kind: SpawnErrorKind = error instanceof SpawnBridgeError ? error.kind : 'internal'
        const message = error instanceof Error ? error.message : String(error)
        return encodeSpawnResponse({ error: { kind, message } }, new Uint8Array(0), new Uint8Array(0))
      }
    },
  }
}

/** One decoded request frame. */
export interface SpawnRequestFrame {
  readonly header: Record<string, unknown>
  readonly payload: Uint8Array
}

/**
 * Decode the outermost frame: the two lengths and the JSON header.
 * @param frame - complete request bytes from the guest.
 * @returns the parsed header and the stdin payload.
 * @throws {SpawnBridgeError} for a truncated or oversized frame.
 */
export function decodeSpawnRequest(frame: Uint8Array): SpawnRequestFrame {
  if (frame.byteLength < SPAWN_FRAME_PREFIX_BYTES) {
    throw new SpawnBridgeError('protocol', 'spawn request is shorter than its 8-byte frame prefix')
  }
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  const headerLength = view.getUint32(0, true)
  const payloadLength = view.getUint32(4, true)
  if (headerLength > MAX_SPAWN_HEADER_BYTES) {
    throw new SpawnBridgeError('protocol', `spawn request header is ${headerLength} bytes; the limit is ${MAX_SPAWN_HEADER_BYTES}`)
  }
  const expected = SPAWN_FRAME_PREFIX_BYTES + headerLength + payloadLength
  if (frame.byteLength !== expected) {
    throw new SpawnBridgeError(
      'protocol',
      `spawn request frame is ${frame.byteLength} bytes but its prefix declares ${expected}`,
    )
  }
  let header: unknown
  try {
    header = JSON.parse(decoder.decode(frame.subarray(SPAWN_FRAME_PREFIX_BYTES, SPAWN_FRAME_PREFIX_BYTES + headerLength)))
  } catch (error) {
    throw new SpawnBridgeError('protocol', `spawn request header is not JSON: ${error instanceof Error ? error.message : String(error)}`)
  }
  if (typeof header !== 'object' || header === null || Array.isArray(header)) {
    throw new SpawnBridgeError('protocol', 'spawn request header must be a JSON object')
  }
  return {
    header: header as Record<string, unknown>,
    payload: frame.subarray(SPAWN_FRAME_PREFIX_BYTES + headerLength),
  }
}

/** Validate and normalise an `exec` request header. */
function readExecRequest(frame: SpawnRequestFrame): SpawnExecRequest {
  const header = frame.header
  // Older/raw clients must not have a requested deadline silently discarded.
  // This transport cannot preempt the synchronous nested interpreter.
  if (header.timeoutMs !== undefined) {
    throw new SpawnBridgeError('protocol', 'spawn exec timeoutMs is unsupported: nested interpreters cannot be preempted')
  }
  const argv = header.argv
  // An empty argv is the bare interpreter: it reads its program from stdin,
  // exactly like `python3` with no script operand.
  if (!Array.isArray(argv) || !argv.every(item => typeof item === 'string')) {
    throw new SpawnBridgeError('protocol', 'spawn exec request argv must be a string array')
  }
  const env: Record<string, string> = {}
  if (header.env !== undefined) {
    if (typeof header.env !== 'object' || header.env === null || Array.isArray(header.env)) {
      throw new SpawnBridgeError('protocol', 'spawn exec request env must be a JSON object')
    }
    for (const [name, value] of Object.entries(header.env as Record<string, unknown>)) {
      if (typeof value !== 'string') throw new SpawnBridgeError('protocol', `spawn exec request env ${name} is not a string`)
      env[name] = value
    }
  }
  const cwd = header.cwd
  if (cwd !== undefined && (typeof cwd !== 'string' || !cwd.startsWith('/'))) {
    throw new SpawnBridgeError('protocol', 'spawn exec request cwd must be an absolute guest path')
  }
  const stdinBytes = header.stdinBytes
  if (stdinBytes !== undefined && stdinBytes !== frame.payload.byteLength) {
    throw new SpawnBridgeError(
      'protocol',
      `spawn exec request declares ${String(stdinBytes)} stdin bytes but carries ${frame.payload.byteLength}`,
    )
  }
  return {
    argv: [...argv as string[]],
    env,
    ...(cwd === undefined ? {} : { cwd }),
    stdin: frame.payload.slice(),
  }
}

/** Encode one response frame the shim reads with `os.read`. */
export function encodeSpawnResponse(
  header: Record<string, unknown>,
  stdout: Uint8Array,
  stderr: Uint8Array,
): Uint8Array {
  const headerBytes = encoder.encode(JSON.stringify({
    ...header,
    stdoutBytes: stdout.byteLength,
    stderrBytes: stderr.byteLength,
  }))
  const out = new Uint8Array(4 + headerBytes.byteLength + stdout.byteLength + stderr.byteLength)
  new DataView(out.buffer, out.byteOffset, out.byteLength).setUint32(0, headerBytes.byteLength, true)
  out.set(headerBytes, 4)
  out.set(stdout, 4 + headerBytes.byteLength)
  out.set(stderr, 4 + headerBytes.byteLength + stdout.byteLength)
  return out
}

/** Interpreter name plus aliases, without duplicates. */
function uniqueNames(interpreter: string, aliases: readonly string[]): string[] {
  const names: string[] = []
  for (const name of [interpreter, ...aliases]) {
    if (name !== '' && !names.includes(name)) names.push(name)
  }
  return names
}

/**
 * Derive the program table from the toolbox's own registration list.
 * @param interpreter - canonical name of the program this tool worker runs.
 * @param commands - summaries the toolbox posted in `init`.
 * @returns the table the shim resolves argv[0] against.
 */
export function spawnProgramTable(
  interpreter: string,
  commands: readonly { readonly program: string; readonly aliases?: readonly string[] | undefined }[],
): SpawnProgramTable {
  const entry = commands.find(command => command.program === interpreter)
  return {
    interpreter,
    aliases: [...(entry?.aliases ?? [])],
    toolboxPrograms: commands.map(command => command.program),
  }
}
