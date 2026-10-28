// SPDX-License-Identifier: MIT
/**
 * Instantiate the pdsh-brush-wasm reactor with Node's built-in WASI and expose a
 * small `run(script)` wrapper.
 *
 * The guest is the same module the Worker would host: WASI is configured with
 * one preopened filesystem subtree (`/dsh`, containing `workspace/`, `home/`
 * and `tmp/`) and the `xl` import module implements the host command table and
 * the cancellation flag. No socket or process import is provided.
 *
 * @module pdsh-brush-wasm/harness/wasm
 */

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { WASI } from 'node:wasi'

/** Default location of the release wasm build. */
export const DEFAULT_WASM_PATH = fileURLToPath(
  new URL('../../../target/wasm32-wasip1/release/pdsh_brush_wasm.wasm', import.meta.url),
)

/**
 * Resolve the wasm path: explicit argument, then env, then the build output.
 *
 * @param {string | undefined} explicit - optional path.
 * @returns {string} absolute path.
 */
export function resolveWasmPath(explicit) {
  return explicit || process.env.PDSH_BRUSH_WASM || DEFAULT_WASM_PATH
}

/**
 * Read one unsigned 32-bit little-endian integer.
 *
 * @param {Buffer} buffer - payload.
 * @param {{offset: number}} cursor - read cursor.
 * @returns {number} value.
 */
function readU32(buffer, cursor) {
  const value = buffer.readUInt32LE(cursor.offset)
  cursor.offset += 4
  return value
}

/**
 * Read one length-prefixed byte string.
 *
 * @param {Buffer} buffer - payload.
 * @param {{offset: number}} cursor - read cursor.
 * @returns {Buffer} value.
 */
function readBytes(buffer, cursor) {
  const length = readU32(buffer, cursor)
  const value = buffer.subarray(cursor.offset, cursor.offset + length)
  if (value.length !== length) throw new Error('truncated wire payload')
  cursor.offset += length
  return value
}

/**
 * Decode the request format of `src/wire.rs`.
 *
 * @param {Buffer} payload - request bytes.
 * @returns {{command: string, args: string[], stdin: Buffer, cwd: string, env: Array<[string, string]>}} request.
 */
export function decodeRequest(payload) {
  const cursor = { offset: 0 }
  const command = readBytes(payload, cursor).toString('utf8')
  const argumentCount = readU32(payload, cursor)
  const args = []
  for (let index = 0; index < argumentCount; index += 1) {
    args.push(readBytes(payload, cursor).toString('utf8'))
  }
  const stdin = readBytes(payload, cursor)
  const cwd = readBytes(payload, cursor).toString('utf8')
  const envCount = readU32(payload, cursor)
  const env = []
  for (let index = 0; index < envCount; index += 1) {
    const name = readBytes(payload, cursor).toString('utf8')
    const value = readBytes(payload, cursor).toString('utf8')
    env.push([name, value])
  }
  if (cursor.offset !== payload.length) throw new Error('trailing request bytes')
  return { command, args, stdin, cwd, env }
}

/**
 * Append a length-prefixed byte string.
 *
 * @param {Buffer[]} parts - output parts.
 * @param {Buffer | string} value - value to append.
 */
function putBytes(parts, value) {
  const buffer = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8')
  const length = Buffer.alloc(4)
  length.writeUInt32LE(buffer.length)
  parts.push(length, buffer)
}

/**
 * Encode the response format of `src/wire.rs`.
 *
 * @param {{exitCode: number, stdout: string, stderr: string}} result - command result.
 * @param {boolean} [cancelled] - cancellation flag.
 * @returns {Buffer} response bytes.
 */
export function encodeResult(result, cancelled = false) {
  const parts = []
  const exitCode = Buffer.alloc(4)
  exitCode.writeInt32LE(result.exitCode | 0)
  parts.push(exitCode)
  putBytes(parts, Buffer.from(result.stdout ?? '', 'utf8'))
  putBytes(parts, Buffer.from(result.stderr ?? '', 'utf8'))
  const flags = Buffer.alloc(4)
  flags.writeUInt32LE(cancelled ? 1 : 0)
  parts.push(flags)
  return Buffer.concat(parts)
}

/**
 * Load and instantiate the module.
 *
 * @param {object} options - options.
 * @param {string} options.root - host directory holding `workspace/`, `home/` and `tmp/`.
 * @param {{names: string[], exec: Function, isCancelled?: Function}} options.commands - host command table.
 * @param {string} [options.wasmPath] - wasm file.
 * @param {WebAssembly.Module} [options.module] - precompiled module.
 * @returns {Promise<object>} the loaded shell.
 */
export async function loadBrush(options) {
  const { root, commands, wasmPath, module: precompiled } = options
  if (typeof root !== 'string') throw new Error('loadBrush needs a host root directory')
  if (commands === undefined || typeof commands.exec !== 'function') {
    throw new Error('loadBrush needs a command table with an exec function')
  }

  const module = precompiled ?? (await WebAssembly.compile(readFileSync(resolveWasmPath(wasmPath))))
  let instance
  const view = () => new Uint8Array(instance.exports.memory.buffer)

  const host = {
    xl_host_list_count: () => commands.names.length,
    xl_host_list_name: (index, pointer, capacity) => {
      const name = Buffer.from(commands.names[index] ?? '', 'utf8')
      if (pointer !== 0 && capacity >= name.length) view().set(name, pointer)
      return capacity >= name.length ? name.length : -name.length
    },
    xl_host_cancelled: () => (commands.isCancelled?.() ? 1 : 0),
    xl_host_exec: (requestPointer, requestLength, responsePointer, responseCapacity) => {
      const request = decodeRequest(Buffer.from(view().slice(requestPointer, requestPointer + requestLength)))
      const result = commands.exec(request)
      const response = encodeResult(result, result.cancelled === true)
      if (response.length > responseCapacity) return -response.length
      view().set(response, responsePointer)
      return response.length
    },
  }

  const wasi = new WASI({
    version: 'preview1',
    args: ['brush'],
    env: {},
    // One preopen for the whole `/dsh` subtree, like the Worker's VFS proxy.
    // Separate preopens per mount would make `cd ..` from one mount to another
    // fail with ENOTCAPABLE, because WASI cannot traverse above a preopen.
    preopens: { '/dsh': root },
    returnOnExit: true,
  })
  const importObject = { ...wasi.getImportObject(), xl: host }
  const instantiated = await WebAssembly.instantiate(module, importObject)
  instance = instantiated instanceof WebAssembly.Instance ? instantiated : instantiated.instance
  wasi.initialize(instance)
  const exports = instance.exports

  /**
   * Copy a guest stream out through the ABI.
   *
   * @param {Function} copy - exported copy function.
   * @returns {string} decoded text.
   */
  function readStream(copy) {
    const length = copy(0, 0)
    if (length < 0) throw new Error('cannot read the guest stream')
    if (length === 0) return ''
    const pointer = exports.xl_brush_alloc(length)
    try {
      copy(pointer, length)
      return Buffer.from(view().slice(pointer, pointer + length)).toString('utf8')
    } finally {
      exports.xl_brush_free(pointer, length)
    }
  }

  /**
   * Run one script.
   *
   * @param {string} script - bash source.
   * @returns {{exitCode: number, stdout: string, stderr: string, error: string, pipelineShim: boolean}} outcome.
   */
  function run(script) {
    const bytes = Buffer.from(script, 'utf8')
    const pointer = exports.xl_brush_alloc(bytes.length)
    try {
      view().set(bytes, pointer)
      const exitCode = exports.xl_brush_run(pointer, bytes.length)
      return {
        exitCode,
        stdout: readStream(exports.xl_brush_stdout),
        stderr: readStream(exports.xl_brush_stderr),
        error: readStream(exports.xl_brush_error),
        pipelineShim: exports.xl_brush_pipeline_shim() !== 0,
      }
    } finally {
      exports.xl_brush_free(pointer, bytes.length)
    }
  }

  return {
    module,
    instance,
    exports,
    run,
    reset() {
      return exports.xl_brush_reset()
    },
    version() {
      const length = exports.xl_brush_version(0, 0)
      const pointer = exports.xl_brush_alloc(length)
      try {
        exports.xl_brush_version(pointer, length)
        return Buffer.from(view().slice(pointer, pointer + length)).toString('utf8')
      } finally {
        exports.xl_brush_free(pointer, length)
      }
    },
    commandNames: commands.names.slice(),
    /** Imports actually linked into the module, for the fs-only assertion. */
    imports: WebAssembly.Module.imports(module),
  }
}
