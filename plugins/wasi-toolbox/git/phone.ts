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
 * A bare `git clone` already applies `--depth 1 --single-branch --no-tags`.
 * Partial clone, sparse-checkout and `worktree` are still rejected.
 */
export const GIT_PHONE_NOTE =
  'Phone: limited storage, memory, battery and network. '
  + 'A bare `git clone` is `git clone --depth 1 --single-branch --no-tags` '
  + '(add `-b <branch>` when you need one branch); avoid full-history clones (`--full`) and deepening unless necessary. '
  + 'Very large repos (hundreds of MB or more) may fail or be slow: read or edit only the files you need, keep changes small, '
  + 'and leave builds and heavy test suites to CI (for example GitHub Actions); run only light tests locally. '
  + 'Partial clone (`--filter`), sparse-checkout and `git worktree` are not available.'
