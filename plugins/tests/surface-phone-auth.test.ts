// SPDX-License-Identifier: MIT
/**
 * The surface-phone authentication object consumed by DSH 0.2.1's
 * `HostConnectionService`: browser-page cookie exchange, API-operator
 * `/connect` exchange, and the D22 channel-authenticated request marker.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

// The surface is plain JavaScript (the bundle aliases its source); this test
// only needs its exported class and predicate.
// @ts-expect-error -- untyped plain-JS module
import { PhoneLaunchAuth, isChannelAuthenticated } from '../surface-phone/src/index.js'

const TOKEN = 'launch-token-for-test'
const HOST = '127.0.0.1:43123'

/** Minimal node:http request face the auth object reads. */
function request(options: { url?: string; method?: string; headers?: Record<string, string> } = {}): {
  url: string
  method: string
  headers: Record<string, string>
} {
  return {
    url: options.url ?? '/',
    method: options.method ?? 'GET',
    headers: { host: HOST, ...options.headers },
  }
}

/** Minimal node:http response face that records writes. */
function response(): {
  status: number | undefined
  headers: Record<string, string>
  body: string
  writeHead(status: number, headers?: Record<string, string>): void
  end(body?: string): void
} {
  return {
    status: undefined,
    headers: {},
    body: '',
    writeHead(status, headers = {}) {
      this.status = status
      this.headers = headers
    },
    end(body = '') {
      this.body = body
    },
  }
}

function cookieOf(headers: Record<string, string>): string {
  const setCookie = headers['set-cookie'] ?? ''
  return setCookie.split(';', 1)[0] ?? ''
}

test('the browser page token exchange mints an authority-bound cookie', () => {
  const auth = new PhoneLaunchAuth(TOKEN)
  const first = response()
  auth.authorizeIndex(request({ url: `/?token=${TOKEN}` }), first as never)
  assert.equal(first.status, 303)
  const cookie = cookieOf(first.headers)
  assert.match(first.headers['set-cookie'] ?? '', /HttpOnly/)
  assert.match(first.headers['set-cookie'] ?? '', /SameSite=Strict/)

  const authenticated = request({ headers: { cookie } })
  assert.equal(auth.isAuthenticated(authenticated), true)
  assert.equal(auth.authenticateApi(authenticated), undefined, 'a page cookie is not an API operator cookie')
  assert.equal(auth.isAuthenticated(request({ headers: { cookie, host: '127.0.0.1:9' } })), false)
  assert.equal(auth.isAuthenticated(request({ headers: { cookie: `${cookie}x` } })), false)
})

test('the /connect exchange publishes an operator and mints an API cookie', () => {
  const auth = new PhoneLaunchAuth(TOKEN)
  const published: string[] = []
  const res = response()
  auth.authorizeConnect(
    request({ url: `/connect?token=${TOKEN}&interactions=answer` }),
    res as never,
    false,
    (interactions: string) => {
      published.push(interactions)
      return 'peer-1'
    },
  )
  assert.deepEqual(published, ['answer'])
  assert.equal(res.status, 302)
  assert.equal(res.headers.location, './api/remote.mux')
  const cookie = cookieOf(res.headers)
  assert.equal(auth.authenticateApi(request({ headers: { cookie } })), 'peer-1')
  assert.equal(auth.isAuthenticated(request({ headers: { cookie } })), false)
})

test('a bad or ambiguous /connect exchange publishes no operator', () => {
  const auth = new PhoneLaunchAuth(TOKEN)
  let published = 0
  for (const url of [
    '/connect?token=wrong',
    `/connect?token=${TOKEN}&interactions=answer&interactions=none`,
    `/connect?token=${TOKEN}&interactions=other`,
    `/connect?token=${TOKEN}&interactions=answer&token=${TOKEN}`,
  ]) {
    const res = response()
    auth.authorizeConnect(request({ url }), res as never, false, () => {
      published += 1
      return 'peer-should-not-exist'
    })
    assert.notEqual(res.status, 302, url)
  }
  assert.equal(published, 0)
})

test('only the entry-set channel marker authenticates without a cookie', () => {
  const keys = ['PDSH_CHANNEL_URL', 'PDSH_CHANNEL_TOKEN', 'PDSH_CHANNEL_ORIGIN'] as const
  const previous = keys.map(key => process.env[key])
  try {
    // The Worker host injects the ordered-channel coordinates (D24) before the
    // surface mounts; without them this process is the desktop carrier and no
    // local caller may self-authenticate with the entry-owned header.
    for (const key of keys) delete process.env[key]
    assert.equal(isChannelAuthenticated(request({ headers: { 'x-pdsh-channel-authenticated': '1' } })), false)
    process.env.PDSH_CHANNEL_ORIGIN = 'http://127.0.0.1:9'
    assert.equal(isChannelAuthenticated(request({ headers: { 'x-pdsh-channel-authenticated': '1' } })), true)
    assert.equal(isChannelAuthenticated(request()), false)
    assert.equal(isChannelAuthenticated(request({ headers: { 'x-pdsh-channel-authenticated': '0' } })), false)
    assert.equal(isChannelAuthenticated(request({ headers: { 'x-pdsh-channel-authenticated': 'true' } })), false)
  } finally {
    keys.forEach((key, index) => {
      const value = previous[index]
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    })
  }
})

test('the auth object exposes the complete 0.2.1 HostConnectionService face', () => {
  const auth = new PhoneLaunchAuth(TOKEN) as Record<string, unknown>
  for (const method of ['authenticatedUrl', 'isAuthenticated', 'authenticateApi', 'authorizeIndex', 'authorizeConnect']) {
    assert.equal(typeof auth[method], 'function', method)
  }
  const url = new URL((auth.authenticatedUrl as (base: string) => string)('http://127.0.0.1:43123/'))
  assert.equal(url.searchParams.get('token'), TOKEN)
})
