// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { UserMessage } from '@deepseek-ai/dsh-session'
import dshbotSteering, { steerInsertedMessage } from '../bot-runtime/src/steering.ts'
import { createAgent, mountRuntime, ScriptAdapter, userMessage } from './bot-runtime-test-kit.ts'

test('a running production Agent steers the identical next-turn message into next-step', async () => {
  const ctx = await mountRuntime()
  const adapter = new ScriptAdapter(['hang'])
  try {
    ctx.llm.registerAdapter(['mock'], adapter)
    await ctx.plugin(dshbotSteering)
    const agent = await createAgent(ctx, 'bot-steering-runtime')
    agent.followup(userMessage('start'))
    await adapter.waitForRequests(1)

    const steering = userMessage('steer this turn')
    agent.followup(steering)
    assert.deepEqual(agent.inbox.nextTurn, [])
    assert.deepEqual(agent.inbox.nextStep.map(message => message.id), [steering.id])
    assert.equal(agent.inbox.nextStep[0]?.id, steering.id)
    assert.deepEqual(agent.inbox.nextStep[0], steering)
    const splice = agent.session.snapshotEvents().at(-1)
    assert.equal(splice?.type, 'agent/inbox/spliced')
    assert.equal(splice.data.target, 'next-step')
    assert.equal(splice.data.inserted[0]?.id, steering.id)

    agent.cancel({ kind: 'user' }, { keepInbox: true })
    await agent.whenIdle()
  } finally {
    await ctx.fiber.dispose()
  }
})

test('a refused steer restores the next-turn fallback with the same message identity', () => {
  const message = userMessage('fallback')
  const followed: UserMessage[] = []
  const fake = {
    status: 'running',
    inbox: {
      nextTurn: [message],
      remove: () => true,
    },
    steer: () => { throw new Error('refused') },
    followup: (value: UserMessage) => { followed.push(value) },
  } as unknown as Agent
  const originalError = console.error
  console.error = () => {}
  try {
    assert.equal(steerInsertedMessage(fake, message, new WeakSet()), false)
  } finally {
    console.error = originalError
  }
  assert.deepEqual(followed, [message])
})
