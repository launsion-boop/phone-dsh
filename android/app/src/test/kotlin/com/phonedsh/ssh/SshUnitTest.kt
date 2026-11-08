// phone-dsh — :app unit tests: the ssh/scp grammar, the shared goldens, local
// mount confinement and the pinned-key rules. No network.
// SPDX-License-Identifier: MIT

package com.phonedsh.ssh

import com.phonedsh.dsh.exec.ExecRequest
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SshUnitTest {
    @Test
    fun theSharedGoldenRequestsDecodeThroughTheRealParsers() {
        // spec/v1/golden/frames/exec-req-2.json (ssh) and exec-req-3.json (scp).
        val ssh = SshInvocation.parse(SshGolden.request("exec-req-2.json").argv)
        assertEquals("demo", ssh.destination)
        assertEquals(SshInvocation.Operation.Command("uname -a"), ssh.operation)
        assertNull(ssh.port)

        val scp = SshInvocation.parse(SshGolden.request("exec-req-3.json").argv)
        assertEquals("demo", scp.destination)
        assertEquals(SshInvocation.Operation.Download("/tmp/report.txt", recursive = false), scp.operation)
        assertNull(scp.port)
    }

    @Test
    fun sshFlagsFollowTheIosGrammar() {
        val parsed = SshInvocation.parse(listOf("ssh", "-T", "-n", "-p", "2222", "-l", "ops", "box", "ls", "-la"))
        assertEquals(2222, parsed.port)
        assertEquals("ops", parsed.user)
        assertTrue(parsed.ignoreStandardInput)
        assertEquals(SshInvocation.Operation.Command("ls -la"), parsed.operation)
        assertEquals(
            SshInvocation.Operation.Command("-x"),
            SshInvocation.parse(listOf("ssh", "--", "box", "-x")).operation,
        )
        for (argv in listOf(
            listOf("ssh", "box"), // no command: no interactive shell
            listOf("ssh", "-L", "8080:x:80", "box", "ls"), // forwarding
            listOf("ssh", "-t", "box", "ls"), // PTY
            listOf("ssh", "-p", "0", "box", "ls"),
            listOf("ssh", "-p", "65536", "box", "ls"),
            listOf("ssh", "box", "a\u0000b"),
        )) {
            assertThrows(argv.toString(), SshFailure::class.java) { SshInvocation.parse(argv) }
        }
    }

    @Test
    fun internalScpFormIsTheOnlyAcceptedScpShape() {
        val upload = SshInvocation.parse(
            listOf("scp", "--pdsh-v1", "upload", "recursive", "box", "2222", "/dsh/workspace/tree", "/srv/in"),
        )
        assertEquals(2222, upload.port)
        assertEquals(SshInvocation.Operation.Upload("/dsh/workspace/tree", "/srv/in", true), upload.operation)
        for (argv in listOf(
            listOf("scp", "a.txt", "box:/tmp/a.txt"), // raw operands: the Worker must translate
            listOf("scp", "--pdsh-v1", "upload", "file", "box", "default", "/dsh/workspace/a"),
            listOf("scp", "--pdsh-v1", "download", "file", "box", "default", "/a", "/b"),
            listOf("scp", "--pdsh-v1", "download", "mirror", "box", "default", "/a"),
            listOf("scp", "--pdsh-v1", "download", "file", "box", "port", "/a"),
        )) {
            assertThrows(argv.toString(), SshFailure::class.java) { SshInvocation.parse(argv) }
        }
    }

    @Test
    fun mountConfinementIncludesSymlinksAndSiblingPrefixes() {
        val root = Files.createTempDirectory("pdsh-ssh-mount")
        try {
            Files.createSymbolicLink(root.resolve("escape"), File(System.getProperty("java.io.tmpdir")).toPath())
            val mounts = mapOf("/dsh/workspace" to root)
            assertEquals("file", SshExecTool.resolveLocalPath("/dsh/workspace/file", mounts).fileName.toString())
            for (path in listOf("/dsh/workspace/../secret", "/dsh/workspace-other/file", "/dsh/workspace/escape/file", "/tmp/file")) {
                assertThrows(path, SshFailure::class.java) { SshExecTool.resolveLocalPath(path, mounts) }
            }
        } finally {
            // Remove the link itself first: a recursive walk must not follow it.
            Files.deleteIfExists(root.resolve("escape"))
            root.toFile().deleteRecursively()
        }
    }

    @Test
    fun anUntrustedConnectionIsRefusedBeforeAnyNetworkAccess() {
        // Port 1 on loopback: a refusal message about trust proves no connect was tried.
        val failure = assertThrows(SshFailure::class.java) {
            SshTransport.connect(SshConnection("127.0.0.1", 1, "test", trustedHostKey = ""), 1_000, SshCancellation())
        }
        assertTrue(failure.message!!.contains("not trusted"))
    }

    @Test
    fun fingerprintsAndPinnedKeyTypesMatchOpenSsh() {
        // OpenSSH's form: SHA-256 of the decoded blob, unpadded base64. The live
        // fixture test compares a real server key against `ssh-keygen -lf` output.
        val key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test"
        val blob = java.util.Base64.getDecoder().decode("AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        val expected = "SHA256:" + java.util.Base64.getEncoder().withoutPadding()
            .encodeToString(java.security.MessageDigest.getInstance("SHA-256").digest(blob))
        assertEquals(expected, SshTransport.fingerprint(key))
        assertEquals("Invalid key", SshTransport.fingerprint("ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"))
        assertEquals("Invalid key", SshTransport.fingerprint("garbage"))
        assertEquals("ssh-ed25519", SshTransport.hostKeyAlgorithmsFor("ssh-ed25519"))
        // RSA keys are pinned with SHA-2 signatures only; SHA-1 `ssh-rsa` is never enabled.
        assertEquals("rsa-sha2-512,rsa-sha2-256", SshTransport.hostKeyAlgorithmsFor("ssh-rsa"))
        assertNull(SshTransport.hostKeyAlgorithmsFor("ssh-dss"))
    }

    @Test
    fun helpListAndStdinRefusalNeedNoConnection() = runBlocking {
        val clock = SshGolden.FixedClock(1_000L)
        var resolved = 0
        val tool = SshExecTool(
            mounts = emptyMap(),
            byteLimit = 4096,
            clock = clock,
            connections = { "demo\tops@example.test:22" },
            resolve = { resolved += 1; throw SshFailure("must not resolve") },
        )
        val list = SshGolden.run(tool, listOf("ssh", "--list"), clock)
        assertEquals(0, list.code)
        assertEquals("demo\tops@example.test:22\n", list.stdout)
        val help = SshGolden.run(tool, listOf("ssh", "--help"), clock)
        assertTrue(help.stdout.startsWith("Usage: ssh"))
        val piped = SshGolden.run(tool, listOf("ssh", "demo", "cat"), clock, stdin = "input")
        assertEquals(1, piped.code)
        assertTrue(piped.stderr, piped.stderr.contains("stdin"))
        assertEquals("a refused stdin request never resolves credentials", 0, resolved)
        val unknown = SshGolden.run(tool, listOf("ssh", "nowhere", "ls"), clock)
        assertEquals(1, unknown.code)
        assertTrue(unknown.stderr.startsWith("ssh: "))
    }
}

/** Shared helpers: the repo's goldens and a one-call tool runner. */
internal object SshGolden {
    class FixedClock(var wall: Long) : com.phonedsh.platform.Clock {
        override fun nowMillis(): Long = wall
        override fun monotonicMillis(): Long = System.nanoTime() / 1_000_000
    }

    class Result(val code: Int?, val status: String, val stdout: String, val stderr: String, val stdoutBytes: ByteArray)

    fun request(name: String): ExecRequest {
        val golden = JSONObject(repoFile("spec/v1/golden/frames/$name").readText())
        val hex = golden.getString("payload_hex")
        val bytes = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        return ExecRequest.parse(String(bytes, Charsets.UTF_8))
    }

    suspend fun run(
        tool: SshExecTool,
        argv: List<String>,
        clock: FixedClock,
        deadlineMs: Long = 10_000L,
        stdin: String? = null,
        execId: String = "exec-" + java.util.UUID.randomUUID().toString().take(8),
    ): Result {
        val json = JSONObject()
            .put("exec_id", execId)
            .put("argv", org.json.JSONArray(argv))
            .put("cwd", "/dsh/workspace")
            .put("requires_mseq", 0)
            .put("idem_key", "c".repeat(64))
            .put("deadline", clock.nowMillis() + deadlineMs)
        if (stdin != null) {
            json.put("stdin", JSONObject().put("mode", "data").put("data", java.util.Base64.getEncoder().encodeToString(stdin.toByteArray())))
        }
        val outcome = tool.invoke(com.phonedsh.dsh.tools.ToolInvocation("c".repeat(64), argv.first(), json.toString()))
        val success = outcome as com.phonedsh.dsh.tools.ToolOutcome.Success
        val result = JSONObject(success.resultJson)
        val out = java.util.Base64.getDecoder().decode(result.getString("stdout"))
        val err = java.util.Base64.getDecoder().decode(result.getString("stderr"))
        return Result(
            code = if (result.isNull("code")) null else result.getInt("code"),
            status = result.getString("status"),
            stdout = String(out, Charsets.UTF_8),
            stderr = String(err, Charsets.UTF_8),
            stdoutBytes = out,
        )
    }

    fun repoFile(relative: String): File {
        val starts = listOfNotNull(System.getProperty("pdsh.repo.root"), System.getProperty("user.dir")).map(::File)
        for (start in starts) {
            var dir: File? = start.absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        error("cannot locate $relative from ${starts.joinToString()}")
    }
}
