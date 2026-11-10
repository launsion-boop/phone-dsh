/**
 * PC-side durable pairing state (§4.6/§8.1): identity, pairs.json, audit log,
 * usability evaluation and the last-pairing banner.
 */
import { join } from 'node:path'
import { fingerprintOf, formatRfc3339 } from '../core/encoding.mjs'
import {
  buildAuditPairEntry,
  buildAuditRotateEntry,
  buildAuditUnpairEntry,
  evaluateRecordAudit,
} from '../core/pairing.mjs'
import {
  appendAuditEvent,
  atomicWriteFile,
  commitPairs,
  discardPairs,
  ensureStateDir,
  loadOrCreateIdentity,
  loadPairs,
  preserveCorruptPairs,
  readAuditLog,
  rotateIdentityFile,
  savePairs,
  stagePairs,
  MAX_PAIR_RECORDS,
  pclinkStateDir,
} from '../core/store.mjs'

/** One process's view of the durable PC state. */
export class PclinkStore {
  /**
   * @param {{dir: string, log?: (...args: unknown[]) => void}} options State dir.
   */
  constructor(options) {
    this.dir = options.dir
    this.log = options.log ?? (() => {})
    this.identity = undefined
    this.pcMachineId = undefined
    this.records = []
    this.stale = false
    this.audit = []
    this.corruptAudit = false
    this.pairsWriteBlocked = false
    this.warnings = []
    this.lastPairing = undefined
  }

  /** Load identity and pairing files, never rewriting stale/foreign records. */
  load() {
    ensureStateDir(this.dir)
    const { identity } = loadOrCreateIdentity(this.dir)
    this.identity = identity
    this.pcMachineId = identity.machineId
    try {
      const loaded = loadPairs(this.dir, this.pcMachineId)
      this.records = loaded.pairs
      this.stale = loaded.stale
    } catch (error) {
      this.records = []
      this.stale = false
      // Preserve the corrupt bytes before any later pairing can replace the
      // file. If even that fails, refuse to overwrite it from addPair.
      try {
        const backup = preserveCorruptPairs(this.dir)
        this.warnings.push(`pairs.json 无法读取，已保留副本 ${backup}；所有配对不可用：${error.message}`)
      } catch (preserveError) {
        this.pairsWriteBlocked = true
        this.warnings.push(`pairs.json 无法读取且无法保留副本（${preserveError.message}）；拒绝覆盖该文件。`)
      }
    }
    const audit = readAuditLog(this.dir)
    this.audit = audit.events
    this.corruptAudit = audit.corrupt
    if (this.corruptAudit) this.warnings.push('pairs.log 含损坏行，所有配对不可用（fail-closed）。')
    else if (this.records.length > 0 && this.audit.length === 0) {
      this.warnings.push('pairs.log 为空或缺失：所有配对不可用，必须重新配对。')
    }
    if (this.stale) this.warnings.push('PC 身份已更换：旧配对记录全部失效，需要每台手机重新配对。')
    this.refreshLastPairing()
    return this
  }

  get stateDir() {
    return this.dir
  }

  /**
   * Usability of one record from the audit log and identity freshness.
   * @param {Record<string, unknown>} record PC record.
   * @returns {{usable: true} | {usable: false, reason: 'unapproved'|'revoked'}} usability.
   */
  usability(record) {
    if (this.stale || this.corruptAudit) return { usable: false, reason: 'unapproved' }
    return evaluateRecordAudit(record, this.audit)
  }

  /** @returns {Array<Record<string, unknown>>} records that may be used for sessions/allowlist. */
  usableRecords() {
    return this.records.filter(record => this.usability(record).usable)
  }

  /** @returns {string[]} allowlist peer machineIds. */
  allowlist() {
    return this.usableRecords().map(record => record.peerMachineId)
  }

  /**
   * Find a usable record by peer machineId.
   * @param {string} peerMachineId Peer machineId.
   * @returns {Record<string, unknown> | undefined} usable record.
   */
  usableRecord(peerMachineId) {
    const record = this.records.find(candidate => candidate.peerMachineId === peerMachineId)
    if (record === undefined) return undefined
    return this.usability(record).usable ? record : undefined
  }

  /** Recompute the persistent "most recent successful pairing" banner facts. */
  refreshLastPairing() {
    let latest
    for (const record of this.records) {
      if (this.usability(record).usable && (latest === undefined || record.approvedAt > latest.approvedAt)) latest = record
    }
    this.lastPairing = latest
  }

  /**
   * Append the pair audit line, then atomically replace pairs.json (§4.6 order).
   * @param {Record<string, unknown>} record Complete PC record.
   * @param {{at?: string}} [options] Audit event time.
   */
  addPair(record, options = {}) {
    if (this.pairsWriteBlocked) {
      throw new Error('pairs.json is corrupt and could not be preserved; refusing to overwrite it')
    }
    const line = buildAuditPairEntry(record, options.at ?? record.approvedAt)
    // A stale file belongs to the previous PC identity. Writing its records
    // under the new pcMachineId would re-adopt records the contract declares
    // stale, so the new durable file starts with only the new record. The old
    // approvals remain inspectable in the append-only pairs.log.
    const next = this.stale
      ? [record]
      : [...this.records.filter(candidate => candidate.peerMachineId !== record.peerMachineId), record]
    // The cap check happens before the audit append (§4.6 order otherwise
    // leaves a pair line with no matching record).
    if (next.length > MAX_PAIR_RECORDS) throw new Error('pairing record limit reached')
    // Stage the replacement before appending the audit line. A write/validation
    // failure here leaves the previous pairs.json and its approval line intact,
    // so re-pairing the same phone cannot turn the old usable record unapproved.
    const staged = stagePairs(this.dir, this.pcMachineId, next)
    try {
      appendAuditEvent(this.dir, line)
    } catch (error) {
      discardPairs(staged)
      throw error
    }
    // The audit line is durable from here on; reflect it in memory even if the
    // final rename fails so the process fails closed consistently with a reload.
    this.audit.push(line)
    try {
      commitPairs(this.dir, staged)
    } catch (error) {
      discardPairs(staged)
      throw new Error(`pairs.json replace failed after the audit append: ${error.message}`)
    }
    if (this.stale) {
      this.warnings.push('旧身份的配对记录未写入新身份文件；pairs.log 保留原审计，所有旧手机必须重新配对。')
      this.stale = false
    }
    this.records = next
    this.refreshLastPairing()
  }

  /**
   * Append one unpair tombstone and remove the record(s).
   *
   * The tombstone append is normative before the record removal. If it throws,
   * the caller must fail-closed and keep the process off the relay.
   * @param {string[]} peerMachineIds Peers to revoke.
   * @param {{at?: string}} [options] Event time.
   * @returns {string[]} removed machineIds.
   */
  unpair(peerMachineIds, options = {}) {
    const removed = []
    for (const peerMachineId of peerMachineIds) {
      if (!this.records.some(record => record.peerMachineId === peerMachineId)) continue
      const line = buildAuditUnpairEntry(peerMachineId, options.at ?? formatRfc3339())
      appendAuditEvent(this.dir, line)
      this.audit.push(line)
      removed.push(peerMachineId)
    }
    if (removed.length > 0) {
      const next = this.records.filter(record => !removed.includes(record.peerMachineId))
      if (this.stale) {
        // Do not rewrite a previous identity's file under the current
        // pcMachineId; those records stay stale/inspectable instead.
        this.records = next
      } else {
        try {
          savePairs(this.dir, this.pcMachineId, next)
          this.records = next
        } catch (error) {
          // The durable tombstone already makes these records revoked on the
          // next load; removal itself is best effort per the contract.
          this.warnings.push(`配对记录删除失败，但 tombstone 已写入：${error.message}`)
        }
      }
      this.refreshLastPairing()
    }
    return removed
  }

  /**
   * Rotate the PC identity after a durable `rotate` audit line.
   * @returns {{oldMachineId: string, newMachineId: string}} rotation facts.
   */
  rotateIdentity() {
    const oldMachineId = this.pcMachineId
    const candidate = rotateIdentityFile(this.dir)
    const newMachineId = candidate.machineId
    const line = buildAuditRotateEntry(oldMachineId, newMachineId)
    try {
      appendAuditEvent(this.dir, line)
    } catch (error) {
      // Should the audit append fail, re-write the old seed and keep the old identity.
      atomicWriteFile(join(this.dir, 'identity.key'), this.identity.seed, 0o600)
      throw error
    }
    this.audit.push(line)
    this.identity = candidate
    this.pcMachineId = newMachineId
    // Every record is now stale; preserve it for inspection and never rewrite it.
    this.stale = this.records.length > 0
    this.warnings.push('PC 身份已更换：所有旧配对失效，每台手机必须重新配对。')
    this.refreshLastPairing()
    return { oldMachineId, newMachineId }
  }

  /**
   * Status records for the admin API (redacted shape; no public keys).
   * @param {Set<string>} online Established peer machineIds.
   * @returns {Array<Record<string, unknown>>} admin status pairs.
   */
  statusPairs(online) {
    const pairs = []
    for (const record of this.records) {
      const usability = this.usability(record)
      pairs.push({
        peerMachineId: record.peerMachineId,
        peerName: record.peerName,
        pairedAt: record.pairedAt,
        approvedAt: record.approvedAt,
        approvedVia: record.approvedVia,
        online: online.has(record.peerMachineId),
        usable: usability.usable,
        ...(usability.usable ? {} : { reason: usability.reason }),
      })
    }
    return pairs
  }

  /**
   * Warnings for the admin status response, including the persistent new-pairing banner.
   * @returns {string[]} warnings (max 64, each ≤2048 bytes).
   */
  statusWarnings() {
    const warnings = [...this.warnings]
    if (this.lastPairing !== undefined) {
      warnings.unshift(`最近配对：${this.lastPairing.peerName}（${fingerprintOf(this.lastPairing.peerMachineId)}）于 ${this.lastPairing.approvedAt}`)
    }
    return warnings.slice(0, 64).map(warning => (warning.length > 2048 ? `${warning.slice(0, 2000)}…` : warning))
  }
}

