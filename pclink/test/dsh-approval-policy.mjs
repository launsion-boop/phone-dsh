/**
 * Test-only DSH approval policy for the PCLink integration test.
 *
 * The pinned DSH has no built-in "always ask for bash" setting: an approval is
 * requested only when a tool opens a sandbox-escalation request, or when a
 * composed `tools/pre-execute` policy returns `{kind:"ask"}`. Returning the ask
 * here uses that documented extension point, so every bash call in this test
 * process goes through the real `ctx.approval` seam. The PCLink test answers the
 * resulting `approval/request` waterfall over `$events`, which makes the
 * approval reachable without depending on the model choosing an escalating
 * command. This module is loaded only by the test's `--patch` overlay.
 */

export const name = 'pclink-test-approval-policy'
export const inject = ['tools']

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx DSH host context.
 */
export function apply(ctx) {
  ctx.on('tools/pre-execute', async (exec, next) => {
    if (exec.name !== 'bash') return next()
    return {
      kind: 'ask',
      reason: 'integration test policy: every bash call asks the operator',
    }
  })
  console.log('[integration-policy] every bash call requires approval')
}
