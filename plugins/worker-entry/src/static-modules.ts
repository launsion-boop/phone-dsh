// SPDX-License-Identifier: MIT
/**
 * The phone Worker's static-module table: the runtime's Node/Browser
 * compatibility table with our own physical seams layered on top.
 *
 * The overrides today:
 *
 *  - the pinned runtime lists `sharp` in `REPLACED_EXTERNAL_PACKAGES` and
 *    serves a `notImplementedFail` stub from `MODULE_PROXIES`; that entry is
 *    what makes every valid image look malformed to attachment-local;
 *  - `@deepseek-ai/dsh-app-boot` is wrapped by `fs-read-state.ts` to mount one
 *    extra plugin before the profile tree (G2-FIX-36). The fs observation
 *    policy keeps its read-before-write state only in the live session object,
 *    so a Worker rebuild loses it and a resumed session is forced to re-read
 *    every previously read file; the extra plugin replays the durable
 *    session's observing calls through the policy's own `fs/observed` event.
 *    The policy row and its module stay untouched: replacing that specifier
 *    would hide its package metadata from the profile compatibility preflight;
 *  - `@deepseek-ai/dsh-workflow-ptc` is served by the Worker-native workflow
 *    engine staged as `@phone-dsh/dsh-workflow-worker`. The official engine
 *    injects a PTC runtime the phone deliberately does not mount; the Worker
 *    bridge keeps the official meta/workflow semantics and runs the script in
 *    a separate workflow Worker;
 *  - `@deepseek-ai/dsh-agent-tool-presentation` is served by the phone
 *    equivalent presentation row: `ptc` degrades to real native presentation
 *    only while no PTC runtime exists, instead of leaving the preset pending;
 *  - `@deepseek-ai/dsh-terminal` refuses its mount: the Worker has no OS PTY,
 *    and leaving the service mounted would report `minimal` healthy until its
 *    first terminal call. The refusal names the phone-shell alternative;
 *  - `node:vm` is the DSH Worker's compile-only face for the parent workflow
 *    syntax check. The workflow isolate is built separately with
 *    `workflow-worker/src/quickjs-vm.ts`, a real QuickJS/WASM realm; no user
 *    script executes in this Worker.
 *
 * Overriding the exact specifier here — after the runtime table is built — is
 * the module-replacement seam the runtime documents for platform-specific
 * modules, and it needs no DSH patch.
 *
 * The function is deliberately free of runtime imports: `runtime-binding.ts`
 * passes `createNodeBuiltins()` in, so tests can compose the same table
 * without loading the pinned checkout's whole proxy graph.
 * @module @phone-dsh/dsh-worker-entry/static-modules
 */
import { APP_BOOT_SPECIFIER } from './fs-read-state.ts'
import { SHARP_MODULE_SPECIFIER } from './sharp-marker.ts'
import { sharpShim, type SharpFactory } from './sharp-shim.ts'
import terminalShim from './terminal-shim.ts'
import toolPresentationShim from './tool-presentation-shim.ts'
import vmShim, { type Script } from './vm-shim.ts'

/** Package specifier the standard preset's `workflow-ptc` row resolves. */
export const WORKFLOW_PTC_SPECIFIER = '@deepseek-ai/dsh-workflow-ptc'

/** Package specifier the ptc preset's presentation row resolves. */
export const TOOL_PRESENTATION_SPECIFIER = '@deepseek-ai/dsh-agent-tool-presentation'

/** Official persistent-terminal provider; the phone Worker has no PTY. */
export const TERMINAL_SPECIFIER = '@deepseek-ai/dsh-terminal'

/** Both spellings the image's Node compatibility layer can request for `node:vm`. */
export const VM_MODULE_SPECIFIERS = Object.freeze(['node:vm', 'vm'])

/** Both spellings for the wrapped `node:module` metadata face. */
export const NODE_MODULE_SPECIFIERS = Object.freeze(['node:module', 'module'])

/** Structural `node:vm` namespace this table exposes. */
export interface VmShimModule {
  readonly Script: typeof Script
  readonly createContext: typeof vmShim.createContext
  readonly runInContext: typeof vmShim.runInContext
  readonly runInNewContext: typeof vmShim.runInNewContext
  readonly runInThisContext: typeof vmShim.runInThisContext
  readonly isContext: typeof vmShim.isContext
  readonly default: unknown
}

/** One entry of the runtime's static-module table. */
export type StaticModuleFactory = () => unknown

/** Static modules this layer replaces in the Worker runtime's table. */
export interface PhoneStaticModuleOverrides {
  /** Callable `sharp` replacement served for `require('sharp')`. */
  readonly sharp: SharpFactory
  /**
   * Factory for the wrapped `@deepseek-ai/dsh-app-boot` module.
   *
   * Omitted by pure table tests that do not load the pinned checkout; the
   * production runtime binding installs the wrapper that reads the image.
   */
  readonly appBoot?: StaticModuleFactory
  /**
   * Factory for the staged `@phone-dsh/dsh-workflow-worker` engine.
   *
   * The production binding loads it lazily from the active image loader, so
   * this table stays free of checkout/image imports.
   */
  readonly workflowPtc?: StaticModuleFactory
  /** The Worker-native presentation row. */
  readonly toolPresentation?: StaticModuleFactory
  /** Loud refusal for the official persistent-terminal provider. */
  readonly terminal?: StaticModuleFactory
  /** The restricted `node:vm` face used by the isolated workflow realm. */
  readonly vm?: StaticModuleFactory
}

/** The overrides this layer installs without any image access. */
export const PHONE_STATIC_MODULE_OVERRIDES: PhoneStaticModuleOverrides = Object.freeze({
  sharp: sharpShim,
  toolPresentation: () => toolPresentationShim,
  terminal: () => terminalShim,
  vm: () => vmShim,
})

/**
 * Copy the runtime's static table and install the phone layer's overrides.
 *
 * The runtime's loader consults this exact-specifier map before filesystem
 * resolution and before its prefix table, so the last assignment wins for every
 * `require('sharp')` in the image — including `createLazyRequire` from
 * attachment-local, which reads the module on first raster operation.
 * @param base - the runtime's table (`createNodeBuiltins()`).
 * @param overrides - shim instances to install; production uses the exported defaults.
 * @returns a new table with this layer's entries in place.
 */
export function composePhoneStaticModules(
  base: Readonly<Record<string, StaticModuleFactory>>,
  overrides: PhoneStaticModuleOverrides = PHONE_STATIC_MODULE_OVERRIDES,
): Record<string, StaticModuleFactory> {
  const modules: Record<string, StaticModuleFactory> = { ...base }
  modules[SHARP_MODULE_SPECIFIER] = () => overrides.sharp
  if (overrides.appBoot !== undefined) {
    modules[APP_BOOT_SPECIFIER] = overrides.appBoot
  }
  if (overrides.workflowPtc !== undefined) {
    modules[WORKFLOW_PTC_SPECIFIER] = overrides.workflowPtc
  }
  if (overrides.toolPresentation !== undefined) {
    modules[TOOL_PRESENTATION_SPECIFIER] = overrides.toolPresentation
  }
  if (overrides.terminal !== undefined) {
    modules[TERMINAL_SPECIFIER] = overrides.terminal
  }
  if (overrides.vm !== undefined) {
    for (const specifier of VM_MODULE_SPECIFIERS) modules[specifier] = overrides.vm
  }
  return modules
}
