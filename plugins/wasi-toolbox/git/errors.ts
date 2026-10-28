// SPDX-License-Identifier: MIT
/**
 * Error shapes of the Worker git program.
 *
 * A git command reports failure through its exit status and a `fatal:` /
 * `error:` line on stderr, not through an exception the shell would print.
 * {@link GitFailure} carries both so {@link runGit} can render exactly what the
 * system git renders, and callers that embed the program (the command table,
 * tests) can inspect the status.
 * @module @phone-dsh/dsh-wasi-toolbox/git/errors
 */

/** One command failure with git's exit status and stderr text. */
export class GitFailure extends Error {
  /** Process exit status (128 for `fatal:`, 129 for usage errors). */
  readonly exitCode: number
  /** Complete stderr text, including the trailing newline. */
  readonly stderr: string

  constructor(exitCode: number, stderr: string) {
    super(stderr.trimEnd())
    this.name = 'GitFailure'
    this.exitCode = exitCode
    this.stderr = stderr.endsWith('\n') ? stderr : `${stderr}\n`
  }
}

/** Build a `fatal:` failure (exit 128), git's shape for operational errors. */
export function fatal(message: string, exitCode = 128): GitFailure {
  return new GitFailure(exitCode, `fatal: ${message}\n`)
}

/** Build an `error:` failure that keeps a non-fatal git exit status. */
export function errorFailure(message: string, exitCode = 1): GitFailure {
  return new GitFailure(exitCode, `error: ${message}\n`)
}

/** Build a usage failure (exit 129), git's shape for a bad command line. */
export function usage(message: string): GitFailure {
  return new GitFailure(129, `${message}\n`)
}

/** True when the failure means "not a git repository". */
export function isNotRepository(error: unknown): boolean {
  return error instanceof GitFailure && /not a git repository/i.test(error.stderr)
}
