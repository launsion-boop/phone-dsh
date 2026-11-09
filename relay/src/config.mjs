// SPDX-License-Identifier: MIT
// Relay configuration: frozen defaults from contract §3.5, environment
// overrides, and a small CLI.  All state remains in memory; nothing here reads
// or writes a file.

import process from 'node:process'
import { createLogger } from './logger.mjs'
import { isLoopbackOrigin, normalizeOrigin } from './origin.mjs'
import { parseTrustedProxies } from './net-util.mjs'

export const MAX_FRAME_BYTES = 16 * 1024 * 1024
// Before relay.ready the relay only needs peer.auth (a few hundred bytes).
// Capping this at 4 KiB keeps an unauthenticated peer from making the relay
// parse a multi-MiB frame (contract §3.5, pclink-v1.4).
export const UNAUTHENTICATED_MAX_FRAME_BYTES = 4 * 1024
// Maximum bytes queued for one target WebSocket before the relay drops a
// forwarded frame instead of adding to the buffer (contract §3.5).  The
// default leaves room for one 16 MiB frame plus in-flight traffic.
export const MAX_BUFFERED_BYTES_PER_CONNECTION = 24 * 1024 * 1024
// Upper bound on the in-memory daily byte counters for one UTC day.
export const MAX_DAILY_BYTE_MACHINES = 100_000

export const DEFAULTS = Object.freeze({
  host: '0.0.0.0',
  port: 8080,
  quiet: false,
  publicOrigin: undefined,
  maxConnectionsPerIp: 20,
  pairRateBytesPerSec: 1 * 1024 * 1024,
  pairBurstBytes: 4 * 1024 * 1024,
  maxFrameBytes: MAX_FRAME_BYTES,
  unauthenticatedMaxFrameBytes: UNAUTHENTICATED_MAX_FRAME_BYTES,
  maxBufferedBytesPerConnection: MAX_BUFFERED_BYTES_PER_CONNECTION,
  dailyBytesPerMachine: 2 * 1024 * 1024 * 1024,
  dailyBytesMaxMachines: MAX_DAILY_BYTE_MACHINES,
  pairJoinsPerIpPerMinute: 5,
  pairAttemptsPerRendezvous: 10,
  pairRendezvousTtlMs: 300 * 1000,
  maxPairSlotsPerConnection: 2,
  handshakeFramesPerSourcePerMinute: 30,
  handshakeFramesPerTargetPerMinute: 300,
  authTimeoutMs: 10 * 1000,
  heartbeatMinMs: 20 * 1000,
  heartbeatMaxMs: 30 * 1000,
  phoneIdleMs: 10 * 60 * 1000,
  sweepIntervalMs: 60 * 1000,
  trustedProxies: [],
})

function assertInteger(value, name, minimum, maximum) {
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer in ${minimum}..${maximum}`)
  }
}

export function makeRelayConfig(overrides = {}) {
  const config = { ...DEFAULTS, ...overrides }
  config.publicOrigin = normalizeOrigin(config.publicOrigin)
  if (typeof config.host !== 'string' || config.host.length === 0) throw new Error('host must be a non-empty string')
  assertInteger(config.port, 'port', 0, 65535)
  assertInteger(config.maxConnectionsPerIp, 'maxConnectionsPerIp', 1, 1_000_000)
  assertInteger(config.pairRateBytesPerSec, 'pairRateBytesPerSec', 1, Number.MAX_SAFE_INTEGER)
  assertInteger(config.pairBurstBytes, 'pairBurstBytes', 1, Number.MAX_SAFE_INTEGER)
  assertInteger(config.maxFrameBytes, 'maxFrameBytes', 1024, MAX_FRAME_BYTES)
  if (overrides.unauthenticatedMaxFrameBytes === undefined) {
    config.unauthenticatedMaxFrameBytes = Math.min(config.unauthenticatedMaxFrameBytes, config.maxFrameBytes)
  }
  assertInteger(config.unauthenticatedMaxFrameBytes, 'unauthenticatedMaxFrameBytes', 1024, config.maxFrameBytes)
  assertInteger(config.maxBufferedBytesPerConnection, 'maxBufferedBytesPerConnection', 1024, 1024 * 1024 * 1024)
  assertInteger(config.dailyBytesPerMachine, 'dailyBytesPerMachine', 1, Number.MAX_SAFE_INTEGER)
  assertInteger(config.dailyBytesMaxMachines, 'dailyBytesMaxMachines', 1, 10_000_000)
  assertInteger(config.pairJoinsPerIpPerMinute, 'pairJoinsPerIpPerMinute', 1, 1_000_000)
  assertInteger(config.pairAttemptsPerRendezvous, 'pairAttemptsPerRendezvous', 1, 1000)
  assertInteger(config.pairRendezvousTtlMs, 'pairRendezvousTtlMs', 1, 24 * 60 * 60 * 1000)
  assertInteger(config.maxPairSlotsPerConnection, 'maxPairSlotsPerConnection', 1, 1000)
  assertInteger(config.handshakeFramesPerSourcePerMinute, 'handshakeFramesPerSourcePerMinute', 1, 1_000_000)
  assertInteger(config.handshakeFramesPerTargetPerMinute, 'handshakeFramesPerTargetPerMinute', 1, 1_000_000)
  assertInteger(config.authTimeoutMs, 'authTimeoutMs', 1, 24 * 60 * 60 * 1000)
  assertInteger(config.heartbeatMinMs, 'heartbeatMinMs', 1, 24 * 60 * 60 * 1000)
  assertInteger(config.heartbeatMaxMs, 'heartbeatMaxMs', 1, 24 * 60 * 60 * 1000)
  assertInteger(config.phoneIdleMs, 'phoneIdleMs', 1, 30 * 24 * 60 * 60 * 1000)
  assertInteger(config.sweepIntervalMs, 'sweepIntervalMs', 1000, 24 * 60 * 60 * 1000)
  if (config.heartbeatMaxMs < config.heartbeatMinMs) throw new Error('heartbeatMaxMs must be >= heartbeatMinMs')
  if (config.pairBurstBytes < 1 || config.pairRateBytesPerSec < 1) throw new Error('pair limits must be positive')
  if (config.maxFrameBytes > MAX_FRAME_BYTES) {
    throw new Error(`maxFrameBytes must not exceed ${MAX_FRAME_BYTES} (16 MiB, contract §3.5)`)
  }
  if (overrides.handshakeSourceBurst === undefined) {
    config.handshakeSourceBurst = Math.max(1, Math.ceil(config.handshakeFramesPerSourcePerMinute / 3))
  } else {
    assertInteger(config.handshakeSourceBurst, 'handshakeSourceBurst', 1, 1_000_000)
  }
  if (overrides.handshakeTargetBurst === undefined) {
    config.handshakeTargetBurst = Math.max(1, Math.ceil(config.handshakeFramesPerTargetPerMinute / 3))
  } else {
    assertInteger(config.handshakeTargetBurst, 'handshakeTargetBurst', 1, 1_000_000)
  }
  config.trustedProxies = parseTrustedProxies(config.trustedProxies)
  config.logger = overrides.logger ?? createLogger({ quiet: config.quiet })
  return config
}

function envInteger(env, name, fallback, minimum, maximum, multiplier = 1) {
  const raw = env[name]
  if (raw === undefined || raw === '') return fallback * multiplier
  if (!/^[0-9]+$/.test(raw)) throw new Error(`${name} must be a non-negative integer`)
  const value = Number(raw) * multiplier
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} is out of range ${minimum}..${maximum}`)
  }
  return value
}

function parseCli(argv) {
  const options = { quiet: false, host: undefined, port: undefined }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--host') {
      options.host = argv[++index]
      if (typeof options.host !== 'string' || options.host === '') throw new Error('--host requires a value')
    } else if (argument === '--port') {
      const raw = argv[++index]
      if (!/^[0-9]+$/.test(String(raw))) throw new Error('--port must be an integer in 1..65535')
      options.port = Number(raw)
      if (options.port < 1 || options.port > 65535) throw new Error('--port must be an integer in 1..65535')
    } else if (argument === '--quiet') {
      options.quiet = true
    } else {
      throw new Error(`unknown argument ${JSON.stringify(argument)}`)
    }
  }
  return options
}

export function loadConfigFromEnvironment(argv = [], env = process.env) {
  const cli = parseCli(argv)
  const publicOrigin = env.PCLINK_PUBLIC_ORIGIN
  if (typeof publicOrigin !== 'string' || publicOrigin.trim() === '') {
    throw new Error('PCLINK_PUBLIC_ORIGIN is required (the relay never guesses from a Host header)')
  }
  const origin = normalizeOrigin(publicOrigin)
  if (new URL(origin).protocol === 'http:' && !isLoopbackOrigin(origin)) {
    throw new Error('production PCLINK_PUBLIC_ORIGIN must be https; http is allowed only for a loopback test')
  }
  const maxFrameBytes = envInteger(env, 'PCLINK_MAX_FRAME_BYTES', DEFAULTS.maxFrameBytes, 1024, MAX_FRAME_BYTES)
  const config = makeRelayConfig({
    host: cli.host ?? '0.0.0.0',
    port: cli.port ?? 8080,
    quiet: cli.quiet,
    publicOrigin: origin,
    maxConnectionsPerIp: envInteger(env, 'PCLINK_MAX_CONNECTIONS_PER_IP', DEFAULTS.maxConnectionsPerIp, 1, 1_000_000),
    pairRateBytesPerSec: envInteger(env, 'PCLINK_PAIR_RATE_BYTES_PER_SEC', DEFAULTS.pairRateBytesPerSec, 1, Number.MAX_SAFE_INTEGER),
    pairBurstBytes: envInteger(env, 'PCLINK_PAIR_BURST_BYTES', DEFAULTS.pairBurstBytes, 1, Number.MAX_SAFE_INTEGER),
    maxFrameBytes,
    unauthenticatedMaxFrameBytes: envInteger(
      env,
      'PCLINK_UNAUTHENTICATED_MAX_FRAME_BYTES',
      Math.min(DEFAULTS.unauthenticatedMaxFrameBytes, maxFrameBytes),
      1024,
      maxFrameBytes,
    ),
    maxBufferedBytesPerConnection: envInteger(env, 'PCLINK_MAX_BUFFERED_BYTES_PER_CONNECTION', DEFAULTS.maxBufferedBytesPerConnection, 1024, 1024 * 1024 * 1024),
    dailyBytesPerMachine: envInteger(env, 'PCLINK_DAILY_BYTES_PER_MACHINE', DEFAULTS.dailyBytesPerMachine, 1, Number.MAX_SAFE_INTEGER),
    dailyBytesMaxMachines: envInteger(env, 'PCLINK_DAILY_BYTES_MAX_MACHINES', DEFAULTS.dailyBytesMaxMachines, 1, 10_000_000),
    pairJoinsPerIpPerMinute: envInteger(env, 'PCLINK_PAIR_JOINS_PER_IP_PER_MINUTE', DEFAULTS.pairJoinsPerIpPerMinute, 1, 1_000_000),
    pairAttemptsPerRendezvous: envInteger(env, 'PCLINK_PAIR_ATTEMPTS_PER_RENDEZVOUS', DEFAULTS.pairAttemptsPerRendezvous, 1, 1000),
    pairRendezvousTtlMs: envInteger(env, 'PCLINK_PAIR_RENDEZVOUS_TTL_SECONDS', DEFAULTS.pairRendezvousTtlMs / 1000, 1, 24 * 60 * 60, 1000),
    maxPairSlotsPerConnection: envInteger(env, 'PCLINK_MAX_PAIR_SLOTS_PER_CONNECTION', DEFAULTS.maxPairSlotsPerConnection, 1, 1000),
    handshakeFramesPerSourcePerMinute: envInteger(env, 'PCLINK_HANDSHAKE_FRAMES_PER_SOURCE_PER_MINUTE', DEFAULTS.handshakeFramesPerSourcePerMinute, 1, 1_000_000),
    handshakeFramesPerTargetPerMinute: envInteger(env, 'PCLINK_HANDSHAKE_FRAMES_PER_TARGET_PER_MINUTE', DEFAULTS.handshakeFramesPerTargetPerMinute, 1, 1_000_000),
    authTimeoutMs: envInteger(env, 'PCLINK_AUTH_TIMEOUT_MS', DEFAULTS.authTimeoutMs, 1, 24 * 60 * 60 * 1000),
    phoneIdleMs: envInteger(env, 'PCLINK_PHONE_IDLE_MS', DEFAULTS.phoneIdleMs, 1, 30 * 24 * 60 * 60 * 1000),
    heartbeatMinMs: envInteger(env, 'PCLINK_HEARTBEAT_MIN_MS', DEFAULTS.heartbeatMinMs, 1, 24 * 60 * 60 * 1000),
    heartbeatMaxMs: envInteger(env, 'PCLINK_HEARTBEAT_MAX_MS', DEFAULTS.heartbeatMaxMs, 1, 24 * 60 * 60 * 1000),
    trustedProxies: env.PCLINK_TRUSTED_PROXIES ?? '',
  })
  return config
}

export function usage() {
  return [
    'usage: node relay.mjs --port 8080 [--host 0.0.0.0] [--quiet]',
    '',
    'PCLINK_PUBLIC_ORIGIN is required; the relay never guesses it from Host.',
    'See relay/README.md for the full environment table.',
  ].join('\n')
}
