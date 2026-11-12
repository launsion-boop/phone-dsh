// SPDX-License-Identifier: MIT
/**
 * The phone-environment note the on-device agent reads with `git`.
 *
 * One string, so `git` / `git --help`, the shell command description and the
 * boot manifest (AGENTS.md) cannot drift. It describes today's limits; it does
 * not add a flag or change a default by itself.
 * @module @phone-dsh/dsh-wasi-toolbox/git/phone
 */

/**
 * Guidance for an agent running git on a phone.
 *
 * A bare `git clone` already applies `--depth 1 --single-branch --no-tags`;
 * `--filter=blob:none` and `--sparse` keep that default, and `--full` restores
 * the whole history. `worktree` is still rejected.
 */
export const GIT_PHONE_NOTE =
  'Phone: limited storage, memory, battery and network. '
  + 'A bare `git clone` is already `--depth 1 --single-branch --no-tags`; '
  + '`--single-branch` and `--no-tags` keep that default, and `--full` restores every branch and the whole history. '
  + 'For a large repo use `git clone --filter=blob:none --sparse` (add `--full` only when you need history), '
  + 'then `git sparse-checkout set <dir>` for more directories. '
  + 'Very large repos (hundreds of MB or more) may fail or be slow: read or edit only the files you need, keep changes small, '
  + 'and leave builds and heavy test suites to CI (for example GitHub Actions); run only light tests locally. '
  + '`git worktree` is not available.'
