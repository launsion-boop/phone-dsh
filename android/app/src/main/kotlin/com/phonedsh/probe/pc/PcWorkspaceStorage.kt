// SPDX-License-Identifier: MIT
// P18 storage for the PC workspace: the drawer backend selection, the last
// workspace per paired PC and the offline roster cache (design §5.3).
//
// Two authorities, deliberately not one:
//   * `phone-dsh.drawer.backend` and `phone-dsh.pc.last-workspace.<machineId>`
//     are small preferences, so they go through the existing `PreferenceFile`
//     seam (`PreferenceStore.kt`) rather than a fourth SharedPreferences file.
//   * `phone-dsh.pc.session-snapshot.<machineId>` is the larger roster
//     envelope. C4 owns its codec (`PclinkRosterCache`), so this class supplies
//     only the directory and the per-PC file names; the envelope/bare fallback,
//     unknown-version rule and "never write an empty list" rule stay in C4.
//
// The transcript snapshot path named by the same P18 row
// (`filesDir/transcript-snapshots/<scope>/<sessionID>.json`) belongs to the
// chat/transcript lane; this class only lists its constants so the P18 owner
// registers one set of paths, and it is not used by the workspace controller.
package com.phonedsh.probe.pc

import com.phonedsh.pclink.PclinkRosterCache
import com.phonedsh.pclink.PclinkRosterCacheEntry
import com.phonedsh.pclink.PclinkRosterSnapshot
import com.phonedsh.pclink.PclinkValidation
import com.phonedsh.probe.PreferenceFile
import java.nio.file.Path

/** The drawer's two backend segments; values are the frozen P18 wire values. */
enum class PcBackend(val wire: String) {
    PHONE("phone"),
    PC("pc"),
    ;

    companion object {
        /** Unknown or absent resolves to `phone`, never to a guessed segment. */
        fun fromWire(value: String?): PcBackend =
            entries.firstOrNull { it.wire == value } ?: PHONE
    }
}

/** One stored PC scope, read together so a caller cannot mix two machines. */
internal data class PcStoredWorkspace(
    val machineId: String,
    val lastWorkspaceId: String?,
    val roster: PclinkRosterCacheEntry,
)

/**
 * The P18 preference keys and the C4 roster cache under one small facade.
 *
 * All writes go through `commit*`/the C4 atomic writer: the drawer must not
 * read back a segment it only `apply()`-ed before a kill.
 */
internal class PcWorkspaceStorage(
    private val preferences: PreferenceFile,
    rosterDirectory: Path,
) {
    private val rosterCache = PclinkRosterCache(rosterDirectory)

    init {
        // Keep the directory name in one place and make the report's registered
        // path impossible to drift: the actual file is `<dir>/<machineId>.json`.
        require(rosterDirectory.fileName?.toString()?.isNotEmpty() == true) {
            "roster directory needs a name"
        }
    }

    // ---- Drawer backend -------------------------------------------------

    fun readBackend(): PcBackend = PcBackend.fromWire(preferences.string(DRAWER_BACKEND_KEY))

    fun writeBackend(backend: PcBackend): Boolean {
        // `putString` is the existing seam's durable-enough write (the same one
        // `PreferenceStore.setAppearance` uses). The drawer selection is an
        // `apply`-class preference; a blocking `commit` on the UI thread would
        // be the wrong trade for one segment.
        return preferences.putString(DRAWER_BACKEND_KEY, backend.wire) &&
            readBackend() == backend
    }

    // ---- Last workspace per PC -----------------------------------------

    fun readLastWorkspace(machineId: String): String? {
        PclinkValidation.requireMachineId(machineId)
        return preferences.string(lastWorkspaceKey(machineId))?.takeIf { it.isNotBlank() }
    }

    fun writeLastWorkspace(machineId: String, workspaceId: String): Boolean {
        PclinkValidation.requireMachineId(machineId)
        if (workspaceId.isBlank()) return false
        val key = lastWorkspaceKey(machineId)
        return preferences.putString(key, workspaceId) && preferences.string(key) == workspaceId
    }

    fun removeLastWorkspace(machineId: String) {
        PclinkValidation.requireMachineId(machineId)
        preferences.remove(lastWorkspaceKey(machineId))
    }

    // ---- Offline roster snapshot (C4 codec) ----------------------------

    fun readRoster(machineId: String): PclinkRosterCacheEntry = rosterCache.read(machineId)

    fun writeRoster(
        machineId: String,
        snapshot: PclinkRosterSnapshot,
        capturedAtMilliseconds: Long,
    ): Boolean = rosterCache.write(machineId, snapshot, capturedAtMilliseconds)

    fun removeRoster(machineId: String): Boolean = rosterCache.remove(machineId)

    /** Reads the two per-PC facts together; the roster may be missing. */
    fun readWorkspace(machineId: String): PcStoredWorkspace = PcStoredWorkspace(
        machineId = machineId,
        lastWorkspaceId = readLastWorkspace(machineId),
        roster = readRoster(machineId),
    )

    /**
     * Unpair removes exactly this PC scope. The other machine's roster file,
     * the drawer selection and every phone-scope key are untouched.
     */
    fun removePcScope(machineId: String) {
        removeLastWorkspace(machineId)
        removeRoster(machineId)
    }

    private fun lastWorkspaceKey(machineId: String): String = "$LAST_WORKSPACE_PREFIX$machineId"

    companion object {
        /** P18 D2: `phone` | `pc`, default `phone`. */
        const val DRAWER_BACKEND_KEY: String = "phone-dsh.drawer.backend"

        /** P18 v1.5: the DSH workspace id last used for a new PC session. */
        const val LAST_WORKSPACE_PREFIX: String = "phone-dsh.pc.last-workspace."

        /**
         * The logical P18 key for the roster envelope. The Android value is the
         * C4 file `<rosterDir>/<machineId>.json` (the P18 row explicitly allows
         * a JSON file for larger snapshots); the prefix is kept here so the P18
         * owner has one spelling to register.
         */
        const val SESSION_SNAPSHOT_PREFIX: String = "phone-dsh.pc.session-snapshot."

        /** `filesDir/pclink/session-snapshot/<machineId>.json`. */
        const val ROSTER_DIRECTORY: String = "pclink/session-snapshot"

        /** `filesDir/transcript-snapshots/<scope>/<sessionID>.json` (P18 row). */
        const val TRANSCRIPT_SNAPSHOT_DIRECTORY: String = "transcript-snapshots"

        /** P18 caps from `PC-20261110-pclink-workspace-cache` §2. */
        const val TRANSCRIPT_MAX_ITEMS: Int = 400
        const val TRANSCRIPT_MAX_BYTES: Int = 512 * 1024
        const val TRANSCRIPT_MAX_ITEM_CHARS: Int = 4_096
        const val TRANSCRIPT_MAX_TITLE_CHARS: Int = 256
        const val TRANSCRIPT_MAX_FILES: Int = 200
    }
}
