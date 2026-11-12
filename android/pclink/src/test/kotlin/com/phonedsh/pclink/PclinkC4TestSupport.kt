// SPDX-License-Identifier: MIT
// Shared fixtures for the C4 tests, never production code: an in-memory RPC
// channel, the real golden `PclinkE2eSession` (established with the shared
// vectors), the pre-paired stores used by the FakePc integration, and small
// outer-frame helpers for the seq/cross-sid vectors.
package com.phonedsh.pclink

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.delay

internal class C4IdentityStore(seed: ByteArray?) : PclinkIdentityStore {
    private var value = seed?.copyOf()

    override fun loadSeed(): ByteArray? = value?.copyOf()

    override fun saveSeed(seed: ByteArray) {
        value = seed.copyOf()
    }

    override fun deleteSeed() {
        value = null
    }
}

internal class C4PairingStore(initial: PclinkPairingRecord? = null) : PclinkPairingStore {
    @Volatile
    var stored: PclinkPairingRecord? = initial

    override fun load(phoneMachineId: String): PclinkPairingStoreState =
        stored?.let { PclinkPairingStoreState.Usable(it) } ?: PclinkPairingStoreState.None

    override fun save(record: PclinkPairingRecord, phoneMachineId: String) {
        stored = record
    }

    override fun delete() {
        stored = null
    }

    override fun hasStoredFile(): Boolean = stored != null
}

/** In-memory outbound channel for standalone `PclinkRpc` tests. */
internal class C4RpcChannel(
    @Volatile var session: PclinkE2eSession? = null,
) : PclinkRpcChannel {
    val sent = CopyOnWriteArrayList<PclinkJson>()

    @Volatile
    var sendError: PclinkError? = null

    override suspend fun sendInner(inner: PclinkJson) {
        sendError?.let { throw it }
        sent.add(inner)
    }

    override fun activeSession(): PclinkE2eSession? = session

    fun frames(type: String): List<PclinkJson> =
        sent.filter { it["type"]?.stringValue == type }
}

/** The real golden session after `peer.hello`, i.e. ESTABLISHED. */
internal fun c4EstablishedGoldenSession(): PclinkE2eSession {
    val session = C2TestSupport.goldenSession()
    val inner = session.open(C2TestSupport.outerFrame(C2TestSupport.frameCase("pc-peer-hello-seq0"))).inner
    session.acceptFirstInner(inner)
    return session
}

internal fun c4RecordFor(pc: PclinkIdentity, origin: String = "https://relay.example"): PclinkPairingRecord =
    PclinkPairingRecord(
        peerMachineId = pc.machineId,
        peerPublicKey = pc.publicKey,
        peerName = "My PC",
        pairedAt = "2026-11-09T00:00:00Z",
        relayOrigin = origin,
        pairingMode = PclinkPairingMode.QR,
    )

/** A copy of one golden outer e2e frame with an optional seq/sid mutation. */
internal fun c4Outer(frame: PclinkJson, seq: Long? = null, sid: String? = null): PclinkJson =
    pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("e2e"),
        "sid" to PclinkJson.Text(sid ?: TestSupport.requireString(frame, "sid")),
        "seq" to PclinkJson.Integer(seq ?: TestSupport.requireInt(frame, "seq")),
        "from" to PclinkJson.Text(TestSupport.requireString(frame, "from")),
        "to" to PclinkJson.Text(TestSupport.requireString(frame, "to")),
        "body" to PclinkJson.Text(TestSupport.requireString(frame, "body")),
    )

internal fun c4ResultFrame(id: String, result: PclinkJson): PclinkJson = pclinkObject(
    "type" to PclinkJson.Text("rpc.result"),
    "id" to PclinkJson.Text(id),
    "ok" to PclinkJson.Bool(true),
    "result" to result,
)

internal fun c4ErrorFrame(id: String, code: String, message: String): PclinkJson = pclinkObject(
    "type" to PclinkJson.Text("rpc.result"),
    "id" to PclinkJson.Text(id),
    "ok" to PclinkJson.Bool(false),
    "error" to pclinkObject(
        "code" to PclinkJson.Text(code),
        "message" to PclinkJson.Text(message),
    ),
)

internal fun c4ChunkFrame(type: String, idKey: String, id: String, chunk: PclinkRpcChunk): PclinkJson =
    pclinkObject(
        "type" to PclinkJson.Text(type),
        idKey to PclinkJson.Text(id),
        "part" to PclinkJson.Integer(chunk.part),
        "last" to PclinkJson.Bool(chunk.last),
        "data" to PclinkJson.Text(chunk.data),
    )

internal suspend fun c4Await(timeoutMillis: Long = 3_000, condition: () -> Boolean) {
    val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
    while (!condition()) {
        if (System.nanoTime() > deadline) throw AssertionError("condition was not met within ${timeoutMillis}ms")
        delay(2)
    }
}
