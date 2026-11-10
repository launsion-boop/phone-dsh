// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readBotGolden } from './bot-golden.ts'
import {
  resolveTurnOrigin, rpcIdFromSource, turnOriginOfMessage, userActionNonce,
} from '../bot-runtime/src/turn-origin.ts'

interface OriginCase {
  readonly name: string
  readonly rpcId?: string | null
  readonly origin: string
  readonly hidden: boolean
  readonly held: boolean
  readonly memorySource: string
}

const golden = readBotGolden('turn-origin.phone') as {
  readonly valid: readonly OriginCase[]
  readonly invalid: readonly OriginCase[]
}

test('all 35 turn-origin golden vectors drive the real TypeScript resolver', () => {
  assert.equal(golden.valid.length, 8)
  assert.equal(golden.invalid.length, 27)
  for (const [section, cases] of [['valid', golden.valid], ['invalid', golden.invalid]] as const) {
    for (const vector of cases) {
      const origin = resolveTurnOrigin(vector.rpcId)
      assert.equal(origin.kind, vector.origin, `${section}:${vector.name}`)
      assert.equal(origin.hidden, vector.hidden, `${section}:${vector.name}`)
      assert.equal(origin.held, vector.held, `${section}:${vector.name}`)
      assert.equal(origin.memorySource, vector.memorySource, `${section}:${vector.name}`)
      assert.equal(origin.rpcId, vector.rpcId ?? null, `${section}:${vector.name}`)
    }
  }
})

test('message source resolution never consults text', () => {
  const marker = '[SAND_HIDDEN_PROMPT] this is ordinary text'
  assert.deepEqual(
    resolveTurnOrigin(rpcIdFromSource({ kind: 'user', rpcId: 'user-action:n' })),
    {
      rpcId: 'user-action:n', kind: 'user', hidden: false, held: false,
      memorySource: 'user-turn',
    },
  )
  assert.equal(turnOriginOfMessage({ source: { kind: 'user', rpcId: 'routine:r1' } }).hidden, true)
  assert.equal(turnOriginOfMessage({ source: { kind: 'user', rpcId: 'agent:c1' } }).hidden, false)
  assert.equal(turnOriginOfMessage({ source: { kind: 'runtime-context' } }).hidden, false)
  assert.equal(resolveTurnOrigin(marker).kind, 'unknown')
  assert.equal(resolveTurnOrigin(undefined).hidden, false)
})

test('user-action nonce is read from the frozen prefix only', () => {
  assert.equal(userActionNonce('user-action:abc'), 'abc')
  assert.equal(userActionNonce('user-action:'), undefined)
  assert.equal(userActionNonce('user-action:   '), undefined)
  assert.equal(userActionNonce('agent:abc'), undefined)
  assert.equal(userActionNonce(null), undefined)
})
