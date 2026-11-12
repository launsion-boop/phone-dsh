// SPDX-License-Identifier: MIT
// JVM fakes for the C5 app tests. They implement the same small ports the
// production controller consumes; none of them copies protocol code, and the
// records/prompts are built from `:pclink`'s public value types.
package com.phonedsh.probe.pc

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.pclink.PclinkClientStatus
import com.phonedsh.pclink.PclinkError
import com.phonedsh.pclink.PclinkIdentity
import com.phonedsh.pclink.PclinkNotice
import com.phonedsh.pclink.PclinkOfflineReason
import com.phonedsh.pclink.PclinkPairingMode
import com.phonedsh.pclink.PclinkPairingPhase
import com.phonedsh.pclink.PclinkPairingPrompt
import com.phonedsh.pclink.PclinkPairingRecord
import com.phonedsh.pclink.PclinkPairingResult
import com.phonedsh.pclink.PclinkPairingUpdate
import com.phonedsh.pclink.PclinkClientState
import com.phonedsh.pclink.PclinkUnpairedReason
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import com.phonedsh.probe.PreferenceFile
import java.time.Instant
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

internal class MapPreferenceFile(
    initial: Map<String, Any?> = emptyMap(),
) : PreferenceFile {
    val values: MutableMap<String, Any?> = LinkedHashMap(initial)

    override fun string(key: String): String? = values[key] as? String
    override fun integer(key: String): Int? = values[key] as? Int
    override fun boolean(key: String): Boolean? = values[key] as? Boolean
    override fun putString(key: String, value: String): Boolean = set(key, value)
    override fun putInt(key: String, value: Int): Boolean = set(key, value)
    override fun putBoolean(key: String, value: Boolean): Boolean = set(key, value)
    override fun stringSet(key: String): Set<String>? = @Suppress("UNCHECKED_CAST") (values[key] as? Set<String>)
    override fun putStringSet(key: String, value: Set<String>): Boolean = set(key, value.toSet())
    override fun commitString(key: String, value: String): Boolean = set(key, value)
    override fun commitInt(key: String, value: Int): Boolean = set(key, value)
    override fun commitBoolean(key: String, value: Boolean): Boolean = set(key, value)
    override fun commitStringSet(key: String, value: Set<String>): Boolean = set(key, value.toSet())
    override fun remove(key: String) {
        values.remove(key)
    }

    private fun set(key: String, value: Any?): Boolean {
        values[key] = value
        return true
    }
}

internal class FakeSecureStore : SecureStore {
    override val level: SecurityLevel = SecurityLevel.SOFTWARE
    val values = LinkedHashMap<String, ByteArray>()
    val unreadable = HashSet<String>()
    var failWrites = false

    override suspend fun put(key: String, value: ByteArray) {
        if (failWrites) throw java.io.IOException("write failed")
        values[key] = value.copyOf()
    }

    override suspend fun get(key: String): SecureLookup = when {
        key in unreadable -> SecureLookup.Unreadable("key-invalidated")
        values.containsKey(key) -> SecureLookup.Found(values.getValue(key).copyOf())
        else -> SecureLookup.Absent
    }

    override suspend fun delete(key: String) {
        values.remove(key)
    }
}

/** A real `PclinkIdentity` plus the pairing value types built from it. */
internal object PcTestValues {
    val pc: PclinkIdentity = PclinkIdentity.generate()
    val phone: PclinkIdentity = PclinkIdentity.generate()

    fun record(
        name: String = "My PC",
        identity: PclinkIdentity = pc,
        pairedAt: String = "2026-11-12T03:13:00Z",
        origin: String = "https://relay.example",
        mode: PclinkPairingMode = PclinkPairingMode.QR,
    ): PclinkPairingRecord = PclinkPairingRecord(
        peerMachineId = identity.machineId,
        peerPublicKey = identity.publicKey,
        peerName = name,
        pairedAt = pairedAt,
        relayOrigin = origin,
        pairingMode = mode,
    )

    fun prompt(
        record: PclinkPairingRecord = record(),
        id: String = "pairing-1",
        mode: PclinkPairingMode = PclinkPairingMode.QR,
    ): PclinkPairingPrompt = PclinkPairingPrompt(
        id = id,
        mode = mode,
        relayOrigin = record.relayOrigin,
        pcName = record.peerName,
        pcMachineId = record.peerMachineId,
        ownFingerprint = phone.fingerprint,
        warningText = PclinkPairingPrompt.FULL_OWNER_WARNING,
        expiresAt = Instant.parse("2026-11-12T03:20:00Z"),
    )
}

internal class FakePcLinkClient : PcLinkClientPort {
    private val mutableStatus = MutableStateFlow(
        PclinkClientStatus(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
            machineId = PcTestValues.phone.machineId,
            fingerprint = PcTestValues.phone.fingerprint,
        ),
    )
    private val mutableNotices = MutableSharedFlow<PclinkNotice>(extraBufferCapacity = 8)
    private val mutableUpdates = MutableSharedFlow<PclinkPairingUpdate>(extraBufferCapacity = 8)

    override val status: StateFlow<PclinkClientStatus> = mutableStatus.asStateFlow()
    override val notices: SharedFlow<PclinkNotice> = mutableNotices.asSharedFlow()
    override val pairingUpdates: SharedFlow<PclinkPairingUpdate> = mutableUpdates.asSharedFlow()

    var startError: Exception? = null
    var nextPrompt: PclinkPairingPrompt? = PcTestValues.prompt()
    var confirmRecord: PclinkPairingRecord = PcTestValues.record()
    var holdPairing = false
    var beginCount = 0
    var confirmCount = 0
    var cancelCount = 0
    var unpairCount = 0
    private var gate: CompletableDeferred<PclinkPairingPrompt>? = null

    fun setStatus(value: PclinkClientStatus) {
        mutableStatus.value = value
    }

    fun setOnline(record: PclinkPairingRecord = confirmRecord) {
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Online,
            record = record,
            peerDshVersion = "0.2.2-rc.1",
            peerAppName = "phoneDSH",
            peerAppVersion = "0.2.2-rc.1",
            lastError = null,
        )
    }

    fun setOffline(reason: PclinkOfflineReason = PclinkOfflineReason.PeerOffline) {
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Offline(reason),
            lastError = null,
        )
    }

    override suspend fun start() {
        startError?.let { throw it }
    }

    override suspend fun beginPairing(qrUri: String): PclinkPairingPrompt {
        beginCount++
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Pairing(PclinkPairingPhase.Joining),
        )
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Pairing(PclinkPairingPhase.WaitingForPC),
        )
        val prompt = nextPrompt ?: throw PclinkError.BadFrame("no prompt")
        if (!holdPairing) return prompt
        val waiting = CompletableDeferred<PclinkPairingPrompt>()
        gate = waiting
        return waiting.await()
    }

    override suspend fun beginManualPairing(code: String, relayOrigin: String): PclinkPairingPrompt =
        beginPairing("manual:$code@$relayOrigin")

    override suspend fun confirmPairing(id: String): PclinkPairingResult {
        confirmCount++
        val record = confirmRecord
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Online,
            record = record,
            peerDshVersion = "0.2.2-rc.1",
        )
        mutableUpdates.emit(PclinkPairingUpdate.Completed(record))
        return PclinkPairingResult(record, nextPrompt ?: PcTestValues.prompt(record))
    }

    override suspend fun cancelPairing() {
        cancelCount++
        val current = gate
        gate = null
        current?.completeExceptionally(PclinkError.PairingCancelled())
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
            record = null,
        )
    }

    override suspend fun unpair() {
        unpairCount++
        mutableStatus.value = mutableStatus.value.copy(
            state = PclinkClientState.Unpaired(PclinkUnpairedReason.NoRecord),
            record = null,
        )
    }

    override suspend fun acknowledgePCUnpair() = unpair()

    override suspend fun removeLocalRecord() = unpair()

    override suspend fun foregroundResumed() = Unit

    override suspend fun stop() = Unit

    override fun clearLastError() {
        mutableStatus.value = mutableStatus.value.copy(lastError = null)
    }
}

internal class ScriptedDshCall : PcDshCall {
    val calls = CopyOnWriteArrayList<Pair<String, JsonValue>>()
    var handler: suspend (String, JsonValue) -> JsonValue = { _, _ ->
        JsonObject(linkedMapOf("accepted" to JsonBool(true)))
    }

    override suspend fun call(endpoint: String, args: JsonValue): JsonValue {
        calls.add(endpoint to args)
        return handler(endpoint, args)
    }
}

/** Serves one empty `session/list` answer and records nothing else. */
internal fun emptySessionList(): JsonValue = JsonObject(
    linkedMapOf("items" to com.phonedsh.agentcore.JsonArray(emptyList())),
)
