// SPDX-License-Identifier: MIT
/**
 * JSONL session persistence with tool-journal reconciliation on write-open,
 * for DSH 0.2.1.
 *
 * DSH 0.2.1's `session-persistence-jsonl` is a function plugin that owns a
 * private service class, so the 0.1.7 subclass wrapper
 * (`@phone-dsh/dsh-tool-journal/persistence`) cannot mount any more. This
 * module mounts the shipped backend itself (the shipped row stays disabled, as
 * the phone profile requires) and wraps the resulting
 * `ctx.sessionPersistence` service: every write handle passes through the same
 * journal reconciliation the subclass performed.
 *
 * It is selected by the surface-phone row's `mode: session-persistence`
 * config (the desktop bundle aliases the package name, so a subpath export
 * cannot be a separate row).
 * @module @phone-dsh/dsh-surface-phone/session-persistence
 */

import * as basePersistence from '@deepseek-ai/dsh-session-persistence-jsonl'

/**
 * Mount the 0.2.1 shipped backend (or the 0.1.7 default-class plugin) under
 * this row's context.
 * @param ctx - plugin context.
 * @param config - shipped backend config.
 */
function mountBackend(ctx, config) {
  if (typeof basePersistence.apply === 'function') {
    ctx.plugin({ name: 'session-persistence-jsonl-base', apply: basePersistence.apply, Config: basePersistence.Config }, config)
    return
  }
  const fallback = basePersistence.default
  if (fallback === undefined) {
    throw new Error('session-persistence-journaled: the mounted session-persistence-jsonl package exposes neither apply() nor a default plugin')
  }
  ctx.plugin(fallback, config)
}

/**
 * Mount the backend and reconcile every write-open against the tool journal.
 * @param ctx - plugin context.
 * @param config - shipped backend config.
 */
export function applySessionPersistence(ctx, config) {
  mountBackend(ctx, config)
  ctx.inject(['sessionPersistence', 'toolJournal'], (serviceCtx) => {
    const persistence = serviceCtx.sessionPersistence
    const original = persistence.open
    const patched = async function open(id, access, options) {
      const handle = await original.call(persistence, id, access, options)
      if (access !== 'write') return handle
      try {
        await serviceCtx.toolJournal.reconcile(String(id), handle, options?.signal)
      } catch (error) {
        await handle.close().catch(() => {})
        throw error
      }
      return handle
    }
    persistence.open = patched
    serviceCtx.effect(() => () => {
      if (persistence.open === patched) persistence.open = original
    }, 'session-persistence-journaled: write-open reconciliation')
  })
}
