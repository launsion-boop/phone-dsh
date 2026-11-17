// SPDX-License-Identifier: MIT
/**
 * Raw operation records for user-driven skill mutations.
 *
 * The settings page is not a model tool and has no chat session. A write or
 * delete therefore first appends a durable `requested` fact through the App's
 * internal host bridge, performs the real file mutation, then appends
 * `applied` or `failed`. Only an `applied` fact can become the provenance
 * basis of the one `skill.changed` event. The body stays in the append-only
 * record; it is never copied into model context or a conversation turn.
 * @module @phone-dsh/dsh-feature-admin/mutation-records
 */

import { createHash, randomUUID } from 'node:crypto'
import type { FeatureAdminFailureCode } from './contracts.ts'
import { FeatureAdminError } from './errors.ts'

/** Largest actual body one raw requested record may carry. */
export const MAX_RECORDED_CONTENT_BYTES = 64 * 1024
/** Feature-admin bridge request timeout; a lost host must not hold the UI. */
const DEFAULT_TIMEOUT_MS = 5_000

/** `write` or `delete` as the host event names them. */
export type SkillMutationAction = 'write' | 'delete'

/** One durable raw-operation reference returned by the host. */
export interface SkillMutationRecord {
  readonly operationId: string
  readonly record: string
}

/** Input to the durable `requested` append. */
export interface SkillMutationBegin {
  readonly operationId: string
  readonly action: SkillMutationAction
  readonly file: string
  /** The exact UTF-8 body the user asked to write or delete. */
  readonly content: string
}

/** One host raw-record seam. Tests inject a fake; production uses the bridge. */
export interface SkillMutationJournal {
  begin(input: SkillMutationBegin): Promise<SkillMutationRecord>
  applied(operationId: string): Promise<SkillMutationRecord>
  failed(operationId: string, failureCode: string): Promise<void>
}

/** A fresh opaque operation id; retries must use a new one. */
export function newSkillMutationOperationId(): string {
  return randomUUID()
}

/** Bounded failure code for the host's `failed` fact. */
export function skillMutationFailureCode(error: unknown): string {
  if (error instanceof FeatureAdminError) return error.code
  const code = typeof error === 'object' && error !== null && 'code' in error
    && typeof error.code === 'string' ? error.code : ''
  if (/^[A-Za-z0-9_-]{1,64}$/u.test(code)) return code.toLowerCase()
  return 'io-error'
}

interface HostBridgeOptions {
  readonly endpoint?: string
  readonly token?: string
  readonly egressToken?: string
  readonly timeoutMs?: number
  readonly fetch?: typeof fetch
}

interface HostReply {
  readonly ok?: unknown
  readonly record?: unknown
  readonly operation_id?: unknown
  readonly code?: unknown
  readonly reason?: unknown
}

function hostUrl(raw: string | undefined): string {
  if (typeof raw !== 'string' || raw === '') return ''
  try {
    const url = new URL(raw)
    if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || url.port === '') return ''
    url.pathname = '/feature-admin/skill-mutation'
    url.search = ''
    url.hash = ''
    return url.toString()
  } catch {
    return ''
  }
}

/**
 * The production journal: one internal, bearer-authenticated POST to the App
 * host on the same loopback origin as `/mcp`. It is not an MCP tool and is not
 * advertised to the model.
 */
export class HostSkillMutationJournal implements SkillMutationJournal {
  private readonly endpoint: string
  private readonly token: string
  private readonly egressToken: string
  private readonly timeoutMs: number
  private readonly fetchImpl: typeof fetch

  constructor(options: HostBridgeOptions = {}) {
    const env = process.env
    this.endpoint = hostUrl(options.endpoint ?? env.PDSH_PHONE_MCP_URL)
    this.token = String(options.token ?? env.PDSH_PHONE_MCP_TOKEN ?? '')
    this.egressToken = String(options.egressToken ?? env.PDSH_MCP_EGRESS_TOKEN ?? '')
    this.timeoutMs = Math.max(1, options.timeoutMs ?? DEFAULT_TIMEOUT_MS)
    this.fetchImpl = options.fetch ?? fetch
  }

  /** True when the App bridge is configured; otherwise a write fails closed. */
  get available(): boolean {
    return this.endpoint !== '' && this.token !== ''
  }

  async begin(input: SkillMutationBegin): Promise<SkillMutationRecord> {
    const content = input.content
    const hash = createHash('sha256').update(content, 'utf8').digest('hex')
    const bytes = Buffer.byteLength(content, 'utf8')
    if (bytes > MAX_RECORDED_CONTENT_BYTES) {
      throw new FeatureAdminError(
        'invalid-request',
        `skill content exceeds the ${String(MAX_RECORDED_CONTENT_BYTES)}-byte raw-record bound; the skill was not written`,
        'record-content-too-large',
      )
    }
    const reply = await this.post({
      op: 'begin',
      operation_id: input.operationId,
      action: input.action,
      file: input.file,
      content,
      content_sha256: hash,
      bytes,
    })
    return { operationId: input.operationId, record: this.recordOf(reply, 'requested') }
  }

  async applied(operationId: string): Promise<SkillMutationRecord> {
    const reply = await this.post({ op: 'applied', operation_id: operationId })
    return { operationId, record: this.recordOf(reply, 'applied') }
  }

  async failed(operationId: string, failureCode: string): Promise<void> {
    await this.post({ op: 'failed', operation_id: operationId, failure_code: failureCode })
  }

  private recordOf(reply: HostReply, status: string): string {
    if (typeof reply.record !== 'string' || !/^record:\/\/event\/[0-9]+$/u.test(reply.record)) {
      throw new FeatureAdminError(
        'io-error',
        `the host did not return a durable ${status} record for the feature-admin operation`,
        'record-append-failed',
      )
    }
    return reply.record
  }

  private async post(body: Readonly<Record<string, unknown>>): Promise<HostReply> {
    if (!this.available) {
      throw new FeatureAdminError(
        'unsupported',
        'the App host raw-record bridge is unavailable; the skill file was not touched. '
        + 'A feature-admin write needs the App settings host so the user operation stays provable.',
        'record-bridge-unavailable',
      )
    }
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.timeoutMs)
    try {
      const headers: Record<string, string> = {
        authorization: `Bearer ${this.token}`,
        'content-type': 'application/json',
        accept: 'application/json',
      }
      if (this.egressToken !== '') headers['x-pdsh-mcp-egress'] = this.egressToken
      const response = await this.fetchImpl(this.endpoint, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: controller.signal,
      })
      if (!response.ok) {
        throw new FeatureAdminError(
          'io-error',
          `the App host refused the feature-admin raw record (HTTP ${String(response.status)})`,
          'record-append-failed',
        )
      }
      const reply = await response.json() as HostReply
      if (reply.ok === true) return reply
      const code = typeof reply.code === 'string' ? reply.code : 'record-append-failed'
      const reason = typeof reply.reason === 'string' && reply.reason !== ''
        ? reply.reason
        : 'the App host refused the feature-admin raw record'
      throw new FeatureAdminError(hostFailureCode(code), reason, code)
    } catch (error) {
      if (error instanceof FeatureAdminError) throw error
      const reason = error instanceof Error ? error.message : String(error)
      throw new FeatureAdminError(
        'io-error',
        `the App host raw-record bridge failed: ${reason}`,
        'record-append-failed',
      )
    } finally {
      clearTimeout(timer)
    }
  }
}

/** Map the host's bounded bridge code onto the existing browser failure vocabulary. */
function hostFailureCode(code: string): FeatureAdminFailureCode {
  switch (code) {
    case 'invalid-request':
    case 'file-mismatch':
    case 'file-still-present':
      return 'conflict'
    case 'unavailable':
    case 'unknown-operation':
    case 'already-applied':
      return 'unsupported'
    default:
      return 'io-error'
  }
}
