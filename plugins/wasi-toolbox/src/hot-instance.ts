// SPDX-License-Identifier: MIT
/**
 * One warm WASI instance. "Warm" means the compiled `WebAssembly.Module` and
 * the tool worker stay alive across commands; the linear memory and the WASI
 * fd table are reset between commands (a wasm instance cannot be reused after
 * `_start` without inheriting the previous command's heap and libc state).
 * `terminate()` is reserved for cancellation and drops the instance.
 * @module @phone-dsh/dsh-wasi-toolbox/hot-instance
 */
import {
  WasiMemoryCeilingError, WasiProcExit, WasiTrapError,
} from './errors.ts'
import { DEFAULT_HOT_INSTANCE_MEMORY_BYTES, DEFAULT_PREOPENS } from './limits.ts'
import { createHttpBridge } from './http-bridge.ts'
import type { HttpTransport } from './http-bridge.ts'
import { MemoryWasiVfs } from './memory-wasi-vfs.ts'
import { createSpawnBridge } from './spawn-bridge.ts'
import type { SpawnExecRequest, SpawnExecResult, SpawnProgramTable } from './spawn-bridge.ts'
import { WasiPreview1 } from './wasi-preview1.ts'
import type { GuestPreopen, WasiVfs } from './types.ts'

/** Exit code the toolbox reports for a trap. */
export const EXIT_TRAP = 134
/** Exit code the toolbox reports for the memory ceiling (`128 + SIGKILL`). */
export const EXIT_MEMORY_LIMIT = 137

const encoder = new TextEncoder()

interface ModuleImportDescriptorLike {
  readonly module: string
  readonly name: string
  readonly kind: string
}

interface ModuleIntrospection {
  imports(module: WebAssembly.Module): readonly ModuleImportDescriptorLike[]
}

/**
 * The nested-process mechanism of one hot instance.
 *
 * A WASI preview1 guest has no `fork`/`exec`, so the Python package gives its
 * `subprocess` shim this one operation: run a fresh interpreter instance with
 * piped stdio on the same tool worker, module and VFS. `depth` is the number
 * of nested instances already on the stack, so a runaway chain fails loud.
 */
export interface NestedSpawner {
  /** Program names the shim resolves argv[0] against. */
  readonly table: SpawnProgramTable
  /** Run one nested interpreter instance; throws {@link SpawnBridgeError} on refusal. */
  run(request: SpawnExecRequest & { readonly depth: number }): SpawnExecResult
}

/** Construction inputs of {@link HotInstance}. */
export interface HotInstanceOptions {
  readonly program: string
  readonly module: WebAssembly.Module
  readonly vfs?: WasiVfs
  readonly preopens?: readonly GuestPreopen[]
  readonly memoryLimitBytes?: number
  readonly defaultEnv?: Readonly<Record<string, string>>
  readonly defaultCwd?: string
  readonly clockNs?: () => bigint
  readonly randomBytes?: (target: Uint8Array) => void
  readonly sleep?: (milliseconds: number) => void
  /** Install the subprocess control file (the Python tool worker does). */
  readonly spawn?: NestedSpawner
  /**
   * Install the `/__xl__/http` egress control file. Present only when the DSH
   * Worker injected loopback `/v1/http` coordinates; without it a guest HTTP
   * call fails loud instead of pretending the network works.
   */
  readonly http?: HttpTransport
}

/** One command invocation on a hot instance. */
export interface HotRunOptions {
  readonly argv?: readonly string[]
  readonly env?: Readonly<Record<string, string>>
  readonly cwd?: string
  /**
   * Complete stdin payload for the interpreter (already delivered and
   * validated by the tool worker). A later run never inherits it.
   */
  readonly stdin?: Uint8Array
  /** Observation of `fd_read(0)`, forwarded to the dispatch watchdog. */
  readonly onStdinRead?: (bytes: number, total: number) => void
  readonly onStdout?: (chunk: Uint8Array) => void
  readonly onStderr?: (chunk: Uint8Array) => void
  /** Nesting depth of this run; defaults to 0 for a shell-dispatched command. */
  readonly spawnDepth?: number
}

/** Result of one {@link HotInstance.run}. */
export interface HotRunResult {
  readonly exitCode: number
  readonly stdoutBytes: number
  readonly stderrBytes: number
  readonly memoryPeakBytes: number
  readonly memoryExceeded: boolean
  readonly instancesCreated: number
}

/** State snapshot for diagnostics and tests. */
export interface HotInstanceDiagnostics {
  readonly program: string
  readonly instancesCreated: number
  readonly resets: number
  readonly memoryBytes: number
  readonly memoryLimitBytes: number
  readonly state: 'cold' | 'warm' | 'terminated'
}

/** A single-tool warm instance. */
export class HotInstance {
  readonly program: string
  readonly module: WebAssembly.Module
  readonly memoryLimitBytes: number
  private readonly vfs: WasiVfs
  private readonly preopens: readonly GuestPreopen[]
  private readonly defaultEnv: Readonly<Record<string, string>>
  private readonly defaultCwd: string | undefined
  private readonly clockNs: (() => bigint) | undefined
  private readonly randomBytes: ((target: Uint8Array) => void) | undefined
  private readonly sleep: ((milliseconds: number) => void) | undefined
  private readonly spawn: NestedSpawner | undefined
  private readonly http: HttpTransport | undefined
  private currentMemoryBytes = 0
  private created = 0
  private resetCount = 0
  private terminated = false

  constructor(options: HotInstanceOptions) {
    this.program = options.program
    this.module = options.module
    this.memoryLimitBytes = options.memoryLimitBytes ?? DEFAULT_HOT_INSTANCE_MEMORY_BYTES
    this.vfs = options.vfs ?? new MemoryWasiVfs()
    this.preopens = options.preopens ?? DEFAULT_PREOPENS
    this.defaultEnv = options.defaultEnv ?? {}
    this.defaultCwd = options.defaultCwd
    this.clockNs = options.clockNs
    this.randomBytes = options.randomBytes
    this.sleep = options.sleep
    this.spawn = options.spawn
    this.http = options.http
  }

  /** Run one command; the next run always gets a fresh instance. */
  run(options: HotRunOptions = {}): HotRunResult {
    if (this.terminated) throw new WasiTrapError(`${this.program} was terminated`)
    let stdoutBytes = 0
    let stderrBytes = 0
    const env: Record<string, string> = { ...this.defaultEnv, ...(options.env ?? {}) }
    const cwd = options.cwd ?? this.defaultCwd
    if (cwd !== undefined && env.PWD === undefined) env.PWD = cwd
    const depth = options.spawnDepth ?? 0
    const wasi = new WasiPreview1({
      args: [this.program, ...(options.argv ?? [])],
      env,
      preopens: this.preopens,
      vfs: this.vfs,
      ...(options.stdin === undefined ? {} : { stdin: options.stdin }),
      ...(options.onStdinRead === undefined ? {} : { onStdinRead: options.onStdinRead }),
      stdout: chunk => {
        stdoutBytes += chunk.byteLength
        options.onStdout?.(chunk)
      },
      stderr: chunk => {
        stderrBytes += chunk.byteLength
        options.onStderr?.(chunk)
      },
      memoryLimitBytes: this.memoryLimitBytes,
      ...(this.clockNs === undefined ? {} : { clockNs: this.clockNs }),
      ...(this.randomBytes === undefined ? {} : { randomBytes: this.randomBytes }),
      ...(this.sleep === undefined ? {} : { sleep: this.sleep }),
      ...(this.spawn === undefined ? {} : {
        spawn: createSpawnBridge({
          table: this.spawn.table,
          run: request => this.spawn!.run({ ...request, depth }),
        }),
      }),
      ...(this.http === undefined ? {} : { http: createHttpBridge({ transport: this.http }) }),
    })

    this.created += 1
    let exitCode = 0
    let memoryPeakBytes = 0
    let memoryExceeded = false
    try {
      const instance = this.instantiate(wasi)
      wasi.attach(instance)
      memoryPeakBytes = wasi.memoryBytes
      exitCode = wasi.start()
      memoryPeakBytes = Math.max(memoryPeakBytes, wasi.memoryBytes)
      if (memoryPeakBytes > this.memoryLimitBytes) {
        throw new WasiMemoryCeilingError(this.memoryLimitBytes, memoryPeakBytes)
      }
      this.currentMemoryBytes = wasi.memoryBytes
    } catch (error) {
      if (error instanceof WasiMemoryCeilingError) {
        memoryExceeded = true
        exitCode = EXIT_MEMORY_LIMIT
        memoryPeakBytes = Math.max(memoryPeakBytes, error.observedBytes)
        this.currentMemoryBytes = 0
        stderrBytes += this.stderrMessage(
          options,
          `wasi-toolbox: ${this.program}: memory ceiling ${this.memoryLimitBytes} bytes exceeded\n`,
        )
      } else {
        if (error instanceof WasiProcExit) {
          exitCode = error.code
        } else {
          exitCode = EXIT_TRAP
          const detail = error instanceof Error ? error.message : String(error)
          stderrBytes += this.stderrMessage(options, `wasi-toolbox: ${this.program}: ${detail}\n`)
        }
        this.currentMemoryBytes = wasi.memoryBytes
      }
    }
    return {
      exitCode,
      stdoutBytes,
      stderrBytes,
      memoryPeakBytes,
      memoryExceeded,
      instancesCreated: this.created,
    }
  }

  /** Drop the instance and its WASI state; the compiled module stays. */
  reset(): void {
    this.currentMemoryBytes = 0
    this.resetCount += 1
  }

  /** Terminate for cancellation; no further runs are accepted. */
  terminate(): void {
    this.currentMemoryBytes = 0
    this.terminated = true
  }

  /** Snapshot for the toolbox and tests. */
  diagnostics(): HotInstanceDiagnostics {
    return {
      program: this.program,
      instancesCreated: this.created,
      resets: this.resetCount,
      memoryBytes: this.currentMemoryBytes,
      memoryLimitBytes: this.memoryLimitBytes,
      state: this.terminated ? 'terminated' : this.currentMemoryBytes === 0 && this.created === 0 ? 'cold' : 'warm',
    }
  }

  private stderrMessage(options: HotRunOptions, message: string): number {
    if (message.length === 0) return 0
    const bytes = encoder.encode(message)
    options.onStderr?.(bytes)
    return bytes.byteLength
  }

  private instantiate(wasi: WasiPreview1): WebAssembly.Instance {
    const introspection = WebAssembly.Module as unknown as ModuleIntrospection
    const memoryImports = introspection.imports(this.module).filter(descriptor => descriptor.kind === 'memory')
    if (memoryImports.length === 0) {
      return new WebAssembly.Instance(this.module, wasi.imports)
    }
    const pages = Math.max(1, Math.floor(this.memoryLimitBytes / 65_536))
    let lastError: unknown
    for (const initial of [1, pages]) {
      const memory = new WebAssembly.Memory({ initial: Math.min(initial, pages), maximum: pages })
      const imports = mergeMemoryImports(wasi.imports, memoryImports, memory)
      try {
        const instance = new WebAssembly.Instance(this.module, imports)
        wasi.setMemory(memory)
        return instance
      } catch (error) {
        lastError = error
        if (!(error instanceof WebAssembly.LinkError) || initial === pages) throw error
      }
    }
    throw new WasiTrapError(`cannot instantiate the module: ${String(lastError)}`)
  }
}

/** Construction options of {@link HotInstancePool}. */
export interface HotInstancePoolOptions {
  /** Build a cold instance for a program the first time it is acquired. */
  create(program: string): HotInstance
}

/** One warm `HotInstance` per tool, reset between commands. */
export class HotInstancePool {
  private readonly instances = new Map<string, HotInstance>()
  private readonly factory: (program: string) => HotInstance

  constructor(options: HotInstancePoolOptions) {
    this.factory = options.create
  }

  /** The warm instance for `program`, created on first use. */
  acquire(program: string): HotInstance {
    const existing = this.instances.get(program)
    if (existing !== undefined) return existing
    const created = this.factory(program)
    this.instances.set(program, created)
    return created
  }

  /** Keep the worker/module warm but drop the instance state after a command. */
  release(program: string): void {
    this.instances.get(program)?.reset()
  }

  /** Cancel path: terminate the instance and remove it from the pool. */
  terminate(program: string): void {
    const instance = this.instances.get(program)
    if (instance === undefined) return
    instance.terminate()
    this.instances.delete(program)
  }

  /** Cancel/dispose path for every tool. */
  terminateAll(): void {
    for (const instance of this.instances.values()) instance.terminate()
    this.instances.clear()
  }

  /** The current instance, without creating one. */
  get(program: string): HotInstance | undefined {
    return this.instances.get(program)
  }

  /** Snapshots for diagnostics and tests. */
  diagnostics(): readonly HotInstanceDiagnostics[] {
    return [...this.instances.values()].map(instance => instance.diagnostics())
  }
}

function mergeMemoryImports(
  imports: WebAssembly.Imports,
  descriptors: readonly ModuleImportDescriptorLike[],
  memory: WebAssembly.Memory,
): WebAssembly.Imports {
  const merged: Record<string, Record<string, unknown>> = {}
  for (const [moduleName, values] of Object.entries(imports)) {
    merged[moduleName] = { ...(values as Record<string, unknown>) }
  }
  for (const descriptor of descriptors) {
    merged[descriptor.module] = { ...(merged[descriptor.module] ?? {}), [descriptor.name]: memory }
  }
  return merged as WebAssembly.Imports
}
