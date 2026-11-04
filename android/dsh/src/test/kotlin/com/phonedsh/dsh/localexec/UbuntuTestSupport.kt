// phone-dsh — :dsh unit test: the `ubuntu.exec` mock harness.
// SPDX-License-Identifier: MIT
//
// ---- what is real and what is a stand-in ------------------------------------
// Real: the job machine, the record store (atomic replace over a real temp
// directory), the artifact ingest (chunk fetch, mutation emission, real file
// writes), the clock and the coroutines.
// Stand-ins, each named where it is defined: [FakeSeal] for design §3's chmod
// window (`BuildSeal` owns the real one in `:platform-android`, which `:dsh`
// does not depend on), and [MockUbuntuAdapter] for the environment.
//
// ---- why the clock is real time --------------------------------------------
// The mock adapter is specified as "delay N then return", and the job deadline
// and the 20 s drain are wall-clock durations by definition, so freezing time
// would test nothing. [TestClock] reads real elapsed time from a fixed base;
// the delays in the tests are therefore milliseconds, never simulated seconds.

package com.phonedsh.dsh.localexec

import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.MemoryTier
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.Comparator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout

/** Real elapsed time from a fixed wall-clock base. */
internal class TestClock(private val base: Long = 1_700_000_000_000L) : Clock {
    private val origin = System.nanoTime()

    override fun nowMillis(): Long = base + (System.nanoTime() - origin) / 1_000_000L

    override fun monotonicMillis(): Long = (System.nanoTime() - origin) / 1_000_000L
}

/** The `:platform` durability SPI over the real filesystem, with the atomic-replace order. */
internal object TestDurability : Durability {
    override suspend fun fsyncPath(path: Path) = Unit

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
        Files.createDirectories(target.parent)
        val temporary = target.resolveSibling("${target.fileName}.tmp")
        write(temporary)
        Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING)
    }

    override fun level(): DurabilityLevel = DurabilityLevel.LEVEL_1_PROCESS_KILL
}

/**
 * A temp directory removed on close.
 *
 * `close()` retries: a test's `finally` cancels the lane's scope, but a job that
 * is already inside the store can still create a file **after** `walk` has
 * enumerated the directory and before the parent is unlinked. One pass then
 * throws `DirectoryNotEmptyException` and fails the test on teardown rather than
 * on anything it asserts — measured as a ~1-in-6 flake, and it is a teardown
 * artifact, not a defect in the lane.
 */
internal class TempDir : AutoCloseable {
    val path: Path = Files.createTempDirectory("pdsh-ubuntu-job")

    override fun close() {
        repeat(10) {
            if (!Files.exists(path)) return
            try {
                Files.walk(path).use { stream ->
                    stream.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                }
                return
            } catch (_: java.nio.file.DirectoryNotEmptyException) {
                // A writer landed between the walk and the unlink; look again.
                Thread.sleep(20)
            } catch (_: java.nio.file.NoSuchFileException) {
                return
            } catch (race: java.io.UncheckedIOException) {
                // `Files.walk` is lazy: a record file the lane renamed over (or
                // deleted) between two iterations surfaces as an unchecked
                // `NoSuchFileException` from the iterator, not from the delete.
                // Same teardown race as above; look again.
                if (race.cause is java.nio.file.NoSuchFileException) {
                    Thread.sleep(20)
                } else {
                    throw race
                }
            }
        }
    }
}

/**
 * The seal seam, with the four things a test has to be able to force.
 *
 * `sealed` models the on-disk `chmod 000`: a *new* FakeSeal starts empty, which
 * is what a boot finds after [repair] has done its job.
 */
internal class FakeSeal(
    private val sealFails: Boolean = false,
    private val restoreFails: Boolean = false,
    private val observedValue: Boolean = false,
) : UbuntuSeal {
    var sealCalls: Int = 0
        private set
    var restoreCalls: Int = 0
        private set
    var repairCalls: Int = 0
        private set

    val sealed: MutableSet<String> = mutableSetOf()

    override suspend fun seal(jobId: String): UbuntuSealResult {
        sealCalls += 1
        if (sealFails) return UbuntuSealResult.Failed("chmod_failed")
        sealed += jobId
        return UbuntuSealResult.Sealed
    }

    override suspend fun restore(jobId: String): UbuntuSealResult {
        restoreCalls += 1
        if (restoreFails) return UbuntuSealResult.Failed("restore_failed")
        sealed -= jobId
        return UbuntuSealResult.Sealed
    }

    override fun observed(jobId: String): Boolean = observedValue

    override suspend fun repair(): Boolean {
        repairCalls += 1
        sealed.clear()
        return true
    }
}

/**
 * The page's VFS sink over a real directory.
 *
 * It behaves like `channel.md` §3.1: a complete write replaces the file, an
 * appended suffix appends at `append_from`. It refuses to write a chunk whose
 * length is not the mutation's length, so a page that fills a mutation wrongly
 * fails a test instead of quietly writing the right bytes.
 */
internal class RecordingSink(private val root: Path) : UbuntuMutationSink {
    val writes: MutableList<Pair<String, UbuntuMutation>> = mutableListOf()
    val lengths: MutableList<Long> = mutableListOf()

    override suspend fun write(path: String, mutation: UbuntuMutation, data: ByteArray) {
        require(data.size.toLong() == mutation.length) {
            "the sink got ${data.size} bytes for a ${mutation.length}-byte mutation"
        }
        writes += path to mutation
        lengths += data.size.toLong()
        val file = file(path)
        if (mutation.complete) {
            Files.createDirectories(file.parent)
            Files.write(
                file,
                data,
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE,
            )
        } else {
            Files.write(file, data, StandardOpenOption.CREATE, StandardOpenOption.APPEND)
        }
    }

    fun file(path: String): Path = root.resolve(path.removePrefix("/dsh/"))
}

/** The 8 GiB row, budgets.md §4's default. */
internal val BUDGETS: ControllerBudgets = ControllerBudgets.forTier(MemoryTier.GIB_8)

/** The 3 GiB row: its `single_file_limit` is the 16 MiB floor. */
internal val BUDGETS_3_GIB: ControllerBudgets = ControllerBudgets.forTier(MemoryTier.AT_MOST_3)

/** The default file limit: 15 MiB, one complete mutation. */
internal const val FIFTEEN_MIB: Long = 15L * 1_048_576L

/** The smallest legal raise of the ingest bound: 16 MiB. */
internal const val SIXTEEN_MIB: Long = 16L * 1_048_576L

/** The default tier's workspace bucket: 288 MB. */
internal val WORKSPACE_BUCKET: Long = BUDGETS.workspaceBytes

/**
 * A prompt that answers with [answer] and records every request it was shown.
 *
 * It is the test's stand-in for the app's dialog, so a gate test can assert both
 * the decision and whether the user was asked at all.
 */
internal class RecordingApprovalPrompt(
    private var answer: UbuntuApprovalDecision = UbuntuApprovalDecision.Approved,
) : UbuntuApprovalPrompt {
    val requests: MutableList<UbuntuApprovalRequest> = mutableListOf()

    /** Answers every later request with [next]. */
    fun answers(next: UbuntuApprovalDecision) {
        answer = next
    }

    override suspend fun ask(request: UbuntuApprovalRequest): UbuntuApprovalDecision {
        requests += request
        return answer
    }
}

/** A gate over [prompt]; the pair lets a test assert the dialog count. */
internal fun approvalGate(
    answer: UbuntuApprovalDecision = UbuntuApprovalDecision.Approved,
    clock: Clock = TestClock(),
    timeoutMillis: Long = 5_000L,
): Pair<UbuntuApprovalGate, RecordingApprovalPrompt> {
    val prompt = RecordingApprovalPrompt(answer)
    return UbuntuApprovalGate(prompt = { prompt }, clock = clock, timeoutMillis = timeoutMillis) to prompt
}

/** A gate whose dialog always approves; the ordinary host-tool fixture. */
internal fun approvingGate(clock: Clock = TestClock()): UbuntuApprovalGate = approvalGate(clock = clock).first

/** A gate with no prompt at all: the fail-closed host a headless caller gets. */
internal fun headlessGate(clock: Clock = TestClock()): UbuntuApprovalGate =
    UbuntuApprovalGate(prompt = { null }, clock = clock)

/** Builds a lane over one temp directory, the mock adapter and the fakes above. */
internal fun newLane(
    scope: CoroutineScope,
    clock: Clock,
    temp: TempDir,
    adapters: List<UbuntuAdapter> = emptyList(),
    seal: UbuntuSeal = FakeSeal(),
    sink: UbuntuMutationSink = RecordingSink(temp.path),
    budgets: ControllerBudgets = BUDGETS,
    workspaceUsedBytes: () -> Long = { 0L },
    admissionOpen: () -> Boolean = { true },
    availableMemoryBytes: () -> Long? = { null },
    snapshotBytes: (workspace: String) -> Long = { 0L },
    memoryPressureEvidence: () -> Boolean = { false },
    pollIntervalMs: Long = 5L,
    stopGraceMillis: Long = 400L,
    logger: HostLog = HostLog.None,
): UbuntuJobLane = UbuntuJobLane(
    scope = scope,
    clock = clock,
    store = UbuntuJobStore(temp.path.resolve("jobs"), TestDurability, logger),
    adapters = adapters.associateBy { it.env },
    seal = seal,
    budgets = budgets,
    vfsRoot = temp.path,
    sink = sink,
    workspaceUsedBytes = workspaceUsedBytes,
    admissionOpen = admissionOpen,
    availableMemoryBytes = availableMemoryBytes,
    snapshotBytes = snapshotBytes,
    memoryPressureEvidence = memoryPressureEvidence,
    pollIntervalMs = pollIntervalMs,
    stopGraceMillis = stopGraceMillis,
    logger = logger,
)

/** Polls [UbuntuJobLane.status] until the job is terminal, bounded. */
internal suspend fun awaitTerminal(
    lane: UbuntuJobLane,
    jobId: String,
    timeoutMs: Long = 20_000L,
): UbuntuJobRecord = withTimeout(timeoutMs) {
    var record = lane.status(jobId)
    while (record == null || !record.terminal) {
        delay(2)
        record = lane.status(jobId)
    }
    record
}

/** Polls [UbuntuJobLane.status] until [predicate] holds, bounded. */
internal suspend fun awaitState(
    lane: UbuntuJobLane,
    jobId: String,
    timeoutMs: Long = 20_000L,
    predicate: (UbuntuJobRecord) -> Boolean,
): UbuntuJobRecord = withTimeout(timeoutMs) {
    var record = lane.status(jobId)
    while (record == null || !predicate(record)) {
        delay(2)
        record = lane.status(jobId)
    }
    record
}

/** A record with the fields a boot test needs, written straight to the store. */
internal fun seededRecord(
    jobId: String,
    state: UbuntuJobState,
    sealState: UbuntuSealState,
    nowMillis: Long = 1_700_000_000_000L,
): UbuntuJobRecord = UbuntuJobRecord(
    jobId = jobId,
    env = MockUbuntuAdapter.DEFAULT_ENV,
    state = state,
    seq = 3,
    createdAtMs = nowMillis,
    updatedAtMs = nowMillis,
    egress = if (state == UbuntuJobState.ADMITTED || state == UbuntuJobState.SEALING) false else true,
    authorityExited = if (state == UbuntuJobState.ADMITTED || state == UbuntuJobState.SEALING) {
        null
    } else {
        UbuntuJobRecord.AUTHORITY_WORKER_VFS
    },
    argvDigest = UbuntuJobLane.digest(listOf("true")),
    argvLength = 1,
    cwd = "/dsh/workspace",
    workspace = "/dsh/workspace",
    limits = UbuntuJobLimits.of(BUDGETS),
    label = null,
    exitCode = null,
    logTail = "",
    artifacts = emptyList(),
    failure = null,
    internalAccessObserved = null,
    seal = sealState,
    sealReason = null,
    jobTimeoutMs = UbuntuExecRequest.DEFAULT_JOB_TIMEOUT_MS,
)
