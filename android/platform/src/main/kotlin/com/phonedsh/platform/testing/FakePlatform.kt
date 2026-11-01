// The shared JVM test double for every upper layer.
// SPDX-License-Identifier: MIT
//
// This class is in src/main on purpose: :platform has no test-fixtures source
// set (adding one would touch the build beyond the single coroutines pin), and
// :controller/:dsh JVM tests must share one fake. It is a test double, not a
// production backend: the Android adapters implement the six interfaces with
// real platform APIs.

package com.phonedsh.platform.testing

import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.platform.EngineHost
import com.phonedsh.platform.LifecycleSignal
import com.phonedsh.platform.LifecycleSignals
import com.phonedsh.platform.LifecycleSnapshot
import com.phonedsh.platform.NotificationAction
import com.phonedsh.platform.Notifier
import com.phonedsh.platform.NotifierAvailability
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.Comparator
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow

/** One recorded [Notifier.notify] call; [action] is kept by reference. */
data class NotificationCall(
    val id: Int,
    val title: String,
    val body: String,
    val ongoing: Boolean,
    val action: NotificationAction?,
)

/**
 * Deterministic implementation of all six SPIs for JVM tests.
 *
 * Test double: it currently ships inside the `:platform` AAR; if the published
 * artifact must be slimmed, move it to a test-fixtures source set or `:testkit`.
 *
 * - Clock: [advanceBy] moves wall and monotonic time together; [setNowMillis]
 *   moves only the wall clock, so a clock-jump test cannot hide behind a
 *   monotonic change.
 * - LifecycleSignals: [emit] records history and delivers to collectors. Every
 *   collector receives one [LifecycleSnapshot] first (latest value per kind, in
 *   first-seen order), then live changes. Signals are carried verbatim — the
 *   fake invents no reading, so a `Battery` it is given with `lowPower = true`
 *   is published with `lowPower = true`; a kind that was never emitted is
 *   absent from the snapshot rather than defaulted.
 * - Durability: reports [durabilityLevel] and performs a real atomic replace in
 *   [tempDir]; [fsyncedPaths] records every sync request.
 * - SecureStore: in-memory three-state lookup ([SecureLookup.Found] /
 *   [SecureLookup.Absent] / [SecureLookup.Unreadable]), defensive byte copies,
 *   and [securityLevel]; [markUnreadable] models key invalidation.
 * - Notifier: records every call in [notifications]/[cancelledIds] and can press
 *   the recorded action through [performAction].
 * - EngineHost: delegates to [engine], a [FakeEngineHost].
 *
 * [root] lets a test supply its own directory; otherwise the first [tempDir]
 * access creates one and [close] deletes it. A caller-supplied root is never
 * deleted by this class.
 */
class FakePlatform(
    nowMillis: Long = 0L,
    monotonicMillis: Long = 0L,
    initialDurabilityLevel: DurabilityLevel = DurabilityLevel.LEVEL_1_PROCESS_KILL,
    initialSecurityLevel: SecurityLevel = SecurityLevel.SOFTWARE,
    initialNotifierAvailability: NotifierAvailability = NotifierAvailability.ENABLED,
    private val root: Path? = null,
    private val engineHost: FakeEngineHost = FakeEngineHost(),
) : Clock, LifecycleSignals, Durability, SecureStore, Notifier,
    EngineHost by engineHost, AutoCloseable {

    private val lock = Any()
    private var wallMillis: Long = nowMillis
    private var monotonic: Long = monotonicMillis

    /** The durability level [level] reports; mutable so a test can lower it. */
    var durabilityLevel: DurabilityLevel = initialDurabilityLevel

    /** The security level [level] reports; mutable so a test can downgrade it. */
    var securityLevel: SecurityLevel = initialSecurityLevel

    /** The availability [availability] reports. */
    var notifierAvailability: NotifierAvailability = initialNotifierAvailability

    /** The engine double behind the delegated [EngineHost] members. */
    val engine: FakeEngineHost
        get() = engineHost

    override fun nowMillis(): Long = wallMillis

    override fun monotonicMillis(): Long = monotonic

    /** Moves both readings forward by [millis]; negative values are rejected. */
    fun advanceBy(millis: Long) {
        require(millis >= 0L) { "a clock cannot advance by a negative duration: $millis" }
        wallMillis += millis
        monotonic += millis
    }

    /** Jumps the wall clock without touching monotonic time (clock-change test). */
    fun setNowMillis(millis: Long) {
        wallMillis = millis
    }

    // --- LifecycleSignals -------------------------------------------------

    private val signalChanges = MutableSharedFlow<LifecycleSignal>(extraBufferCapacity = 64)
    private val signalHistory = mutableListOf<LifecycleSignal>()
    private val latestSignals = LinkedHashMap<Class<*>, LifecycleSignal>()

    override val events: Flow<LifecycleSignal> = flow {
        val current = synchronized(lock) { latestSignals.values.toList() }
        emit(LifecycleSnapshot(current))
        emitAll(signalChanges)
    }

    /**
     * Records [signal], remembers it as the current value of its kind and
     * publishes it.
     *
     * [LifecycleSnapshot] is rejected: the fake generates the one snapshot each
     * collector must receive first, so a caller cannot inject a second one or
     * bypass the current-value set.
     */
    fun emit(signal: LifecycleSignal) {
        require(signal !is LifecycleSnapshot) {
            "LifecycleSnapshot is generated per subscription; emit the individual signals instead"
        }
        synchronized(lock) {
            signalHistory += signal
            latestSignals[signal.javaClass] = signal
        }
        signalChanges.tryEmit(signal)
    }

    /** Every signal passed to [emit], in emission order. */
    val emittedSignals: List<LifecycleSignal>
        get() = synchronized(lock) { signalHistory.toList() }

    // --- Durability -------------------------------------------------------

    private val fsyncHistory = mutableListOf<Path>()

    override fun level(): DurabilityLevel = durabilityLevel

    override suspend fun fsyncPath(path: Path) {
        synchronized(lock) { fsyncHistory.add(path) }
    }

    /** Paths passed to [fsyncPath], in call order. */
    val fsyncedPaths: List<Path>
        get() = synchronized(lock) { fsyncHistory.toList() }

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
        val absolute = target.toAbsolutePath()
        val parent = absolute.parent
            ?: throw IllegalArgumentException("target has no parent directory: $target")
        Files.createDirectories(parent)
        val temp = Files.createTempFile(parent, ".${absolute.fileName}.", ".tmp")
        var published = false
        try {
            write(temp)
            fsyncPath(temp)
            Files.move(
                temp,
                absolute,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            published = true
            fsyncPath(parent)
        } finally {
            if (!published) {
                Files.deleteIfExists(temp)
            }
        }
    }

    // --- SecureStore ------------------------------------------------------

    private val secrets = linkedMapOf<String, ByteArray>()
    private val unreadable = linkedMapOf<String, String>()

    override val level: SecurityLevel
        get() = securityLevel

    override suspend fun put(key: String, value: ByteArray) {
        synchronized(lock) { secrets[key] = value.copyOf() }
    }

    override suspend fun get(key: String): SecureLookup = synchronized(lock) {
        val reason = unreadable[key]
        if (reason != null) {
            SecureLookup.Unreadable(reason)
        } else {
            val value = secrets[key]
            if (value == null) {
                SecureLookup.Absent
            } else {
                SecureLookup.Found(value.copyOf())
            }
        }
    }

    override suspend fun delete(key: String) {
        synchronized(lock) {
            secrets.remove(key)
            unreadable.remove(key)
        }
    }

    /** Keys currently held by the in-memory store, including unreadable ones. */
    fun storedKeys(): Set<String> = synchronized(lock) { secrets.keys.toSet() }

    /**
     * Makes [key] report [SecureLookup.Unreadable] without deleting its bytes,
     * modelling a Keystore entry invalidated by a lock-screen change.
     *
     * The mark takes precedence over [put] until [markReadable] is called, so a
     * fail-closed test cannot accidentally observe a readable value.
     */
    fun markUnreadable(key: String, reason: String = "key-invalidated") {
        synchronized(lock) { unreadable[key] = reason }
    }

    /** Removes an unreadable mark; the stored bytes become readable again. */
    fun markReadable(key: String) {
        synchronized(lock) { unreadable.remove(key) }
    }

    // --- Notifier ---------------------------------------------------------

    private val notificationCalls = mutableListOf<NotificationCall>()
    private val cancelCalls = mutableListOf<Int>()

    override val availability: NotifierAvailability
        get() = notifierAvailability

    override fun notify(
        id: Int,
        title: String,
        body: String,
        ongoing: Boolean,
        action: NotificationAction?,
    ) {
        synchronized(lock) {
            notificationCalls.add(NotificationCall(id, title, body, ongoing, action))
        }
    }

    override fun cancel(id: Int) {
        synchronized(lock) { cancelCalls.add(id) }
    }

    /** Every `notify` call, in order. */
    val notifications: List<NotificationCall>
        get() = synchronized(lock) { notificationCalls.toList() }

    /** Every `cancel` id, in order. */
    val cancelledIds: List<Int>
        get() = synchronized(lock) { cancelCalls.toList() }

    /**
     * Presses the action of the most recent notification [id].
     *
     * Returns `false` when that notification has no action. This is how a test
     * exercises the graceful-stop button without an Android PendingIntent.
     */
    fun performAction(id: Int): Boolean {
        val action = synchronized(lock) {
            notificationCalls.lastOrNull { it.id == id }?.action
        } ?: return false
        action.onClick()
        return true
    }

    // --- Temporary directory ---------------------------------------------

    private var ownedTempDir: Path? = null

    /**
     * A directory for tests that need real files.
     *
     * Created on first access when [root] was not supplied; [close] deletes only
     * a directory this instance created.
     */
    val tempDir: Path
        @Synchronized get() = root
            ?: ownedTempDir
            ?: Files.createTempDirectory("phonedsh-platform-fake").also { ownedTempDir = it }

    override fun close() {
        val dir = ownedTempDir ?: return
        ownedTempDir = null
        if (!Files.exists(dir)) return
        val stream = Files.walk(dir)
        try {
            stream.sorted(Comparator.reverseOrder<Path>()).forEach { Files.deleteIfExists(it) }
        } finally {
            stream.close()
        }
    }
}
