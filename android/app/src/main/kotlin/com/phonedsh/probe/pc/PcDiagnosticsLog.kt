// SPDX-License-Identifier: MIT
// Phone-side PCLink diagnostics (P18, PC-20261110-pclink-workspace-cache §2).
//
// The file is the only way to answer "the drawer said the PC was offline while
// it was working" from a device. Its input is a closed value, not a free-form
// string: state name, offline-reason name and a seconds gap. There is no title,
// message, pairing code, token or fingerprint parameter, so a caller cannot
// leak one even by accident.
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkOfflineReason
import java.io.File
import java.io.FileOutputStream
import java.time.Instant

/** One line: only the three values the design allows. */
internal data class PcDiagnosticEvent(
    val state: String,
    val reason: String? = null,
    /** Seconds since the connection was lost, only logged on `online`. */
    val gapSeconds: Double? = null,
)

/**
 * Append-only, size-bounded `filesDir/pclink-diag.log`.
 *
 * Rotation is one step (`pclink-diag.1.log`) so the pair is capped at ~512 KiB.
 * A missing file is an empty log, never an error; a failed append is dropped
 * rather than crashing the connection path.
 */
internal class PcDiagnosticsLog(
    private val directory: File,
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val maxBytes: Int = MAX_BYTES,
) {
    private val lock = Any()

    val file: File get() = File(directory, FILE_NAME)
    val rotatedFile: File get() = File(directory, ROTATED_FILE_NAME)

    fun append(event: PcDiagnosticEvent) {
        val safeState = safeToken(event.state)
        if (safeState.isEmpty()) return
        val safeReason = event.reason?.let(::safeToken)?.takeIf { it.isNotEmpty() }
        val gap = event.gapSeconds
            ?.takeIf { it.isFinite() && it >= 0.0 }
            ?.let { "gap=%.1fs".format(java.util.Locale.ROOT, it) }
        val line = buildString {
            append(Instant.ofEpochMilli(clockMillis()).toString())
            append(' ')
            append("state=")
            append(safeState)
            if (safeReason != null) {
                append(" reason=")
                append(safeReason)
            }
            if (gap != null) {
                append(' ')
                append(gap)
            }
        } + "\n"
        val bytes = line.toByteArray(Charsets.UTF_8)
        synchronized(lock) {
            try {
                if (!directory.isDirectory && !directory.mkdirs()) return
                if (bytes.size > maxBytes) return
                if (file.isFile && file.length() + bytes.size > maxBytes) rotateLocked()
                FileOutputStream(file, true).use { stream ->
                    stream.write(bytes)
                    stream.fd.sync()
                }
            } catch (_: Exception) {
                // Diagnostics are best-effort: a full disk must not break PCLink.
            }
        }
    }

    /** Lines currently in the live file, oldest first. */
    fun read(): List<String> = synchronized(lock) {
        if (!file.isFile) return emptyList()
        try {
            file.readLines(Charsets.UTF_8).filter { it.isNotEmpty() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** Lines preserved by the last rotation. */
    fun readRotated(): List<String> = synchronized(lock) {
        if (!rotatedFile.isFile) return emptyList()
        try {
            rotatedFile.readLines(Charsets.UTF_8).filter { it.isNotEmpty() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun rotateLocked() {
        if (rotatedFile.exists()) rotatedFile.delete()
        if (file.exists()) file.renameTo(rotatedFile)
    }

    /**
     * One stable lower-case token. Dots are kept because reason names use them;
     * everything that could carry a message (spaces, `=`, quotes, newlines) is
     * folded to `_`. The log format therefore can never be confused by input.
     */
    private fun safeToken(raw: String): String = buildString {
        for (character in raw.lowercase()) {
            if (character in 'a'..'z' || character in '0'..'9' || character == '_' || character == '.') {
                append(character)
            } else {
                append('_')
            }
        }
    }.take(64)

    companion object {
        const val FILE_NAME: String = "pclink-diag.log"
        const val ROTATED_FILE_NAME: String = "pclink-diag.1.log"
        const val MAX_BYTES: Int = 256 * 1024

        /** A stable case name for every offline reason; never a localized message. */
        fun reasonName(reason: PclinkOfflineReason?): String? = when (reason) {
            null -> null
            PclinkOfflineReason.NotStarted -> "not_started"
            PclinkOfflineReason.Network -> "network"
            PclinkOfflineReason.PeerOffline -> "peer_offline"
            PclinkOfflineReason.Replaced -> "replaced"
            PclinkOfflineReason.AuthenticationFailed -> "authentication_failed"
            PclinkOfflineReason.VersionUnsupported -> "version_unsupported"
            PclinkOfflineReason.UnpairedPrompt -> "unpaired_prompt"
            is PclinkOfflineReason.ProtocolError -> "protocol_error"
            is PclinkOfflineReason.Storage -> "storage"
        }
    }
}
