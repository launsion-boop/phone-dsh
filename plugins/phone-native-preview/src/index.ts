// SPDX-License-Identifier: MIT
// Host half of the native Office preview. This is a pure UI plugin: the empty
// apply exists so the package has a Loader row; its browser half is discovered
// through `dsh.client` and served as `./client`. The native Quick Look bridge
// lives in PhoneDSHEngine and is installed by the final app assembly.

/** Host plugin body — no Worker-side behaviour. */
export function apply(): void {}
