// phone-dsh — :dsh / com.phonedsh.dsh.host: `host-state.json`, the D14 boot record.
// SPDX-License-Identifier: MIT
//
// ---- the hole this file closes ---------------------------------------------
// The controller emits `ControllerEffect.PERSIST_HOST_STATE` on every accepted
// transition *and* on its boot mapping (ControllerStateMachine.transition() and
// boot()), but no code in `:app` ever wrote the file: the composition root
// booted with a literal `ControllerStateMachine.boot(persistedState = null)`,
// so every start was `COLD_START`. budgets.md §3's boot mapping — persisted
// `Parked` -> `Parked`, persisted `Backoff` -> `Backoff`, persisted
// `HandingOff` -> `Failed` — was therefore unreachable on Android: a process
// killed while `Parked` came back as a cold start instead of `PARKED_RESUME`,
// and the nine-state table's persisted rows could not be exercised at all.
//
// ---- the record ------------------------------------------------------------
// The shape is the Swift reference's (`Sources/PhoneDSHController/
// HostStateMachine.swift`, `PersistedHostState`), so a workspace written by one
// port stays readable by the other:
//
//   { "version": 1, "state": "parked", "updated_at_ms": 0,
//     "reason": null, "backoff_until_ms": null,
//     "boot_disposition": "parked_resume", "boot_reason": "persisted_parked" }
//
// `state` uses the Swift raw spellings (`running`, `handingOff`, ...), not the
// D14 display names, because that is what an existing file already contains.
//
// ---- what this store deliberately does not do ------------------------------
//   * It never invents a state: an absent, unreadable or unknown-version file
//     returns `null`, which the caller maps to "no persisted state" (the boot
//     row that already exists). It does not fall back to `Parked` or `Running`.
//   * It is synchronous and atomic. `Durability.atomicReplace` writes a
//     temporary sibling, fsyncs it, renames it over the target and fsyncs the
//     directory, so a kill can never leave half a JSON document behind — the
//     one property that makes reading the file at boot safe. The write happens
//     inside the transition that produced it (the Swift reference does the
//     same) so the file never describes a state older than the last recorded
//     transition.
//   * A write failure is *not* a D14 transition: §2 has no row for it, so it is
//     logged and the next transition retries. The state machine is unchanged.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.HostState
import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.json.JSONException
import org.json.JSONObject

/**
 * Reads and writes the persisted D14 host state.
 *
 * @param file `host-state.json` under the workspace root.
 * @param durability the `:platform` atomic-write SPI.
 * @param clock the wall clock, for `updated_at_ms` and `backoff_until_ms`
 *   (both are wall-clock facts a later process must be able to compare).
 */
class HostStateStore(
    val file: Path,
    private val durability: Durability,
    private val clock: Clock,
    private val logger: HostLog = HostLog.None,
) {
    /**
     * One readable `host-state.json`.
     *
     * @param state the persisted D14 state, already parsed against the closed
     *   nine-state set.
     * @param updatedAtMillis when the record was written.
     * @param reason the failure code of a persisted `Failed`, if any.
     * @param backoffUntilMillis the wall-clock deadline of a persisted
     *   `Backoff`, `null` outside it or when the record predates the field.
     * @param bootDisposition why the process that wrote the record booted.
     * @param bootReason the machine-readable boot cause of that process.
     */
    data class Record(
        val state: HostState,
        val updatedAtMillis: Long,
        val reason: String?,
        val backoffUntilMillis: Long?,
        val bootDisposition: String?,
        val bootReason: String?,
    )

    /**
     * The record on disk, or `null` when there is none this build can trust.
     *
     * `null` covers: no file, unreadable file, unparsable JSON, an unknown
     * `version`, and an unknown `state` spelling. In every case the caller
     * boots as "no persisted state" — the honest mapping, because a state this
     * build cannot name is not a state it may claim to have restored.
     */
    fun load(): Record? {
        if (!Files.isRegularFile(file)) return null
        val text = try {
            // `Files.readString` is API 33; minSdk is 26, so read the bytes.
            String(Files.readAllBytes(file), Charsets.UTF_8)
        } catch (failure: IOException) {
            logger.warn(
                "host-state.json is unreadable (${failure.javaClass.simpleName}); " +
                    "booting as no persisted state",
            )
            return null
        }
        return try {
            parse(JSONObject(text))
        } catch (failure: JSONException) {
            logger.warn(
                "host-state.json does not parse (${failure.javaClass.simpleName}); " +
                    "booting as no persisted state",
            )
            null
        }
    }

    /**
     * Persists the current state of [machine].
     *
     * @param backoffUntilMillis `RetryLane.backoffUntilMillis`, so a boot into
     *   `Backoff` can restore the rest of the window instead of starting a new
     *   one.
     * @return `true` when the record is on disk. A `false` is logged here and
     *   means "the previous record is still there"; it never throws, because
     *   the D14 state has already been recorded and there is no row that a
     *   failed write could move it to.
     */
    fun save(machine: ControllerStateMachine, backoffUntilMillis: Long? = null): Boolean {
        val record = JSONObject()
            .put(KEY_VERSION, VERSION)
            .put(KEY_STATE, spelling(machine.state))
            .put(KEY_UPDATED_AT, clock.nowMillis())
            .put(KEY_REASON, machine.lastFailure?.code ?: JSONObject.NULL)
            .put(
                KEY_BACKOFF_UNTIL,
                if (machine.state == HostState.BACKOFF && backoffUntilMillis != null) {
                    backoffUntilMillis
                } else {
                    JSONObject.NULL
                },
            )
            .put(KEY_BOOT_DISPOSITION, machine.bootDisposition.wireName)
            .put(KEY_BOOT_REASON, machine.bootReason)
        val bytes = record.toString().toByteArray(Charsets.UTF_8)
        return try {
            runBlocking {
                durability.atomicReplace(file) { temporary -> Files.write(temporary, bytes) }
            }
            true
        } catch (failure: IOException) {
            logger.warn(
                "cannot persist host-state.json (${failure.javaClass.simpleName}); " +
                    "the D14 state is unchanged and the next transition retries",
            )
            false
        }
    }

    private fun parse(json: JSONObject): Record? {
        val version = json.optInt(KEY_VERSION, -1)
        if (version != VERSION) {
            logger.warn("host-state.json has version $version; this build writes $VERSION")
            return null
        }
        val raw = json.optString(KEY_STATE, "")
        val state = stateOf(raw)
        if (state == null) {
            logger.warn("host-state.json names a state this build does not have: '$raw'")
            return null
        }
        return Record(
            state = state,
            updatedAtMillis = json.optLong(KEY_UPDATED_AT, 0L),
            reason = json.optionalString(KEY_REASON),
            backoffUntilMillis = json.optionalLong(KEY_BACKOFF_UNTIL),
            bootDisposition = json.optionalString(KEY_BOOT_DISPOSITION),
            bootReason = json.optionalString(KEY_BOOT_REASON),
        )
    }

    private fun JSONObject.optionalString(key: String): String? =
        if (!has(key) || isNull(key)) null else optString(key)

    private fun JSONObject.optionalLong(key: String): Long? =
        if (!has(key) || isNull(key)) null else optLong(key)

    companion object {
        /** The record version; a reader refuses anything else instead of guessing. */
        const val VERSION: Int = 1

        const val FILE_NAME: String = "host-state.json"

        private const val KEY_VERSION = "version"
        private const val KEY_STATE = "state"
        private const val KEY_UPDATED_AT = "updated_at_ms"
        private const val KEY_REASON = "reason"
        private const val KEY_BACKOFF_UNTIL = "backoff_until_ms"
        private const val KEY_BOOT_DISPOSITION = "boot_disposition"
        private const val KEY_BOOT_REASON = "boot_reason"

        /**
         * The Swift raw spelling of each state.
         *
         * `HostState.wireName` is the D14 display name (`HandingOff`); the
         * persisted format uses the Swift `HostState` raw value (`handingOff`),
         * and the comparison on read is case-insensitive so a hand-edited file
         * or an older writer cannot make the record unreadable.
         */
        private val SPELLINGS: Map<String, HostState> = mapOf(
            "running" to HostState.RUNNING,
            "draining" to HostState.DRAINING,
            "parked" to HostState.PARKED,
            "recovering" to HostState.RECOVERING,
            "backoff" to HostState.BACKOFF,
            "handingoff" to HostState.HANDING_OFF,
            "remote" to HostState.REMOTE,
            "reclaiming" to HostState.RECLAIMING,
            "failed" to HostState.FAILED,
        )

        /** The persisted spelling of [state]; see [SPELLINGS]. */
        fun spelling(state: HostState): String =
            if (state == HostState.HANDING_OFF) "handingOff" else state.wireName.lowercase()

        /** The state named by [raw], or `null` when this build has no such state. */
        fun stateOf(raw: String): HostState? = SPELLINGS[raw.trim().lowercase()]
    }
}
