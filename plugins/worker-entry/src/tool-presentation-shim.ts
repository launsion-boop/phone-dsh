// SPDX-License-Identifier: MIT
/**
 * Worker-side `@deepseek-ai/dsh-agent-tool-presentation` replacement.
 *
 * The official row waits for `ctx.ptcRuntime` before declaring `ptc`
 * presentation. The Worker has no PTC runtime (it would need a child Node
 * process with a control pipe, which the phone execution world deliberately
 * rejects), so an unmodified `ptc` row stays pending and the whole preset is
 * reported broken. On a phone the equivalent mobile presentation is the
 * native tool catalog: every tool keeps its real schema, identity, permission
 * and result. This shim declares `native` for that case and says so in the
 * log. It never deletes tools, fabricates PTC output, or claims the ptc
 * transport is available when `ctx.ptcRuntime` is absent.
 * @module @phone-dsh/dsh-worker-entry/tool-presentation-shim
 */
import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import type { ToolPresentationMode } from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-tools'

/** Cordis plugin name; identical to the official package so diagnostics read the same. */
export const name = 'tool-presentation'

/** The tool registry is the only required service. */
export const inject = ['tools']

/** Plugin config. */
export interface Config {
  /** Requested presentation form. */
  mode: ToolPresentationMode
}

/** Runtime schema. */
export const Config: z<Config> = z.object({
  mode: z.union(['native', 'ptc'] as const).required(),
})

/**
 * Declare the presentation for the mounting preset scope.
 *
 * A `ptc` request degrades to `native` only when the Worker composes no PTC
 * runtime. If a runtime is ever mounted, the official behaviour applies.
 * @param ctx - the preset's mounting context.
 * @param config - requested presentation mode.
 */
export function apply(ctx: Context, config: Config): void {
  if (config.mode === 'native') {
    ctx.tools.presentAs('native')
    return
  }
  if (ctx.get('ptcRuntime') === undefined) {
    ctx.logger.warn(
      'ptc was requested but this Worker has no ptcRuntime; '
      + 'presenting the real tool catalog natively instead (mobile-equivalent presentation)',
    )
    ctx.tools.presentAs('native')
    return
  }
  ctx.tools.presentAs('ptc')
}

/** Module namespace shape the Cordis loader accepts. */
export default { name, inject, Config, apply }
