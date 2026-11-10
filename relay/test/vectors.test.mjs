// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import { sign } from 'node:crypto'
import { decodeB64url } from '../src/base64url.mjs'
import {
  machineIdFromPublicKey,
  relayAuthTranscript,
  sha256,
  verifyRelayAuthSignature,
} from '../src/identity.mjs'
import { normalizeOrigin } from '../src/origin.mjs'
import { createIdentity, readGolden } from './helpers.mjs'

const golden = readGolden('pclink-v1-vectors.json')

test('machineId and relay-auth vectors use the real base32/machineId/signature code', () => {
  const { origin, nonce, transcript_hex: transcriptHex } = golden.relay_auth
  const nonceRaw = Buffer.from(nonce, 'base64url')
  assert.equal(relayAuthTranscript(origin, nonceRaw).toString('hex'), transcriptHex)

  for (const side of ['phone', 'pc']) {
    const identityVector = golden.identities[side]
    const authVector = golden.relay_auth[side]
    const publicKey = Buffer.from(identityVector.public_key, 'base64url')

    assert.equal(sha256(publicKey).toString('hex'), identityVector.sha256_hex)
    assert.equal(machineIdFromPublicKey(publicKey), identityVector.machine_id)
    assert.equal(authVector.machine_id, identityVector.machine_id)
    assert.equal(authVector.public_key, identityVector.public_key)
    assert.equal(
      verifyRelayAuthSignature(
        publicKey,
        origin,
        nonceRaw,
        Buffer.from(authVector.signature, 'base64url'),
      ),
      true,
    )

    // Re-derive the fixed test key from the public label and sign the same
    // transcript.  This consumes the vector through the real signing primitive
    // used by the test peer, not a copied expected value.
    const generated = createIdentity(identityVector.seed_label)
    assert.equal(generated.publicKeyB64, identityVector.public_key)
    assert.equal(generated.machineId, identityVector.machine_id)
    const reSigned = sign(null, relayAuthTranscript(origin, nonceRaw), generated.privateKey)
    assert.equal(reSigned.toString('base64url'), authVector.signature)
  }

  const valid = Buffer.from(golden.identities.phone.public_key, 'base64url')
  assert.throws(() => machineIdFromPublicKey(valid.subarray(1)), /32-byte/)
  const mutated = Buffer.from(valid)
  mutated[0] ^= 1
  const mutatedMachineId = machineIdFromPublicKey(mutated)
  assert.match(mutatedMachineId, /^[a-z2-7]{26}$/)
  assert.notEqual(mutatedMachineId, golden.identities.phone.machine_id)
})

test('relay-auth negatives reject mutations, wrong keys and wrong origins', () => {
  const { origin, nonce, phone } = golden.relay_auth
  const nonceRaw = Buffer.from(nonce, 'base64url')
  const publicKey = Buffer.from(phone.public_key, 'base64url')
  const signature = Buffer.from(phone.signature, 'base64url')

  assert.equal(verifyRelayAuthSignature(publicKey, origin, nonceRaw, signature), true)
  assert.equal(verifyRelayAuthSignature(publicKey, 'https://other.example', nonceRaw, signature), false)
  assert.equal(verifyRelayAuthSignature(publicKey, origin, Buffer.alloc(32, 7), signature), false)

  const mutated = Buffer.from(signature)
  mutated[0] ^= 1
  assert.equal(verifyRelayAuthSignature(publicKey, origin, nonceRaw, mutated), false)

  const pcKey = Buffer.from(golden.relay_auth.pc.public_key, 'base64url')
  assert.equal(verifyRelayAuthSignature(pcKey, origin, nonceRaw, signature), false)
})

test('encoding and origin invalid rows are rejected by the real primitives', () => {
  const invalid = new Map(golden.invalid.map(row => [row.case, row]))

  const padding = invalid.get('b64url-padding')
  assert.equal(decodeB64url(padding.text), null)

  const nonCanonical = invalid.get('b64url-noncanonical-last-char')
  assert.equal(decodeB64url(nonCanonical.text), null)

  const mismatch = invalid.get('relay-origin-mismatch')
  assert.notEqual(normalizeOrigin(mismatch.actual), normalizeOrigin(mismatch.expected_origin))

  const uppercase = invalid.get('relay-origin-uppercase')
  assert.throws(() => normalizeOrigin(uppercase.actual), /lowercase/)
})
