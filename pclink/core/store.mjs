/** Local PC state files (§8.1): identity, pairs.json, pairs.log and admin.json. */

import {
  closeSync,
  existsSync,
  fchmodSync,
  fstatSync,
  fsyncSync,
  ftruncateSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeSync,
} from 'node:fs'
import { dirname, join } from 'node:path'
import { b64urlDecode, b64urlEncode, randomBytes } from './encoding.mjs'
import { pclinkError } from './errors.mjs'
import { parseStrictJsonObject } from './json.mjs'
import { identityFromSeed } from './identity.mjs'
import { validatePairingRecord, validatePhonePairingRecord } from './pairing.mjs'

/** Maximum records in one PC pairs.json (§4.6). */
export const MAX_PAIR_RECORDS = 1024

/**
 * State directory for one DSH home.
 * @param {string} dshHome DSH home directory.
 * @returns {string} `$DSH_HOME/pclink`.
 */
export function pclinkStateDir(dshHome) {
  return join(dshHome, 'pclink')
}

/**
 * Create the state directory with mode 0700 (and tighten an existing one).
 * @param {string} dir Directory.
 */
export function ensureStateDir(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 })
  let descriptor
  try {
    descriptor = openSync(dir, 'r')
    fchmodSync(descriptor, 0o700)
  } catch {
    // Best effort on platforms that refuse to open a directory.
  } finally {
    if (descriptor !== undefined) closeSync(descriptor)
  }
}

/**
 * Atomically replace one file: temp file in the same directory, fsync, rename, fsync dir.
 * @param {string} file Destination.
 * @param {string | Uint8Array} data Bytes or text.
 * @param {number} [mode] Creation mode.
 */
export function atomicWriteFile(file, data, mode = 0o600) {
  commitFileWrite(file, stageFileWrite(file, data, mode))
}

/**
 * Stage one file replacement without touching the destination.
 *
 * The caller may append its audit line only after this succeeds, and must call
 * {@link commitFileWrite} (or discard) with the returned temporary path.
 * @param {string} file Destination.
 * @param {string | Uint8Array} data Bytes or text.
 * @param {number} [mode] Creation mode.
 * @returns {string} temporary path in the destination directory.
 */
export function stageFileWrite(file, data, mode = 0o600) {
  const directory = dirname(file)
  ensureStateDir(directory)
  const temporary = join(directory, `.${process.pid}.${randomBytes(8).toString('hex')}.tmp`)
  const bytes = typeof data === 'string' ? Buffer.from(data, 'utf8') : Buffer.from(data)
  closestWrite(temporary, bytes, mode)
  return temporary
}

/**
 * Commit a staged replacement (rename + directory fsync).
 * @param {string} file Destination.
 * @param {string} temporary Staged temp path from {@link stageFileWrite}.
 */
export function commitFileWrite(file, temporary) {
  renameSync(temporary, file)
  syncDirectory(dirname(file))
}

/**
 * Discard a staged replacement after a failed append/commit.
 * @param {string} temporary Staged temp path.
 */
export function discardFileWrite(temporary) {
  rmSync(temporary, { force: true })
}

function syncDirectory(directory) {
  let descriptor
  try {
    descriptor = openSync(directory, 'r')
    fsyncSync(descriptor)
  } catch {
    // Directory fsync is best effort on platforms that refuse to open a directory.
  } finally {
    if (descriptor !== undefined) closeSync(descriptor)
  }
}

function closestWrite(path, bytes, mode) {
  const descriptor = openSync(path, 'wx', mode)
  try {
    fchmodSync(descriptor, mode)
    writeSync(descriptor, bytes, 0, bytes.length)
    fsyncSync(descriptor)
  } finally {
    closeSync(descriptor)
  }
}

/**
 * Load or create `identity.key`.
 * @param {string} dir State directory.
 * @returns {{identity: ReturnType<typeof identityFromSeed>, created: boolean}}
 */
export function loadOrCreateIdentity(dir) {
  ensureStateDir(dir)
  const file = join(dir, 'identity.key')
  if (existsSync(file)) {
    const seed = readFileSync(file)
    if (seed.length !== 32) throw pclinkError('bad_frame', 'identity.key must contain 32 raw bytes')
    try {
      const descriptor = openSync(file, 'r')
      fchmodSync(descriptor, 0o600)
      closeSync(descriptor)
    } catch {
      // Permission tightening is best effort; the read above already succeeded.
    }
    return { identity: identityFromSeed(seed), created: false }
  }
  const seed = randomBytes(32)
  atomicWriteFile(file, seed, 0o600)
  return { identity: identityFromSeed(seed), created: true }
}

/**
 * Replace `identity.key` with a fresh seed (rotate-identity).
 * @param {string} dir State directory.
 * @returns {ReturnType<typeof identityFromSeed>} new identity.
 */
export function rotateIdentityFile(dir) {
  ensureStateDir(dir)
  const seed = randomBytes(32)
  atomicWriteFile(join(dir, 'identity.key'), seed, 0o600)
  return identityFromSeed(seed)
}

/**
 * Load `pairs.json`.
 *
 * A file whose top-level `pcMachineId` differs from the current identity is
 * returned with `stale:true`; records are preserved, never rewritten here.
 * @param {string} dir State directory.
 * @param {string} currentMachineId Current identity machineId.
 * @returns {{present: boolean, pcMachineId?: string, pairs: Array<Record<string, unknown>>, stale: boolean}}
 */
export function loadPairs(dir, currentMachineId) {
  const file = join(dir, 'pairs.json')
  if (!existsSync(file)) return { present: false, pairs: [], stale: false }
  let value
  try {
    value = parseStrictJsonObject(readFileSync(file))
  } catch (error) {
    throw pclinkError('bad_frame', `pairs.json is unreadable: ${error.message}`)
  }
  if (value.v !== 1 || typeof value.pcMachineId !== 'string' || !Array.isArray(value.pairs)) {
    throw pclinkError('bad_frame', 'pairs.json has an invalid top-level shape')
  }
  if (value.pairs.length > MAX_PAIR_RECORDS) throw pclinkError('bad_frame', 'pairs.json exceeds 1024 records')
  const pairs = value.pairs.map(record => validatePairingRecord(record))
  return { present: true, pcMachineId: value.pcMachineId, pairs, stale: value.pcMachineId !== currentMachineId }
}

/**
 * Validate and stage a `pairs.json` replacement.
 *
 * Staging can fail (read-only directory, ENOSPC, invalid record) before any
 * audit line is appended, so a failed re-pair leaves the old file and its
 * approval line intact.
 * @param {string} dir State directory.
 * @param {string} pcMachineId Current identity machineId.
 * @param {Array<Record<string, unknown>>} pairs Records.
 * @returns {string} staged temp path.
 */
export function stagePairs(dir, pcMachineId, pairs) {
  if (!Array.isArray(pairs) || pairs.length > MAX_PAIR_RECORDS) throw pclinkError('bad_frame', 'too many pairing records')
  const validated = pairs.map(record => validatePairingRecord(record))
  return stageFileWrite(
    join(dir, 'pairs.json'),
    `${JSON.stringify({ v: 1, pcMachineId, pairs: validated })}\n`,
    0o600,
  )
}

/**
 * Commit a staged `pairs.json` replacement.
 * @param {string} dir State directory.
 * @param {string} temporary Staged temp path.
 */
export function commitPairs(dir, temporary) {
  commitFileWrite(join(dir, 'pairs.json'), temporary)
}

/**
 * Discard a staged `pairs.json` replacement.
 * @param {string} temporary Staged temp path.
 */
export function discardPairs(temporary) {
  discardFileWrite(temporary)
}

/**
 * Atomically replace `pairs.json`.
 * @param {string} dir State directory.
 * @param {string} pcMachineId Current identity machineId.
 * @param {Array<Record<string, unknown>>} pairs Records.
 */
export function savePairs(dir, pcMachineId, pairs) {
  commitPairs(dir, stagePairs(dir, pcMachineId, pairs))
}

/**
 * Preserve an unreadable `pairs.json` under a sidecar name so a later pairing
 * cannot silently overwrite the corrupt bytes.
 * @param {string} dir State directory.
 * @returns {string} backup path.
 */
export function preserveCorruptPairs(dir) {
  const file = join(dir, 'pairs.json')
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const candidate = join(dir, `pairs.json.corrupt-${stamp}${attempt === 0 ? '' : `-${String(attempt)}`}`)
    if (existsSync(candidate)) continue
    renameSync(file, candidate)
    syncDirectory(dir)
    return candidate
  }
  throw new Error('could not allocate a corrupt pairs.json backup name')
}

/**
 * Probe that `pairs.log` can be appended to and fsynced (§4.6 fail-closed).
 *
 * The probe appends one byte, fsyncs, then truncates back to the original size
 * and fsyncs again, so an ENOSPC/read-only filesystem is detected before the
 * relay is dialed without leaving a non-event line in the audit log.
 * @param {string} dir State directory.
 */
export function probeAuditAppend(dir) {
  ensureStateDir(dir)
  const file = join(dir, 'pairs.log')
  const descriptor = openSync(file, 'a+', 0o600)
  let size
  try {
    fchmodSync(descriptor, 0o600)
    size = fstatSync(descriptor).size
    writeSync(descriptor, '\n')
    fsyncSync(descriptor)
    // Restore the exact byte stream: the probe must not leave a non-event line.
    ftruncateSync(descriptor, size)
    fsyncSync(descriptor)
  } catch (error) {
    // A failed append may still have written bytes; restore the log length so
    // the byte stream stays event-only as far as the write succeeded.
    try {
      if (size !== undefined) {
        ftruncateSync(descriptor, size)
        fsyncSync(descriptor)
      }
    } catch {
      // The reader tolerates an empty line; surface the original failure.
    }
    throw error
  } finally {
    closeSync(descriptor)
  }
}

/**
 * Append one fsynced NDJSON audit line (`O_APPEND|O_CREAT`, mode 0600).
 * @param {string} dir State directory.
 * @param {Record<string, unknown>} event Audit event.
 */
export function appendAuditEvent(dir, event) {
  ensureStateDir(dir)
  const file = join(dir, 'pairs.log')
  const line = `${JSON.stringify(event)}\n`
  const descriptor = openSync(file, 'a', 0o600)
  try {
    fchmodSync(descriptor, 0o600)
    writeSync(descriptor, line, undefined, 'utf8')
    fsyncSync(descriptor)
  } finally {
    closeSync(descriptor)
  }
}

/**
 * Read the append-only audit log.
 * @param {string} dir State directory.
 * @returns {{events: Array<Record<string, unknown>>, corrupt: boolean}} events and corruption flag.
 */
export function readAuditLog(dir) {
  const file = join(dir, 'pairs.log')
  if (!existsSync(file)) return { events: [], corrupt: false }
  let text
  try {
    text = readFileSync(file, 'utf8')
  } catch {
    return { events: [], corrupt: true }
  }
  const events = []
  let corrupt = false
  for (const line of text.split('\n')) {
    if (line === '') continue
    try {
      const event = parseStrictJsonObject(line)
      if (event.v !== 1 || (event.event !== 'pair' && event.event !== 'unpair' && event.event !== 'rotate')) {
        corrupt = true
        continue
      }
      events.push(event)
    } catch {
      corrupt = true
    }
  }
  return { events, corrupt }
}

/**
 * Validate one phone record set (`{"v":1,"phoneMachineId":...,"records":[...]}`).
 * @param {unknown} value Parsed file.
 * @returns {Array<Record<string, unknown>>} records (zero or one).
 */
export function validatePhonePairsFile(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw pclinkError('bad_frame', 'phone pairs file shape')
  if (value.v !== 1 || typeof value.phoneMachineId !== 'string' || !Array.isArray(value.records) || value.records.length > 1) {
    throw pclinkError('bad_frame', 'phone pairs file shape')
  }
  return value.records.map(record => validatePhonePairingRecord(record))
}

/**
 * Read and validate `admin.json`.
 * @param {string} dir State directory.
 * @returns {{v: 1, port: number, token: string} | undefined} admin file, or undefined when absent.
 */
export function loadAdminFile(dir) {
  const file = join(dir, 'admin.json')
  if (!existsSync(file)) return undefined
  let value
  try {
    value = parseStrictJsonObject(readFileSync(file))
  } catch {
    throw pclinkError('unavailable', 'admin.json is unreadable; the plugin is not running')
  }
  if (value.v !== 1 || !Number.isInteger(value.port) || value.port < 49152 || value.port > 65535) {
    throw pclinkError('unavailable', 'admin.json has an invalid port; the plugin is not running')
  }
  b64urlDecode(value.token, { length: 32 })
  try {
    const descriptor = openSync(file, 'r')
    fchmodSync(descriptor, 0o600)
    closeSync(descriptor)
  } catch {
    // Best effort permission tightening.
  }
  return { v: 1, port: value.port, token: value.token }
}

/**
 * Atomically replace `admin.json` (token never logged or echoed).
 * @param {string} dir State directory.
 * @param {{port: number, token: Uint8Array}} value Bound port and 32-byte token.
 */
export function saveAdminFile(dir, value) {
  atomicWriteFile(join(dir, 'admin.json'), `${JSON.stringify({ v: 1, port: value.port, token: b64urlEncode(value.token) })}\n`, 0o600)
}

/**
 * Remove a file if present.
 * @param {string} file Path.
 */
export function removeFile(file) {
  rmSync(file, { force: true })
}
