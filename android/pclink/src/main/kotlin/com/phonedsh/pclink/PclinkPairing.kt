// SPDX-License-Identifier: MIT
// The four MACed pairing payloads (§4.4). Every factory builds the closed
// object and then decodes it through the same production validator the receive
// path uses, so a factory can never create a shape the receiver rejects.
package com.phonedsh.pclink

/**
 * One `pair.hello`/`pair.auth`/`pair.confirm`/`pair.final` payload. The raw
 * object is authoritative: MACs are computed over `canonical_json` with the
 * `mac` member removed.
 */
sealed class PclinkPairingMessage {
    abstract val raw: PclinkJson

    abstract val type: String

    val mac: String get() = raw.requiredString("mac")

    class Hello(override val raw: PclinkJson) : PclinkPairingMessage() {
        override val type: String get() = "pair.hello"
        val role: String get() = raw.requiredString("role")
        val machineId: String get() = raw.requiredString("machineId")
        val publicKey: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("publicKey"), 32)
        val name: String get() = raw.requiredString("name")
        val relay: String get() = raw.requiredString("relay")
        val nonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("nonce"), 32)
    }

    class Auth(override val raw: PclinkJson) : PclinkPairingMessage() {
        override val type: String get() = "pair.auth"
        val role: String get() = raw.requiredString("role")
        val machineId: String get() = raw.requiredString("machineId")
        val publicKey: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("publicKey"), 32)
        val name: String get() = raw.requiredString("name")
        val relay: String get() = raw.requiredString("relay")
        val nonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("nonce"), 32)
        val peerNonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("peerNonce"), 32)
    }

    class Confirm(override val raw: PclinkJson) : PclinkPairingMessage() {
        override val type: String get() = "pair.confirm"
        val role: String get() = raw.requiredString("role")
        val nonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("nonce"), 32)
        val peerNonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("peerNonce"), 32)
        val transcriptHash: ByteArray
            get() = PclinkBase64Url.decode(raw.requiredString("transcriptHash"), 32)
    }

    class Final(override val raw: PclinkJson) : PclinkPairingMessage() {
        override val type: String get() = "pair.final"
        val role: String get() = raw.requiredString("role")
        val nonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("nonce"), 32)
        val peerNonce: ByteArray get() = PclinkBase64Url.decode(raw.requiredString("peerNonce"), 32)
        val transcriptHash: ByteArray
            get() = PclinkBase64Url.decode(raw.requiredString("transcriptHash"), 32)
    }

    /** MAC domain selected by the message type, never by a caller-supplied value. */
    fun domain(): String = when (this) {
        is Hello -> PclinkCrypto.PAIR_HELLO_DOMAIN
        is Auth -> PclinkCrypto.PAIR_AUTH_DOMAIN
        is Confirm -> PclinkCrypto.PAIR_CONFIRM_DOMAIN
        is Final -> PclinkCrypto.PAIR_FINAL_DOMAIN
    }

    fun canonicalWithoutMac(): PclinkJson {
        val members = LinkedHashMap(raw.objectValue ?: throw PclinkError.BadFrame("pairing message is not an object"))
        members.remove("mac")
        return PclinkJson.Object(members)
    }

    /** Verifies the MAC over the canonical object without `mac` (§4.4). */
    fun verifyMac(pairKey: ByteArray) {
        val claimed = PclinkBase64Url.decode(mac, 32)
        val expected = PclinkCrypto.pairMac(pairKey, domain(), canonicalWithoutMac())
        if (!PclinkCrypto.constantTimeEquals(claimed, expected)) {
            throw PclinkError.AuthFailed("pairing MAC mismatch")
        }
    }

    companion object {
        fun decode(value: PclinkJson): PclinkPairingMessage {
            PclinkWire.validatePairingMessage(value)
            return when (value.requiredString("type")) {
                "pair.hello" -> Hello(value)
                "pair.auth" -> Auth(value)
                "pair.confirm" -> Confirm(value)
                "pair.final" -> Final(value)
                else -> throw PclinkError.BadFrame("unknown pairing message type")
            }
        }

        fun makeHello(
            machineId: String,
            publicKey: ByteArray,
            name: String,
            relayOrigin: String,
            nonce: ByteArray,
            pairKey: ByteArray,
        ): Hello {
            val withoutMac = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("pair.hello"),
                "role" to PclinkJson.Text("pc"),
                "machineId" to PclinkJson.Text(machineId),
                "publicKey" to PclinkJson.Text(PclinkBase64Url.encode(publicKey)),
                "name" to PclinkJson.Text(name),
                "relay" to PclinkJson.Text(relayOrigin),
                "nonce" to PclinkJson.Text(PclinkBase64Url.encode(nonce)),
            )
            return Hello(withMac(withoutMac, pairKey, PclinkCrypto.PAIR_HELLO_DOMAIN))
        }

        fun makeAuth(
            machineId: String,
            publicKey: ByteArray,
            name: String,
            relayOrigin: String,
            nonce: ByteArray,
            peerNonce: ByteArray,
            pairKey: ByteArray,
        ): Auth {
            val withoutMac = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("pair.auth"),
                "role" to PclinkJson.Text("phone"),
                "machineId" to PclinkJson.Text(machineId),
                "publicKey" to PclinkJson.Text(PclinkBase64Url.encode(publicKey)),
                "name" to PclinkJson.Text(name),
                "relay" to PclinkJson.Text(relayOrigin),
                "nonce" to PclinkJson.Text(PclinkBase64Url.encode(nonce)),
                "peerNonce" to PclinkJson.Text(PclinkBase64Url.encode(peerNonce)),
            )
            return Auth(withMac(withoutMac, pairKey, PclinkCrypto.PAIR_AUTH_DOMAIN))
        }

        fun makeConfirm(
            helloNonce: ByteArray,
            authNonce: ByteArray,
            transcriptHash: ByteArray,
            pairKey: ByteArray,
        ): Confirm {
            val withoutMac = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("pair.confirm"),
                "role" to PclinkJson.Text("pc"),
                "nonce" to PclinkJson.Text(PclinkBase64Url.encode(helloNonce)),
                "peerNonce" to PclinkJson.Text(PclinkBase64Url.encode(authNonce)),
                "transcriptHash" to PclinkJson.Text(PclinkBase64Url.encode(transcriptHash)),
            )
            return Confirm(withMac(withoutMac, pairKey, PclinkCrypto.PAIR_CONFIRM_DOMAIN))
        }

        fun makeFinal(
            authNonce: ByteArray,
            helloNonce: ByteArray,
            transcriptHash: ByteArray,
            pairKey: ByteArray,
        ): Final {
            val withoutMac = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("pair.final"),
                "role" to PclinkJson.Text("phone"),
                "nonce" to PclinkJson.Text(PclinkBase64Url.encode(authNonce)),
                "peerNonce" to PclinkJson.Text(PclinkBase64Url.encode(helloNonce)),
                "transcriptHash" to PclinkJson.Text(PclinkBase64Url.encode(transcriptHash)),
            )
            return Final(withMac(withoutMac, pairKey, PclinkCrypto.PAIR_FINAL_DOMAIN))
        }

        private fun withMac(
            withoutMac: PclinkJson,
            pairKey: ByteArray,
            domain: String,
        ): PclinkJson {
            val mac = PclinkCrypto.pairMac(pairKey, domain, withoutMac)
            val members = LinkedHashMap(withoutMac.objectValue!!)
            members["mac"] = PclinkJson.Text(PclinkBase64Url.encode(mac))
            return PclinkJson.Object(members)
        }
    }
}

/** Pairing transcript hash `sha256(th1 || 0x00 || th2)` (§4.4). */
object PclinkPairingTranscript {
    fun hash(hello: PclinkPairingMessage.Hello, auth: PclinkPairingMessage.Auth): ByteArray =
        PclinkCrypto.pairTranscriptHash(hello.canonicalWithoutMac(), auth.canonicalWithoutMac())
}

/**
 * PC-side lookup policy used by the pairing responder and its state-machine
 * tests: a syntactically valid init from an unknown machineId gets
 * `unpaired`, never a session or a sid-cache entry (§5.1).
 */
enum class PclinkPairingLookupResult { FOUND, UNPAIRED }

object PclinkPairingLookup {
    fun decide(records: Collection<PclinkPairingRecord>, fromMachineId: String): PclinkPairingLookupResult =
        if (records.any { it.peerMachineId == fromMachineId }) {
            PclinkPairingLookupResult.FOUND
        } else {
            PclinkPairingLookupResult.UNPAIRED
        }

    fun requireRecord(records: Collection<PclinkPairingRecord>, fromMachineId: String): PclinkPairingRecord =
        records.firstOrNull { it.peerMachineId == fromMachineId }
            ?: throw PclinkError.Unpaired("no pairing record for $fromMachineId")
}


/**
 * Pairing-carrier shape check for the phone receive path (§4.3). A rendezvous
 * is the 22-character b64url *text prefix* of a hash, not the canonical
 * encoding of 16 bytes, so it is checked as text rather than decoded with a
 * 16-byte expected length (that C1 validator rejects real rendezvous values).
 */
object PclinkPairingWire {
    private val RENDEZVOUS = Regex("^[A-Za-z0-9_-]{22}$")

    fun validatePairFrame(value: PclinkJson): String {
        val type = value["type"]?.stringValue ?: throw PclinkError.BadFrame("missing pairing type")
        when (type) {
            "relay.pair.open", "relay.pair.join" -> {
                val members = value.closedObject(setOf("v", "type", "rendezvous"))
                if (members["v"]?.longValue != 1L || !RENDEZVOUS.matches(value.requiredString("rendezvous"))) {
                    throw PclinkError.BadFrame("pair rendezvous")
                }
            }
            "relay.pair.joined" -> {
                val members = value.closedObject(setOf("v", "type", "rendezvous", "role", "peerMachineId"))
                if (members["v"]?.longValue != 1L || !RENDEZVOUS.matches(value.requiredString("rendezvous"))) {
                    throw PclinkError.BadFrame("pair rendezvous")
                }
                if (value.requiredString("role") !in setOf("pc", "phone")) {
                    throw PclinkError.BadFrame("pair role")
                }
                PclinkValidation.requireMachineId(value.requiredString("peerMachineId"))
            }
            "relay.pair.message" -> {
                val members = value.closedObject(setOf("v", "type", "rendezvous", "payload"))
                if (members["v"]?.longValue != 1L || !RENDEZVOUS.matches(value.requiredString("rendezvous"))) {
                    throw PclinkError.BadFrame("pair rendezvous")
                }
                if (value["payload"]?.objectValue == null) throw PclinkError.BadFrame("pair payload")
            }
            "relay.pair.close" -> {
                val members = value.closedObject(setOf("v", "type", "rendezvous", "reason"))
                if (members["v"]?.longValue != 1L || !RENDEZVOUS.matches(value.requiredString("rendezvous"))) {
                    throw PclinkError.BadFrame("pair rendezvous")
                }
                if (value.requiredString("reason") !in PclinkWire.pairCloseReasons) {
                    throw PclinkError.BadFrame("pair close reason")
                }
            }
            else -> throw PclinkError.BadFrame("unknown pairing relay type")
        }
        return type
    }
}
