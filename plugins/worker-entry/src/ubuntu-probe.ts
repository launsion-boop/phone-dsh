// SPDX-License-Identifier: MIT
/**
 * The one boot probe that decides whether this host has a local Linux
 * environment.
 *
 * ---- why a probe and not a capability string ----
 * `channel.md` §4.1 fixes the host HELLO vocabulary: `exec/1` plus zero or more
 * read-only `accelerator:<name>` entries, and "other capability strings are
 * reserved". `ubuntu.exec` is a write-capable host tool (`bridge.md` §12), so it
 * cannot be advertised as one of those read-only names and must not invent a
 * new cap. The Worker therefore asks the host directly, once per boot:
 *
 *     phone ubuntu probe
 *
 * A host that serves `phone info` only answers `unsupported` (the exec bridge
 * refuses an argv the registered tool cannot honour), and the Worker publishes
 * no capability — the `ubuntu` command is then unregistered and the shell
 * answers `command not found` / 127, which is design §4.3's honest, observable
 * "this device does not have it". A host that does serve it answers one JSON
 * object (`{available, env, backend, commands}`) and the command appears.
 *
 * ---- why the probe is bounded and silent ----
 * It is one extra EXEC_REQ during boot: it has a short deadline, a per-boot
 * idempotency key (so a replay never answers for a host that has since
 * changed), and every failure path returns `undefined` without throwing. A
 * probe that fails must not fail the Worker boot.
 * @module @phone-dsh/dsh-worker-entry/ubuntu-probe
 */

import {
  ChannelExecTransport,
  TransportExecClient,
  acceleratorsFromCaps,
} from '../../exec-bridge/src/index.ts'
import type { ChannelClient } from '../../channel/src/index.ts'
import type { UbuntuCapability } from '../../shell-ext/src/index.ts'

/** Bounds the whole probe: connect, request, first answer. */
export const UBUNTU_PROBE_TIMEOUT_MS = 4_000

/** The host-tool call that answers the question. */
export const UBUNTU_PROBE_ARGV: readonly string[] = ['phone', 'ubuntu', 'probe']

/** The tool whose advertisement makes the probe possible at all. */
const PHONE_TOOL = 'phone'

/** One per-boot identity for the probe's request. */
let probeSequence = 0

/** 32 random bytes as lowercase hex (exec.md's `idem_key` shape). */
function probeIdemKey(): string {
  const crypto = globalThis.crypto
  if (crypto !== undefined && typeof crypto.getRandomValues === 'function') {
    const bytes = new Uint8Array(32)
    crypto.getRandomValues(bytes)
    let hex = ''
    for (const byte of bytes) hex += byte.toString(16).padStart(2, '0')
    return hex
  }
  // No CSPRNG is not a reason to reuse the key: a per-boot counter mixed with
  // wall time still cannot collide with another boot in the ledger.
  return `${Date.now().toString(16)}${(probeSequence).toString(16)}`.padStart(64, '0').slice(-64)
}

/** A bounded exec id (`[A-Za-z0-9._-]{1,64}`). */
function probeExecId(): string {
  probeSequence += 1
  return `pdsh-ubuntu-probe-${probeSequence.toString(36)}-${Date.now().toString(36)}`
}

/** Decode the probe's JSON answer into a capability, or undefined. */
export function ubuntuCapabilityOf(stdout: string): UbuntuCapability | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return undefined
  const record = parsed as Record<string, unknown>
  if (record.available !== true) return undefined
  const env = record.env
  const backend = record.backend
  if (typeof env !== 'string' || env === '') return undefined
  if (typeof backend !== 'string' || backend === '') return undefined
  const commands = Array.isArray(record.commands)
    ? record.commands.filter((name): name is string => typeof name === 'string' && name !== '')
    : []
  return { env, backend, commands }
}

/**
 * Ask the host whether it can run `ubuntu` jobs.
 *
 * @param channel - the connected ordered channel (its HELLO caps are the host's
 *   advertisement of `phone`).
 * @param timeoutMs - the whole-probe bound; defaults to
 *   {@link UBUNTU_PROBE_TIMEOUT_MS}.
 * @returns the host's answer, or undefined when it has no local environment.
 */
export async function probeUbuntuHost(
  channel: ChannelClient,
  timeoutMs: number = UBUNTU_PROBE_TIMEOUT_MS,
): Promise<UbuntuCapability | undefined> {
  // Only a host that advertises the `phone` tool can answer: before that
  // dispatch, the request is refused by the exec bridge itself.
  if (!acceleratorsFromCaps(channel.hostHello?.caps).includes(PHONE_TOOL)) return undefined
  const deadline = Math.max(1, timeoutMs)
  const transport = new ChannelExecTransport(channel, undefined, {
    helloTimeoutMs: deadline,
  })
  const client = new TransportExecClient(transport)
  const signal = typeof AbortSignal.timeout === 'function'
    ? AbortSignal.timeout(deadline)
    : undefined
  let stream: Awaited<ReturnType<TransportExecClient['exec']>> | undefined
  try {
    stream = await client.exec({
      exec_id: probeExecId(),
      argv: [...UBUNTU_PROBE_ARGV],
      cwd: '/dsh/workspace',
      env: {},
      stdin: { mode: 'ignore' },
      // No VFS dependency: the probe runs before the Worker's first command and
      // must not wait for a mutation watermark.
      requires_mseq: 0,
      idem_key: probeIdemKey(),
      deadline: Date.now() + deadline,
      grace_ms: 500,
    }, signal)
    let stdout = ''
    let exitCode: number | null | undefined
    for await (const event of stream) {
      if (event.type === 'output' && event.stream === 'stdout') {
        stdout += Buffer.from(event.data, 'base64').toString('utf8')
        continue
      }
      if (event.type === 'exit') {
        exitCode = event.code
        break
      }
      if (event.type === 'error') return undefined
    }
    if (exitCode !== 0) return undefined
    return ubuntuCapabilityOf(stdout)
  } catch {
    // A probe is not a boot dependency: every failure is "no environment".
    return undefined
  } finally {
    stream?.close()
    transport.destroy()
  }
}
