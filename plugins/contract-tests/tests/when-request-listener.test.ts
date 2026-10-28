// SPDX-License-Identifier: MIT
// The Worker host passes the app's captured HTTP request listener to the
// runtime tunnel; whenRequestListener is the only way that listener arrives.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { observe } from '../src/observed.ts'
import { loadProbe } from '../src/probe-loader.ts'

test('http: whenRequestListener resolves with the createServer listener', async (t) => {
  const probe = await loadProbe()
  const beforeCapture = probe.requestListener()
  const pending = probe.whenRequestListener()
  let resolvedWith: unknown
  void pending.then(listener => { resolvedWith = listener })
  await Promise.resolve()
  const pendingBeforeCapture = resolvedWith === undefined

  const listener = (): void => {}
  const server = probe.createServer(listener)
  const captured = await pending
  const serverMethods = {
    on: typeof server.on,
    once: typeof server.once,
    listen: typeof server.listen,
    address: typeof server.address,
    close: typeof server.close,
    closeAllConnections: typeof server.closeAllConnections,
    closeIdleConnections: typeof server.closeIdleConnections,
  }
  const second = await probe.whenRequestListener()
  observe(t, 'whenRequestListener', {
    requestListenerBeforeCapture: beforeCapture ?? null,
    pendingBeforeCapture,
    resolvedWithSameListener: captured === listener,
    requestListenerAfterCapture: probe.requestListener() === listener,
    secondCallReturnsCapturedListener: second === listener,
    serverMethods,
  })
  assert.equal(beforeCapture, undefined, 'no listener exists before the app binds a server')
  assert.equal(pendingBeforeCapture, true, 'whenRequestListener must wait for the capture')
  assert.equal(captured, listener, 'the awaited listener must be the one createServer captured')
  assert.equal(probe.requestListener(), listener)
  assert.equal(second, listener, 'later calls must answer the captured listener immediately')
  assert.equal(serverMethods.listen, 'function')
  assert.equal(serverMethods.on, 'function')
  assert.equal(serverMethods.address, 'function')
})
