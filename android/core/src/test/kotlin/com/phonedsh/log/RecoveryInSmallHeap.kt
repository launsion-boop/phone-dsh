// Test harness: recover one workspace in a heap-bounded child JVM.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.nio.file.Paths
import kotlinx.coroutines.runBlocking

/**
 * Runs [WorkspaceLog.recover] for the workspace at `args[0]` in a JVM whose
 * heap is bounded by the caller (`-Xmx`).
 *
 * `BigWorkspaceRecoveryTest` uses it to reproduce the P19 condition without a
 * device: the old recovery decoded every retained 15 MiB record and its
 * `data_hex` JSON, which cannot fit in 128 MiB; the streaming recovery can.
 * The exit code is the assertion: 0 only for `Recovered`.
 */
object RecoveryInSmallHeap {
    @JvmStatic
    fun main(args: Array<String>) {
        val root = Paths.get(args[0])
        val log = newLog(root, RecordingDurability(root), bootId = BootId.random())
        when (val outcome = runBlocking { log.recover() }) {
            is RecoveryOutcome.Recovered -> println(
                "RECOVERED next_mseq=${outcome.nextMseq} acked=${outcome.effectiveTail} " +
                    "records=${outcome.recordCount}",
            )

            is RecoveryOutcome.Failed -> {
                println("FAILED code=${outcome.code} detail=${outcome.detail}")
                kotlin.system.exitProcess(1)
            }
        }
    }
}
