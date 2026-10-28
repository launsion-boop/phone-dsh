// SPDX-License-Identifier: MIT
/**
 * Test-only keepalive for `node --test` workers.
 *
 * Some production timers are deliberately unref'ed so they never keep the
 * Worker alive. In a test child, a test that waits for such a timer to resolve
 * can lose the race with the event loop draining, which Node reports as
 * `cancelledByParent` ("Promise resolution is still pending but the event loop
 * has already resolved"). A test worker gets one referenced interval instead;
 * the root `after` hook clears it before the runner reports.
 *
 * The launcher imports this file with `--import`, never `NODE_OPTIONS`, so a
 * JSON probe a test spawns does not inherit the keepalive.
 */
if (process.env.NODE_TEST_CONTEXT !== undefined) {
  const { after } = await import('node:test')
  const keepalive = setInterval(() => {}, 60_000)
  after(() => {
    clearInterval(keepalive)
  })
}
