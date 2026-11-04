// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the mock external environment.
// SPDX-License-Identifier: MIT
//
// ---- what this is -----------------------------------------------------------
// The in-process stand-in for a local Ubuntu environment: no proot, no rootfs, no
// package manager. It delays, then exits with a code, then serves a fixed
// artifact manifest. That is enough to prove the part of the contract a mock can
// prove — the job machine, the budgets, the ingest precheck and the recovery
// rows — and it proves nothing about a real environment, which is the point of
// saying "mock" in the name.
//
// ---- why the three artifacts are the sizes they are -------------------------
// bridge.md §12.7 makes 15 MiB the per-*mutation* bound and lets an environment
// raise the per-*artifact* bound to the tier's `single_file_limit`. The three
// entries sit on both sides of that line:
//
//   * `tiny.txt`   12 bytes            — the ordinary case;
//   * `mid.bin`    15 MiB + 512 KiB    — over one mutation, under 16 MiB: it can
//                                        only land as a complete write plus one
//                                        appended suffix, which is the chain
//                                        channel.md §6 already fixes;
//   * `huge.bin`   20 MiB              — over a 16 MiB bound and over the default
//                                        15 MiB bound: refused, and the refusal
//                                        is the "job succeeded, ingest failed"
//                                        path of bridge.md §12.7.
//
// `mid.bin` is exactly `BIG = 15 MiB + 512 KiB` so the append boundary is a
// number a test can assert byte for byte, and `huge.bin` is exactly 20 MiB so the
// refusal's `limit` and `bytes` are both round numbers.
//
// ---- the bytes are generated, never stored ----------------------------------
// A 20 MiB array per job would make the tests allocate for no reason. Byte `i` of
// an artifact is a function of `(name, i)`, so a test can verify any range
// without the adapter ever holding the whole file — and `readArtifact` is a real
// range read of a deterministic stream, which is what the fetch contract is
// about.

package com.phonedsh.dsh.localexec

import com.phonedsh.platform.Clock

/** The in-process fake adapter (see the file header for what it does and does not prove). */
class MockUbuntuAdapter(
    override val env: String = DEFAULT_ENV,
    override val egress: Boolean = false,
    override val authorityExited: String = UbuntuJobRecord.AUTHORITY_WORKER_VFS,
    override val fileLimitBytes: Long = UbuntuJobLimits.DEFAULT_FILE_LIMIT_BYTES,
    override val rssLimitBytes: Long? = null,
    private val clock: Clock,
    /** How long the fake command runs before it exits. */
    private val delayMillis: Long = DEFAULT_DELAY_MS,
    /** The exit code a completed run reports. */
    private val exitCode: Int = 0,
    /** `true` when `stop` may claim the environment will report an exit. */
    private val stopsCleanly: Boolean = true,
    /** The manifest the finished job reports. */
    val manifest: List<UbuntuArtifactLine> = DEFAULT_MANIFEST,
) : UbuntuAdapter {

    private val started = mutableMapOf<String, Long>()
    private val stopped = mutableSetOf<String>()
    private val alive = mutableSetOf<String>()

    /** How many times `start` was called; a fail-closed test asserts this stays 0. */
    var startCount: Int = 0
        private set

    /** How many times `stop` was called. */
    var stopCount: Int = 0
        private set

    /** The argv of the last accepted start, so a test can assert the command that ran. */
    var lastArgv: List<String>? = null
        private set

    override suspend fun start(jobId: String, argv: List<String>, cwd: String): UbuntuStartAck {
        startCount += 1
        lastArgv = argv
        started[jobId] = clock.nowMillis()
        alive += jobId
        stopped -= jobId
        return UbuntuStartAck.Accepted
    }

    override suspend fun poll(jobId: String): UbuntuAdapterStatus {
        if (jobId !in alive) return UbuntuAdapterStatus.Gone
        val beganAt = started[jobId] ?: return UbuntuAdapterStatus.Gone
        if (jobId in stopped) {
            // A stopped command still reports an exit: 124 is exec.md's deadline
            // value, and it is a result, not an infrastructure failure.
            alive -= jobId
            return UbuntuAdapterStatus.Exited(DEADLINE_EXIT_CODE, tail(jobId), manifest)
        }
        val elapsed = clock.nowMillis() - beganAt
        if (elapsed < delayMillis) return UbuntuAdapterStatus.Running(tail(jobId))
        alive -= jobId
        return UbuntuAdapterStatus.Exited(exitCode, tail(jobId), manifest)
    }

    override suspend fun stop(jobId: String): Boolean {
        stopCount += 1
        if (!stopsCleanly) return false
        if (jobId in alive) stopped += jobId
        return true
    }

    override suspend fun readArtifact(
        jobId: String,
        name: String,
        offset: Long,
        length: Int,
    ): UbuntuArtifactChunk? {
        val line = manifest.firstOrNull { it.name == name } ?: return null
        if (offset < 0 || length < 0 || offset > line.bytes) return null
        val end = minOf(offset + length, line.bytes)
        val size = (end - offset).toInt()
        val bytes = ByteArray(size) { index -> byteAt(name, offset + index) }
        return UbuntuArtifactChunk(bytes, eof = end >= line.bytes)
    }

    private fun tail(jobId: String): String = "mock $env: $jobId\n"

    companion object {
        const val DEFAULT_ENV = "ubuntu-24.04"

        /** Long enough that `submit` returns before the job could have finished. */
        const val DEFAULT_DELAY_MS = 120L

        /** exec.md's deadline exit value. */
        const val DEADLINE_EXIT_CODE = 124

        /** 15 MiB, channel.md §6's per-mutation bound. */
        const val MID_BYTES: Long = 15L * UbuntuJobLimits.MIB + 512L * 1024L

        /** 20 MiB, above the 16 MiB floor and the 15 MiB default. */
        const val HUGE_BYTES: Long = 20L * UbuntuJobLimits.MIB

        val DEFAULT_MANIFEST: List<UbuntuArtifactLine> = listOf(
            UbuntuArtifactLine("tiny.txt", 12),
            UbuntuArtifactLine("mid.bin", MID_BYTES),
            UbuntuArtifactLine("huge.bin", HUGE_BYTES),
        )

        /** The deterministic byte at [index] of artifact [name]. */
        fun byteAt(name: String, index: Long): Byte {
            var value = name.hashCode().toLong() and 0xFFFF
            value = (value * 31 + index * 7 + 11) and 0xFF
            return value.toByte()
        }
    }
}
