// SPDX-License-Identifier: MIT
/**
 * Golden bytes for the non-closing `ERROR VFS_REFUSED` frame (channel.md
 * §4.8/§10, G2-ENG-03). The normative example lives in channel.md; this test
 * keeps the TypeScript encoder byte-identical to it.
 *
 * The resource code adds three required members (`path`, `limit`, `reason`) on
 * top of the ordinary ERROR shape, and is the only ERROR that does not close
 * the ordered channel.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { bytesToHex, canonicalStringify, decodeUtf8, encodeUtf8 } from './index.ts'
import { encodeFrame, FrameDecoder, FrameType } from './frames.ts'
import { isVfsRefusedPayload, type VfsRefusedPayload } from './payloads.ts'

/** Exact fields and bytes of the channel.md §4.8 example (seq 9). */
const FIELDS: VfsRefusedPayload = {
  code: 'VFS_REFUSED',
  limit: 15 * 1024 * 1024,
  message: 'EFBIG',
  path: '/dsh/workspace/a',
  reason: 'file-too-large',
}
const PAYLOAD_HEX = '7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d'
const FRAME_HEX = '5a4c7f0000000000000000090000006d7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d'

test('golden: ERROR VFS_REFUSED is canonical JSON with path/limit/reason', () => {
  const payload = encodeUtf8(canonicalStringify(FIELDS))
  assert.equal(bytesToHex(payload), PAYLOAD_HEX)
  const frame = encodeFrame({ type: FrameType.ERROR, seq: 9n, payload })
  assert.equal(bytesToHex(frame), FRAME_HEX)
  const decoded = new FrameDecoder().push(frame)
  assert.equal(decoded.length, 1)
  assert.equal(decoded[0]?.type, FrameType.ERROR)
  const parsed = JSON.parse(decodeUtf8(decoded[0]?.payload as Uint8Array)) as unknown
  assert.equal(isVfsRefusedPayload(parsed), true)
  assert.deepEqual(parsed, FIELDS)
})

test('VFS_REFUSED validation rejects malformed limits and reasons', () => {
  assert.equal(isVfsRefusedPayload({ ...FIELDS, limit: -1 }), false)
  assert.equal(isVfsRefusedPayload({ ...FIELDS, limit: 1.5 }), false)
  assert.equal(isVfsRefusedPayload({ ...FIELDS, reason: 'other' }), false)
  assert.equal(isVfsRefusedPayload({ ...FIELDS, path: undefined }), false)
  assert.equal(isVfsRefusedPayload({ ...FIELDS, code: 'VFS_CONFLICT' }), false)
})
