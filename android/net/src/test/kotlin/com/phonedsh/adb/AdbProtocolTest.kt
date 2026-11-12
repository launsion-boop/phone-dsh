// phone-dsh — :net tests: ADB packets, RSA identity, shell_v2 and the client loop
// (ports ADBProtocolTests.swift, including its byte-level packet golden).
// SPDX-License-Identifier: MIT

package com.phonedsh.adb

import com.phonedsh.platform.SecurityLevel
import com.phonedsh.platform.testing.FakePlatform
import java.math.BigInteger
import java.net.ServerSocket
import java.security.KeyFactory
import java.security.spec.RSAPublicKeySpec
import java.util.Base64
import javax.crypto.Cipher
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AdbProtocolTest {
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    @Test
    fun packetGoldenAndChecksumRejection() {
        val packet = AdbPacket(AdbPacket.OPEN, 1, 0, byteArrayOf(97, 0))
        assertEquals("4f50454e01000000000000000200000061000000b0afbab16100", hex(packet.encoded()))
        assertEquals(packet, AdbPacket.read(ScriptedAdb(listOf(packet))))
        val corrupt = packet.encoded().also { it[24] = 98 }
        assertThrows(AdbFailure::class.java) { AdbPacket.read(ScriptedAdb(corrupt)) }
        val oversized = packet.encoded().also { it[12] = 0; it[13] = 0; it[14] = 32; it[15] = 0 }
        assertThrows(AdbFailure::class.java) { AdbPacket.read(ScriptedAdb(oversized)) }
    }

    @Test
    fun androidKeyMontgomeryParameters() {
        // N = 2^2048 - 159 => R² mod N = 159² = 25281 (0x62c1).
        val modulus = BigInteger.ONE.shiftLeft(2048).subtract(BigInteger.valueOf(159))
        val encoded = AdbIdentity.androidPublicKey(modulus, BigInteger.valueOf(65537))
        assertEquals(524, encoded.size)
        assertEquals(64L, encoded.le32(0))
        assertEquals(0xFFFF_FFFFL, (encoded.le32(4) * encoded.le32(8)) and 0xFFFF_FFFFL)
        assertEquals(25281L, encoded.le32(264))
        assertTrue(encoded.copyOfRange(268, 520).all { it == 0.toByte() })
        assertEquals(65537L, encoded.le32(520))
        assertThrows(AdbFailure::class.java) { AdbIdentity.androidPublicKey(modulus, BigInteger.valueOf(3)) }
    }

    @Test
    fun signatureAndPublicKeyUseSameIdentity() {
        val identity = newIdentity()
        val token = ByteArray(20) { 19 }
        val text = String(identity.publicKey(), Charsets.UTF_8)
        assertTrue(text.endsWith(" phone-dsh@android\u0000"))
        val bytes = Base64.getDecoder().decode(text.substringBefore(' '))
        val modulus = BigInteger(1, bytes.copyOfRange(8, 264).reversedArray())
        val key = KeyFactory.getInstance("RSA").generatePublic(RSAPublicKeySpec(modulus, BigInteger.valueOf(65537)))
        // PKCS#1 v1.5 type 1 over DigestInfo(SHA-1) || token: what adbd verifies.
        val recovered = Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
            init(Cipher.DECRYPT_MODE, key)
            doFinal(identity.sign(token))
        }
        assertEquals("3021300906052b0e03021a05000414" + hex(token), hex(recovered))
        assertThrows(AdbFailure::class.java) { identity.sign(ByteArray(0)) }
    }

    @Test
    fun identityIsStoredInSecureStoreAndUnreadableFailsClosed() = runBlocking<Unit> {
        FakePlatform(initialSecurityLevel = SecurityLevel.TEE).use { platform ->
            val first = AdbIdentity.loadOrCreate(platform)
            val second = AdbIdentity.loadOrCreate(platform)
            assertNotSame(first, second)
            assertArrayEquals(first.publicKey(), second.publicKey())
            platform.markUnreadable(AdbIdentity.STORE_KEY, "key-invalidated")
            assertThrows(AdbFailure::class.java) { runBlocking { AdbIdentity.loadOrCreate(platform) } }
        }
    }

    @Test
    fun fragmentedShellFramesPreserveBinaryAndNonzeroExit() {
        val decoder = AdbShellDecoder(100)
        val stdout = byteArrayOf(0, 255.toByte(), 13, 10)
        val stream = shellFrame(1, stdout) + shellFrame(2, "error".toByteArray()) + shellFrame(3, byteArrayOf(7))
        for (byte in stream) decoder.append(byteArrayOf(byte))
        assertEquals(AdbShellResult(stdout, "error".toByteArray(), 7), decoder.finish())
        assertThrows(AdbFailure::class.java) { decoder.append(shellFrame(1, ByteArray(0))) }
    }

    @Test
    fun shellMissingExitAndOutputOverflowFail() {
        val decoder = AdbShellDecoder(4)
        decoder.append(shellFrame(1, byteArrayOf(1, 2, 3)))
        assertThrows(AdbFailure::class.java) { decoder.finish() }
        assertThrows(AdbFailure::class.java) { decoder.append(shellFrame(2, byteArrayOf(4, 5))) }
    }

    @Test
    fun authPublicKeyFallbackAndShellRoundTrip() = runBlocking<Unit> {
        val transport = ScriptedAdb(
            listOf(
                AdbPacket(AdbPacket.AUTH, 1, 0, ByteArray(20) { 1 }),
                AdbPacket(AdbPacket.AUTH, 1, 0, ByteArray(20) { 2 }),
                connected(),
                AdbPacket(AdbPacket.OKAY, 42, 1),
                AdbPacket(AdbPacket.OKAY, 42, 1),
                AdbPacket(AdbPacket.WRITE, 42, 1, shellFrame(1, "hello".toByteArray()) + shellFrame(3, byteArrayOf(0))),
                AdbPacket(AdbPacket.CLOSE, 42, 1),
            ),
        )
        val result = AdbClient.run(transport, newIdentity(), "echo hello", timeoutMillis = 1_000, outputLimit = 100)
        assertEquals("hello", String(result.stdout))
        assertEquals(
            listOf(AdbPacket.CONNECT, AdbPacket.AUTH, AdbPacket.AUTH, AdbPacket.OPEN, AdbPacket.WRITE, AdbPacket.OKAY, AdbPacket.CLOSE),
            transport.sent.map { it.le32(0) },
        )
        assertEquals(2L, transport.sent[1].le32(4))
        assertEquals(3L, transport.sent[2].le32(4))
        assertEquals("shell,v2,raw:echo hello\u0000", String(transport.sent[3].copyOfRange(24, transport.sent[3].size)))
        assertTrue(transport.closed)
    }

    @Test
    fun tlsAndUnexpectedStreamAreRejectedWithoutRetry() = runBlocking<Unit> {
        for (packets in listOf(listOf(AdbPacket(AdbPacket.TLS)), listOf(connected(), AdbPacket(AdbPacket.CLOSE, 0, 1)))) {
            val transport = ScriptedAdb(packets)
            assertThrows(AdbFailure::class.java) {
                runBlocking { AdbClient.run(transport, newIdentity(), "input tap 1 2", timeoutMillis = 1_000, outputLimit = 100) }
            }
            assertTrue(transport.sent.count { it.le32(0) == AdbPacket.OPEN } <= 1)
            assertTrue(transport.closed)
        }
    }

    @Test
    fun apkInputIsChunkedAcknowledgedAndClosedWhileReceivingOutput() = runBlocking<Unit> {
        val bytes = ByteArray(9000) { (it + 5).toByte() }
        val ack = AdbPacket(AdbPacket.OKAY, 42, 1)
        val output = AdbPacket(AdbPacket.WRITE, 42, 1, shellFrame(1, "Success\n".toByteArray()) + shellFrame(3, byteArrayOf(0)))
        val transport = ScriptedAdb(
            listOf(
                connected(), ack,
                AdbPacket(AdbPacket.WRITE, 42, 1, shellFrame(2, "progress".toByteArray())),
                ack, ack, ack, ack, output, AdbPacket(AdbPacket.CLOSE, 42, 1),
            ),
        )
        val result = AdbClient.run(transport, newIdentity(), "pm install -S 9000 -", bytes, 1_000, 100)
        assertEquals(0, result.exitCode)
        assertEquals("progress", String(result.stderr))
        val writes = transport.sent.filter { it.le32(0) == AdbPacket.WRITE }.map { it.copyOfRange(24, it.size) }
        assertEquals(4, writes.size)
        assertTrue(writes.all { it.size <= 4096 })
        assertEquals(listOf(4091L, 4091L, 818L), writes.dropLast(1).map { it.le32(1) })
        assertArrayEquals(bytes, writes.dropLast(1).fold(ByteArray(0)) { acc, w -> acc + w.copyOfRange(5, w.size) })
        assertArrayEquals(shellFrame(4, ByteArray(0)), writes.last())
        assertEquals("output is acknowledged before waiting for the upload ack", AdbPacket.OKAY, transport.sent[3].le32(0))
    }

    @Test
    fun earlyInstallExitStopsUploadAndRejectsPrematureSuccess() = runBlocking<Unit> {
        for (code in listOf(0, 1)) {
            val ack = AdbPacket(AdbPacket.OKAY, 42, 1)
            val transport = ScriptedAdb(
                listOf(
                    connected(), ack,
                    AdbPacket(AdbPacket.WRITE, 42, 1, shellFrame(3, byteArrayOf(code.toByte()))),
                    ack, AdbPacket(AdbPacket.CLOSE, 42, 1),
                ),
            )
            val outcome = runCatching {
                AdbClient.run(transport, newIdentity(), "pm install -S 9000 -", ByteArray(9000) { 1 }, 1_000, 100)
            }
            if (code == 0) assertTrue(outcome.isFailure) else assertEquals(1, outcome.getOrThrow().exitCode)
            assertEquals(1, transport.sent.count { it.le32(0) == AdbPacket.WRITE })
            assertTrue(transport.closed)
        }
    }

    @Test
    fun eofBeforeAnyAuthIsTypedUnreachable() {
        val failure = assertThrows(AdbFailure::class.java) {
            runBlocking {
                AdbClient.run(ScriptedAdb(ByteArray(0)), newIdentity(), "id",
                    timeoutMillis = 1_000, outputLimit = 100)
            }
        }
        assertEquals(AdbFailureKind.UNREACHABLE, failure.kind)
    }

    @Test
    fun eofDuringTheAuthHandshakeIsTypedUnauthorized() {
        val transport = ScriptedAdb(listOf(AdbPacket(AdbPacket.AUTH, 1, 0, ByteArray(20) { 1 })))
        val failure = assertThrows(AdbFailure::class.java) {
            runBlocking {
                AdbClient.run(transport, newIdentity(), "id", timeoutMillis = 1_000, outputLimit = 100)
            }
        }
        assertEquals(AdbFailureKind.UNAUTHORIZED, failure.kind)
        assertEquals(1, transport.sent.count { it.le32(0) == AdbPacket.AUTH })
    }

    @Test
    fun holdOpenAfterAuthTimesOutAsUnauthorized() {
        // adbd answers AUTH(1), then keeps the socket open while the TV shows
        // UsbDebuggingActivity; the probe timeout must be typed unauthorized so
        // the caller retries instead of reporting a plain failure.
        ServerSocket(0).use { listener ->
            val server = Thread {
                runCatching {
                    listener.accept().use { socket ->
                        val input = socket.getInputStream()
                        val header = ByteArray(24)
                        var read = 0
                        while (read < header.size) {
                            val n = input.read(header, read, header.size - read)
                            if (n < 0) return@use
                            read += n
                        }
                        socket.getOutputStream().run {
                            write(AdbPacket(AdbPacket.AUTH, 1, 0, ByteArray(20)).encoded())
                            flush()
                        }
                        Thread.sleep(2_000)
                    }
                }
            }.apply { isDaemon = true; start() }
            val failure = assertThrows(AdbFailure::class.java) {
                runBlocking {
                    AdbClient.run(AdbSocketTransport("127.0.0.1", listener.localPort), newIdentity(), "id",
                        timeoutMillis = 1_000, outputLimit = 100)
                }
            }
            assertEquals(AdbFailureKind.UNAUTHORIZED, failure.kind)
            server.interrupt()
        }
    }

    @Test
    fun realTcpTimeoutAndCancellationSettle() = runBlocking<Unit> {
        ServerSocket(0).use { listener ->
            val accepted = Thread { runCatching { while (true) listener.accept() } }.apply { isDaemon = true; start() }
            val identity = newIdentity()
            val started = System.nanoTime()
            val timedOut = runCatching {
                AdbClient.run(AdbSocketTransport("127.0.0.1", listener.localPort), identity, "id", timeoutMillis = 100, outputLimit = 100)
            }
            assertTrue(timedOut.exceptionOrNull() is AdbFailure)
            val task = async {
                AdbClient.run(AdbSocketTransport("127.0.0.1", listener.localPort), identity, "id", timeoutMillis = 30_000, outputLimit = 100)
            }
            delay(50)
            task.cancel()
            assertTrue(runCatching { task.await() }.isFailure)
            assertTrue((System.nanoTime() - started) / 1_000_000 < 3_000)
            accepted.interrupt()
        }
    }
}
