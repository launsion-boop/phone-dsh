// SPDX-License-Identifier: MIT
/**
 * Deterministic fake runner for the shell-corpus tooling tests.
 *
 * It implements the documented runner interface without touching the DSH
 * checkout: command prefixes select the outcome the test needs to classify.
 *
 * @module tools/shell-corpus/fixtures/fake-runner
 */

/**
 * Create one fake runner.
 *
 * @returns {{name: string, run: Function, close: Function}} the runner.
 */
export function createRunner() {
  return {
    name: 'fake',
    async run(command) {
      if (command.startsWith('missing')) {
        return { exitCode: 127, stdout: '', stderr: 'bash: git: command not found\n' }
      }
      if (command.startsWith('loop')) {
        return { exitCode: 127, stdout: '', stderr: 'bash: for: command not found\n' }
      }
      if (command.startsWith('syntax')) {
        return { exitCode: 2, stdout: '', stderr: 'bash: syntax error: unexpected token\n' }
      }
      if (command.startsWith('unavailable')) {
        return { exitCode: 127, stdout: '', stderr: 'ln: not available in the worker host\n' }
      }
      if (command.startsWith('broken')) {
        return { exitCode: 1, stdout: '', stderr: 'bash: cat: No such file or directory\n' }
      }
      if (command.startsWith('boom')) {
        throw new Error('fake runner exploded')
      }
      return { exitCode: 0, stdout: 'ok\n', stderr: '' }
    },
    async close() {},
  }
}
