// SPDX-License-Identifier: MIT
// Phone pairing record, usability/audit model and the injectable durable store
// (§4.6, design §5.2). `:pclink` is a JVM module: this file only uses
// java.nio.file. The Android Keystore/context wiring belongs to `:app` (C5).
package com.phonedsh.pclink

import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.nio.file.attribute.PosixFilePermissions

/** `connection.mode`; `direct` is reserved and never usable in v1 (§4.6). */
enum class PclinkConnectionMode(val wire: String) {
    RELAY("relay"),
    DIRECT("direct"),
}

/**
 * One phone-side pairing record. The phone record never carries the PC-only
 * `approvedAt`/`approvedVia`; `pairingMode` is optional display metadata.
 */
class PclinkPairingRecord(
    val peerMachineId: String,
    peerPublicKey: ByteArray,
    val peerName: String,
    val pairedAt: String,
    val relayOrigin: String,
    val connectionMode: PclinkConnectionMode = PclinkConnectionMode.RELAY,
    val pairingMode: PclinkPairingMode? = null,
) {
    val peerPublicKey: ByteArray = peerPublicKey.copyOf()

    init {
        PclinkValidation.requireMachineId(peerMachineId, "peerMachineId")
        if (this.peerPublicKey.size != 32) {
            throw PclinkError.BadFrame("peerPublicKey must be 32 bytes")
        }
        if (PclinkBase32.machineId(this.peerPublicKey) != peerMachineId) {
            throw PclinkError.Storage("pairing record machineId does not match its public key")
        }
        PclinkValidation.name(peerName)
        if (!PclinkValidation.isTimestamp(pairedAt)) {
            throw PclinkError.Storage("pairing record pairedAt is not RFC 3339 UTC")
        }
        PclinkValidation.origin(relayOrigin)
        if (connectionMode != PclinkConnectionMode.RELAY) {
            throw PclinkError.VersionUnsupported("connection.mode ${connectionMode.wire} is not callable in v1")
        }
    }

    val fingerprint: String get() = PclinkValidation.fingerprint(peerMachineId)

    fun toJson(): PclinkJson {
        val members = LinkedHashMap<String, PclinkJson>()
        members["peerMachineId"] = PclinkJson.Text(peerMachineId)
        members["peerPublicKey"] = PclinkJson.Text(PclinkBase64Url.encode(peerPublicKey))
        members["peerName"] = PclinkJson.Text(peerName)
        members["pairedAt"] = PclinkJson.Text(pairedAt)
        members["relayOrigin"] = PclinkJson.Text(relayOrigin)
        members["connection"] = pclinkObject("mode" to PclinkJson.Text(connectionMode.wire))
        pairingMode?.let { members["pairingMode"] = PclinkJson.Text(it.wire) }
        return PclinkJson.Object(members)
    }

    fun copy(
        peerMachineId: String = this.peerMachineId,
        peerPublicKey: ByteArray = this.peerPublicKey,
        peerName: String = this.peerName,
        pairedAt: String = this.pairedAt,
        relayOrigin: String = this.relayOrigin,
        connectionMode: PclinkConnectionMode = this.connectionMode,
        pairingMode: PclinkPairingMode? = this.pairingMode,
    ): PclinkPairingRecord = PclinkPairingRecord(
        peerMachineId = peerMachineId,
        peerPublicKey = peerPublicKey,
        peerName = peerName,
        pairedAt = pairedAt,
        relayOrigin = relayOrigin,
        connectionMode = connectionMode,
        pairingMode = pairingMode,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PclinkPairingRecord) return false
        return peerMachineId == other.peerMachineId &&
            peerPublicKey.contentEquals(other.peerPublicKey) &&
            peerName == other.peerName &&
            pairedAt == other.pairedAt &&
            relayOrigin == other.relayOrigin &&
            connectionMode == other.connectionMode &&
            pairingMode == other.pairingMode
    }

    override fun hashCode(): Int {
        var result = peerMachineId.hashCode()
        result = 31 * result + peerPublicKey.contentHashCode()
        result = 31 * result + peerName.hashCode()
        result = 31 * result + pairedAt.hashCode()
        result = 31 * result + relayOrigin.hashCode()
        result = 31 * result + connectionMode.hashCode()
        result = 31 * result + (pairingMode?.hashCode() ?: 0)
        return result
    }

    override fun toString(): String =
        "PclinkPairingRecord(peerMachineId=$peerMachineId, peerName=$peerName, relayOrigin=$relayOrigin)"

    companion object {
        /** Parses a phone record and re-derives the key-bound machineId (§2.2). */
        fun fromJson(value: PclinkJson): PclinkPairingRecord {
            PclinkWire.validatePairingRecordShape(value, phoneRecord = true)
            val publicKey = PclinkBase64Url.decode(value.requiredString("peerPublicKey"), 32)
            val machineId = value.requiredString("peerMachineId")
            if (PclinkBase32.machineId(publicKey) != machineId) {
                throw PclinkError.Storage("pairing record machineId does not match its public key")
            }
            val connection = value["connection"]?.closedObject(setOf("mode"))
                ?: throw PclinkError.Storage("missing connection")
            val mode = connection["mode"]?.stringValue
            val parsedMode = PclinkConnectionMode.entries.firstOrNull { it.wire == mode }
                ?: throw PclinkError.Storage("unknown connection mode")
            if (parsedMode != PclinkConnectionMode.RELAY) {
                throw PclinkError.VersionUnsupported("connection.mode ${parsedMode.wire} is not callable in v1")
            }
            val pairingMode = value["pairingMode"]?.let {
                PclinkPairingMode.fromWire(it.stringValue ?: throw PclinkError.Storage("unknown phone pairingMode"))
                    ?: throw PclinkError.Storage("unknown phone pairingMode")
            }
            return PclinkPairingRecord(
                peerMachineId = machineId,
                peerPublicKey = publicKey,
                peerName = value.requiredString("peerName"),
                pairedAt = value.requiredString("pairedAt"),
                relayOrigin = value.requiredString("relayOrigin"),
                connectionMode = parsedMode,
                pairingMode = pairingMode,
            )
        }

        /** Shape-only phone-record check for schema fixtures (no key re-derivation). */
        fun validatePhoneRecordJson(value: PclinkJson) {
            PclinkWire.validatePairingRecordShape(value, phoneRecord = true)
        }

        /**
         * Validates the PC-side record shape used by the shared fixtures. The
         * PC record requires both approval fields; `cli`/`webui` are the
         * accepted legacy values and are never rewritten by the phone.
         */
        fun validatePcRecordJson(value: PclinkJson) {
            PclinkWire.validatePairingRecordShape(value, phoneRecord = false)
        }
    }
}

/** Result of loading the one phone record against the current identity (§4.6). */
sealed interface PclinkPairingStoreState {
    data object None : PclinkPairingStoreState
    data class Usable(val record: PclinkPairingRecord) : PclinkPairingStoreState

    /** The envelope belongs to a different identity; preserved but never used. */
    data class Stale(val record: PclinkPairingRecord) : PclinkPairingStoreState
}

/**
 * Injectable persistence seam. C2's tests use an in-memory implementation; C5
 * passes `PclinkFilePairingStore(context.filesDir.resolve("pclink/pairs.json"))`.
 */
interface PclinkPairingStore {
    fun load(phoneMachineId: String): PclinkPairingStoreState
    fun save(record: PclinkPairingRecord, phoneMachineId: String)
    fun delete()
    fun hasStoredFile(): Boolean
}

/** PC audit usability (§4.6); the phone drives the same state-machine rows. */
enum class PclinkRecordUsability { USABLE, UNAPPROVED, REVOKED, STALE, UNSUPPORTED }

object PclinkRecordAudit {
    /**
     * The latest `pair`/`unpair` line for the peer must be a `pair` line that
     * matches the peer key and `sha256(canonical_json(record))`; otherwise the
     * record is unapproved or revoked and never used.
     */
    fun evaluate(record: PclinkJson, audit: List<PclinkJson>): PclinkRecordUsability {
        val peerMachineId = record["peerMachineId"]?.stringValue ?: return PclinkRecordUsability.UNSUPPORTED
        val peerPublicKey = record["peerPublicKey"]?.stringValue ?: return PclinkRecordUsability.UNSUPPORTED
        if (record["connection"]?.get("mode")?.stringValue != "relay") {
            return PclinkRecordUsability.UNSUPPORTED
        }
        var latest: PclinkJson? = null
        for (entry in audit) {
            if (entry["peerMachineId"]?.stringValue != peerMachineId) continue
            when (entry["event"]?.stringValue) {
                "pair", "unpair" -> latest = entry
                else -> continue
            }
        }
        latest ?: return PclinkRecordUsability.UNAPPROVED
        if (latest["event"]?.stringValue != "pair") return PclinkRecordUsability.REVOKED
        if (latest["peerPublicKey"]?.stringValue != peerPublicKey) return PclinkRecordUsability.UNAPPROVED
        val digest = PclinkHex.encode(PclinkCrypto.sha256(PclinkJsonEncoder.canonical(record)))
        if (latest["recordSha256"]?.stringValue != digest) return PclinkRecordUsability.UNAPPROVED
        return PclinkRecordUsability.USABLE
    }
}

/**
 * `{"v":1,"phoneMachineId":"...","records":[record]}` on disk, written by an
 * atomic same-directory replace with file and directory fsync (§4.6). Android
 * has no portable POSIX 0600; the app UID sandbox is the real boundary and this
 * store asks the filesystem for owner-only permissions where it supports them.
 */
class PclinkFilePairingStore(private val file: Path) : PclinkPairingStore {
    companion object {
        const val DEFAULT_FILE_NAME = "pairs.json"

        fun inDirectory(directory: Path): PclinkFilePairingStore =
            PclinkFilePairingStore(directory.resolve(DEFAULT_FILE_NAME))
    }

    override fun hasStoredFile(): Boolean = Files.exists(file)

    override fun load(phoneMachineId: String): PclinkPairingStoreState {
        if (!Files.exists(file)) return PclinkPairingStoreState.None
        try {
            val value = PclinkJsonParser.parseDocumentObject(Files.readAllBytes(file))
            val envelope = value.closedObject(setOf("v", "phoneMachineId", "records"))
            if (envelope["v"]?.longValue != 1L) {
                throw PclinkError.Storage("pairing file v is not 1")
            }
            val storedMachineId = value.requiredString("phoneMachineId")
            PclinkValidation.requireMachineId(storedMachineId)
            val records = value["records"]?.arrayValue
                ?: throw PclinkError.Storage("pairing file records is not an array")
            if (records.size > 1) {
                throw PclinkError.Storage("the phone holds at most one pairing record")
            }
            if (records.isEmpty()) return PclinkPairingStoreState.None
            val record = PclinkPairingRecord.fromJson(records.first())
            return if (storedMachineId == phoneMachineId) {
                PclinkPairingStoreState.Usable(record)
            } else {
                PclinkPairingStoreState.Stale(record)
            }
        } catch (error: PclinkError.VersionUnsupported) {
            throw error
        } catch (error: PclinkError) {
            throw PclinkError.Storage("cannot read the pairing record: ${error.message}")
        } catch (error: Exception) {
            throw PclinkError.Storage("cannot read the pairing record: ${error.message}")
        }
    }

    override fun save(record: PclinkPairingRecord, phoneMachineId: String) {
        PclinkValidation.requireMachineId(phoneMachineId, "phoneMachineId")
        val document = pclinkObject(
            "v" to PclinkJson.Integer(1),
            "phoneMachineId" to PclinkJson.Text(phoneMachineId),
            "records" to PclinkJson.Array(listOf(record.toJson())),
        )
        try {
            atomicWrite(PclinkJsonEncoder.encode(document))
        } catch (error: PclinkError) {
            throw error
        } catch (error: Exception) {
            throw PclinkError.Storage("cannot write the pairing record: ${error.message}")
        }
    }

    override fun delete() {
        try {
            Files.deleteIfExists(file)
            file.parent?.let { directory ->
                if (Files.isDirectory(directory)) fsyncDirectory(directory)
            }
        } catch (error: Exception) {
            throw PclinkError.Storage("cannot delete the pairing record: ${error.message}")
        }
    }

    private fun atomicWrite(data: ByteArray) {
        val directory = file.toAbsolutePath().parent ?: throw PclinkError.Storage("pairing file has no parent")
        Files.createDirectories(directory)
        val temporary = Files.createTempFile(directory, ".${file.fileName}.tmp.", "")
        var moved = false
        try {
            FileChannel.open(
                temporary,
                StandardOpenOption.WRITE,
                StandardOpenOption.TRUNCATE_EXISTING,
            ).use { channel ->
                val buffer = ByteBuffer.wrap(data)
                while (buffer.hasRemaining()) channel.write(buffer)
                channel.force(true)
            }
            ownerOnly(temporary)
            try {
                Files.move(
                    temporary,
                    file,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING)
            }
            moved = true
            ownerOnly(file)
            fsyncDirectory(directory)
        } finally {
            if (!moved) Files.deleteIfExists(temporary)
        }
    }

    private fun ownerOnly(path: Path) {
        try {
            val permissions = setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
            )
            Files.setPosixFilePermissions(path, PosixFilePermissions.asFileAttribute(permissions).value())
        } catch (_: UnsupportedOperationException) {
            // Non-POSIX filesystem: the app UID sandbox remains the boundary.
        } catch (_: Exception) {
            // Keep the write successful; do not claim POSIX 0600 everywhere.
        }
    }

    private fun fsyncDirectory(directory: Path) {
        try {
            FileChannel.open(directory, StandardOpenOption.READ).use { it.force(true) }
        } catch (_: Exception) {
            // Directory fsync is not available on every filesystem. The atomic
            // rename still prevents a partially written record.
        }
    }
}
