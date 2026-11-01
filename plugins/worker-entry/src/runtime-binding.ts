// SPDX-License-Identifier: MIT
/**
 * The only module that imports the pinned DeepSeek Harness webworker runtime.
 *
 * `entry.ts` loads this module with a dynamic import so the entry's pure logic
 * (sink encoding, API bridge, console mirror, tests) can run in Node without the
 * checkout, and the esbuild bundle still resolves the runtime's source through
 * `PDSH_DSH_CHECKOUT`.
 *
 * The imports and the top-level platform installation mirror the runtime's own
 * `worker.ts`: the same `createNodeBuiltins()` / `REPLACED_PREFIXES` module
 * table, the same captured `whenRequestListener`, the same async-context,
 * timer and crypto globals, and the same shell-process role dispatch. DSH stays
 * a pinned dependency: nothing here is copied from or patches the checkout.
 * @module @phone-dsh/dsh-worker-entry/runtime-binding
 */
import { createWorkerHost } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/worker-host.ts'
import '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/buffer.ts'
import { alsCausality, runAtAsyncContextRoot } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/async_hooks.ts'
import { createNodeBuiltins, REPLACED_PREFIXES } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtins.ts'
import { whenRequestListener } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/http.ts'
import { installCryptoGlobals } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/globals/crypto.ts'
import { installProcessGlobal } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/globals/process.ts'
import { installTimerGlobals } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/globals/timers.ts'
import { installAsyncContextHooks } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/polyfill/async-context/async-context-hooks.ts'
import { isShellStartFrame, type RuntimeShellStartFrame } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/shell/process/protocol.ts'
import { runShellProcess } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/shell/process/host.ts'
import { createSyntheticExchange } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/transport/synthetic-http.ts'
import { constants as runtimeFsConstants, promises as runtimeFsPromises } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/fs.ts'
import { setActiveVfs } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/active.ts'
import { DEFAULT_ROOT, IMAGE_MANIFEST_PATH } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/image-layout.ts'
import { requireActiveModuleLoader } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/module-system/module-loader.ts'
import moduleShim from './module-shim.ts'
import { captureNodeTimerPrototypes, installNodeTimerCompat } from './node-timer-compat.ts'
import { installExecFsPolicy, type VfsNamespace } from '../../wasi-toolbox/src/index.ts'
import {
  APP_BOOT_SPECIFIER, createAppBootShim, loadPinnedModule, type AppBootModule,
} from './fs-read-state.ts'
import {
  NODE_MODULE_SPECIFIERS, PHONE_STATIC_MODULE_OVERRIDES, composePhoneStaticModules, type StaticModuleFactory,
} from './static-modules.ts'
import { installModuleImportDiagnostics, type ImportSeamLoader } from './module-import.ts'
import { installByteFaithfulWrites, type FsStringWriteFace } from './write-encoding.ts'
import { installNumericOpenFlags } from './numeric-open-flags.ts'
import { installBoundedDirectoryOpener, type BoundedDirectoryVfs } from './bounded-opendir.ts'

// The runtime's worker.ts installs these before its message listener exists, so
// every image module sees the same patched platform. Keep the order.
installAsyncContextHooks()
captureNodeTimerPrototypes()
installTimerGlobals()
installNodeTimerCompat()
installCryptoGlobals()

/** Port the runtime tunnel posts page-facing frames through. */
export interface PhoneRuntimeTunnelPort {
  postMessage(message: unknown, transfer?: Transferable[]): void
}

/** Inputs the entry supplies when it builds the DSH worker host. */
export interface PhoneRuntimeHostOptions {
  readonly image: string
  /** Ordered overlays: gzip bytes or fetchable URLs, applied after the image. */
  readonly overlays: readonly (string | Uint8Array)[]
  readonly env?: Readonly<Record<string, string>> | undefined
  /** Tunnel port; the entry observes it to bridge `/api/remote.mux`. */
  readonly channel?: PhoneRuntimeTunnelPort | undefined
  /**
   * Override for the staged Worker workflow engine factory. Production omits
   * it; tests that cannot load a package from a booted image may supply a stub.
   */
  readonly workflowPtcFactory?: StaticModuleFactory | undefined
  /**
   * Optional wrapper around the pinned app-boot module, applied once per Worker
   * after it loads from the image and before it runs. The runtime does not
   * expose the live Cordis context app-boot returns, so an embedding probe uses
   * this to observe the same module instance the production factory built. It
   * must return the module (or a transparent wrapper); production leaves it
   * unset.
   */
  readonly wrapAppBoot?: ((module: AppBootModule) => AppBootModule) | undefined
}

/**
 * Lazy factory for the staged Worker workflow engine served for
 * `require('@deepseek-ai/dsh-workflow-ptc')`.
 *
 * The standard preset names the official package. Loading it through the
 * active image loader keeps the official package graph (its dependencies and
 * package identity) while the export itself is the Worker bridge that injects
 * `subagents`/`workingDirectory` instead of `ptcRuntime`.
 * @returns a static-module factory that loads the engine on first require.
 */
export function createWorkflowPtcFactory(): StaticModuleFactory {
  let module: Record<string, unknown> | undefined
  return () => {
    module ??= loadPinnedModule(
      requireActiveModuleLoader(),
      DEFAULT_ROOT,
      '@phone-dsh/dsh-workflow-worker',
      'default',
    )
    return module
  }
}

/** Build the runtime's worker host with the official Node-compatibility table. */
export function createPhoneWorkerHost(options: PhoneRuntimeHostOptions): ReturnType<typeof createWorkerHost> {
  /**
   * The wrapped `@deepseek-ai/dsh-app-boot` module, loaded once per Worker from
   * the image. The runtime's static-module factories are not memoized, so the
   * wrapper keeps the module instance stable across repeated `require()` calls.
   * It is per host: two hosts in one process must not share one Worker's boot
   * module (and the observer of one must not leak into the other).
   */
  let appBootModule: AppBootModule | undefined
  /**
   * Load and wrap the pinned app-boot module from the mounted image.
   *
   * The package is resolved by its directory, not by `@deepseek-ai/...`: that
   * specifier is exactly what the static table is overriding, so resolving it by
   * name would recurse. `requireActiveModuleLoader()` is the loader the runtime
   * published before app-boot ran.
   * @returns the wrapped app-boot module.
   */
  const appBootFactory = (): AppBootModule => {
    const loader = requireActiveModuleLoader()
    // JavaScriptCore's stack omits the error message, so an import failure would
    // otherwise reach app-boot's audit as bare frames (`anonymous@`). Wrap the one
    // loader seam here, before app-boot imports any profile entry. The wrapper
    // keeps the failure and replaces the thrown value with controlled fields
    // (known type, fixed code, strict specifier and known static locations); the
    // raw message, stack, cause and custom fields are never forwarded.
    installModuleImportDiagnostics(loader as unknown as ImportSeamLoader)
    appBootModule ??= (options.wrapAppBoot ?? ((module: AppBootModule): AppBootModule => module))(
      createAppBootShim(
        loadPinnedModule(loader, process.cwd(), APP_BOOT_SPECIFIER, 'boot') as unknown as AppBootModule,
      ),
    )
    return appBootModule
  }
  const modules = composePhoneStaticModules(createNodeBuiltins(), {
    ...PHONE_STATIC_MODULE_OVERRIDES,
    appBoot: appBootFactory,
    workflowPtc: options.workflowPtcFactory ?? createWorkflowPtcFactory(),
  })
  // The runtime's `require.resolve.paths` reports `null` for every static
  // package specifier; the compatibility preflight needs the image package
  // manifest for the Worker workflow/presentation overrides. Wrap only that
  // metadata path, not resolution or loading.
  for (const specifier of NODE_MODULE_SPECIFIERS) modules[specifier] = () => moduleShim
  const host = createWorkerHost({
    // The runtime table plus this layer's overrides: `sharp` becomes the
    // Worker-side raster shim instead of the runtime's notImplementedFail stub
    // (G2-FIX-60), and app-boot is wrapped to mount the fs read-state replay
    // before the profile tree so a resumed session's durable reads reach the
    // unmodified observation policy (G2-FIX-36). Every other entry is the
    // runtime's own.
    staticModules: modules,
    staticModulePrefixes: REPLACED_PREFIXES,
    requestListener: whenRequestListener,
    alsCausality,
    image: options.image,
    overlays: options.overlays,
    ...options.env === undefined ? {} : { env: options.env },
    ...options.channel === undefined ? {} : { channel: options.channel },
  })
  // A tunnel request belongs to no async boundary; dispatch it at the context
  // root exactly as the runtime's own worker.ts does, so it cannot inherit
  // whatever ran just before it on this thread.
  return {
    handleMessage: (data: unknown): void => { runAtAsyncContextRoot(() => { host.handleMessage(data) }) },
    start: () => host.start(),
    stop: () => host.stop(),
    get vfs() { return host.vfs },
    get modules() { return host.modules },
  }
}

/**
 * Run one shell-role Worker (a `bash -c` child process spawned by the runtime's
 * `child_process` shim from this same bundle).
 * @param data - The `shell-start` frame.
 */
export function runShellRole(data: unknown): void {
  if (!isShellStartFrame(data)) throw new Error('worker entry: shell role needs a shell-start frame')
  const frame: RuntimeShellStartFrame = data
  installProcessGlobal({ cwd: frame.cwd, env: frame.env })
  runShellProcess(frame, (globalThis as { self?: unknown }).self)
}

/**
 * Publish the namespace-wrapped VFS as the filesystem the runtime's `node:fs`
 * proxy reads.
 *
 * The host installs its own `MemoryVfs` during `start()`; the entry replaces
 * that slot with the namespace proxy immediately afterwards, so every later
 * `node:fs` call (DSH tool or Worker adapter) resolves `/tmp` and `/dsh/tmp`
 * to the same storage path. The host's own `MemoryVfs` stays the authority —
 * the proxy only canonicalises the path before delegating.
 * @param vfs - the namespace-wrapped VFS.
 */
export function activateWorkerVfs(vfs: unknown): void {
  setActiveVfs(vfs as Parameters<typeof setActiveVfs>[0])
}

/**
 * Apply the exec read policy to the one `node:fs.promises` object the Worker
 * adapters hold.
 *
 * `VfsFileSystem` (the Worker shell) and `NodeGitFs` both do
 * `import { promises as fsp } from 'node:fs'`, so they observe this object's
 * members at call time. DSH's own services import named members from
 * `node:fs/promises`, which `fs/promises.ts` destructured once at module load;
 * they keep their bound functions and continue to read the session state they
 * own. This is the one seam that gives the execution surfaces the same read
 * policy without changing a pinned DSH module.
 * @param namespace - path authority carrying the policy.
 * @returns a disposer restoring the original promise functions.
 */
export function installWorkerExecFsPolicy(namespace: VfsNamespace): () => void {
  return installExecFsPolicy(runtimeFsPromises, namespace)
}

/**
 * Add a capture-only bounded opener to the same virtual `node:fs.promises` face.
 *
 * The pinned runtime's `opendir` materialises the complete directory listing
 * inside the call. This installer wraps that member after the exec policy so
 * the path alias and the private-namespace refusal still run, but the shared
 * member itself stays transparent for ordinary DSH/session/storage reads. A
 * separate function marker lets the Worker command capture opt into the
 * preflight. The bound combines public `MemoryVfs.usage()` with the pinned
 * image manifest's initial lazy registrations and later public
 * `deferArchive()` calls. The host's real Node `fs.promises` object is not
 * touched; only the runtime's virtual module face is.
 * @param vfs - the mounted (unwrapped) VFS whose public face provides the bound.
 * @param maxEntries - whole-VFS ceiling; defaults to the Worker command default.
 * @param check - optional install-level deadline/abort check. The Worker
 *   command capture supplies its own check per call (the production path);
 *   this parameter lets a boot-time caller add another boundary.
 * @returns a disposer restoring the previous opener and deferArchive.
 */
export function installWorkerBoundedDirectoryOpener(
  vfs: unknown,
  maxEntries?: number,
  check?: () => void,
): () => void {
  return installBoundedDirectoryOpener({
    vfs: vfs as BoundedDirectoryVfs,
    fs: runtimeFsPromises as unknown as Parameters<typeof installBoundedDirectoryOpener>[0]['fs'],
    manifestPath: `${DEFAULT_ROOT}/${IMAGE_MANIFEST_PATH}`,
    ...maxEntries === undefined ? {} : { maxEntries },
    ...check === undefined ? {} : { check },
  })
}

/**
 * Add the pinned runtime's missing numeric open capability before bootstrap.
 *
 * `node:fs` and `node:fs/promises` share the runtime's one `constants` object,
 * so adding its absent `O_EXCL` here makes DSH's numeric
 * `O_CREAT | O_EXCL | O_WRONLY` a real mask. The mounted VFS is wrapped by
 * `namespace-boot.ts` with the matching interpreter; this installer only owns
 * the virtual constants table.
 * @returns a disposer restoring the table.
 */
export function installWorkerNumericOpenFlags(): () => void {
  return installNumericOpenFlags({ constants: runtimeFsConstants as unknown as Record<string, unknown> })
}

/**
 * Make the runtime's encoding-ignoring string writes byte-faithful.
 *
 * The pinned runtime's `node:fs` bridge stores the UTF-8 encoding of a string
 * and ignores a declared Node string encoding (upstream contract gap). The
 * Worker shell supplies Node's byte encodings — just-bash redirections hand it
 * a latin1-shaped `ByteString` with `{encoding: 'binary'}` — so without this
 * shim those bytes are double-encoded before the sink ever sees them. Install
 * before {@link installWorkerExecFsPolicy} so the read-policy wrapper composes
 * on top and both disposers unwind in LIFO order.
 * @returns a disposer restoring the original write faces.
 */
export function installWorkerByteFaithfulWrites(): () => void {
  return installByteFaithfulWrites(runtimeFsPromises as unknown as FsStringWriteFace)
}

export { whenRequestListener, createSyntheticExchange }
