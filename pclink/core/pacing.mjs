/**
 * Sender-side pacing for established-session `e2e` frames (contract §3.8,
 * `pclink-v1.5`).
 *
 * The relay pair bucket (§3.5) is a drop boundary, not a queue. A sender that
 * writes faster than the pair rate loses a frame, which breaks the receiver's
 * contiguous `seq`. This queue waits for local tokens and writes in enqueue
 * order; it never drops, coalesces or reorders a frame. A single frame larger
 * than the burst waits for a full bucket and then overdraws, exactly like the
 * relay's pclink-v1.4 single-frame rule.
 */

/** Reference rate: 0.9 MiB/s (margin under the relay's 1 MiB/s pair rate). */
export const PACING_RATE_BYTES_PER_SEC = Math.floor(0.9 * 1024 * 1024)
/** Reference burst: 3.5 MiB (margin under the relay's 4 MiB pair burst). */
export const PACING_BURST_BYTES = Math.floor(3.5 * 1024 * 1024)
/** A `rate_limited` without `retryAfterMs` still waits at least this long. */
export const RATE_LIMITED_FALLBACK_MS = 1_000
/** A terminal close is not worth queueing past this wait. */
export const TERMINAL_CLOSE_MAX_WAIT_MS = 10_000

/**
 * Exact UTF-8 length of one serialized outer frame; this is the byte count the
 * relay's pair bucket charges.
 * @param {Record<string, unknown>} frame Outer frame.
 * @returns {number} UTF-8 byte length.
 */
export function frameByteLength(frame) {
  return Buffer.byteLength(JSON.stringify(frame), 'utf8')
}

/** One token bucket with the relay's full-bucket single-frame overdraft. */
export class PacingBucket {
  /**
   * @param {{ratePerSecond?: number, burst?: number}} [options] Bucket shape.
   */
  constructor(options = {}) {
    this.ratePerSecond = options.ratePerSecond ?? PACING_RATE_BYTES_PER_SEC
    this.burst = options.burst ?? PACING_BURST_BYTES
    if (!Number.isFinite(this.ratePerSecond) || this.ratePerSecond <= 0) throw new Error('pacing rate must be positive')
    if (!Number.isFinite(this.burst) || this.burst <= 0) throw new Error('pacing burst must be positive')
    this.tokens = this.burst
    this.lastRefill = undefined
  }

  /** @param {number} now Monotonic epoch ms. */
  refill(now) {
    if (this.lastRefill === undefined) {
      this.lastRefill = now
      return
    }
    if (now > this.lastRefill) {
      this.tokens = Math.min(this.burst, this.tokens + ((now - this.lastRefill) / 1000) * this.ratePerSecond)
      this.lastRefill = now
    }
  }

  /**
   * Wait needed before `bytes` may be written. Does not consume tokens.
   * @param {number} bytes Serialized frame length.
   * @param {number} now Monotonic epoch ms.
   * @returns {number} milliseconds to wait (0 = write now).
   */
  delayFor(bytes, now) {
    this.refill(now)
    if (bytes <= this.tokens + 1e-9) return 0
    if (bytes > this.burst && this.tokens >= this.burst - 1e-9) return 0
    const required = bytes > this.burst ? this.burst : bytes
    return Math.max(1, Math.ceil(((required - this.tokens) / this.ratePerSecond) * 1000))
  }

  /**
   * Charge one approved frame. May leave a negative balance only after an
   * approved overdraft.
   * @param {number} bytes Serialized frame length.
   * @param {number} now Monotonic epoch ms.
   */
  consume(bytes, now) {
    this.refill(now)
    this.tokens -= bytes
  }
}

/** FIFO pacer for one relay connection (one bucket per peer). */
export class PacingQueue {
  /**
   * @param {{
   *   send: (frame: Record<string, unknown>) => boolean,
   *   timers: {setTimeout: Function, clearTimeout: Function, now: () => number},
   *   ratePerSecond?: number,
   *   burst?: number,
   *   log?: (...args: unknown[]) => void,
   *   measure?: (frame: Record<string, unknown>) => number,
   * }} options Dependencies.
   */
  constructor(options) {
    this.send = options.send
    this.timers = options.timers
    this.log = options.log ?? (() => {})
    this.measure = options.measure ?? frameByteLength
    this.bucket = new PacingBucket({ ratePerSecond: options.ratePerSecond, burst: options.burst })
    this.items = []
    this.timer = undefined
    this.closed = false
  }

  /** @returns {number} queued frame count (test/diagnostic helper). */
  get queued() {
    return this.items.length
  }

  /**
   * Queue one frame. Frames are written in call order.
   * @param {Record<string, unknown>} frame Sealed outer frame.
   * @param {{session?: object, terminal?: boolean, label?: string}} [options] Ownership and close semantics.
   * @returns {boolean} true when accepted.
   */
  enqueue(frame, options = {}) {
    if (this.closed) return false
    const item = {
      frame,
      session: options.session,
      terminal: options.terminal === true,
      bytes: this.measure(frame),
      enqueuedAt: this.timers.now(),
      label: options.label,
    }
    if (item.terminal) this.items.unshift(item)
    else this.items.push(item)
    this.drain()
    return true
  }

  /**
   * Discard queued non-terminal frames owned by one closed session. A terminal
   * close is kept so the peer still learns the session is dead.
   * @param {object} session Session record.
   */
  dropSession(session) {
    this.items = this.items.filter(item => item.session !== session || item.terminal)
    this.drain()
  }

  /** Drop every queued frame (relay down/shutdown). */
  clear() {
    this.items = []
    if (this.timer !== undefined) {
      this.timers.clearTimeout(this.timer)
      this.timer = undefined
    }
  }

  /** Stop accepting frames. */
  close() {
    this.closed = true
    this.clear()
  }

  /** Write as many frames as the bucket permits, then schedule the next one. */
  drain() {
    if (this.timer !== undefined) return
    const now = this.timers.now()
    while (this.items.length > 0) {
      const item = this.items[0]
      if (item.session?.closed === true && !item.terminal) {
        this.items.shift()
        continue
      }
      if (item.terminal && now - item.enqueuedAt > TERMINAL_CLOSE_MAX_WAIT_MS) {
        this.log('pacing dropped an overdue terminal close')
        this.items.shift()
        continue
      }
      const delay = this.bucket.delayFor(item.bytes, now)
      if (delay > 0) {
        if (item.terminal && delay > TERMINAL_CLOSE_MAX_WAIT_MS - (now - item.enqueuedAt)) {
          this.log('pacing dropped a terminal close the relay limit would outlast')
          this.items.shift()
          continue
        }
        this.schedule(delay)
        return
      }
      this.bucket.consume(item.bytes, now)
      this.items.shift()
      if (!this.send(item.frame)) {
        this.log(`pacing write failed label=${String(item.label ?? 'e2e')}`)
      }
    }
  }

  schedule(delayMs) {
    if (this.timer !== undefined || this.closed) return
    this.timer = this.timers.setTimeout(() => {
      this.timer = undefined
      this.drain()
    }, delayMs)
    this.timer?.unref?.()
  }
}
