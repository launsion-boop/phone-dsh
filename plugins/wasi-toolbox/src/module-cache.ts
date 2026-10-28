// SPDX-License-Identifier: MIT
/**
 * Compile-once module cache. `WebAssembly.Module` is structured-cloneable, so a
 * module compiled in the DSH worker is posted to each tool worker without
 * recompiling its bytes; concurrent requests for the same URL share one
 * in-flight compile. One URL is one compile for the lifetime of the cache.
 * @module @phone-dsh/dsh-wasi-toolbox/module-cache
 */
import type { MessageEndpoint } from './message-endpoint.ts'
import type { ToolboxModuleSource } from './types.ts'

/** Loader that turns a URL into wasm bytes. */
export type ModuleBytesLoader = () => Promise<Uint8Array>

/** Construction inputs of {@link ModuleCache}. */
export interface ModuleCacheOptions {
  /** Override for tests; defaults to `WebAssembly.compile`. */
  readonly compile?: (bytes: Uint8Array) => Promise<WebAssembly.Module>
}

/** Cache of compiled wasm modules keyed by source URL. */
export class ModuleCache {
  private readonly modules = new Map<string, WebAssembly.Module>()
  private readonly inflight = new Map<string, Promise<WebAssembly.Module>>()
  private readonly compileImpl: (bytes: Uint8Array) => Promise<WebAssembly.Module>
  private compileCount = 0

  constructor(options: ModuleCacheOptions = {}) {
    this.compileImpl = options.compile ?? (async bytes => WebAssembly.compile(new Uint8Array(bytes).buffer))
  }

  /** Number of byte-to-module compiles performed. */
  get compiles(): number {
    return this.compileCount
  }

  /** Number of cached modules. */
  get size(): number {
    return this.modules.size
  }

  has(url: string): boolean {
    return this.modules.has(url)
  }

  get(url: string): WebAssembly.Module | undefined {
    return this.modules.get(url)
  }

  /** Compile a source once and return the shared module. */
  async getModule(source: ToolboxModuleSource): Promise<WebAssembly.Module> {
    const cached = this.modules.get(source.url)
    if (cached !== undefined) return cached
    const pending = this.inflight.get(source.url)
    if (pending !== undefined) return pending
    const compiling = (async () => {
      const bytes = await source.load()
      const module = await this.compileImpl(bytes)
      this.compileCount += 1
      this.modules.set(source.url, module)
      return module
    })()
    this.inflight.set(source.url, compiling)
    try {
      return await compiling
    } finally {
      this.inflight.delete(source.url)
    }
  }

  /** Compile bytes under an explicit URL (used by tests and preloaders). */
  async compile(url: string, loader: ModuleBytesLoader): Promise<WebAssembly.Module> {
    return this.getModule({ url, load: loader })
  }

  /** Post a cached module to a tool worker as a structured clone. */
  share(endpoint: MessageEndpoint, url: string): void {
    const module = this.modules.get(url)
    if (module === undefined) throw new Error(`module ${url} is not cached`)
    endpoint.postMessage({ type: 'wasm-module', url, module })
  }

  /** Diagnostics for `WasiToolbox.stats()`. */
  stats(): { readonly modules: number; readonly compiles: number } {
    return { modules: this.modules.size, compiles: this.compileCount }
  }
}
