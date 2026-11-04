// Build the bounded, typed EXEC_REQ used by the read-only native shell page.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.dsh.exec.Confine
import com.phonedsh.dsh.exec.ConfineMode
import com.phonedsh.dsh.exec.ExecRequest
import com.phonedsh.dsh.exec.ExecTier
import com.phonedsh.dsh.exec.StdinSpec
import com.phonedsh.ui.state.StateRequestId
import java.security.MessageDigest

/** Typed translation of the one UI form; it never invokes a process itself. */
internal object ShellExecRequestFactory {
    private const val XL_KEY: String = "XL_IDEMPOTENCY_KEY"

    fun create(
        command: String,
        workingDirectory: String,
        arguments: String,
        requestId: StateRequestId,
        availableCommands: List<String>,
        mountedRoots: List<String>,
        requiresMseq: Long,
        deadline: Long,
    ): ExecRequest? {
        if (command !in availableCommands || requestId.value.isBlank()) return null
        val mountRoot = mountedRoots.firstOrNull { root ->
            (workingDirectory == root || workingDirectory.startsWith(root + "/")) &&
                workingDirectory.split('/').none { it == ".." || it == "." }
        } ?: return null
        val argv = listOf(command) + arguments.split(Regex("\\r\\n|\\n|\\r")).filter(String::isNotEmpty)
        // Host-originated actions have no Worker tool-journal key. Use this UI
        // request identity for retries of the same form submission, then apply
        // the exec.md D10 canonical argv/cwd/env hash formula.
        val xlIdempotencyKey = "xl1-" + sha256(requestId.value.toByteArray(Charsets.UTF_8)).take(32)
        val environment = mapOf(XL_KEY to xlIdempotencyKey)
        val environmentJson = JsonObject(mapOf(XL_KEY to JsonString(xlIdempotencyKey))).toJsonString()
        val argvJson = JsonArray(argv.map(::JsonString)).toJsonString()
        val envHash = sha256(environmentJson.toByteArray(Charsets.UTF_8))
        val identity = listOf(xlIdempotencyKey, argvJson, workingDirectory, envHash).joinToString("\u001f")
        return runCatching {
            ExecRequest(
                execId = requestId.value,
                argv = argv,
                cwd = workingDirectory,
                env = environment,
                deadline = deadline,
                stdin = StdinSpec.Ignore,
                tier = ExecTier.INTERACTIVE,
                confine = Confine(ConfineMode.READ_ONLY, mountRoot),
                requiresMseq = requiresMseq,
                idemKey = sha256(identity.toByteArray(Charsets.UTF_8)),
            )
        }.getOrNull()
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { byte -> "%02x".format(byte) }
}
