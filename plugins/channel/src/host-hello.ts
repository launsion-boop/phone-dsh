// SPDX-License-Identifier: MIT
/**
 * Parsing and capability helpers for the host HELLO (channel.md §4.1).
 *
 * D12 routes a command to the host only when the host HELLO advertised
 * `accelerator:<name>`; the Worker therefore has to keep the parsed host HELLO
 * of its current connection. `parseHostHello` is the one validator used by the
 * WebSocket client and by the in-memory channel, and `waitForHostHello` gives
 * transports a bounded wait before they choose an accelerator set.
 * @module @phone-dsh/dsh-channel/host-hello
 */
import { decodeUtf8 } from './bytes.ts'
import type { ChannelClient } from './client.ts'
import { FrameError } from './errors.ts'
import {
  REQUIRED_HOST_CAPABILITIES,
  type Fence,
  type HelloHostPayload,
} from './payloads.ts'
import { isValidBootId, isValidFenceOwner } from './validate.ts'

/** The host HELLO did not arrive before the caller's deadline. */
export class HostHelloTimeoutError extends Error {
  readonly code = 'HELLO_TIMEOUT'

  constructor(timeoutMs: number) {
    super(`host HELLO did not arrive within ${String(timeoutMs)} ms`)
    this.name = 'HostHelloTimeoutError'
  }
}

/**
 * Parse and validate a host HELLO payload.
 * @param payload - decoded 0x01 payload bytes.
 * @returns the fully typed host HELLO (all u64 fields as bigint).
 */
export function parseHostHello(payload: Uint8Array): HelloHostPayload {
  const value = parseJsonObject(payload, 'HELLO')
  if (value['proto'] !== 1) throw new FrameError('PROTO_MISMATCH', 'HELLO proto must be 1')
  if (value['role'] !== 'host') throw new FrameError('PROTO_MISMATCH', 'inbound HELLO role must be host')
  const bootId = value['boot_id']
  if (!isValidBootId(bootId)) {
    throw new FrameError('BAD_PAYLOAD', 'HELLO boot_id must be 32 lowercase hex characters')
  }
  const sessionEpoch = requireU64Integer(value['session_epoch'], 'HELLO session_epoch')
  const fence = parseFence(value['fence'], 'HELLO fence')
  const capsValue = value['caps']
  if (!Array.isArray(capsValue) || capsValue.some(cap => typeof cap !== 'string')) {
    throw new FrameError('BAD_PAYLOAD', 'HELLO caps must be an array of strings')
  }
  const caps = [...(capsValue as string[])]
  for (const required of REQUIRED_HOST_CAPABILITIES) {
    if (!caps.includes(required)) {
      throw new FrameError('PROTO_MISMATCH', `host HELLO lacks required capability ${required}`)
    }
  }
  const nextMseq = requireU64Integer(value['next_mseq'], 'HELLO next_mseq')
  const ackedMseq = requireU64Integer(value['acked_mseq'], 'HELLO acked_mseq')
  const durableMseq = requireU64Integer(value['durable_mseq'], 'HELLO durable_mseq')
  if (nextMseq < 1n) throw new FrameError('BAD_PAYLOAD', 'HELLO next_mseq must be at least 1')
  if (nextMseq <= ackedMseq) throw new FrameError('BAD_PAYLOAD', 'HELLO next_mseq must exceed acked_mseq')
  if (durableMseq > ackedMseq) throw new FrameError('BAD_PAYLOAD', 'HELLO durable_mseq exceeds acked_mseq')
  return {
    proto: 1,
    role: 'host',
    boot_id: bootId,
    session_epoch: sessionEpoch,
    fence,
    caps,
    next_mseq: nextMseq,
    acked_mseq: ackedMseq,
    durable_mseq: durableMseq,
  }
}

/** Keep only `accelerator:<name>` entries, in advertised order, without duplicates. */
export function acceleratorsFromCaps(caps: readonly string[] | undefined): string[] {
  if (caps === undefined) return []
  const names: string[] = []
  for (const cap of caps) {
    if (!cap.startsWith('accelerator:')) continue
    const name = cap.slice('accelerator:'.length)
    if (name !== '' && !names.includes(name)) names.push(name)
  }
  return names
}

/** Accelerator names the host advertised in one parsed HELLO. */
export function hostAccelerators(hello: HelloHostPayload | undefined): string[] {
  return acceleratorsFromCaps(hello?.caps)
}

/**
 * Wait for the host HELLO of the current connection, bounded.
 *
 * Transports call this before choosing between a local command and 0x20, so an
 * empty accelerator set is never mistaken for "not yet known".
 * @param channel - client exposing `hostHello`/`onHostHello`.
 * @param timeoutMs - upper bound; defaults to 10 s.
 * @param signal - optional abort signal (rejects with its reason).
 */
export function waitForHostHello(
  channel: Pick<ChannelClient, 'hostHello' | 'onHostHello'>,
  timeoutMs = 10_000,
  signal?: AbortSignal,
): Promise<HelloHostPayload> {
  const current = channel.hostHello
  if (current !== undefined) return Promise.resolve(current)
  signal?.throwIfAborted()
  return new Promise<HelloHostPayload>((resolve, reject) => {
    let settled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let off: (() => void) | undefined
    const finish = (task: () => void): void => {
      if (settled) return
      settled = true
      if (timer !== undefined) clearTimeout(timer)
      off?.()
      signal?.removeEventListener('abort', onAbort)
      task()
    }
    const onAbort = (): void => { finish(() => { reject(signal?.reason) }) }
    off = channel.onHostHello((hello) => { finish(() => { resolve(hello) }) })
    if (!settled) {
      timer = setTimeout(() => { finish(() => { reject(new HostHelloTimeoutError(timeoutMs)) }) }, timeoutMs)
      signal?.addEventListener('abort', onAbort, { once: true })
    }
  })
}

/** Options for {@link makeHostHello}; the required capabilities are implied. */
export interface HostHelloInit {
  readonly caps?: readonly string[]
  readonly nextMseq?: bigint
  readonly ackedMseq?: bigint
  readonly durableMseq?: bigint
  readonly bootId?: string
  readonly sessionEpoch?: bigint
  readonly fence?: Fence
}

/**
 * Build a valid host HELLO for in-memory channels and tests. Production host
 * HELLOs always come from the wire and go through {@link parseHostHello}.
 */
export function makeHostHello(init: HostHelloInit = {}): HelloHostPayload {
  const acked = init.ackedMseq ?? 0n
  const caps = [...REQUIRED_HOST_CAPABILITIES]
  for (const cap of init.caps ?? []) if (!caps.includes(cap)) caps.push(cap)
  return {
    proto: 1,
    role: 'host',
    boot_id: init.bootId ?? '00112233445566778899aabbccddeeff',
    session_epoch: init.sessionEpoch ?? 1n,
    fence: init.fence ?? { owner: 'phone', generation: 0n, wal_seq: 0n },
    caps,
    next_mseq: init.nextMseq ?? acked + 1n,
    acked_mseq: acked,
    durable_mseq: init.durableMseq ?? 0n,
  }
}

function parseJsonObject(payload: Uint8Array, what: string): Record<string, unknown> {
  let parsed: unknown
  try {
    parsed = JSON.parse(decodeUtf8(payload)) as unknown
  } catch {
    throw new FrameError('BAD_PAYLOAD', `${what} payload is not valid UTF-8 JSON`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new FrameError('BAD_PAYLOAD', `${what} payload must be a JSON object`)
  }
  return parsed as Record<string, unknown>
}

function requireU64Integer(value: unknown, what: string): bigint {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new FrameError('BAD_PAYLOAD', `${what} must be a non-negative integer`)
  }
  return BigInt(value)
}

function parseFence(value: unknown, what: string): Fence {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new FrameError('BAD_PAYLOAD', `${what} must be an object`)
  }
  const record = value as Record<string, unknown>
  const owner = record['owner']
  if (!isValidFenceOwner(owner)) throw new FrameError('BAD_PAYLOAD', `${what}.owner is invalid`)
  return {
    owner,
    generation: requireU64Integer(record['generation'], `${what}.generation`),
    wal_seq: requireU64Integer(record['wal_seq'], `${what}.wal_seq`),
  }
}
