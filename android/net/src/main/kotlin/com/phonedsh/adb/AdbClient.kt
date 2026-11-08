// phone-dsh — :net / com.phonedsh.adb: one shell_v2 command over LAN TCP/IP ADB.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBClient.swift` and `ADBTransport.swift`.
// Each command owns its TCP connection. A deadline or a cancellation closes that
// connection; a command is never retried after OPEN because it may mutate the
// device. TLS (Android 11+ wireless-debugging pairing) is refused, exactly as on
// iOS: only the classic `adb tcpip` port is supported.
//
// The streaming FileHandle transfer of the Swift client (the Worker `adb push` /
// `adb pull` accelerator) is not ported: Android does not advertise
// `accelerator:adb` (see docs/protocol-changes/PC-20261108-android-adb-host.md).

package com.phonedsh.adb

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A validated ADB target. */
public data class AdbEndpoint(public val host: String, public val port: Int) {
    public companion object {
        public fun of(host: String, port: Int = 5555): AdbEndpoint {
            val trimmed = host.trim()
            if (trimmed.isEmpty() || trimmed.length > 253 || port !in 1..65535 ||
                trimmed.any { it.isWhitespace() || it in "/\\@?#" }
            ) {
                throw AdbFailure("Enter an Android IP address or hostname and a port from 1 to 65535")
            }
            return AdbEndpoint(trimmed, port)
        }
    }
}

/** Blocking byte transport; [close] must unblock a pending [read]/[write]. */
public interface AdbTransport : AutoCloseable {
    public fun start()
    public fun read(count: Int): ByteArray
    public fun write(bytes: ByteArray)
    override fun close()
}

/** Plain TCP to `host:port`. */
public class AdbSocketTransport(private val host: String, private val port: Int) : AdbTransport {
    private val socket = Socket()
    private var input: InputStream? = null
    private var output: OutputStream? = null

    override fun start() {
        socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        socket.tcpNoDelay = true
        input = socket.getInputStream()
        output = socket.getOutputStream()
    }

    override fun read(count: Int): ByteArray {
        val stream = input ?: throw AdbFailure("ADB connection is not open")
        val out = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val n = stream.read(out, offset, count - offset)
            if (n < 0) throw AdbFailure("ADB connection closed; check authorization and TCP/IP debugging")
            offset += n
        }
        return out
    }

    override fun write(bytes: ByteArray) {
        val stream = output ?: throw AdbFailure("ADB connection is not open")
        stream.write(bytes)
        stream.flush()
    }

    override fun close() {
        runCatching { socket.close() }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
    }
}

/** What the MCP server needs from ADB; tests substitute a recorder. */
public interface AdbCommandExecuting {
    public suspend fun shell(
        endpoint: AdbEndpoint,
        command: String,
        stdin: ByteArray = ByteArray(0),
        timeoutMillis: Long = 30_000,
        outputLimit: Int = 8 * 1024 * 1024,
    ): AdbShellResult
}

/** The production executor: a fresh TCP connection and the stored identity per command. */
public class AdbClient(
    private val identity: suspend () -> AdbIdentity,
    private val transport: (AdbEndpoint) -> AdbTransport = { AdbSocketTransport(it.host, it.port) },
) : AdbCommandExecuting {
    override suspend fun shell(
        endpoint: AdbEndpoint,
        command: String,
        stdin: ByteArray,
        timeoutMillis: Long,
        outputLimit: Int,
    ): AdbShellResult = run(transport(endpoint), identity(), command, stdin, timeoutMillis, outputLimit)

    public companion object {
        /**
         * Runs [command] on [transport] with a wall-clock [timeoutMillis]. The
         * deadline and coroutine cancellation both close the transport, which
         * unblocks the IO thread; the outcome is then reported as an error, never
         * retried.
         */
        public suspend fun run(
            transport: AdbTransport,
            identity: AdbIdentity,
            command: String,
            stdin: ByteArray = ByteArray(0),
            timeoutMillis: Long,
            outputLimit: Int,
        ): AdbShellResult {
            if (command.contains('\u0000') || command.toByteArray(Charsets.UTF_8).size >= 3800 ||
                stdin.size > 128 * 1024 * 1024 || timeoutMillis !in 100..3_600_000 ||
                outputLimit !in 1..1_073_741_824
            ) {
                throw AdbFailure("Invalid ADB command or execution limits")
            }
            val timedOut = AtomicBoolean(false)
            return coroutineScope {
                val guard = launch(Dispatchers.IO) {
                    try {
                        delay(timeoutMillis)
                        timedOut.set(true)
                    } finally {
                        transport.close()
                    }
                }
                try {
                    withContext(Dispatchers.IO) { blocking(transport, identity, command, stdin, outputLimit) }
                } catch (failure: CancellationException) {
                    throw failure
                } catch (failure: IOException) {
                    // A cancellation closed the socket: report the cancellation, not the IO error.
                    currentCoroutineContext().ensureActive()
                    if (timedOut.get()) throw AdbFailure("Android command timed out; its outcome is unknown")
                    throw AdbFailure(failure.message ?: "ADB connection failed")
                } catch (failure: AdbFailure) {
                    currentCoroutineContext().ensureActive()
                    if (timedOut.get()) throw AdbFailure("Android command timed out; its outcome is unknown")
                    throw failure
                } finally {
                    guard.cancel()
                    transport.close()
                }
            }
        }

        internal fun blocking(
            transport: AdbTransport,
            identity: AdbIdentity,
            command: String,
            stdin: ByteArray,
            outputLimit: Int,
        ): AdbShellResult {
            transport.start()
            transport.write(
                AdbPacket(AdbPacket.CONNECT, 0x01000000, 4096, "host::features=shell_v2;\u0000".toByteArray()).encoded(),
            )
            var authStep = 0
            while (true) {
                val packet = AdbPacket.read(transport)
                if (packet.command == AdbPacket.CONNECT) {
                    val banner = String(packet.payload, Charsets.UTF_8)
                    val features = banner.split("features=").drop(1).firstOrNull()
                        ?.split(';', '\u0000')?.firstOrNull()?.split(',').orEmpty()
                    if ("shell_v2" !in features) throw AdbFailure("Android does not advertise shell_v2 (Android 7+ required)")
                    if (packet.arg1 < 4096) throw AdbFailure("Unsupported ADB packet limit")
                    break
                }
                if (packet.command == AdbPacket.TLS) {
                    throw AdbFailure(
                        "TLS wireless-debugging ports are not supported; use the Android TCP/IP ADB port, usually 5555",
                    )
                }
                if (packet.command != AdbPacket.AUTH || packet.arg0 != 1L || authStep >= 2) {
                    throw AdbFailure("ADB authorization refused; unlock Android and accept this phone's debugging key")
                }
                val data = if (authStep == 0) identity.sign(packet.payload) else identity.publicKey()
                transport.write(AdbPacket(AdbPacket.AUTH, if (authStep == 0) 2L else 3L, 0L, data).encoded())
                authStep += 1
            }
            transport.write(
                AdbPacket(AdbPacket.OPEN, 1, 0, ("shell,v2,raw:$command\u0000").toByteArray(Charsets.UTF_8)).encoded(),
            )
            val opened = AdbPacket.read(transport)
            if (opened.command != AdbPacket.OKAY || opened.arg1 != 1L || opened.arg0 == 0L) {
                throw AdbFailure("Android refused the shell service")
            }
            val remote = opened.arg0
            // One unacknowledged WRTE at a time. Keep consuming output while
            // uploading: pm can reject an APK before consuming all its bytes.
            var inputOffset = 0
            var inputClosed = false
            fun sendInput() {
                val frame = ByteArrayOutputStream()
                if (inputOffset < stdin.size) {
                    val count = minOf(4091, stdin.size - inputOffset)
                    frame.write(0)
                    frame.appendLe(count.toLong())
                    frame.write(stdin, inputOffset, count)
                    inputOffset += count
                } else {
                    frame.write(4)
                    frame.appendLe(0)
                    inputClosed = true
                }
                transport.write(AdbPacket(AdbPacket.WRITE, 1, remote, frame.toByteArray()).encoded())
            }
            sendInput()
            val decoder = AdbShellDecoder(outputLimit)
            while (true) {
                if (Thread.currentThread().isInterrupted) throw AdbFailure("Android operation cancelled")
                val packet = AdbPacket.read(transport)
                if (packet.arg0 != remote || packet.arg1 != 1L) throw AdbFailure("ADB stream identity mismatch")
                when (packet.command) {
                    AdbPacket.WRITE -> {
                        decoder.append(packet.payload)
                        transport.write(AdbPacket(AdbPacket.OKAY, 1, remote).encoded())
                    }
                    AdbPacket.CLOSE -> {
                        transport.write(AdbPacket(AdbPacket.CLOSE, 1, remote).encoded())
                        val result = decoder.finish()
                        if (result.exitCode == 0 && inputOffset != stdin.size) {
                            throw AdbFailure("Android exited before receiving the entire input")
                        }
                        return result
                    }
                    AdbPacket.OKAY -> if (!inputClosed && !decoder.exited) sendInput()
                    else -> throw AdbFailure("Unexpected ADB stream packet")
                }
            }
        }
    }
}
