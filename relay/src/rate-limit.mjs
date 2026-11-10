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
  constructor({ ratePerSecond, burst, overdraftSingleFrame = false, now = performance.now() }) {
    if (!Number.isFinite(ratePerSecond) || ratePerSecond <= 0) throw new Error('token bucket rate must be positive')
    if (!Number.isFinite(burst) || burst <= 0) throw new Error('token bucket burst must be positive')
    this.ratePerSecond = ratePerSecond
    this.burst = burst
    this.overdraftSingleFrame = overdraftSingleFrame
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
    if (this.overdraftSingleFrame && cost > this.burst && this.tokens >= this.burst - 1e-9) {
      // A single frame larger than the steady-state burst is allowed from a
      // full bucket.  The balance goes negative and refills at the configured
      // rate, so a repeated oversized frame is still rate-limited.
      return { ok: true, retryAfterMs: 0, overdraft: true }
    }
    // With overdraft enabled, a large frame must wait for the bucket to be
    // full (not for the full frame cost) because the overdraft is absolute.
    const required = this.overdraftSingleFrame && cost > this.burst ? this.burst : cost
    return { ok: false, retryAfterMs: retryAfterMs(this.ratePerSecond, required - this.tokens) }
  }

  consume(cost, now = performance.now()) {
    this.refill(now)
    // No floor: an allowed single-frame overdraft must leave a debt that the
    // next refill pays back.  check()/take() only consume an approved cost, so
    // the ordinary path never goes below zero.
    this.tokens -= cost
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
  constructor(limitBytes, maxEntries = 100_000) {
    if (!Number.isFinite(limitBytes) || limitBytes <= 0) throw new Error('daily byte limit must be positive')
    if (!Number.isInteger(maxEntries) || maxEntries <= 0) throw new Error('daily byte machine cap must be a positive integer')
    this.limitBytes = limitBytes
    this.maxEntries = maxEntries
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
    if (current !== undefined && current.day === day) return current
    // Bound the in-memory map within one UTC day.  Evicting the oldest counter
    // is deliberate: the daily quota is best-effort, and the map must not grow
    // with attacker-chosen identities (contract §3.5).  Replacing an existing
    // machineId's stale entry does not grow the map, so no eviction is needed
    // in that case.
    if (current === undefined && this.entries.size >= this.maxEntries) {
      const oldest = this.entries.keys().next().value
      if (oldest !== undefined) this.entries.delete(oldest)
    }
    const fresh = { day, bytes: 0 }
    this.entries.set(machineId, fresh)
    return fresh
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
