// SPDX-License-Identifier: MIT
/**
 * Behaviour of the read-only model provider projection.
 *
 * The parser is the Worker's only view of the host configuration, so these
 * tests cover the states a real boot can present: a missing variable, malformed
 * JSON, an invalid endpoint/selection, duplicate ids, and a valid document that
 * must not leak any field the host did not publish intentionally.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  CREDENTIAL_PROJECTION,
  MODEL_PROVIDER_ENV,
  readModelConfig,
} from '../phone-model-config/src/model-config.ts'
import { MODEL_CONFIG_CONTRIBUTION } from '../phone-model-config/src/remote.ts'
import { en, zh } from '../phone-model-config/src/client/locales.ts'

const VALID = JSON.stringify({
  version: 1,
  selectedId: 'deepseek',
  providers: [{
    id: 'deepseek',
    displayName: 'DeepSeek',
    baseURL: 'https://api.example.com/anthropic',
    model: 'deepseek-flash',
    reasoningEffort: 'high',
  }],
})

function config(raw: string | undefined) {
  return readModelConfig(raw === undefined ? {} : { [MODEL_PROVIDER_ENV]: raw })
}

test('missing and blank environment report an honest unconfigured state', () => {
  for (const raw of [undefined, '', '   ']) {
    const snapshot = config(raw)
    assert.equal(snapshot.configured, false)
    if (snapshot.configured) return
    assert.equal(snapshot.reason, 'missing')
    assert.equal(snapshot.credential, CREDENTIAL_PROJECTION)
    assert.deepEqual(snapshot.detail, { code: 'env-missing' })
  }
})

test('malformed JSON and non-object documents are invalid, never fabricated', () => {
  for (const raw of ['{', 'null', '[]', '"text"']) {
    const snapshot = config(raw)
    assert.equal(snapshot.configured, false)
    if (snapshot.configured) return
    assert.equal(snapshot.reason, 'invalid')
    assert.equal(typeof snapshot.detail.code, 'string')
    assert.doesNotMatch(JSON.stringify(snapshot.detail), /sk-|apiKey|secret/)
  }
})

test('invalid details are structured codes that the client can localize', () => {
  const cases = [
    ['{', 'json-invalid'],
    ['null', 'document-not-object'],
    [JSON.stringify({ version: 2, selectedId: 'a', providers: [] }), 'version-unsupported'],
    [JSON.stringify({ version: 1, selectedId: 'a', providers: [] }), 'providers-empty'],
    [JSON.stringify({ version: 1, selectedId: 'a', providers: [{ id: 'a', displayName: '', baseURL: 'https://a.example', model: 'm' }] }), 'provider-invalid'],
    [JSON.stringify({ version: 1, selectedId: 'a', providers: [
      { id: 'a', displayName: 'A', baseURL: 'https://a.example', model: 'm' },
      { id: 'a', displayName: 'B', baseURL: 'https://b.example', model: 'n' },
    ] }), 'duplicate-provider-id'],
    [JSON.stringify({ version: 1, providers: [{ id: 'a', displayName: 'A', baseURL: 'https://a.example', model: 'm' }] }), 'selected-missing'],
    [JSON.stringify({ version: 1, selectedId: 'missing', providers: [{ id: 'a', displayName: 'A', baseURL: 'https://a.example', model: 'm' }] }), 'selected-unknown'],
  ] as const
  for (const [raw, code] of cases) {
    const snapshot = config(raw)
    assert.equal(snapshot.configured, false, raw)
    if (snapshot.configured) return
    assert.equal(snapshot.detail.code, code, raw)
    assert.doesNotMatch(JSON.stringify(snapshot.detail), / is (not|missing|invalid)|must /)
  }
})

test('zh and en dictionaries own the same keys', () => {
  assert.deepEqual(Object.keys(en).sort(), Object.keys(zh).sort())
})

test('invalid version, provider fields, duplicates and selections fail closed', () => {
  const invalidDocuments = [
    { version: 2, selectedId: 'a', providers: [{ id: 'a', displayName: 'A', baseURL: 'https://a.example', model: 'm' }] },
    { version: 1, selectedId: 'a', providers: [] },
    { version: 1, selectedId: 'missing', providers: [{ id: 'a', displayName: 'A', baseURL: 'https://a.example', model: 'm' }] },
    { version: 1, selectedId: 'a', providers: [{ id: 'a', displayName: 'A', baseURL: 'ftp://a.example', model: 'm' }] },
    { version: 1, selectedId: 'a', providers: [{ id: 'a', displayName: 'A', baseURL: 'https://', model: 'm' }] },
    { version: 1, selectedId: 'a', providers: [{ id: 'a', displayName: 'A', baseURL: 'https://a.example/?query=1', model: 'm' }] },
    { version: 1, selectedId: 'a', providers: [{ id: 'a', displayName: 'A', baseURL: 'https://a.example', model: 'm' }, { id: 'a', displayName: 'B', baseURL: 'https://b.example', model: 'n' }] },
  ]
  for (const document of invalidDocuments) {
    const snapshot = config(JSON.stringify(document))
    assert.equal(snapshot.configured, false, JSON.stringify(document))
    if (snapshot.configured) return
    assert.equal(snapshot.reason, 'invalid')
    assert.equal(typeof snapshot.detail.code, 'string')
  }
})

test('valid host JSON projects the selected provider and ignores secret-shaped fields', () => {
  const withExtras = JSON.stringify({
    version: 1,
    selectedId: 'deepseek',
    apiKey: 'sk-must-never-appear',
    credentialRef: 'provider.deepseek',
    providers: [{
      id: 'deepseek',
      displayName: 'DeepSeek',
      baseURL: 'https://api.example.com/anthropic',
      model: 'deepseek-flash',
      reasoningEffort: 'high',
      apiKey: 'sk-must-never-appear',
      apiKeyEnv: 'DEEPSEEK_API_KEY',
      credentialRef: 'provider.deepseek',
    }],
  })
  const snapshot = config(withExtras)
  assert.equal(snapshot.configured, true)
  if (!snapshot.configured) return
  assert.equal(snapshot.selectedId, 'deepseek')
  assert.deepEqual(snapshot.selected, {
    id: 'deepseek',
    displayName: 'DeepSeek',
    baseURL: 'https://api.example.com/anthropic',
    model: 'deepseek-flash',
    reasoningEffort: 'high',
  })
  assert.deepEqual(snapshot.providers, [snapshot.selected])
  assert.equal(snapshot.credential.storage, 'device-keychain')
  assert.equal(snapshot.credential.injectedBy, 'host')
  assert.equal(snapshot.credential.writable, false)
  const serialized = JSON.stringify(snapshot)
  assert.doesNotMatch(serialized, /sk-must-never-appear/)
  assert.doesNotMatch(serialized, /apiKey|apiKeyEnv|credentialRef/)
})

test('the projection is frozen and the environment is not mutated', () => {
  const environment = { [MODEL_PROVIDER_ENV]: VALID }
  const snapshot = readModelConfig(environment)
  assert.equal(snapshot.configured, true)
  assert.deepEqual(environment, { [MODEL_PROVIDER_ENV]: VALID })
  assert.equal(Object.isFrozen(snapshot), true)
  if (!snapshot.configured) return
  assert.equal(Object.isFrozen(snapshot.selected), true)
  assert.equal(Object.isFrozen(snapshot.providers), true)
})

test('the client descriptor names the read-only phone/modelConfig endpoint', () => {
  assert.equal(MODEL_CONFIG_CONTRIBUTION.package, '@phone-dsh/dsh-phone-model-config')
  assert.equal(MODEL_CONFIG_CONTRIBUTION.descriptors.length, 1)
  const descriptor = MODEL_CONFIG_CONTRIBUTION.descriptors[0]!
  assert.equal(descriptor.namespace, 'phone')
  assert.equal(descriptor.method, 'modelConfig')
  assert.equal(descriptor.service, 'modelConfig')
  assert.equal(descriptor.invocation.kind, 'direct')
  assert.deepEqual(descriptor.parameters, [])
  assert.equal(descriptor.result.mode, 'src-json')
})
