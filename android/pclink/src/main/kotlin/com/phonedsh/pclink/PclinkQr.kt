// SPDX-License-Identifier: MIT
// QR/manual pairing materials (§4.1, §4.2). The parser is hand-written on
// purpose: URLComponents/URI would tolerate a raw `+`, duplicate parameters and
// uppercase origins that the frozen contract rejects.
package com.phonedsh.pclink

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** The two explicit, mutually exclusive v1 pairing modes (§4.1). */
enum class PclinkPairingMode(val wire: String) {
    QR("qr"),
    MANUAL("manual"),
    ;

    companion object {
        fun fromWire(value: String): PclinkPairingMode? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * One in-memory pairing offer. The PC key/machineId are pinned only for the QR
 * path; the manual path learns them from the MACed `pair.hello`.
 */
class PclinkPairingOffer(
    val mode: PclinkPairingMode,
    val relayOrigin: String,
    secret: ByteArray,
    val pcMachineId: String? = null,
    pcPublicKey: ByteArray? = null,
    val pcName: String? = null,
) {
    val secret: ByteArray = secret.copyOf()
    val pcPublicKey: ByteArray? = pcPublicKey?.copyOf()

    init {
        PclinkValidation.origin(relayOrigin)
        when (mode) {
            PclinkPairingMode.QR -> if (this.secret.size != 16) {
                throw PclinkError.BadFrame("QR pairing secret must be 16 bytes")
            }
            PclinkPairingMode.MANUAL -> if (this.secret.size != 10) {
                throw PclinkError.BadFrame("manual pairing secret must be 10 bytes")
            }
        }
        this.pcPublicKey?.let { key ->
            if (key.size != 32) throw PclinkError.BadFrame("PC public key must be 32 bytes")
        }
        pcMachineId?.let { PclinkValidation.requireMachineId(it, "pcMachineId") }
        pcName?.let { PclinkValidation.name(it) }
    }

    val rendezvous: String
        get() = PclinkCrypto.rendezvous(secret, relayOrigin)

    val pairKey: ByteArray
        get() = PclinkCrypto.pairKey(secret)

    val websocketUrl: String
        get() = PclinkValidation.websocketUrl(relayOrigin)

    /**
     * Verifies a received `pair.hello` against the QR pin and the frozen MAC
     * rules (§4.4). A manual offer has no pin; the key-derived machineId is
     * still compared with the message.
     */
    fun verifyHello(hello: PclinkPairingMessage.Hello) {
        if (hello.relay != relayOrigin) {
            throw PclinkError.AuthFailed("pair.hello relay does not match the pairing origin")
        }
        val derived = PclinkBase32.machineId(hello.publicKey)
        if (derived != hello.machineId) {
            throw PclinkError.AuthFailed("pair.hello machineId does not match its key")
        }
        pcMachineId?.let { pinned ->
            if (hello.machineId != pinned) {
                throw PclinkError.AuthFailed("pair.hello machineId does not match the QR pin")
            }
        }
        pcPublicKey?.let { pinned ->
            if (!hello.publicKey.contentEquals(pinned)) {
                throw PclinkError.AuthFailed("pair.hello publicKey does not match the QR pin")
            }
        }
        hello.verifyMac(pairKey)
    }

    override fun toString(): String =
        "PclinkPairingOffer(mode=$mode, relayOrigin=$relayOrigin, pinned=${pcMachineId != null})"
}

/** Frozen `pclink://pair?...` URI parser/builder (§4.2). */
object PclinkQrCode {
    private const val PREFIX = "pclink://pair?"
    private val ALLOWED = setOf("v", "r", "m", "k", "s", "n")

    fun parse(uri: String): PclinkPairingOffer {
        if (uri.toByteArray(Charsets.UTF_8).size > PclinkLimits.PAIRING_QR_LENGTH_LIMIT) {
            throw PclinkError.BadFrame("QR URI exceeds 512 bytes")
        }
        if (uri.contains('#')) throw PclinkError.BadFrame("QR URI must not have a fragment")
        if (!uri.startsWith(PREFIX)) throw PclinkError.BadFrame("QR URI must be pclink://pair")
        val query = uri.substring(PREFIX.length)
        if (query.contains('+')) throw PclinkError.BadFrame("QR URI must not contain a raw +")
        val parameters = LinkedHashMap<String, String>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) throw PclinkError.BadFrame("empty QR query parameter")
            val equals = pair.indexOf('=')
            if (equals <= 0 || pair.indexOf('=', equals + 1) >= 0) {
                throw PclinkError.BadFrame("QR query parameter is malformed")
            }
            val name = pair.substring(0, equals)
            if (name.contains('%')) {
                throw PclinkError.BadFrame("QR parameter names must not be percent-encoded")
            }
            if (parameters.containsKey(name)) {
                throw PclinkError.BadFrame("duplicate QR parameter $name")
            }
            parameters[name] = percentDecode(pair.substring(equals + 1))
        }
        for (key in parameters.keys) {
            if (key !in ALLOWED) throw PclinkError.BadFrame("unknown QR parameter $key")
        }
        if (parameters["v"] != "1") throw PclinkError.BadFrame("QR v must be 1")
        val origin = parameters["r"] ?: throw PclinkError.BadFrame("QR is missing r")
        val machineId = parameters["m"] ?: throw PclinkError.BadFrame("QR is missing m")
        val keyText = parameters["k"] ?: throw PclinkError.BadFrame("QR is missing k")
        val secretText = parameters["s"] ?: throw PclinkError.BadFrame("QR is missing s")
        val name = parameters["n"] ?: throw PclinkError.BadFrame("QR is missing n")
        PclinkValidation.origin(origin)
        PclinkValidation.requireMachineId(machineId, "m")
        val publicKey = PclinkBase64Url.decode(keyText, expectedLength = 32)
        val secret = PclinkBase64Url.decode(secretText, expectedLength = 16)
        if (PclinkBase32.machineId(publicKey) != machineId) {
            throw PclinkError.AuthFailed("QR machineId does not match its public key")
        }
        PclinkValidation.name(name)
        return PclinkPairingOffer(
            mode = PclinkPairingMode.QR,
            relayOrigin = origin,
            secret = secret,
            pcMachineId = machineId,
            pcPublicKey = publicKey,
            pcName = name,
        )
    }

    fun makeUri(
        relayOrigin: String,
        pcMachineId: String,
        pcPublicKey: ByteArray,
        secret: ByteArray,
        pcName: String,
    ): String {
        PclinkValidation.origin(relayOrigin)
        PclinkValidation.requireMachineId(pcMachineId)
        if (pcPublicKey.size != 32 || secret.size != 16) {
            throw PclinkError.BadFrame("QR key/secret length")
        }
        if (PclinkBase32.machineId(pcPublicKey) != pcMachineId) {
            throw PclinkError.AuthFailed("QR machineId does not match its public key")
        }
        PclinkValidation.name(pcName)
        val uri = PREFIX + listOf(
            "v=1",
            "r=${percentEncode(relayOrigin)}",
            "m=$pcMachineId",
            "k=${PclinkBase64Url.encode(pcPublicKey)}",
            "s=${PclinkBase64Url.encode(secret)}",
            "n=${percentEncode(pcName)}",
        ).joinToString("&")
        if (uri.toByteArray(Charsets.UTF_8).size > PclinkLimits.PAIRING_QR_LENGTH_LIMIT) {
            throw PclinkError.BadFrame("QR URI exceeds 512 bytes")
        }
        return uri
    }

    /** RFC 3986 unreserved characters stay literal; everything else is uppercase `%XX`. */
    fun percentEncode(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val unsigned = byte.toInt() and 0xFF
            val unreserved = unsigned in 0x41..0x5A || unsigned in 0x61..0x7A ||
                unsigned in 0x30..0x39 || unsigned == 0x2D || unsigned == 0x2E ||
                unsigned == 0x5F || unsigned == 0x7E
            if (unreserved) {
                out.append(unsigned.toChar())
            } else {
                out.append('%')
                out.append(HEX[(unsigned shr 4) and 0xF])
                out.append(HEX[unsigned and 0xF])
            }
        }
        return out.toString()
    }

    fun percentDecode(value: String): String {
        val bytes = ArrayList<Byte>(value.length)
        val input = value.toByteArray(Charsets.UTF_8)
        var index = 0
        while (index < input.size) {
            val byte = input[index].toInt() and 0xFF
            when {
                byte == 0x25 -> {
                    if (index + 2 >= input.size) {
                        throw PclinkError.BadFrame("invalid percent escape")
                    }
                    val high = hexValue(input[index + 1])
                    val low = hexValue(input[index + 2])
                    if (high < 0 || low < 0) throw PclinkError.BadFrame("invalid percent escape")
                    bytes.add(((high shl 4) or low).toByte())
                    index += 3
                }
                byte == 0x2B -> throw PclinkError.BadFrame("raw + is not a space")
                else -> {
                    bytes.add(byte.toByte())
                    index++
                }
            }
        }
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes.toByteArray()))
                .toString()
        } catch (_: CharacterCodingException) {
            throw PclinkError.BadFrame("percent escape is not UTF-8")
        }
    }

    private fun hexValue(byte: Byte): Int = when (val value = byte.toInt() and 0xFF) {
        in 0x30..0x39 -> value - 0x30
        in 0x61..0x66 -> value - 0x61 + 10
        in 0x41..0x46 -> value - 0x41 + 10
        else -> -1
    }

    private const val HEX = "0123456789ABCDEF"
}

/** Manual code parsing/display (§4.1, §4.5). */
object PclinkManualCode {
    fun parse(input: String, relayOrigin: String): PclinkPairingOffer {
        PclinkValidation.origin(relayOrigin)
        return PclinkPairingOffer(
            mode = PclinkPairingMode.MANUAL,
            relayOrigin = relayOrigin,
            secret = PclinkCrockford.decode(input),
        )
    }

    fun display(secret: ByteArray): String = PclinkCrockford.display(PclinkCrockford.encode(secret))
}

/**
 * The fingerprint is a display/unpair-target value in v1.6; it is never a
 * pairing-approval input (CCR-1 / §2.2 / §4.6).
 */
object PclinkApproval {
    fun fingerprintMatches(input: String, publicKey: ByteArray): Boolean =
        PclinkValidation.fingerprintMatches(input, PclinkBase32.machineId(publicKey))

    /**
     * v1.6 automatic approval: a verified `pair.auth` is the approval, so a
     * QR/manual mode always produces `confirm_sent`. `approved == false` is
     * only retained for the frozen resource fixture; a new pairing is never
     * silently approved without the screen-secret proof.
     */
    fun decide(mode: String, approved: Boolean): String {
        if (PclinkPairingMode.fromWire(mode) == null) throw PclinkError.BadFrame("unknown pairing mode")
        return if (approved) "confirm_sent" else "blocked"
    }
}
