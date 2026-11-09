// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import { RELAY_PLANE_SCHEMAS, parseRelayFrame } from '../src/frames.mjs'
import { readGolden } from './helpers.mjs'

const samples = readGolden('schema-samples.json')

test('relay-plane schema samples: every valid sample is accepted by the real parser', () => {
  for (const sample of samples.valid) {
    if (!RELAY_PLANE_SCHEMAS.has(sample.schema)) continue
    const parsed = parseRelayFrame(sample.value)
    assert.equal(
      parsed.ok,
      true,
      `${sample.schema}/${sample.name}: ${parsed.ok ? '' : parsed.message}`,
    )
  }
})

test('relay-plane schema samples: every invalid sample is rejected by the real parser', () => {
  for (const sample of samples.invalid) {
    if (!RELAY_PLANE_SCHEMAS.has(sample.schema)) continue
    const parsed = parseRelayFrame(sample.value)
    assert.equal(
      parsed.ok,
      false,
      `${sample.schema}/${sample.name} was accepted`,
    )
  }
})

test('pairing-message payloads are intentionally opaque to the relay', () => {
  // The payload travels inside relay.pair.message; the relay only requires it
  // to be an object and never validates pair.* content or MACs.  Treating the
  // pairing-message schema as relay-plane would make the relay parse pairing
  // secrets/keys, which contract §4.3 forbids.
  assert.equal(RELAY_PLANE_SCHEMAS.has('pairing-message.schema.json'), false)
  const wrap = {
    v: 1,
    type: 'relay.pair.message',
    rendezvous: 'AAAAAAAAAAAAAAAAAAAAAA',
    payload: samples.invalid.find(sample => sample.schema === 'pairing-message.schema.json').value,
  }
  assert.equal(parseRelayFrame(wrap).ok, true)
})
