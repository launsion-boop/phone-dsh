// SPDX-License-Identifier: MIT
/**
 * The host-routed fetch provider is the phone's answer to the independent
 * Fetch API's 404 on raw `text/plain` sources. These tests keep the two
 * properties that fix depends on: a text body is returned verbatim, and a
 * non-text response fails as an explicit content-type error instead of being
 * rendered as empty Markdown.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { WebFetchProvider } from '@deepseek-ai/dsh-web'
import { apply, inject, name } from '../web-fetch-host/src/index.ts'

function provider(): WebFetchProvider {
  let registered: WebFetchProvider | undefined
  const ctx = {
    web: {
      registerFetchProvider(candidate: WebFetchProvider) { registered = candidate },
    },
  }
  apply(ctx as never)
  assert.ok(registered, 'the provider registered on ctx.web')
  return registered
}

test('the plugin advertises its loader name and the web service dependency', () => {
  assert.equal(name, 'web-fetch-host')
  assert.deepEqual(inject, ['web'])
})

test('a text/plain response is returned verbatim as text', async (t) => {
  const body = '# raw source\nnot Markdown-extracted\n'
  t.mock.method(globalThis, 'fetch', async () => new Response(body, {
    status: 200,
    headers: { 'content-type': 'text/plain; charset=utf-8' },
  }))
  const result = await provider().fetch({ url: 'https://raw.example.test/file.md' })
  assert.equal(result.statusCode, 200)
  assert.equal(result.body.kind, 'text')
  assert.equal(result.body.content, body)
  assert.equal(result.truncated, false)
})

test('an HTML response keeps the html kind for tool-web rendering', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => new Response('<h1>hi</h1>', {
    status: 200,
    headers: { 'content-type': 'text/html; charset=utf-8' },
  }))
  const result = await provider().fetch({ url: 'https://example.test/page' })
  assert.equal(result.body.kind, 'html')
  assert.equal(result.body.content, '<h1>hi</h1>')
})

test('a non-2xx response is a result, not a thrown provider error', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => new Response('missing', {
    status: 404,
    headers: { 'content-type': 'text/plain' },
  }))
  const result = await provider().fetch({ url: 'https://example.test/missing' })
  assert.equal(result.statusCode, 404)
  assert.equal(result.body.content, 'missing')
})

test('an unsupported content type fails explicitly', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => new Response(new Uint8Array([0, 1, 2]), {
    status: 200,
    headers: { 'content-type': 'application/octet-stream' },
  }))
  await assert.rejects(
    provider().fetch({ url: 'https://example.test/file.bin' }),
    (error: unknown) => (error as { code?: string }).code === 'WEB_UNSUPPORTED_CONTENT_TYPE',
  )
})

test('a large text body is capped and flagged truncated', async (t) => {
  let registered: WebFetchProvider | undefined
  const ctx = {
    web: {
      registerFetchProvider(candidate: WebFetchProvider) { registered = candidate },
    },
  }
  apply(ctx as never, { maxResponseBytes: 4, maxBodyChars: 100 })
  assert.ok(registered)
  t.mock.method(globalThis, 'fetch', async () => new Response('abcdefgh', {
    status: 200,
    headers: { 'content-type': 'text/plain' },
  }))
  const result = await registered.fetch({ url: 'https://example.test/long.txt' })
  assert.equal(result.body.content, 'abcd')
  assert.equal(result.truncated, true)
})

test('request URLs are restricted to HTTP(S) without credentials before any network call', async (t) => {
  const fetch = t.mock.method(globalThis, 'fetch', async () => new Response('never'))
  await assert.rejects(provider().fetch({ url: 'file:///etc/passwd' }),
                       (error: unknown) => (error as { code?: string }).code === 'WEB_INVALID_URL')
  await assert.rejects(provider().fetch({ url: 'https://user:pass@example.test/' }),
                       (error: unknown) => (error as { code?: string }).code === 'WEB_BLOCKED_URL')
  assert.equal(fetch.mock.callCount(), 0)
})
