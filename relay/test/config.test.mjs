// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  DEFAULTS,
  MAX_FRAME_BYTES,
  loadConfigFromEnvironment,
  makeRelayConfig,
} from '../src/config.mjs'
import { createRelayServer } from '../src/server.mjs'

const BASE_ENV = { PCLINK_PUBLIC_ORIGIN: 'https://relay.example' }

test('config defaults match contract §3.5 exactly', () => {
  const config = loadConfigFromEnvironment([], BASE_ENV)
  assert.equal(config.publicOrigin, 'https://relay.example')
  assert.equal(config.port, 8080)
  assert.equal(config.maxConnectionsPerIp, 20)
  assert.equal(config.pairRateBytesPerSec, 1 * 1024 * 1024)
  assert.equal(config.pairBurstBytes, 4 * 1024 * 1024)
  assert.equal(config.maxFrameBytes, 16 * 1024 * 1024)
  assert.equal(config.unauthenticatedMaxFrameBytes, 4 * 1024)
  assert.equal(config.maxBufferedBytesPerConnection, 24 * 1024 * 1024)
  assert.equal(config.dailyBytesPerMachine, 2 * 1024 * 1024 * 1024)
  assert.equal(config.dailyBytesMaxMachines, 100_000)
  assert.equal(config.pairJoinsPerIpPerMinute, 5)
  assert.equal(config.pairAttemptsPerRendezvous, 10)
  assert.equal(config.pairRendezvousTtlMs, 300 * 1000)
  assert.equal(config.maxPairSlotsPerConnection, 2)
  assert.equal(config.handshakeFramesPerSourcePerMinute, 30)
  assert.equal(config.handshakeFramesPerTargetPerMinute, 300)
  assert.equal(config.handshakeSourceBurst, 10)
  assert.equal(config.handshakeTargetBurst, 100)
  assert.equal(config.authTimeoutMs, 10 * 1000)
  assert.equal(config.heartbeatMinMs, 20 * 1000)
  assert.equal(config.heartbeatMaxMs, 30 * 1000)
  assert.equal(config.phoneIdleMs, 10 * 60 * 1000)
})

test('documented environment variables override the defaults', () => {
  const config = loadConfigFromEnvironment([], {
    ...BASE_ENV,
    PCLINK_MAX_CONNECTIONS_PER_IP: '3',
    PCLINK_PAIR_RATE_BYTES_PER_SEC: '1000',
    PCLINK_PAIR_BURST_BYTES: '2000',
    PCLINK_MAX_FRAME_BYTES: '2048',
    PCLINK_UNAUTHENTICATED_MAX_FRAME_BYTES: '1024',
    PCLINK_MAX_BUFFERED_BYTES_PER_CONNECTION: '4096',
    PCLINK_DAILY_BYTES_PER_MACHINE: '5000',
    PCLINK_DAILY_BYTES_MAX_MACHINES: '7',
    PCLINK_PAIR_JOINS_PER_IP_PER_MINUTE: '2',
    PCLINK_PAIR_ATTEMPTS_PER_RENDEZVOUS: '3',
    PCLINK_PAIR_RENDEZVOUS_TTL_SECONDS: '30',
    PCLINK_MAX_PAIR_SLOTS_PER_CONNECTION: '1',
    PCLINK_HANDSHAKE_FRAMES_PER_SOURCE_PER_MINUTE: '60',
    PCLINK_HANDSHAKE_FRAMES_PER_TARGET_PER_MINUTE: '600',
    PCLINK_AUTH_TIMEOUT_MS: '500',
    PCLINK_PHONE_IDLE_MS: '1000',
    PCLINK_HEARTBEAT_MIN_MS: '100',
    PCLINK_HEARTBEAT_MAX_MS: '200',
    PCLINK_TRUSTED_PROXIES: '127.0.0.1,10.0.0.0/8',
  })
  assert.equal(config.maxConnectionsPerIp, 3)
  assert.equal(config.pairRateBytesPerSec, 1000)
  assert.equal(config.pairBurstBytes, 2000)
  assert.equal(config.maxFrameBytes, 2048)
  assert.equal(config.unauthenticatedMaxFrameBytes, 1024)
  assert.equal(config.maxBufferedBytesPerConnection, 4096)
  assert.equal(config.dailyBytesPerMachine, 5000)
  assert.equal(config.dailyBytesMaxMachines, 7)
  assert.equal(config.pairJoinsPerIpPerMinute, 2)
  assert.equal(config.pairAttemptsPerRendezvous, 3)
  assert.equal(config.pairRendezvousTtlMs, 30_000)
  assert.equal(config.maxPairSlotsPerConnection, 1)
  assert.equal(config.handshakeSourceBurst, 20)
  assert.equal(config.handshakeTargetBurst, 200)
  assert.equal(config.authTimeoutMs, 500)
  assert.equal(config.phoneIdleMs, 1000)
  assert.equal(config.heartbeatMinMs, 100)
  assert.equal(config.heartbeatMaxMs, 200)
  assert.equal(config.trustedProxies.length, 2)
})

test('origin is required, lowercase and https except for loopback tests', () => {
  assert.throws(() => loadConfigFromEnvironment([], {}), /PCLINK_PUBLIC_ORIGIN/)
  assert.throws(
    () => loadConfigFromEnvironment([], { PCLINK_PUBLIC_ORIGIN: 'https://Relay.Example' }),
    /lowercase/,
  )
  assert.throws(
    () => loadConfigFromEnvironment([], { PCLINK_PUBLIC_ORIGIN: 'http://relay.example' }),
    /https/,
  )
  assert.throws(
    () => loadConfigFromEnvironment([], { PCLINK_PUBLIC_ORIGIN: 'https://relay.example/path' }),
    /canonical/,
  )
  const loopback = loadConfigFromEnvironment([], { PCLINK_PUBLIC_ORIGIN: 'http://127.0.0.1:3220' })
  assert.equal(loopback.publicOrigin, 'http://127.0.0.1:3220')
})

test('the frame cap can be lowered but never raised above 16 MiB', () => {
  assert.throws(
    () => loadConfigFromEnvironment([], {
      ...BASE_ENV,
      PCLINK_MAX_FRAME_BYTES: String(MAX_FRAME_BYTES + 1),
    }),
    /out of range/,
  )
  assert.throws(
    () => makeRelayConfig({ publicOrigin: 'http://127.0.0.1:1', maxFrameBytes: MAX_FRAME_BYTES + 1 }),
    /maxFrameBytes/,
  )
  const lowered = loadConfigFromEnvironment([], {
    ...BASE_ENV,
    PCLINK_MAX_FRAME_BYTES: '2048',
  })
  assert.equal(lowered.maxFrameBytes, 2048)
  // The pre-auth default is clamped when the operator lowers only the
  // authenticated frame cap.
  assert.equal(lowered.unauthenticatedMaxFrameBytes, 2048)
  assert.equal(makeRelayConfig({
    publicOrigin: 'http://127.0.0.1:1',
    maxFrameBytes: 1024,
  }).unauthenticatedMaxFrameBytes, 1024)
})

test('the pre-auth and buffered-byte caps cannot be misconfigured', () => {
  assert.throws(
    () => loadConfigFromEnvironment([], {
      ...BASE_ENV,
      PCLINK_MAX_FRAME_BYTES: '2048',
      PCLINK_UNAUTHENTICATED_MAX_FRAME_BYTES: '4096',
    }),
    /out of range/,
  )
  assert.throws(
    () => makeRelayConfig({
      publicOrigin: 'http://127.0.0.1:1',
      maxFrameBytes: 2048,
      unauthenticatedMaxFrameBytes: 4096,
    }),
    /unauthenticatedMaxFrameBytes/,
  )
  assert.throws(
    () => makeRelayConfig({ publicOrigin: 'http://127.0.0.1:1', maxBufferedBytesPerConnection: 0 }),
    /maxBufferedBytesPerConnection/,
  )
  assert.throws(
    () => makeRelayConfig({ publicOrigin: 'http://127.0.0.1:1', dailyBytesMaxMachines: 0 }),
    /dailyBytesMaxMachines/,
  )
})

test('CLI host/port and unknown-argument handling', () => {
  const config = loadConfigFromEnvironment(['--host', '127.0.0.1', '--port', '3220', '--quiet'], BASE_ENV)
  assert.equal(config.host, '127.0.0.1')
  assert.equal(config.port, 3220)
  assert.equal(config.quiet, true)
  assert.throws(() => loadConfigFromEnvironment(['--bogus'], BASE_ENV), /unknown argument/)
  assert.throws(() => loadConfigFromEnvironment(['--port', '0'], BASE_ENV), /1\.\.65535/)
  assert.throws(() => loadConfigFromEnvironment(['--port', 'abc'], BASE_ENV), /1\.\.65535/)
})

test('a loaded config can be passed to createRelayServer without re-parsing failures', async t => {
  const loaded = loadConfigFromEnvironment([], {
    ...BASE_ENV,
    PCLINK_TRUSTED_PROXIES: '127.0.0.1,10.0.0.0/8',
  })
  const relay = createRelayServer({
    ...loaded,
    host: '127.0.0.1',
    port: 0,
    publicOrigin: 'http://127.0.0.1:0',
    logger: { info() {} },
  })
  await relay.listen()
  t.after(() => relay.close())
  assert.equal(relay.config.trustedProxies.length, 2)
  assert.match(relay.origin, /^http:\/\/127\.0\.0\.1:[0-9]+$/)
})

test('invalid numeric limits and inverted heartbeat ranges are rejected', () => {
  assert.throws(
    () => loadConfigFromEnvironment([], { ...BASE_ENV, PCLINK_MAX_CONNECTIONS_PER_IP: '0' }),
    /out of range/,
  )
  assert.throws(
    () => loadConfigFromEnvironment([], { ...BASE_ENV, PCLINK_MAX_CONNECTIONS_PER_IP: 'x' }),
    /non-negative integer/,
  )
  assert.throws(
    () => makeRelayConfig({
      publicOrigin: 'http://127.0.0.1:1',
      heartbeatMinMs: 200,
      heartbeatMaxMs: 100,
    }),
    /heartbeatMaxMs/,
  )
  assert.throws(
    () => loadConfigFromEnvironment([], { ...BASE_ENV, PCLINK_TRUSTED_PROXIES: 'not-an-ip' }),
    /TRUSTED_PROXIES/,
  )
  assert.equal(DEFAULTS.maxFrameBytes, MAX_FRAME_BYTES)
})
