// SPDX-License-Identifier: MIT
// In-memory token buckets and UTC-day byte counters.  The relay never
// persists these; a restart clears every limit (contract §3.5).

import { performance } from 'node:perf_hooks'

const MAX_RETRY_AFTER_MS = 86_400_000

function retryAfterMs(ratePerSecond, missingTokens) {
  if (ratePerSecond <= 0) return MAX_RETRY_AFTER_MS
  return Math.min(MAX_RETRY_AFTER_MS, Math.max(1, Math.ceil((missingTokens / ratePerSecond) * 1000)))
}

export class TokenBucket {
  constructor({ ratePerSecond, burst, now = performance.now() }) {
    if (!Number.isFinite(ratePerSecond) || ratePerSecond <= 0) throw new Error('token bucket rate must be positive')
    if (!Number.isFinite(burst) || burst <= 0) throw new Error('token bucket burst must be positive')
    this.ratePerSecond = ratePerSecond
    this.burst = burst
    this.tokens = burst
    this.lastRefill = now
    this.lastUsed = now
  }

  refill(now = performance.now()) {
    if (now > this.lastRefill) {
      this.tokens = Math.min(this.burst, this.tokens + ((now - this.lastRefill) / 1000) * this.ratePerSecond)
      this.lastRefill = now
    }
    this.lastUsed = now
  }

  check(cost, now = performance.now()) {
    this.refill(now)
    if (cost <= this.tokens + 1e-9) return { ok: true, retryAfterMs: 0 }
    return { ok: false, retryAfterMs: retryAfterMs(this.ratePerSecond, cost - this.tokens) }
  }

  consume(cost, now = performance.now()) {
    this.refill(now)
    this.tokens = Math.max(0, this.tokens - cost)
  }

  take(cost, now = performance.now()) {
    const result = this.check(cost, now)
    if (result.ok) this.consume(cost, now)
    return result
  }
}

export function perMinuteBucket(perMinute, burst = perMinute) {
  return new TokenBucket({ ratePerSecond: perMinute / 60, burst })
}

export class DailyBytes {
  constructor(limitBytes) {
    if (!Number.isFinite(limitBytes) || limitBytes <= 0) throw new Error('daily byte limit must be positive')
    this.limitBytes = limitBytes
    this.entries = new Map()
  }

  static dayKey(nowMs = Date.now()) {
    return new Date(nowMs).toISOString().slice(0, 10)
  }

  static msUntilNextUtcDay(nowMs = Date.now()) {
    const date = new Date(nowMs)
    const next = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1)
    return Math.min(MAX_RETRY_AFTER_MS, Math.max(1, next - nowMs))
  }

  entry(machineId, nowMs) {
    const day = DailyBytes.dayKey(nowMs)
    const current = this.entries.get(machineId)
    if (current === undefined || current.day !== day) {
      const fresh = { day, bytes: 0 }
      this.entries.set(machineId, fresh)
      return fresh
    }
    return current
  }

  check(machineId, bytes, nowMs = Date.now()) {
    const entry = this.entry(machineId, nowMs)
    if (entry.bytes + bytes > this.limitBytes) {
      return { ok: false, retryAfterMs: DailyBytes.msUntilNextUtcDay(nowMs) }
    }
    return { ok: true, retryAfterMs: 0 }
  }

  consume(machineId, bytes, nowMs = Date.now()) {
    const entry = this.entry(machineId, nowMs)
    entry.bytes += bytes
  }

  take(machineId, bytes, nowMs = Date.now()) {
    const result = this.check(machineId, bytes, nowMs)
    if (result.ok) this.consume(machineId, bytes, nowMs)
    return result
  }

  sweep(nowMs = Date.now()) {
    const day = DailyBytes.dayKey(nowMs)
    for (const [machineId, entry] of this.entries) {
      if (entry.day !== day) this.entries.delete(machineId)
    }
  }
}

export function sweepBuckets(map, now, maxIdleMs) {
  for (const [key, bucket] of map) {
    if (now - bucket.lastUsed > maxIdleMs) map.delete(key)
  }
}
