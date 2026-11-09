// SPDX-License-Identifier: MIT
// Metadata-only stdout logger.
//
// Callers pass already-hashed machineIds/IPs, frame types and lengths, and
// error codes.  Secrets, bodies, rendezvous values, pairing payloads, nonces
// and signatures never reach this module (contract §3.5).

import { createHmac, randomBytes } from 'node:crypto'
import process from 'node:process'

// Per-process random salt for source-IP log hashes.  It is deliberately not
// persisted: a captured log cannot be brute-forced back to an IPv4 address
// (32 bits would be trivial with a plain SHA-256 prefix), and restarting the
// relay changes every future hash.  machineId hashes stay plain SHA-256 (they
// are already derived from a high-entropy public key).
const LOG_IP_SALT = randomBytes(32)

export function hashIpForLog(ip) {
  return createHmac('sha256', LOG_IP_SALT).update(String(ip), 'utf8').digest('hex').slice(0, 8)
}

export function createLogger({ quiet = false, sink = process.stdout } = {}) {
  return {
    info(event, fields = {}) {
      if (quiet) return
      const record = { ts: new Date().toISOString(), event }
      for (const [key, value] of Object.entries(fields)) {
        if (value === undefined) continue
        record[key] = value
      }
      sink.write(`${JSON.stringify(record)}\n`)
    },
  }
}
