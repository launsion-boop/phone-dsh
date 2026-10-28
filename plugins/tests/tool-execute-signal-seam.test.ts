// SPDX-License-Identifier: MIT
/**
 * W9-CONTRACT seam: `tools/execute` is the one mutable point the tool journal
 * uses to cancel an in-flight Worker command (G2-FIX-84).
 *
 * The journal wrapper assigns `exec.signal = fuseAbortSignals(exec.signal,
 * hostCancellation)` and relies on the pinned DSH runtime passing that same
 * execution object into the delegated tool body and fusing the caller signal
 * back. The pinned runtime documents it (`ToolDispatchExecution`: an
 * around-dispatch wrapper "may replace the signal for its delegated lifetime")
 * and implements it in `dispatchToolBody`, but a pin change could silently drop
 * the replacement: the journal's abort race would then settle the call while
 * the actual command kept running, which is exactly the G2-A09/G2-A10
 * half-write class.
 *
 * This seam contract test drives the real `ToolRuntime` from the pinned
 * checkout, not a copy of its waterfall: the wrapper replaces the signal and
 * the tool body must observe the replacement and its cancellation cause.
 */
import assert from 'node:assert/strict'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { TOOL_ABORTED, defineTool } from '@deepseek-ai/dsh-tools'
import { test } from 'node:test'

/** Fail the test instead of hanging when the runtime ignores the seam. */
function within<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${label} did not settle within ${milliseconds} ms`))
    }, milliseconds)
    timer.unref?.()
    promise.then(
      value => { clearTimeout(timer); resolve(value) },
      error => { clearTimeout(timer); reject(error) },
    )
  })
}

/** One tool that holds until the signal the body actually received aborts. */
function holdTool(observe: (signal: AbortSignal) => void) {
  return defineTool({
    name: 'hold',
    description: 'holds until its execution signal aborts',
    parameters: {},
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(_args, exec) {
      observe(exec.signal)
      if (!exec.signal.aborted) {
        await new Promise<void>(resolve => {
          exec.signal.addEventListener('abort', () => { resolve() }, { once: true })
        })
      }
      return 'released'
    },
  })
}

test('W9-CONTRACT: a tools/execute signal replacement reaches the in-flight body', {
  timeout: 10_000,
}, async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  try {
    let bodySignal: AbortSignal | undefined
    ctx.tools.register(holdTool(signal => { bodySignal = signal }))

    const hostCancellation = new AbortController()
    const cause = { kind: 'hook', reason: { kind: 'drain', admission: 'closed', reason: 'drain' } }
    let replacementAssigned = false
    ctx.on('tools/execute', async (exec, next) => {
      // The journal's assignment: the caller-visible signal is replaced.
      exec.signal = hostCancellation.signal
      replacementAssigned = true
      const timer = setTimeout(() => { hostCancellation.abort(cause) }, 10)
      timer.unref?.()
      return next()
    })

    const caller = new AbortController()
    const result = await within(ctx.tools.execute({
      callId: ToolCallId('seam-host-cancel'),
      name: 'hold',
      arguments: {},
      signal: caller.signal,
    }), 3_000, 'the replaced tool signal')

    assert.equal(replacementAssigned, true)
    assert.notEqual(bodySignal, caller.signal,
      'the body observed the wrapper replacement, not only the caller signal')
    assert.equal(bodySignal?.aborted, true,
      'the body command observed the host cancellation on its own signal')
    assert.deepEqual(bodySignal?.reason, cause,
      'the AgentCancelCause chain is preserved on the body signal')
    assert.equal(result.isError, true, 'the runtime still returns the aborted result')
    if (!result.isError) assert.fail('the replaced signal must abort the call')
    assert.equal(result.error?.info?.code, TOOL_ABORTED)
  } finally {
    await ctx.fiber.dispose()
  }
})

test('W9-CONTRACT: the caller signal stays fused with a replacement signal', {
  timeout: 10_000,
}, async () => {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  try {
    let bodySignal: AbortSignal | undefined
    ctx.tools.register(holdTool(signal => { bodySignal = signal }))

    // The journal's fused host signal never aborts in this test; only the
    // session-level caller cancel does. DSH must fuse it into the replacement,
    // otherwise the journal's assignment would mask `session/cancel`.
    const replacement = new AbortController()
    ctx.on('tools/execute', async (exec, next) => {
      exec.signal = replacement.signal
      return next()
    })

    const caller = new AbortController()
    const cause = { kind: 'user', reason: { kind: 'user' } }
    const timer = setTimeout(() => { caller.abort(cause) }, 10)
    timer.unref?.()
    const result = await within(ctx.tools.execute({
      callId: ToolCallId('seam-caller-cancel'),
      name: 'hold',
      arguments: {},
      signal: caller.signal,
    }), 3_000, 'the fused caller signal')

    assert.equal(result.isError, true)
    if (!result.isError) assert.fail('the fused caller signal must abort the call')
    assert.equal(result.error?.info?.code, TOOL_ABORTED)
    assert.equal(bodySignal?.aborted, true,
      'the replacement signal fused the caller cancellation')
    assert.deepEqual(bodySignal?.reason, cause,
      'the caller cancel cause reaches the command unchanged')
  } finally {
    await ctx.fiber.dispose()
  }
})
