// One remote host, addressed the way its own protocol understands it.
// SPDX-License-Identifier: MIT
//
// The seam is transport-neutral on purpose. The device protocol's wire format is
// not frozen: spec/host/v1 README §1 keeps "a device protocol's own wire format"
// outside the normative tree until it freezes, and the draft adapter contract puts
// discovery, pairing and framing in the protocol's half. An [Endpoint] therefore
// must not pretend to be a URL, a BLE address or an MCP route. It is the pair a
// future adapter needs to dial, and the key every other type in this package looks
// a device up by.
//
// An endpoint never carries a credential. A pairing code, an attestation token or
// a launch token belongs to the platform secure store and is injected by the
// adapter; an address that embeds one would leak it into every log line, into the
// state stream and into a crash report. Keeping credentials out of [Endpoint] is
// what lets this type be printed.

package com.phonedsh.domain.connector

/**
 * Where one remote host answers, expressed only as (protocol, address).
 *
 * @property protocolId the protocol that owns [address]'s syntax, for example a
 *   `devicews` or `open-adapter` identifier. It is opaque to this module: only
 *   the adapter that declares it may interpret it.
 * @property address the adapter's own address text. The syntax belongs to
 *   [protocolId]; this module never parses it and never adds a member to it.
 */
data class Endpoint(
    val protocolId: String,
    val address: String,
) {
    init {
        require(protocolId.isNotEmpty() && protocolId.length <= MAX_PROTOCOL_LENGTH) {
            "protocolId must be 1..$MAX_PROTOCOL_LENGTH characters, was ${protocolId.length}"
        }
        require(protocolId.none { it.isWhitespace() || it.isISOControl() }) {
            "protocolId must not contain whitespace or control characters"
        }
        require(address.isNotEmpty() && address.length <= MAX_ADDRESS_LENGTH) {
            "address must be 1..$MAX_ADDRESS_LENGTH characters, was ${address.length}"
        }
        require(address.none { it.isISOControl() }) {
            "address must not contain control characters"
        }
        require(address == address.trim()) {
            "address must not start or end with whitespace"
        }
    }

    companion object {
        /** The longest protocol identifier this seam carries. */
        const val MAX_PROTOCOL_LENGTH: Int = 128

        /** The longest address this seam carries; longer text is a caller bug, not a peer. */
        const val MAX_ADDRESS_LENGTH: Int = 2_048
    }
}
