// SPDX-License-Identifier: MIT
/**
 * Worker plugin entry for the iPhone Files directory import.
 *
 * The plugin adds only the `phone/import*` Remotes over the existing session
 * workspace. It does not mount a surface, a session store or a filesystem; the
 * final assembly adds this package's row beside the resident phone surface.
 *
 * @module @phone-dsh/dsh-phone-directory-import
 */

import type { Context } from '@deepseek-ai/cordis'
import { PhoneDirectoryImportRemote } from './remote.ts'

export const name = 'phone-directory-import'

/** Apply the Remote service; config is reserved for assembly-owned caps. */
export function apply(ctx: Context, config: Record<string, unknown> = {}): void {
  void config
  ctx.plugin(PhoneDirectoryImportRemote)
}
