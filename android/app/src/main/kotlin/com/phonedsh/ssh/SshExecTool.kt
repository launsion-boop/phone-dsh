// phone-dsh — :app / com.phonedsh.ssh: the `ssh` / `scp` exec/1 accelerators.
// SPDX-License-Identifier: MIT
//
// Android half of `Sources/PhoneDSHSSH/SSHExecProvider.swift`, registered under
// the names `ssh` and `scp` through `HostExec.defaultTools(nativeTools = …)` so
// the host HELLO advertises `accelerator:ssh` / `accelerator:scp` only when this
// implementation is linked (exec.md §3, channel.md §4.1).
//
// Contract (docs/native-ssh.md): saved aliases only; the pinned host key is the
// only key accepted; no forwarding, no PTY; non-empty initial stdin is refused
// unless `-n`; cancellation and the deadline close the SSH channel and the TCP
// connection (exit 130 / 124); output is bounded and a truncation exits non-zero.
// Remote writes are intentional remote effects; local materialized mounts are
// read-only, and downloads only emit records for the Worker's VFS writer.
//
// Android difference, by construction of this host's exec bridge: a tool returns
// one completed `ExecToolResult`, not a live stream, so stdout is delivered once
// at the end and is bounded by `ExecToolResult.MAX_STREAM_BYTES`. An SCP download
// therefore fits the smaller of the device byte budget and what its base64 NDJSON
// records can carry in one result; beyond it the transfer fails with the same
// limit message as iOS (files whose `end` record was emitted are kept by the
// Worker, as on iOS). The idempotency ledger replays a completed or cancelled
// result for a repeated `idem_key`, so a retry never re-runs a remote effect.

package com.phonedsh.ssh

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.jcraft.jsch.SftpException
import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecRequest
import com.phonedsh.dsh.exec.ExecRequestException
import com.phonedsh.dsh.exec.ExecToolResult
import com.phonedsh.dsh.exec.StdinSpec
import com.phonedsh.dsh.tools.CancellableTool
import com.phonedsh.dsh.tools.RegisteredTool
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.Clock
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * One instance serves both `ssh` and `scp` ([registeredTools]).
 *
 * @param mounts guest root (`/dsh/workspace`, `/dsh/home`) to its materialized
 *   host directory; uploads read only below these roots.
 * @param byteLimit the device byte budget for one SSH output or SCP tree.
 * @param clock wall time for the request's absolute `deadline`.
 * @param connections the `ssh --list` text (aliases and endpoints, no secrets).
 * @param resolve alias → connection with its Keystore credentials; throws
 *   [SshFailure] for an unknown or ambiguous name.
 */
class SshExecTool(
    private val mounts: Map<String, Path>,
    private val byteLimit: Long,
    private val clock: Clock,
    private val connections: () -> String,
    private val resolve: (String) -> SshConnection,
) : CancellableTool {
    private val operations = ConcurrentHashMap<String, SshCancellation>()

    /** `ssh` and `scp`, the two exec.md §3 names this tool answers. */
    fun registeredTools(): List<RegisteredTool> = listOf(RegisteredTool(SSH, this), RegisteredTool(SCP, this))

    override fun cancelExecution(execId: String) {
        val operation = operations[execId] ?: return
        // Closing a socket can block briefly; never on the channel thread.
        CLOSER.execute { operation.cancel() }
    }

    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        val request = try {
            ExecRequest.parse(invocation.argumentsJson)
        } catch (invalid: ExecRequestException) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, "the dispatch request is unreadable")
        }
        if (request.stdin is StdinSpec.Pipe) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, "ssh/scp have no stdin pipe; stdin.mode must be ignore")
        }
        val operation = SshCancellation()
        if (operations.putIfAbsent(request.execId, operation) != null) {
            return ToolOutcome.Success(
                result(1, ByteArray(0), line(request, "SSH execution already active; do not retry remote side effects")),
            )
        }
        val remainingMs = request.deadline?.let { it - clock.nowMillis() } ?: DEFAULT_DEADLINE_MS
        val timer = DEADLINES.schedule({ operation.cancel(timeout = true) }, remainingMs.coerceAtLeast(1L), TimeUnit.MILLISECONDS)
        try {
            return coroutineScope {
                var finished = false
                // A cancelled bridge coroutine must also close the connection.
                val watcher = launch {
                    try {
                        awaitCancellation()
                    } finally {
                        if (!finished) operation.cancel()
                    }
                }
                try {
                    ToolOutcome.Success(withContext(Dispatchers.IO) { execute(request, operation, remainingMs) })
                } finally {
                    finished = true
                    watcher.cancel()
                }
            }
        } finally {
            timer.cancel(false)
            operation.close()
            operations.remove(request.execId, operation)
        }
    }

    /** Blocking body; returns the `ExecToolResult` JSON. */
    private fun execute(request: ExecRequest, operation: SshCancellation, remainingMs: Long): String {
        val stdout = ResultSink(MAX_OUTPUT_BYTES)
        val stderr = ByteArrayOutputStream()
        var code = 0
        var truncated = false
        try {
            when (request.argv) {
                listOf(SSH, "--help") -> stdout.append(SshInvocation.USAGE.toByteArray(Charsets.UTF_8))
                listOf(SSH, "--list") -> stdout.append((connections() + "\n").toByteArray(Charsets.UTF_8))
                else -> {
                    val invocation = SshInvocation.parse(request.argv)
                    val command = invocation.operation as? SshInvocation.Operation.Command
                    if (command != null && stdinBytes(request.stdin) > 0 && !invocation.ignoreStandardInput) {
                        throw SshFailure("SSH stdin piping is not supported; use scp to upload input files")
                    }
                    val connection = resolve(invocation.destination)
                    invocation.port?.let { if (it != connection.port) throw SshFailure("Port differs from saved SSH connection") }
                    invocation.user?.let { if (it != connection.username) throw SshFailure("User differs from saved SSH connection") }
                    val session = SshTransport.connect(connection, remainingMs, operation)
                    if (operation.cancelled) throw SshFailure("SSH cancelled")
                    when (val op = invocation.operation) {
                        is SshInvocation.Operation.Command -> {
                            val outcome = runCommand(session, op.command, operation)
                            code = outcome.code
                            stdout.append(outcome.stdout)
                            stderr.write(outcome.stderr)
                            if (outcome.exceeded) {
                                truncated = true
                                throw SshFailure("SSH output limit exceeded; redirect large output to a file and use scp")
                            }
                        }
                        is SshInvocation.Operation.Upload -> withSftp(session) { sftp ->
                            val source = resolveLocalPath(op.local, mounts)
                            val transfer = SshFileTransfer(byteLimit, stdout::append) { operation.cancelled }
                            val existing = SshFileTransfer.statOrNull(sftp, op.remote)
                            val target = if (existing != null && with(SshFileTransfer) { existing.isDirectory() }) {
                                SshFileTransfer.remoteJoin(op.remote, source.fileName.toString())
                            } else {
                                op.remote
                            }
                            transfer.upload(source, target, op.recursive, sftp)
                        }
                        is SshInvocation.Operation.Download -> withSftp(session) { sftp ->
                            val transfer = SshFileTransfer(byteLimit, stdout::append) { operation.cancelled }
                            val basename = SshFileTransfer.basename(op.remote)
                            val source = if (basename == "." || basename == "..") sftp.realpath(op.remote) else op.remote
                            transfer.download(source, "", op.recursive, sftp)
                        }
                    }
                }
            }
        } catch (failure: Exception) {
            code = 1
            if (!operation.cancelled) stderr.write(line(request, describe(failure)))
        }
        if (operation.cancelled) {
            val timedOut = operation.timedOut
            return result(
                if (timedOut) EXIT_TIMED_OUT else EXIT_CANCELLED,
                stdout.bytes(),
                stderr.toByteArray(),
                if (timedOut) ExecEvent.ExitStatus.TIMED_OUT else ExecEvent.ExitStatus.CANCELLED,
            )
        }
        if (truncated && code == 0) code = 1
        return result(code, stdout.bytes(), stderr.toByteArray())
    }

    private class CommandOutcome(val code: Int, val stdout: ByteArray, val stderr: ByteArray, val exceeded: Boolean)

    private fun runCommand(session: Session, command: String, operation: SshCancellation): CommandOutcome {
        val budget = SharedBudget(minOf(byteLimit, MAX_OUTPUT_BYTES.toLong()))
        val out = BoundedSink(budget)
        val err = BoundedSink(budget)
        val channel = session.openChannel("exec") as ChannelExec
        try {
            channel.setCommand(command)
            // Initial stdin is empty: the remote command reads EOF, like `ssh -n`.
            channel.setInputStream(ByteArrayInputStream(ByteArray(0)))
            channel.setOutputStream(out, true)
            channel.setErrStream(err, true)
            channel.connect(CHANNEL_OPEN_TIMEOUT_MS)
            while (!channel.isClosed) {
                if (operation.cancelled) throw SshFailure("SSH cancelled")
                if (budget.exceeded) break
                Thread.sleep(POLL_MS)
            }
            val status = channel.exitStatus
            return CommandOutcome(
                code = when {
                    budget.exceeded -> 1
                    status >= 0 -> status
                    else -> 1
                },
                stdout = out.bytes(),
                stderr = if (!budget.exceeded && status < 0) {
                    err.bytes() + "ssh: remote command ended without an exit status\n".toByteArray(Charsets.UTF_8)
                } else {
                    err.bytes()
                },
                exceeded = budget.exceeded,
            )
        } finally {
            channel.disconnect()
        }
    }

    private inline fun withSftp(session: Session, body: (ChannelSftp) -> Unit) {
        val sftp = session.openChannel("sftp") as ChannelSftp
        try {
            sftp.connect(CHANNEL_OPEN_TIMEOUT_MS)
            body(sftp)
        } finally {
            sftp.disconnect()
        }
    }

    private fun stdinBytes(stdin: StdinSpec): Int = when (stdin) {
        is StdinSpec.Data -> stdin.sizeBytes
        else -> 0
    }

    private fun line(request: ExecRequest, message: String): ByteArray =
        "${request.argv.firstOrNull() ?: SSH}: $message\n".toByteArray(Charsets.UTF_8)

    private fun describe(failure: Exception): String = when (failure) {
        is SshFailure -> failure.message.orEmpty()
        is SftpException -> "SFTP error ${failure.id}: ${failure.message.orEmpty()}"
        is JSchException -> "SSH error: ${failure.message.orEmpty()}"
        is java.nio.file.NoSuchFileException -> "Local file not found"
        is IOException -> "I/O error: ${failure.message ?: failure.javaClass.simpleName}"
        else -> failure.message ?: failure.javaClass.simpleName
    }

    private fun result(
        code: Int,
        stdout: ByteArray,
        stderr: ByteArray,
        status: ExecEvent.ExitStatus = ExecEvent.ExitStatus.EXITED,
    ): String {
        val encoder = Base64.getEncoder()
        return JSONObject()
            .put("status", status.wireName)
            .put("code", code)
            .put("signal", JSONObject.NULL)
            .put("quiescent", true)
            .put("stdout", encoder.encodeToString(stdout))
            .put("stderr", encoder.encodeToString(stderr.copyOf(minOf(stderr.size, MAX_OUTPUT_BYTES))))
            .toString()
    }

    /** stdout of one run; a record that would not fit is refused with the limit message. */
    private class ResultSink(private val limit: Int) {
        private val buffer = ByteArrayOutputStream()

        fun append(bytes: ByteArray) {
            if (buffer.size() + bytes.size > limit) throw SshFailure(SshFileTransfer.LIMIT_MESSAGE)
            buffer.write(bytes)
        }

        fun bytes(): ByteArray = buffer.toByteArray()
    }

    companion object {
        const val SSH: String = "ssh"
        const val SCP: String = "scp"

        /** Protocol-level refusal; the bridge forwards it as the terminal `unsupported`. */
        const val CODE_UNSUPPORTED: String = "unsupported"

        /** iOS uses a 120 s budget when a request carries no deadline. */
        const val DEFAULT_DEADLINE_MS: Long = 120_000L

        const val EXIT_TIMED_OUT: Int = 124
        const val EXIT_CANCELLED: Int = 130

        /** One stream's ceiling, below the exec result budget like the Rust accelerators. */
        val MAX_OUTPUT_BYTES: Int = ExecToolResult.MAX_STREAM_BYTES - 1024

        private const val CHANNEL_OPEN_TIMEOUT_MS = 15_000
        private const val POLL_MS = 20L

        private val DEADLINES: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "pdsh-ssh-deadline").apply { isDaemon = true }
        }
        private val CLOSER = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "pdsh-ssh-cancel").apply { isDaemon = true }
        }

        /**
         * Maps `/dsh/workspace/…` or `/dsh/home/…` to the materialized host path.
         *
         * Refuses NUL, any `..` component, a path outside both mounts (including a
         * sibling prefix such as `/dsh/workspace-other`) and any symbolic link on
         * the way, checked component by component because the final file may not
         * exist yet.
         */
        fun resolveLocalPath(path: String, mounts: Map<String, Path>): Path {
            if (path.contains('\u0000') || path.split('/').contains("..")) throw SshFailure("Invalid local path")
            for ((guest, root) in mounts) {
                if (path != guest && !path.startsWith("$guest/")) continue
                val base = root.toRealPath()
                var result = base
                for (component in path.substring(guest.length).split('/')) {
                    if (component.isEmpty() || component == ".") continue
                    result = result.resolve(component)
                    if (Files.isSymbolicLink(result)) throw SshFailure("scp refuses symbolic links in local paths")
                }
                if (!result.normalize().startsWith(base)) throw SshFailure("Invalid local path")
                return result.normalize()
            }
            throw SshFailure("scp can only read /dsh/workspace and /dsh/home")
        }
    }
}
