// :testkit harness — the third runner's execution over the real host VFS path.
// SPDX-License-Identifier: MIT
//
// ---- what is real here ------------------------------------------------------
//   * a real `com.phonedsh.log.WorkspaceLog` on a temporary directory: recovery,
//     append, materialization and the D18 epoch close are the `:core` ones;
//   * a real `VfsSink` behind the real `HostChannel`: seeding sends actual
//     `VFS_MUT` frames over the channel's HELLO-negotiated connection, the sink
//     decodes them with the Rust codec, appends to the WAL and answers with a
//     level-1 `VFS_ACK` for every mutation;
//   * the same `DefaultPhoneDshHost` facade the app holds, so the HELLO this
//     runner sees is the one the worker would see (`channel/1`, `wal/1`,
//     `exec/1`, `accelerator:phone`).
//
// The seed tree is **never written to disk directly**. `setupWorkspace` sends
// one `VFS_MUT` per seeded file and then checks the level-1 ACK, the epoch
// close's level-2 ACK and the resulting materialized tree byte for byte; a
// mismatch is an execution error, not a product verdict.
//
// ---- what is a test double here, and why -----------------------------------
// The engine is `:platform`'s `FakePlatform`/`FakeEngineHost`: there is no
// WebView in a JVM test, and the facade only needs `EngineHost` to reach
// `Running` so D14 opens admission. Clock, durability, notifier and lifecycle
// signals are the same shared JVM doubles, so nothing here can claim a device
// fact. The WAL, VFS sink, channel and codec are the real ones.
//
// ---- what is honestly absent ------------------------------------------------
// * **No model.** Turns come from a [ScenarioTurnDriver]; [ScriptedTurnDriver]
//   replays pre-set outcomes and [NoModelTurnDriver] reports them undelivered.
//   Neither writes the workspace. A real model needs a `:net` `GatewaySession`
//   plus a live upstream and the engine turn loop; that is a later step.
// * **No Worker console.** `consoleErrors` is the host facade's own error-level
//   log (channel/sink/facade failures). With no WebView there is no Worker
//   console stream, so `no_console_error` here means "the host logged no error",
//   which is weaker than the macOS runner's assertion. An empty list is a real
//   empty host log, not a fabricated clean console.
// * **No restart driver.** `perturbationCoverage()` is always `null`; the runner
//   turns that into a fail-loud `restart_recovered`, never a vacuous pass.

package com.phonedsh.testkit.harness

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.host.DefaultPhoneDshHost
import com.phonedsh.dsh.host.HostCapabilities
import com.phonedsh.dsh.host.HostHello
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.asHostWal
import com.phonedsh.log.BootId as LogBootId
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.testkit.scenario.CommandOutcome
import com.phonedsh.testkit.scenario.PerturbationCoverage
import com.phonedsh.testkit.scenario.ScenarioExecution
import com.phonedsh.testkit.scenario.TurnOutcome
import com.phonedsh.wire.WireCodec
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/** One `VFS_ACK` the host sent while the workspace was being seeded. */
public data class VfsAck(
    /** `1` for a WAL append, `2` for the epoch close (channel.md §3.2). */
    public val level: Int,
    /** The highest contiguous mseq the ACK covers. */
    public val uptoMseq: Long,
)

/** One `workspace_command` attempt, for diagnostics outside the report. */
public data class CommandRun(
    public val command: String,
    public val outcome: CommandOutcome,
)

/**
 * The third runner's [ScenarioExecution] over the real host VFS/WAL path.
 *
 * Construct it, run a decoded scenario through
 * [com.phonedsh.testkit.scenario.ScenarioRunner], then [close] it. Each
 * [setupWorkspace] call starts a fresh workspace: the previous host is stopped,
 * its directory removed and a new log recovered, so a scenario never sees a
 * stray file from the previous one.
 *
 * @param turns how a turn is "delivered"; [NoModelTurnDriver] by default.
 * @param commands how a `workspace_command` is attempted;
 *   [ToyboxWorkspaceCommandRunner] by default.
 * @param platform the host double every real host component is wired to, and
 *   the owner of this execution's scratch directory ([FakePlatform.tempDir]).
 *   A JVM test keeps the default, whose scratch directory is the process temp
 *   directory. An instrumented caller supplies its own root under the app's
 *   cache directory and deletes it itself, so a device run does not depend on
 *   the process temp directory, which is an OS/process detail rather than a
 *   sandbox guarantee; [close] only closes the platform (which deletes a
 *   directory it created itself).
 */
public class HostScenarioExecution(
    private val turns: ScenarioTurnDriver = NoModelTurnDriver,
    private val commands: WorkspaceCommandRunner = ToyboxWorkspaceCommandRunner(),
    private val platform: FakePlatform = FakePlatform(),
) : ScenarioExecution, AutoCloseable {
    private val logRoot: Path = platform.tempDir.resolve("workspace-log")
    private val paths = WalPaths(logRoot)
    private val hostLog = RecordingHostLog()

    private var scope: CoroutineScope? = null
    private var host: DefaultPhoneDshHost? = null
    private var connection: RecordingConnection? = null
    private var caps: List<String> = emptyList()

    private val promptLog = mutableListOf<String>()
    private val outcomeLog = mutableListOf<TurnOutcome>()
    private val commandLog = mutableListOf<CommandRun>()

    /** Every prompt handed to [runTurn], in order. */
    public val prompts: List<String> get() = promptLog.toList()

    /** Every outcome [runTurn] returned, in order. */
    public val turnOutcomes: List<TurnOutcome> get() = outcomeLog.toList()

    /** Every command attempt and its outcome, in order. */
    public val commandRuns: List<CommandRun> get() = commandLog.toList()

    /** The capabilities of the HELLO the host actually sent this boot. */
    public val helloCaps: List<String> get() = caps

    /** The host facade's error-level log lines; the source of [consoleErrors]. */
    public val hostErrors: List<String> get() = hostLog.errors()

    /** The host facade's warning-level log lines, for diagnostics only. */
    public val hostWarnings: List<String> get() = hostLog.warnings()

    /** Every `VFS_ACK` the host sent this boot, in order. */
    public val acknowledgements: List<VfsAck>
        get() {
            val current = connection ?: return emptyList()
            return acknowledgementsOf(current)
        }

    /** `materialized/workspace`, the derived copy the runner reads (read-only use). */
    public val workspaceDirectory: Path get() = paths.materializedWorkspace

    // ------------------------------------------------------------------ setup

    /**
     * Materializes a clean workspace from [files] through the real VFS path.
     *
     * One `VFS_MUT` per file, sent on the HELLO-negotiated connection, and then
     * an epoch close. Every level-1 ACK must name the mseq that was sent, the
     * close must produce a level-2 ACK, and the materialized tree must match
     * [files] byte for byte; any mismatch throws instead of letting the runner
     * judge a workspace the WAL never produced.
     *
     * @param files workspace-relative path -> bytes (the runner's seed).
     * @throws IllegalStateException when the host, the sink, the WAL or the
     *   materialized tree does not agree with the requested seed.
     */
    override fun setupWorkspace(files: Map<String, ByteArray>) {
        teardown()
        resetLogRoot()
        val log = WorkspaceLog(
            paths = paths,
            durability = platform,
            clock = platform,
            bootId = LogBootId.random(),
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        this.scope = scope
        val host = DefaultPhoneDshHost(
            engine = platform.engine,
            controller = ControllerStateMachine.boot(persistedState = null),
            clock = platform,
            signals = platform,
            notifier = platform,
            wal = log.asHostWal(),
            logger = hostLog,
            scope = scope,
        )
        this.host = host
        host.start()
        try {
            runBlocking { withTimeout(BOOT_TIMEOUT_MILLIS) { host.ready.first { it } } }
        } catch (timeout: Exception) {
            throw IllegalStateException("the host facade did not become ready: ${timeout.message}", timeout)
        }
        platform.engine.setState(EngineHostState.Running(LOOPBACK_ORIGIN, LOOPBACK_PORT))
        val admission = host.controller.admission
        if (admission != Admission.OPEN) {
            throw IllegalStateException(
                "the D14 admission gate is $admission, not OPEN; VFS_MUT would be deferred " +
                    "and the workspace would stay empty",
            )
        }

        val connection = RecordingConnection(CONNECTION_ID)
        this.connection = connection
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, workerHelloFrame())
        }
        val hello = connection.sent().firstOrNull { it.frameType() == HELLO_TYPE }?.fields()
            ?: throw IllegalStateException(
                "the host answered no HELLO frame; frames=${describeFrames(connection)}; " +
                    "host errors=${hostLog.errors()}",
            )
        caps = hello.stringList("caps")
        val required = listOf(HostCapabilities.CHANNEL, HostCapabilities.WAL, HostCapabilities.EXEC)
        val missing = required.filter { it !in caps }
        if (missing.isNotEmpty()) {
            throw IllegalStateException(
                "the host HELLO advertises $caps; it is missing $missing, so the VFS/WAL path " +
                    "that setupWorkspace relies on is not wired",
            )
        }

        var mseq = hello.long("next_mseq")
            ?: throw IllegalStateException("the host HELLO carries no next_mseq: ${hello.toJsonString()}")
        val seed = LinkedHashMap(files)
        for ((path, bytes) in seed) {
            val vfsPath = vfsPathFor(path)
            runBlocking { host.channel.onBinary(connection, mutFrame(mseq, vfsPath, bytes)) }
            acknowledgementsOf(connection).lastOrNull { it.level == 1 && it.uptoMseq == mseq }
                ?: throw IllegalStateException(
                    "no level-1 VFS_ACK for mseq $mseq ($vfsPath); " +
                        "frames=${describeFrames(connection)}; host errors=${hostLog.errors()}",
                )
            mseq += 1
        }
        val durable = runBlocking { host.closeEpoch() }
            ?: throw IllegalStateException(
                "the epoch close returned no durable watermark after ${seed.size} mutation(s)",
            )
        val levelTwo = acknowledgementsOf(connection).lastOrNull { it.level == 2 }
        if (levelTwo == null || levelTwo.uptoMseq != durable) {
            throw IllegalStateException(
                "the epoch close produced no level-2 VFS_ACK for durable_upto=$durable; " +
                    "acks=${acknowledgementsOf(connection)}",
            )
        }
        verifyMaterialized(seed)
    }

    /** Checks the derived copy against the seed; a difference is an execution defect. */
    private fun verifyMaterialized(seed: Map<String, ByteArray>) {
        val present = workspaceFiles()
        val missing = seed.keys.filter { it !in present }
        if (missing.isNotEmpty()) {
            throw IllegalStateException(
                "the WAL materialized tree is missing ${missing.size} of ${seed.size} seeded " +
                    "file(s), for example ${missing.take(3)}",
            )
        }
        for ((path, expected) in seed) {
            val actual = readFile(path)
                ?: throw IllegalStateException("the seeded file '$path' is not readable in the materialized tree")
            if (!actual.contentEquals(expected)) {
                throw IllegalStateException(
                    "the materialized copy of '$path' differs from the seeded bytes " +
                        "(${actual.size} vs ${expected.size} bytes)",
                )
            }
        }
    }

    // ------------------------------------------------------------------ turns

    override fun runTurn(prompt: String): TurnOutcome {
        val index = promptLog.size
        promptLog += prompt
        val outcome = turns.drive(prompt, index)
        outcomeLog += outcome
        return outcome
    }

    // ------------------------------------------------------------- workspace

    override fun workspaceFiles(): Set<String> {
        val root = paths.materializedWorkspace
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) return emptySet()
        val files = LinkedHashSet<String>()
        Files.walk(root).use { stream ->
            for (entry in stream) {
                if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue
                files += root.relativize(entry).toString().replace('\\', '/')
            }
        }
        return files
    }

    override fun readFile(path: String): ByteArray? {
        val normalized = path.replace('\\', '/')
        if (normalized.isEmpty()) return null
        val components = normalized.trimStart('/').split('/')
        if (components.any { it.isEmpty() || it == "." || it == ".." }) return null
        val root = paths.materializedWorkspace.toAbsolutePath().normalize()
        val target = root.resolve(normalized.trimStart('/')).normalize()
        if (!target.startsWith(root)) return null
        if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS)) return null
        return Files.readAllBytes(target)
    }

    override fun consoleErrors(): List<String> = hostLog.errors()

    override fun runWorkspaceCommand(command: String): CommandOutcome {
        val outcome = if (host == null) {
            CommandOutcome.pendingHost(
                "pending_host: setupWorkspace has not run, so there is no materialized workspace",
            )
        } else {
            commands.run(
                command,
                WorkspaceTrees(paths.materializedWorkspace, paths.materializedHome),
            )
        }
        commandLog += CommandRun(command, outcome)
        return outcome
    }

    /**
     * Always `null`: this execution owns no restart/perturbation driver.
     *
     * The runner reports `restart_recovered` as a failure ("perturbation
     * coverage was not finalized") instead of letting it pass vacuously. A real
     * driver needs process restart / park-resume control, which a JVM test does
     * not have.
     */
    override fun perturbationCoverage(): PerturbationCoverage? = null

    // -------------------------------------------------------------- lifecycle

    /**
     * Stops the host facade, cancels its scope and closes the platform.
     *
     * A scratch directory the caller supplied to the platform is not deleted
     * here; only a directory the platform created for itself is removed.
     */
    override fun close() {
        teardown()
        platform.close()
    }

    private fun teardown() {
        val connection = this.connection
        val host = this.host
        if (connection != null && host != null) {
            try {
                runBlocking { host.channel.onClosed(connection, ChannelCloseCause.SERVER_STOPPED) }
            } catch (_: Exception) {
                // Closing a channel is best-effort; the facade stop below is the real one.
            }
        }
        host?.stop()
        scope?.cancel()
        this.connection = null
        this.host = null
        this.scope = null
        caps = emptyList()
        promptLog.clear()
        outcomeLog.clear()
        commandLog.clear()
        hostLog.clear()
    }

    private fun resetLogRoot() {
        try {
            if (Files.exists(logRoot, LinkOption.NOFOLLOW_LINKS)) {
                Files.walk(logRoot).use { stream ->
                    stream.sorted(Comparator.reverseOrder<Path>()).forEach { Files.deleteIfExists(it) }
                }
            }
            Files.createDirectories(logRoot)
        } catch (failure: IOException) {
            throw IllegalStateException("cannot reset the workspace log directory", failure)
        }
    }

    // ------------------------------------------------------------------ frames

    private fun workerHelloFrame(): ByteArray = WireCodec.encode(
        """
        {"type":"HELLO","fields":{
          "boot_id":"ffeeddccbbaa99887766554433221100",
          "caps":["channel/1","vfs-sink/1","journal/1","api/1"],
          "fence":{"generation":0,"owner":"phone","wal_seq":0},
          "last_mseq":0,
          "proto":1,
          "role":"worker",
          "session_epoch":0
        }}
        """.trimIndent(),
        HostHello.HELLO_SEQ,
    )

    /**
     * One complete `VFS_MUT` frame, built from the golden-vector `fields` shape
     * and encoded by the Rust codec (the runner never writes the frame bytes
     * itself; `channel.md` §3.1's layout exists only in the codec).
     */
    private fun mutFrame(mseq: Long, path: String, data: ByteArray): ByteArray {
        val fields = JsonObject(
            linkedMapOf(
                "append_from" to JsonNumber("0"),
                "data_hex" to JsonString(hex(data)),
                "data_len" to JsonNumber(data.size.toString()),
                "mflags" to JsonNumber(MFLAG_ENTRY_CHANGED.toString()),
                "mode" to JsonNumber(FILE_MODE.toString()),
                "mseq" to JsonNumber(mseq.toString()),
                "op" to JsonNumber(VFS_WRITE_OP.toString()),
                "path" to JsonString(path),
            ),
        )
        return WireCodec.encode(
            "{\"type\":\"VFS_MUT\",\"fields\":${fields.toJsonString()}}",
            // seq 1 is the worker HELLO; each mutation takes the next one.
            seq = mseq + 1,
        )
    }

    private fun acknowledgementsOf(connection: RecordingConnection): List<VfsAck> =
        connection.sent().mapNotNull { frame ->
            if (frame.frameType() != VFS_ACK_TYPE) return@mapNotNull null
            val fields = frame.fields() ?: return@mapNotNull null
            val level = fields.long("level")?.toInt() ?: return@mapNotNull null
            val upto = fields.long("upto_mseq") ?: return@mapNotNull null
            VfsAck(level, upto)
        }

    private fun describeFrames(connection: RecordingConnection): String =
        connection.sent().map { frame ->
            when (val type = frame.frameType()) {
                HELLO_TYPE -> "HELLO"
                VFS_ACK_TYPE -> "VFS_ACK"
                ERROR_TYPE -> {
                    val fields = frame.fields()
                    "ERROR(${fields?.get("code")?.let { (it as? JsonString)?.value } ?: "?"})"
                }

                else -> "0x" + type.toString(16)
            }
        }.joinToString(prefix = "[", postfix = "]", separator = ", ")

    private fun ByteArray.frameType(): Int {
        if (size < HEADER_BYTES) return -1
        val magic = ((this[0].toInt() and 0xFF) shl 8) or (this[1].toInt() and 0xFF)
        if (magic != MAGIC) return -1
        return this[2].toInt() and 0xFF
    }

    private fun ByteArray.fields(): JsonObject? = try {
        JsonValue.parse(WireCodec.decode(this)) as? JsonObject
    } catch (_: Exception) {
        null
    }

    private fun JsonObject.long(name: String): Long? = (this[name] as? JsonNumber)?.asLongOrNull()

    private fun JsonObject.stringList(name: String): List<String> =
        (this[name] as? JsonArray)?.values?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()

    private fun vfsPathFor(relative: String): String {
        val normalized = relative.replace('\\', '/').trimStart('/')
        if (normalized.isEmpty()) {
            throw IllegalArgumentException("a seed path is empty")
        }
        val components = normalized.split('/')
        if (components.any { it.isEmpty() || it == "." || it == ".." }) {
            throw IllegalArgumentException("seed path '$relative' is not a safe workspace-relative path")
        }
        return "$VFS_WORKSPACE_PREFIX$normalized"
    }

    private fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            append(HEX[value ushr 4]).append(HEX[value and 0x0F])
        }
    }

    /**
     * The one channel connection this execution owns. The host's VFS frames are
     * delivered to it; [acknowledgements] reads them back.
     */
    private class RecordingConnection(override val id: String) : LoopbackConnection {
        private val lock = Any()
        private val frames = mutableListOf<ByteArray>()
        private val closes = mutableListOf<Pair<Short, String>>()

        override suspend fun sendBinary(payload: ByteArray) {
            synchronized(lock) { frames += payload.copyOf() }
        }

        override suspend fun close(code: Short, reason: String) {
            synchronized(lock) { closes += code to reason }
        }

        fun sent(): List<ByteArray> = synchronized(lock) { frames.toList() }

        fun closes(): List<Pair<Short, String>> = synchronized(lock) { closes.toList() }
    }

    /** The host facade's log seam, recorded instead of printed. */
    private class RecordingHostLog : HostLog {
        private val lock = Any()
        private val errors = mutableListOf<String>()
        private val warnings = mutableListOf<String>()

        override fun debug(message: String) = Unit

        override fun info(message: String) = Unit

        override fun warn(message: String) {
            synchronized(lock) { warnings += message }
        }

        override fun error(message: String) {
            synchronized(lock) { errors += message }
        }

        fun errors(): List<String> = synchronized(lock) { errors.toList() }

        fun warnings(): List<String> = synchronized(lock) { warnings.toList() }

        fun clear() {
            synchronized(lock) {
                errors.clear()
                warnings.clear()
            }
        }
    }

    private companion object {
        /** The `:dsh` host test's loopback origin; nothing listens, the engine is a double. */
        const val LOOPBACK_ORIGIN = "http://127.0.0.1:41234"
        const val LOOPBACK_PORT = 41234
        const val CONNECTION_ID = "scenario-worker"
        const val BOOT_TIMEOUT_MILLIS = 10_000L

        /** channel.md §1: 16-byte header, `magic u16 = 0x5A4C`, `type` at offset 2. */
        const val HEADER_BYTES = 16
        const val MAGIC = 0x5A4C
        const val HELLO_TYPE = 0x01
        const val VFS_ACK_TYPE = 0x11
        const val ERROR_TYPE = 0x7F

        /** `channel.md` §3.1: op 1 is a complete write; `mflags` bit 0 is entry-changed. */
        const val VFS_WRITE_OP = 1
        const val MFLAG_ENTRY_CHANGED = 1

        /** `0o644`, the mode every seeded text file gets. */
        const val FILE_MODE = 420
        const val VFS_WORKSPACE_PREFIX = "/dsh/workspace/"
        const val HEX = "0123456789abcdef"
    }
}
