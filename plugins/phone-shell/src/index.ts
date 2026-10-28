// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-phone-shell` Host entry.
 *
 * The profile row names this package and calls {@link apply}. The service is a
 * Remote owner under the shared `phone` namespace; the browser half lives at
 * the `./client` export and registers the `phone-shell` right-Sidebar kind.
 * @module @phone-dsh/dsh-phone-shell
 */

export { apply, capsFromHello, normalizeConsoleRequest, PhoneShellRemote } from './service.ts'
export type * from './contract.ts'
export { default } from './service.ts'
