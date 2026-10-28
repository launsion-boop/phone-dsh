// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-feature-admin` Host half.
 *
 * Registers the `phone/featureAdmin` Remote used by the phone settings tab:
 * installed plugin enablement through DSH's profile patch writer, flat skill
 * editing under `/dsh/home/skills`, and the official agent-preset roster when
 * one is composed. It deliberately has no install, uninstall, market or
 * package-manager path.
 * @module @phone-dsh/dsh-feature-admin
 */

import type { Context } from '@deepseek-ai/cordis'
import type { FeatureAdminConfig } from './contracts.ts'
import { PhoneFeatureAdmin } from './service.ts'

export * from './contracts.ts'
export { PhoneFeatureAdmin } from './service.ts'

/** Plugin label used in Loader diagnostics. */
export const name = 'feature-admin'
/** Optional services are resolved with `ctx.get` so absent capabilities refuse instead of blocking boot. */
export const inject: string[] = []

/**
 * Mount the phone feature-admin Remote.
 * @param ctx - Host Cordis context.
 * @param config - optional skills root (the phone profile keeps the default).
 */
export function apply(ctx: Context, config: FeatureAdminConfig = {}): PhoneFeatureAdmin {
  return new PhoneFeatureAdmin(ctx, config)
}
