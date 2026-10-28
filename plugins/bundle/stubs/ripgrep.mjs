// SPDX-License-Identifier: MIT
// `@vscode/ripgrep` replacement. The grep/glob tools spawn ripgrep through
// ctx.subprocess, which on the phone is the exec bridge, so the binary must be
// the guest's ripgrep (for example Alpine `apk add ripgrep`), not a host path.
export const rgPath = process.env.PDSH_GUEST_RG_PATH || 'rg'
export default { rgPath }
