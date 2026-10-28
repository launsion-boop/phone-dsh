// SPDX-License-Identifier: MIT
/**
 * Durable read-state restore for DSH's filesystem observation policy
 * (G2-FIX-36).
 *
 * `@deepseek-ai/dsh-fs-observation-policy` keeps the read-before-write state
 * in an in-memory `WeakMap` keyed by the live agent session. The pinned
 * package documents the consequence: observations do not survive a session
 * resume, so a resumed agent must re-read every target before a guarded write
 * or edit. On the phone a park/resume rebuilds the Worker and resumes the
 * session from its durable JSONL log; every file read in an earlier turn is
 * still in that log, but the policy's state is gone. The model then burns a
 * whole turn re-reading files it has already read.
 *
 * The upstream plugin exposes no restore hook. This module is the minimal
 * worker-entry shim: it wraps DSH's app-boot `boot()` only to mount one extra
 * Cordis plugin on the host context before the profile tree, and that plugin:
 *
 *  1. mirrors the real policy's live observations (`fs/observed`) only to know
 *     which targets already have in-memory state;
 *  2. captures the versions when an agent/session is published (the resume
 *     boundary) and the first time a session asks for `fs/write-intent` or
 *     `fs/edit-intent`; it replays that session's successful observing tool
 *     calls (`read`, `read_image`, `write`, `edit`) from
 *     `session.snapshotEvents()` as ordinary `fs/observed` events, with the
 *     target resolved and stat'ed against the current filesystem;
 *  3. delegates every decision to the unmodified pinned policy through the
 *     waterfall's `next()`.
 *
 * It never manufactures an intent: the provider's version guard still fences a
 * concurrent change, and a target that was never read or written in the
 * session is never observed, so the policy still decides `createIfAbsent` and
 * the provider still refuses to overwrite it with `FS_NOT_OBSERVED`.
 *
 * The pinned policy module itself is **not** replaced in the static-module
 * table: the profile compatibility preflight resolves every profile row's real
 * package metadata through `createRequire.resolve.paths`, and a static
 * replacement would hide that package from it (the row would be disabled).
 * Wrapping `@deepseek-ai/dsh-app-boot` leaves all profile rows resolving
 * normally and needs no DSH source patch.
 *
 * The durable tool result does not carry the provider's opaque version token,
 * so the replayed observation uses the target's current version (the policy
 * only needs the version that a later guarded mutation must still match).
 * Changes made between the original read and the rebuild cannot be compared
 * without that token; that limitation is recorded as a contract gap in the
 * final report and in the worker-entry README.
 * @module @phone-dsh/dsh-worker-entry/fs-read-state
 */

/** Pinned app-boot module this layer wraps to mount the replay plugin. */
export const APP_BOOT_SPECIFIER = '@deepseek-ai/dsh-app-boot'

/** Name of the Cordis plugin mounted before the profile tree. */
export const READ_STATE_PLUGIN_NAME = 'pdsh-fs-read-state'

/** Tool calls that emit an `fs/observed` event on success (dsh-tool-fs 0.2.1). */
export const OBSERVING_TOOL_NAMES: ReadonlySet<string> = new Set(['read', 'read_image', 'write', 'edit'])

/** One resolved filesystem target, structurally from `@deepseek-ai/dsh-fs`. */
export interface FsObservationTarget {
  readonly targetKey: string
  readonly displayPath: string
}

/** `ctx.fs.stat()`'s relevant fields, structurally from `@deepseek-ai/dsh-fs`. */
export interface FsObservationInfo {
  readonly version: string
  readonly type: 'file' | 'directory' | 'other'
}

/** The `ctx.fs` subset the replay needs. */
export interface FsObservationFileSystem {
  resolve(path: string, options?: { cwd?: string; signal?: AbortSignal }): Promise<FsObservationTarget>
  stat(target: FsObservationTarget, signal?: AbortSignal): Promise<FsObservationInfo | undefined>
}

/** The Cordis `Context` subset the replay uses. */
export interface FsObservationPolicyContext {
  on(name: string, listener: (...args: any[]) => unknown, options?: { readonly prepend?: boolean }): unknown
  get(name: string): unknown
  emit(name: string, ...args: unknown[]): void
}

/** The app-boot module face this layer wraps; every other export passes through. */
export interface AppBootModule {
  boot(...args: any[]): Promise<unknown>
}

/** The image loader subset used to load the pinned module by package path. */
export interface PinnedModuleLoader {
  resolve(specifier: string, fromDirectory: string): unknown
  load(resolution: unknown): unknown
}

/** One `Session.snapshotEvents()` event, structurally from `@deepseek-ai/dsh-session`. */
interface SessionEventLike {
  readonly type?: unknown
  readonly data?: unknown
}

/** One session object as the policy and the durable log expose it. */
interface SessionLike {
  snapshotEvents?: () => readonly SessionEventLike[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Derive the observed-state owner exactly as the policy does: the live agent
 * session carried on the tool execution actor.
 * @param actor - opaque `fs/*` event actor (the tool execution).
 * @returns the session object used as the policy's weak-map key, or undefined.
 */
function ownerSession(actor: unknown): SessionLike | undefined {
  if (!isRecord(actor)) return undefined
  const agent = actor.agent
  if (!isRecord(agent)) return undefined
  const session = agent.session
  return isRecord(session) ? session as SessionLike : undefined
}

/**
 * Extract every target path that the durable session observed successfully.
 *
 * The event log is the source of truth: a `tool/result` only counts when its
 * paired `tool/call` names one of {@link OBSERVING_TOOL_NAMES} and the result
 * is not an error. The path comes from the tool's persisted `meta.path`, the
 * canonical absolute path DSH writes into the session log.
 * @param events - one session's `snapshotEvents()` array.
 * @returns deduplicated absolute paths in first-observed order.
 */
export function observedPathsFromSessionEvents(events: readonly unknown[]): string[] {
  const calls = new Map<string, string>()
  const paths = new Set<string>()
  for (const event of events) {
    if (!isRecord(event)) continue
    const data = event.data
    if (!isRecord(data)) continue
    if (event.type === 'tool/call') {
      const callId = data.callId
      const name = data.name
      if (typeof callId === 'string' && typeof name === 'string') calls.set(callId, name)
      continue
    }
    if (event.type !== 'tool/result') continue
    const message = data.message
    if (!isRecord(message) || message.isError === true) continue
    const callId = message.toolCallId
    const name = typeof callId === 'string' ? calls.get(callId) : undefined
    if (name === undefined || !OBSERVING_TOOL_NAMES.has(name)) continue
    const meta = data.meta
    if (!isRecord(meta) || typeof meta.path !== 'string' || meta.path === '') continue
    paths.add(meta.path)
  }
  return [...paths]
}

/**
 * Choose a package entry file from an unpacked `package.json`.
 *
 * The image loader is asked for the package by directory so this never goes
 * through the specifier table (which is what is being overridden). `exports`
 * is preferred over `main`, matching Node's resolution for the pinned module.
 * @param manifest - parsed `package.json` value.
 * @param fallback - package-relative entry when the manifest names none.
 * @returns a package-relative entry path.
 */
export function selectPackageEntry(manifest: unknown, fallback = 'lib/index.js'): string {
  if (!isRecord(manifest)) return fallback
  const exported = manifest.exports
  if (typeof exported === 'string') return exported
  if (isRecord(exported)) {
    const root = exported['.']
    if (typeof root === 'string') return root
    if (isRecord(root)) {
      for (const condition of ['browser', 'import', 'require', 'default'] as const) {
        const candidate = root[condition]
        if (typeof candidate === 'string') return candidate
      }
    }
  }
  if (typeof manifest.main === 'string' && manifest.main !== '') return manifest.main
  return fallback
}

/**
 * Load one pinned module from the image by package directory and wrap it.
 *
 * The module is resolved by its directory and a relative entry path rather
 * than by specifier: the specifier is already answered by this layer's static
 * module table, so asking for it would recurse into the wrapper.
 * @param loader - the active image module loader.
 * @param root - the Worker's virtual root (`/dsh`).
 * @param specifier - the pinned package to load (e.g. `@deepseek-ai/dsh-app-boot`).
 * @param member - the export the caller needs (e.g. `boot`).
 * @returns the loaded module object.
 */
export function loadPinnedModule(
  loader: PinnedModuleLoader,
  root: string,
  specifier: string,
  member: string,
): Record<string, unknown> {
  const packageDirectory = `${root.replace(/\/+$/u, '')}/node_modules/${specifier}`
  const manifest = loader.load(loader.resolve('./package.json', packageDirectory))
  const entry = selectPackageEntry(manifest)
  const relative = entry.startsWith('.') ? entry : `./${entry}`
  const module = loader.load(loader.resolve(relative, packageDirectory))
  if (!isRecord(module) || typeof module[member] !== 'function') {
    throw new Error(`worker entry: ${specifier} at ${packageDirectory}/${entry} does not export ${member}()`)
  }
  return module
}

/** The plugin mounted before the profile tree; it only registers the replay. */
const READ_STATE_PLUGIN = {
  name: READ_STATE_PLUGIN_NAME,
  apply(ctx: FsObservationPolicyContext): void {
    installDurableReadState(ctx)
  },
}

/**
 * Wrap the pinned app-boot module so the read-state plugin is mounted before
 * the profile tree, then run the launcher's own prepare step.
 *
 * All other app-boot exports pass through unchanged. The wrapper is a shim on
 * the host's boot glue, not a replacement of any DSH plugin row: the profile
 * compatibility preflight and the image loader still resolve every pinned
 * package normally.
 * @param real - the pinned `@deepseek-ai/dsh-app-boot` module.
 * @returns a module whose `boot()` installs the replay first.
 */
export function createAppBootShim(real: AppBootModule): AppBootModule {
  return {
    ...real,
    boot(
      binName: string,
      configPath: string,
      patches: unknown[] | undefined,
      prepare?: (ctx: FsObservationPolicyContext) => unknown,
      bareModuleBaseUrl?: string,
    ): Promise<unknown> {
      const prepareWithReadState = async (ctx: FsObservationPolicyContext): Promise<void> => {
        // Mount before the launcher's prepare step and before any profile row:
        // the prepended intent listeners must precede the real policy's
        // single-slot deciders, and the resume listener must exist before the
        // first agent can be created.
        await (ctx as unknown as { plugin(plugin: unknown): Promise<unknown> }).plugin(READ_STATE_PLUGIN)
        await prepare?.(ctx)
      }
      return real.boot(binName, configPath, patches, prepareWithReadState, bareModuleBaseUrl)
    },
  }
}

/**
 * Register the replay on the host context.
 *
 * State is per mounted plugin instance (one per Worker tree, exactly like the
 * real gate's WeakMap): the mirror and the per-session seed promises are closed
 * over, so a reloaded tree starts clean and a Worker rebuild installs a new
 * instance.
 * @param ctx - the host context, before the profile tree mounts.
 */
export function installDurableReadState(ctx: FsObservationPolicyContext): void {
  /** Targets that already have a live in-memory observation for a session. */
  const observed = new WeakMap<object, Set<string>>()
  /** One replay per session; cleared on failure so a later intent retries. */
  const seeding = new WeakMap<object, Promise<void>>()

  const markObserved = (target: unknown, actor: unknown): void => {
    const session = ownerSession(actor)
    if (session === undefined || !isRecord(target) || typeof target.targetKey !== 'string') return
    let keys = observed.get(session)
    if (keys === undefined) {
      keys = new Set()
      observed.set(session, keys)
    }
    keys.add(target.targetKey)
  }

  ctx.on('fs/observed', (target: unknown, _observation: unknown, actor: unknown) => {
    markObserved(target, actor)
  })

  const seed = async (session: SessionLike): Promise<boolean> => {
    const fs = ctx.get('fs') as FsObservationFileSystem | undefined
    if (fs === undefined) return false
    const paths = typeof session.snapshotEvents === 'function'
      ? observedPathsFromSessionEvents(session.snapshotEvents())
      : []
    if (paths.length === 0) return true
    const already = observed.get(session)
    const actor = { agent: { session } }
    for (const path of paths) {
      let resolved: FsObservationTarget
      try {
        resolved = await fs.resolve(path)
      } catch {
        continue
      }
      if (already?.has(resolved.targetKey) === true) continue
      let info: FsObservationInfo | undefined
      try {
        info = await fs.stat(resolved)
      } catch {
        continue
      }
      if (info === undefined) {
        ctx.emit('fs/observed', resolved, { kind: 'absent' }, actor)
        continue
      }
      if (info.type !== 'file') continue
      ctx.emit('fs/observed', resolved, { kind: 'present', version: info.version }, actor)
    }
    return true
  }

  const ensureSeeded = (session: SessionLike): Promise<void> => {
    let pending = seeding.get(session)
    if (pending === undefined) {
      pending = seed(session).then((seeded) => {
        // The fs service is mounted by the time tools run; a resume listener
        // that fired earlier must not suppress the intent-time retry.
        if (!seeded) seeding.delete(session)
      }).catch((error: unknown) => {
        seeding.delete(session)
        console.warn('worker entry: read-state restore skipped for this intent', error)
      })
      seeding.set(session, pending)
    }
    return pending
  }

  const replayBeforeIntent = async (target: FsObservationTarget, actor: unknown, next: () => unknown): Promise<unknown> => {
    const session = ownerSession(actor)
    if (session === undefined) return next()
    // A live observation in this Worker is authoritative: never replace it
    // with a value read from the durable log.
    if (observed.get(session)?.has(target.targetKey) === true) return next()
    await ensureSeeded(session)
    return next()
  }

  // Capture the versions at session publication (resume/rebuild), before any
  // new command can touch the tree. The intent-time replay below is the
  // fallback for a listener that fired before the fs service mounted.
  ctx.on('agent/created', (payload: unknown) => {
    if (!isRecord(payload) || !isRecord(payload.agent)) return
    const session = ownerSession({ agent: payload.agent })
    if (session === undefined) return
    return ensureSeeded(session)
  })

  ctx.on('fs/write-intent', replayBeforeIntent, { prepend: true })
  ctx.on('fs/edit-intent', replayBeforeIntent, { prepend: true })
}
