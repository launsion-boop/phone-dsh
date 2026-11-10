/** Schema fixtures driven through the shared subset validator and runtime codecs. */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { assertDisplayNames, validateJsonSchema } from '../core/schema.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'
import { validateInnerMessage } from '../core/inner.mjs'
import { validateE2eFrame, validateE2eHandshakeOuter, validateRelayFrame } from '../core/relay.mjs'
import { validateSessionConfirm, validateSessionInit, validateSessionReject, validateSessionResp } from '../core/handshake.mjs'

const HERE = fileURLToPath(new URL('.', import.meta.url))
const SPEC = join(HERE, '..', '..', 'spec', 'pclink', 'v1')
const schemaDir = join(SPEC, 'schema')
const schemas = new Map()
for (const name of readdirSync(schemaDir).filter(name => name.endsWith('.schema.json')).sort()) {
  schemas.set(name, parseStrictJsonObject(readFileSync(join(schemaDir, name))))
}
const samples = parseStrictJsonObject(readFileSync(join(SPEC, 'golden', 'schema-samples.json')))

function runtimeValidate(schemaName, value) {
  switch (schemaName) {
    case 'inner-message.schema.json': return validateInnerMessage(value)
    case 'e2e-frame.schema.json': return validateE2eFrame(value)
    case 'e2e-handshake.schema.json': {
      validateE2eHandshakeOuter(value)
      const body = value.body
      if (body.type === 'session.init') return validateSessionInit(body)
      if (body.type === 'session.resp') return validateSessionResp(body)
      if (body.type === 'session.confirm') return validateSessionConfirm(body)
      if (body.type === 'session.reject') return validateSessionReject(body)
      throw new Error('unknown handshake body')
    }
    case 'relay-challenge.schema.json':
    case 'relay-auth.schema.json':
    case 'relay-ready.schema.json':
    case 'relay-allow.schema.json':
    case 'relay-offline.schema.json':
    case 'relay-error.schema.json':
    case 'relay-heartbeat.schema.json':
    case 'relay-redirect.schema.json':
    case 'relay-pair.schema.json':
      // peer.auth is client→relay, not a relay→client frame; check its shape
      // through the generic schema validator only.
      if (schemaName === 'relay-auth.schema.json') return value
      return validateRelayFrame(value)
    default:
      return value
  }
}

test('schema samples: every valid and invalid row through the shared validator', () => {
  assert.equal(samples.format, 'pclink-v1-schema-samples')
  assert.equal(samples.format_version, 1)
  for (const row of samples.valid) {
    assert.ok(schemas.has(row.schema), row.schema)
    assertDisplayNames(row.value, `${row.schema}#${row.name}`)
    validateJsonSchema(row.value, schemas.get(row.schema), `${row.schema}#${row.name}`)
    runtimeValidate(row.schema, structuredClone(row.value))
  }
  for (const row of samples.invalid) {
    assert.ok(schemas.has(row.schema), row.schema)
    let rejected = false
    try {
      assertDisplayNames(row.value, `${row.schema}#${row.name}`)
      validateJsonSchema(row.value, schemas.get(row.schema), `${row.schema}#${row.name}`)
    } catch {
      rejected = true
    }
    if (!rejected) {
      try {
        runtimeValidate(row.schema, structuredClone(row.value))
      } catch {
        rejected = true
      }
    }
    assert.equal(rejected, true, `invalid sample accepted: ${row.schema}#${row.name} (${row.reason})`)
  }
  assert.equal(new Set(samples.valid.map(row => row.schema)).size, schemas.size)
  assert.equal(new Set(samples.invalid.map(row => row.schema)).size, schemas.size)
})

test('inner runtime codec agrees with every inner-message schema sample', () => {
  for (const row of samples.valid.filter(row => row.schema === 'inner-message.schema.json')) {
    assert.doesNotThrow(() => validateInnerMessage(structuredClone(row.value)), row.name)
  }
  for (const row of samples.invalid.filter(row => row.schema === 'inner-message.schema.json')) {
    assert.throws(() => validateInnerMessage(structuredClone(row.value)), row.name)
  }
})

test('endpoints inventory is valid, unique and keeps the frozen retry classes', () => {
  const inventory = parseStrictJsonObject(readFileSync(join(SPEC, 'endpoints.json')))
  validateJsonSchema(inventory, schemas.get('endpoints.schema.json'), 'endpoints.json')
  assert.equal(inventory.v, 1)
  assert.equal(inventory.suite, 'workspace/1')
  assert.equal(inventory.dshTestedRange, '>=0.2.2-rc.1 <0.3.0')
  assert.equal(inventory.defaultRetry, 'unsafe')
  const names = new Set()
  for (const endpoint of inventory.endpoints) {
    assert.equal(names.has(endpoint.name), false, endpoint.name)
    names.add(endpoint.name)
    if (endpoint.kind === 'stream') assert.equal(endpoint.retry, 'read', endpoint.name)
    assert.equal(endpoint.phoneOnly, endpoint.name.startsWith('phone/'), endpoint.name)
  }
  for (const [name, retry] of Object.entries({
    'session/prompt': 'idempotent',
    '$events/result': 'unsafe',
    'session/follow': 'read',
    'workspace/follow': 'read',
    'session/list': 'read',
  })) {
    assert.equal(inventory.endpoints.find(endpoint => endpoint.name === name)?.retry, retry, name)
  }
})
