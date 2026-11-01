// phone-dsh — :dsh unit test support: exec fixtures and the golden locator.
// SPDX-License-Identifier: MIT
//
// Unit tests only. The fixtures keep the six required assertions short without
// hiding the wire shapes: requests are built as JSON and parsed by the real
// decoder, results are built as the real tool-result JSON, and the goldens are
// read from spec/ in place (the repository is the oracle, not a copy).

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.tools.InMemoryRequestLedger
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.RegisteredTool
import com.phonedsh.dsh.tools.RequestLedger
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.Clock
import java.io.File
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONArray
import org.json.JSONObject

/** Shared exec values; the 64-hex keys are deliberately obvious, not derived. */
internal object ExecFixtures {
    /** A D6 exec_id in the conventional `<XL_IDEMPOTENCY_KEY>-<n>` shape. */
    const val EXEC_ID: String = "xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0-0"

    /** The same call re-issued with another spawn id; replay must keep [EXEC_ID]. */
    const val OTHER_EXEC_ID: String = "xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0-1"

    /** D10 key A. */
    val IDEM_A: String = "a".repeat(64)

    /** D10 key B. */
    val IDEM_B: String = "b".repeat(64)

    /** A minimal valid EXEC_REQ as JSON, ready to be mutated by a validation test. */
    fun baseRequest(
        execId: String = EXEC_ID,
        argv: List<String> = listOf("rg", "--json", "needle"),
        cwd: String = "/dsh/workspace",
        idemKey: String = IDEM_A,
        requiresMseq: Long = 0L,
    ): JSONObject = JSONObject().apply {
        put("exec_id", execId)
        put("argv", JSONArray(argv))
        put("cwd", cwd)
        put("requires_mseq", requiresMseq)
        put("idem_key", idemKey)
    }

    /** A valid [ExecRequest], parsed through the production decoder. */
    fun request(
        execId: String = EXEC_ID,
        argv: List<String> = listOf("rg", "--json", "needle"),
        cwd: String = "/dsh/workspace",
        idemKey: String = IDEM_A,
        requiresMseq: Long = 0L,
        graceMs: Long? = null,
        deadline: Long? = null,
        stdin: JSONObject? = null,
    ): ExecRequest {
        val json = baseRequest(execId, argv, cwd, idemKey, requiresMseq)
        graceMs?.let { json.put("grace_ms", it) }
        deadline?.let { json.put("deadline", it) }
        stdin?.let { json.put("stdin", it) }
        return ExecRequest.parse(json.toString())
    }

    /** The `stdin` object of a `pipe` request (unsupported by in-process tools). */
    fun pipeStdin(): JSONObject = JSONObject().put("mode", "pipe")

    /** The exec-tool result contract: status/code/signal/quiescent + base64 streams. */
    fun resultJson(
        stdout: ByteArray = "hello\n".encodeToByteArray(),
        stderr: ByteArray = ByteArray(0),
        code: Int? = 0,
        status: ExecEvent.ExitStatus = ExecEvent.ExitStatus.EXITED,
        quiescent: Boolean = true,
    ): String {
        val json = JSONObject()
        json.put("status", status.wireName)
        json.put("code", code ?: JSONObject.NULL)
        json.put("signal", JSONObject.NULL)
        json.put("quiescent", quiescent)
        json.put("stdout", Base64.getEncoder().encodeToString(stdout))
        json.put("stderr", Base64.getEncoder().encodeToString(stderr))
        return json.toString()
    }

    /** A bridge whose only accelerator is `name`, wired to test seams. */
    fun bridge(
        tool: PhoneTool,
        name: String = "rg",
        admission: AdmissionGate = AdmissionGate.Open,
        workspace: ExecWorkspace = ExecWorkspace.None,
        clock: Clock = TestClock(),
        pollMs: Long = 1L,
        waitLimitMs: Long = 60L,
        ledger: RequestLedger = InMemoryRequestLedger(),
    ): ExecBridge = ExecBridge(
        capability = ExecCapability.of(RegisteredTool(name, tool)),
        admission = admission,
        workspace = workspace,
        clock = clock,
        logger = HostLog.None,
        readinessPollMs = pollMs,
        readinessWaitLimitMs = waitLimitMs,
        ledger = ledger,
    )
}

/** One fake tool: counts invocations and answers a fixed result object. */
internal class CountingTool(private val result: String = ExecFixtures.resultJson()) : PhoneTool {
    val calls = AtomicInteger()

    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        calls.incrementAndGet()
        return ToolOutcome.Success(result)
    }
}

/**
 * One fake tool that stays in flight until the test opens [gate].
 *
 * [started] completes when the tool body is entered, which is the point where
 * the first request owns a live execution and a second request can join it;
 * [finished] completes after [gate] opens, so a cancellation test can prove the
 * tool's late result produces no further events.
 */
internal class GatedTool(
    val started: CompletableDeferred<Unit> = CompletableDeferred(),
    private val gate: CompletableDeferred<Unit> = CompletableDeferred(),
    private val result: String = ExecFixtures.resultJson(),
) : PhoneTool {
    val calls = AtomicInteger()
    val finished: CompletableDeferred<Unit> = CompletableDeferred()

    /** Lets the tool return; the test controls exactly when. */
    fun release() {
        gate.complete(Unit)
    }

    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        calls.incrementAndGet()
        started.complete(Unit)
        gate.await()
        finished.complete(Unit)
        return ToolOutcome.Success(result)
    }
}

/**
 * Wall time is settable; the monotonic reading advances by [tickMs] on every
 * read.
 *
 * The bridge uses monotonic time for its bounded `requires_mseq` wait. A fake
 * that returned a constant would make that bound unreachable and hang the test;
 * advancing per read makes the bound deterministic without sleeping for the
 * production budget.
 */
internal class TestClock(
    var wall: Long = 1_800_000_000_000L,
    private val tickMs: Long = 1L,
) : Clock {
    private var monotonic = 0L

    override fun nowMillis(): Long = wall

    override fun monotonicMillis(): Long {
        val reading = monotonic
        monotonic += tickMs
        return reading
    }
}

/** Reads the normative goldens from the repository. */
internal object ExecSpec {
    /** One `spec/v1/golden/frames` document. */
    fun golden(name: String): JSONObject = JSONObject(repoFile("spec/v1/golden/frames/$name").readText())

    fun hexBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "hex length must be even" }
        return ByteArray(hex.length / 2) { index ->
            hex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    private fun repoFile(relative: String): File {
        val starts = buildList {
            System.getProperty("pdsh.repo.root")?.let { add(File(it)) }
            System.getProperty("user.dir")?.let { add(File(it)) }
            runCatching {
                ExecSpec::class.java.protectionDomain?.codeSource?.location?.toURI()?.let { add(File(it)) }
            }
        }
        for (start in starts) {
            var current: File? = start.absoluteFile
            repeat(8) {
                val directory = current ?: return@repeat
                val candidate = File(directory, relative)
                if (candidate.isFile) return candidate
                current = directory.parentFile
            }
        }
        error("cannot locate $relative from ${starts.joinToString { it.absolutePath }}")
    }
}

/** Lowercase hex of [this]; the golden files store bytes that way. */
internal fun ByteArray.hex(): String = joinToString(separator = "") { byte -> "%02x".format(byte) }
