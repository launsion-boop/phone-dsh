// SPDX-License-Identifier: MIT
/** The official profile service with genuine offline preset installation. */
import type { Context } from '@deepseek-ai/cordis'
import PluginManager, { parseInstallSpec } from '@deepseek-ai/dsh-plugin-manager'
import type { ChangeResult, Config, InstallBundleOptions, PluginInstallCancellation, PluginInstallRequestId } from '@deepseek-ai/dsh-plugin-manager'
import { LocalPresetBundles, refusedBundle } from './creator-bundles.ts'

interface Installation {
  controller: AbortController
  applying: boolean
  result: Promise<ChangeResult>
}

export default class PhoneCreatorManager extends PluginManager {
  static override inject = ['loader', 'profileContext', 'agentPresets']
  private readonly localBundles: LocalPresetBundles
  private readonly closing = new AbortController()
  private readonly localInstalls = new Map<PluginInstallRequestId, Installation>()
  private queue: Promise<unknown> = Promise.resolve()

  constructor(ctx: Context, config: Config) {
    super(ctx, config)
    this.localBundles = new LocalPresetBundles(ctx)
    ctx.effect(() => async () => {
      this.closing.abort()
      await this.queue.catch(() => {})
    }, 'phone-creator: settle local installations')
  }

  override installBundle(spec: string, options?: InstallBundleOptions): Promise<ChangeResult> {
    const settings = options ?? {}
    if (settings.requestId !== undefined) {
      const previous = this.localInstalls.get(settings.requestId)
      if (previous !== undefined) return previous.result
    }
    const control: Installation = { controller: new AbortController(), applying: false, result: Promise.resolve(refusedBundle(spec, 'Not started')) }
    const signal = AbortSignal.any([this.closing.signal, control.controller.signal])
    const task = this.queue.then(async () => {
      try {
        const parsed = parseInstallSpec(spec)
        if (parsed.kind !== 'path' || settings.registry !== undefined || (settings.approvedBuilds?.length ?? 0) > 0) {
          return refusedBundle(spec, 'This phone installs workspace-local declarative Agent preset bundles only. npm/Git packages, lifecycle scripts and new JavaScript dependencies require desktop DSH.')
        }
        const result = await this.localBundles.install(parsed.path, settings.enabled !== false, signal, () => { control.applying = true })
        return { ...result, target: spec }
      } catch (error) {
        if (signal.aborted) return { changed: false, application: 'cancelled' as const, stage: 'install' as const, target: spec }
        return refusedBundle(spec, error instanceof Error ? error.message : String(error))
      }
    })
    control.result = task
    this.queue = task.then(() => {}, () => {})
    if (settings.requestId !== undefined) this.localInstalls.set(settings.requestId, control)
    return task
  }

  override waitForInstall(requestId: PluginInstallRequestId): Promise<ChangeResult | null> {
    return this.localInstalls.get(requestId)?.result ?? super.waitForInstall(requestId)
  }

  override async cancelInstall(requestId: PluginInstallRequestId): Promise<PluginInstallCancellation> {
    const operation = this.localInstalls.get(requestId)
    if (operation === undefined) return super.cancelInstall(requestId)
    if (operation.applying) return { status: 'too-late' }
    operation.controller.abort()
    await operation.result
    return { status: 'cancelled' }
  }

  override setBundleEnabled(name: string, enabled: boolean): Promise<ChangeResult> {
    if (!this.localBundles.owns(name)) return super.setBundleEnabled(name, enabled)
    const task = this.queue.then(() => this.localBundles.select(name, enabled, this.closing.signal))
    this.queue = task.then(() => {}, () => {})
    return task
  }

  override removeBundle(name: string): Promise<ChangeResult> {
    if (!this.localBundles.owns(name)) return super.removeBundle(name)
    // Removing declarations can strand durable sessions. Keep the saved bundle;
    // ordinary enable/disable is available without deleting its files.
    return Promise.resolve({ changed: false, application: 'failed', stage: 'remove', target: name,
      error: { code: 'not-removable', diagnostic: 'Use enable/disable for temporary availability changes. Files are retained; re-enable the bundle before resuming sessions that require it.' } })
  }
}
