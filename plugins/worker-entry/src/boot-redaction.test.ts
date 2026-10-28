// SPDX-License-Identifier: MIT
/**
 * Direct behavior tests for the shared boot redactor. The page and Worker both
 * import it, so a credential-shaped header must be removed even when its value
 * is not one of the boot transport keys; the URL rules stay unchanged.
 * @module @phone-dsh/dsh-worker-entry/boot-redaction.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { redactBootFailureDetail, bootTransportSecretValues } from './boot-redaction.ts'

test('credential-shaped headers are redacted regardless of spelling or case', () => {
  const detail = redactBootFailureDetail(new Error(
    'request failed x-api-key: sk-live-secret, Cookie: session=abc; token=def, '
    + 'X-PDSH-Upstream-Authorization: Basic dXNlcjpwYXNz, Authorization: Bearer bearer-secret, '
    + 'x-auth-token: auth-secret, keep=one',
  ))
  for (const secret of [
    'sk-live-secret', 'session=abc', 'token=def', 'dXNlcjpwYXNz', 'bearer-secret', 'auth-secret',
  ]) {
    assert.equal(detail.includes(secret), false, `${secret} must not survive`)
  }
  assert.match(detail, /x-api-key: \[redacted\]/i)
  assert.match(detail, /Cookie: \[redacted\]/i)
  assert.match(detail, /X-PDSH-Upstream-Authorization: \[redacted\]/i)
  assert.match(detail, /Authorization: \[redacted\]/i)
  assert.match(detail, /x-auth-token: \[redacted\]/i)
  assert.match(detail, /keep=one/)
})

test('an arbitrary header value cannot hide behind a comma boundary', () => {
  const detail = redactBootFailureDetail(
    'x-api-key: sk-one, next-header: value, Cookie: a=b; c=d, e=f',
  )
  assert.equal(detail.includes('sk-one'), false)
  assert.equal(detail.includes('a=b'), false)
  assert.equal(detail.includes('c=d'), false)
  assert.equal(detail.includes('e=f'), false, 'a cookie list is consumed as one value')
  assert.match(detail, /next-header: value/)
})

test('transport query and exact-value redaction keep their existing behavior', () => {
  const secrets = bootTransportSecretValues({
    image: 'http://127.0.0.1/image.tar.gz?token=image-token',
    overlays: ['https://overlay.invalid/a.gz?overlay=overlay-token'],
    xl: { channelURL: 'ws://127.0.0.1/channel?channel=channel-token' },
  })
  const detail = redactBootFailureDetail(new Error(
    'GET http://127.0.0.1/static/web/index.html?token=launch-token&keep=one#chat failed',
  ), secrets)
  assert.doesNotMatch(detail, /launch-token|image-token|overlay-token|channel-token/)
  assert.match(detail, /keep=one/)
  assert.match(detail, /failed/)
  assert.ok(detail.length <= 321)
})

test('exact transport values are removed in raw, percent-encoded and JSON-escaped form', () => {
  const secrets = bootTransportSecretValues({
    xl: {
      token: 'tok/en',
      env: { PDSH_PASS: 'p"q' },
    },
  })
  const detail = redactBootFailureDetail(
    new Error('raw tok/en, encoded tok%2Fen, json p\\"q'),
    secrets,
  )
  assert.equal(detail.includes('tok/en'), false)
  assert.equal(detail.includes('tok%2Fen'), false)
  assert.equal(detail.includes('p\\"q'), false)
  assert.match(detail, /\[redacted\]/)
})
