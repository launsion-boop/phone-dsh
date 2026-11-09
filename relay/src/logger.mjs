// SPDX-License-Identifier: MIT
// Metadata-only stdout logger.
//
// Callers pass already-hashed machineIds/IPs, frame types and lengths, and
// error codes.  Secrets, bodies, rendezvous values, pairing payloads, nonces
// and signatures never reach this module (contract §3.5).

import process from 'node:process'

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
