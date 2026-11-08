// phone-dsh — :app integration tests against the shared loopback SSH fixture.
// SPDX-License-Identifier: MIT
//
// The fixture is the iOS one, unchanged: start `scripts/testing/ssh-fixture.py
// <private-temp-dir>` (Python asyncssh + bcrypt) and set PDSH_SSH_TEST_CONFIG to
// its config.json. Each case mirrors `Tests/PhoneDSHSSHTests/SSHConnectionTests.swift`.
// Without the variable every case is reported as skipped (JUnit assumption),
// never as passed. Optionally PDSH_SSH_TEST_FINGERPRINT carries `ssh-keygen -lf`
// output for the fixture host key, to compare the fingerprint with OpenSSH's.

package com.phonedsh.ssh

import com.phonedsh.dsh.exec.AdmissionGate
import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecCapability
import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecWorkspace
import java.io.File
import java.nio.file.Files
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class SshLiveFixtureTest {
    private class Fixture(json: JSONObject) {
        val port = json.getInt("port")
        val stalledPort = json.getInt("stalledPort")
        val keyOnlyPort = json.getInt("keyOnlyPort")
        val password = json.getString("password")
        val hostKey = json.getString("hostKey")
        val otherHostKey = json.getString("otherHostKey")
        val privateKey = json.getString("privateKey")
        val encryptedKey = json.getString("encryptedKey")
        val rsaKey = json.getString("rsaKey")
        val remote = File(json.getString("remote"))
        val connection: SshConnection
            get() = SshConnection("127.0.0.1", port, "fixture", password = password, trustedHostKey = hostKey)
    }

    private fun fixture(): Fixture {
        val path = System.getenv("PDSH_SSH_TEST_CONFIG")
        assumeTrue("Start scripts/testing/ssh-fixture.py and set PDSH_SSH_TEST_CONFIG for live SSH/SFTP tests", path != null)
        return Fixture(JSONObject(File(path!!).readText()))
    }

    private fun tool(config: Fixture, workspace: java.nio.file.Path? = null, limit: Long = 4096, clock: SshGolden.FixedClock): SshExecTool {
        val root = workspace ?: Files.createTempDirectory("pdsh-ssh-ws")
        return SshExecTool(
            mounts = mapOf("/dsh/workspace" to root, "/dsh/home" to root),
            byteLimit = limit,
            clock = clock,
            connections = { "test" },
            resolve = { config.connection },
        )
    }

    private fun clock() = SshGolden.FixedClock(System.currentTimeMillis())

    @Test
    fun stalledHandshakeDeadlineAndCancellation() {
        val config = fixture()
        val stalled = config.connection.copy(port = config.stalledPort)
        var start = System.nanoTime()
        assertThrows(SshFailure::class.java) { SshTransport.connect(stalled, 200, SshCancellation()) }
        assertTrue("deadline must close a stalled handshake", (System.nanoTime() - start) / 1_000_000 < 2_000)

        val cancellation = SshCancellation()
        var failure: Throwable? = null
        val worker = Thread { failure = runCatching { SshTransport.connect(stalled, 30_000, cancellation) }.exceptionOrNull() }
        worker.start()
        Thread.sleep(100)
        start = System.nanoTime()
        cancellation.cancel()
        worker.join(5_000)
        assertTrue("cancel must close a stalled handshake", !worker.isAlive && (System.nanoTime() - start) / 1_000_000 < 2_000)
        assertTrue(failure is SshFailure)
    }

    @Test
    fun nativeCommandsAndExitStatus() = runBlocking {
        val config = fixture()
        val clock = clock()
        val tool = tool(config, clock = clock)
        val result = SshGolden.run(tool, listOf("ssh", "test", "output"), clock)
        assertEquals("ssh stdout\n", result.stdout)
        assertEquals("ssh stderr\n", result.stderr)
        assertEquals(7, result.code)

        clock.wall = System.currentTimeMillis()
        val timeout = SshGolden.run(tool, listOf("ssh", "test", "wait"), clock, deadlineMs = 1_000)
        assertEquals(124, timeout.code)
        assertEquals("timed_out", timeout.status)

        clock.wall = System.currentTimeMillis()
        val bounded = SshGolden.run(tool, listOf("ssh", "test", "large"), clock)
        assertNotEquals(0, bounded.code)
        assertTrue(bounded.stderr, bounded.stderr.contains("output limit"))
    }

    @Test
    fun passwordDisabledAndRejectedHaveActionableErrors() {
        val config = fixture()
        val start = System.nanoTime()
        val keyOnly = assertThrows(SshFailure::class.java) {
            SshTransport.connect(config.connection.copy(port = config.keyOnlyPort), 5_000, SshCancellation())
        }
        assertTrue(keyOnly.message, keyOnly.message!!.contains("authorized key"))
        assertTrue((System.nanoTime() - start) / 1_000_000 < 3_000)

        val wrong = assertThrows(SshFailure::class.java) {
            SshTransport.connect(config.connection.copy(password = "deliberately-wrong-fixture-password"), 5_000, SshCancellation())
        }
        assertTrue(wrong.message, wrong.message!!.contains("password") && wrong.message!!.contains("Settings"))
    }

    @Test
    fun keyAuthenticationAndChangedHostKeyRefusal() {
        val config = fixture()
        val observed = SshTransport.inspectHostKey("127.0.0.1", config.port)
        assertEquals(PublicKeyLine.parse(config.hostKey)!!.encoded(), observed)
        System.getenv("PDSH_SSH_TEST_FINGERPRINT")?.let { openssh ->
            assertTrue("ssh-keygen printed: $openssh", openssh.contains(SshTransport.fingerprint(observed)))
        }
        for ((key, passphrase) in listOf(config.privateKey to "", config.encryptedKey to "fixture-passphrase", config.rsaKey to "")) {
            val cancellation = SshCancellation()
            val session = SshTransport.connect(
                config.connection.copy(password = "", privateKey = key, passphrase = passphrase),
                5_000,
                cancellation,
            )
            assertTrue(session.isConnected)
            cancellation.close()
        }
        // An encrypted key with the wrong passphrase fails locally, before auth.
        assertThrows(SshFailure::class.java) {
            SshTransport.connect(
                config.connection.copy(password = "", privateKey = config.encryptedKey, passphrase = "wrong"),
                5_000,
                SshCancellation(),
            )
        }
        // A valid but different public key must never authenticate.
        val changed = assertThrows(SshFailure::class.java) {
            SshTransport.connect(config.connection.copy(trustedHostKey = config.otherHostKey), 2_000, SshCancellation())
        }
        assertTrue(changed.message, changed.message!!.contains("does not match"))
    }

    @Test
    fun sftpRoundTripAndDirectoryTransfer() = runBlocking {
        val config = fixture()
        val workspace = Files.createTempDirectory("pdsh-ssh-sftp")
        val remote = "/roundtrip-" + UUID.randomUUID()
        try {
            Files.createDirectories(workspace.resolve("tree"))
            val bytes = ByteArray(65_537) { (it % 256).toByte() }
            Files.write(workspace.resolve("tree/binary"), bytes)
            Files.write(workspace.resolve("tree/empty"), ByteArray(0))
            val clock = clock()
            val tool = tool(config, workspace, limit = 100_000, clock = clock)
            val upload = SshGolden.run(
                tool, listOf("scp", "--pdsh-v1", "upload", "recursive", "test", "default", "/dsh/workspace/tree", remote), clock,
            )
            assertEquals(upload.stderr, 0, upload.code)
            assertArrayEquals(bytes, File(config.remote, "$remote/binary").readBytes())

            clock.wall = System.currentTimeMillis()
            val download = SshGolden.run(tool, listOf("scp", "--pdsh-v1", "download", "recursive", "test", "default", "$remote/."), clock)
            assertEquals(download.stderr, 0, download.code)
            val restored = java.io.ByteArrayOutputStream()
            var ends = 0
            for (line in download.stdout.split("\n").filter { it.isNotEmpty() }) {
                val record = JSONObject(line)
                if (record.getString("type") == "data") restored.write(Base64.getDecoder().decode(record.getString("data")))
                if (record.getString("type") == "end") ends += 1
            }
            assertArrayEquals(bytes, restored.toByteArray())
            assertEquals(2, ends)

            // A tree over the device byte budget fails with the iOS limit message.
            clock.wall = System.currentTimeMillis()
            val small = tool(config, workspace, limit = 1_000, clock = clock)
            val over = SshGolden.run(small, listOf("scp", "--pdsh-v1", "download", "recursive", "test", "default", "$remote/."), clock)
            assertEquals(1, over.code)
            assertTrue(over.stderr, over.stderr.contains("limit"))
        } finally {
            File(config.remote, remote).deleteRecursively()
            workspace.toFile().deleteRecursively()
        }
    }

    @Test
    fun cancelAndStdinRefusal() = runBlocking {
        val config = fixture()
        val clock = clock()
        val tool = tool(config, clock = clock)
        val execId = "cancel-" + UUID.randomUUID().toString().take(8)
        val started = System.nanoTime()
        val running = async(kotlinx.coroutines.Dispatchers.IO) {
            SshGolden.run(tool, listOf("ssh", "test", "wait"), clock, deadlineMs = 20_000, execId = execId)
        }
        delay(500)
        tool.cancelExecution(execId)
        val result = running.await()
        assertEquals(130, result.code)
        assertEquals("cancelled", result.status)
        assertTrue("cancel closes the connection promptly", (System.nanoTime() - started) / 1_000_000 < 5_000)

        clock.wall = System.currentTimeMillis()
        val piped = SshGolden.run(tool, listOf("ssh", "test", "output"), clock, stdin = "input")
        assertEquals(1, piped.code)
        assertTrue(piped.stderr.contains("stdin"))
    }

    @Test
    fun theSharedGoldenFramesRunThroughTheRealBridge() = runBlocking {
        val config = fixture()
        val ssh = SshGolden.request("exec-req-2.json")
        val scp = SshGolden.request("exec-req-3.json")
        // The goldens carry a fixed absolute deadline; the clock sits before it.
        val clock = SshGolden.FixedClock(ssh.deadline!! - 60_000)
        val shared = tool(config, clock = clock)
        // Both goldens carry the same exec_id under different idem_keys, so each
        // runs on its own bridge (one bridge would answer exec_id_conflict).
        fun bridge() = ExecBridge(
            capability = shared.registeredTools().let { ExecCapability.of(it[0], it[1]) },
            admission = AdmissionGate.Open,
            workspace = ExecWorkspace { ssh.requiresMseq },
            clock = clock,
        )
        val events = bridge().onRequest(ssh).toList()
        assertEquals(listOf("start", "output", "exit"), events.map { it.type })
        val output = events[1] as ExecEvent.Output
        assertEquals("connected\n", String(Base64.getDecoder().decode(output.data)))
        assertEquals(0, (events.last() as ExecEvent.Exit).code)

        // exec-req-3 downloads /tmp/report.txt from the fixture's confined root.
        val report = File(config.remote, "tmp/report.txt")
        report.parentFile!!.mkdirs()
        report.writeText("golden report\n")
        try {
            val download = bridge().onRequest(scp).toList()
            val exit = download.last() as ExecEvent.Exit
            assertEquals(0, exit.code)
            val stdout = String(Base64.getDecoder().decode((download[1] as ExecEvent.Output).data))
            val types = stdout.trim().split("\n").map { JSONObject(it).getString("type") }
            assertEquals(listOf("file", "data", "end"), types)
            val data = JSONObject(stdout.trim().split("\n")[1]).getString("data")
            assertEquals("golden report\n", String(Base64.getDecoder().decode(data)))
        } finally {
            report.delete()
        }
    }
}
