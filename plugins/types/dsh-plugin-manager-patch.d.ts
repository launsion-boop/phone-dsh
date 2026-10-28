// SPDX-License-Identifier: MIT
// Type face for the DSH plugin-manager profile writer the phone feature-admin
// host bundles from the verified checkout. The published package deliberately
// does not ship `src/`; `scripts/pack-image.mjs` bundles the source face, so the
// TypeScript project needs the same declarations without vendoring the source.
declare module '@deepseek-ai/dsh-plugin-manager/src/patch.ts' {
  import type { EntryOptions } from '@deepseek-ai/cordis-plugin-loader'
  import type { ProfileContext } from '@deepseek-ai/dsh-app-boot'

  export function flatten(rows: EntryOptions[]): EntryOptions[]
  export function writePluginEnabled(profile: ProfileContext,
                                     id: string,
                                     name: string,
                                     enabled: boolean): Promise<boolean>
}
