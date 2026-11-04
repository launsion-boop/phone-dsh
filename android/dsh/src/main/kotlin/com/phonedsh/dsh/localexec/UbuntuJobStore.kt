// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the durable job records.
// SPDX-License-Identifier: MIT
//
// ---- the one property this file has to have ---------------------------------
// After a process kill a job must still be readable, and its `egress` /
// `authorityExited` testimony must still be exactly what was true when it was
// written. So every save is `Durability.atomicReplace` (temp sibling, fsync,
// rename, directory fsync — the rule wal.md §7.1 sets for the manifest and
// `HostStateStore` reuses), one file per job, and a read never guesses: an
// unreadable file, an unknown `version` or a `state` spelling this build does not
// have returns `null` instead of a default. A record this build cannot name is
// not a record it may claim to have recovered.
//
// ---- why JSON and not the WAL ----------------------------------------------
// These are host-side observations, not workspace mutations: they are not part of
// the `mseq` sequence, they never enter the materialized copy and they are never
// handed to a Worker. `host-state.json` is the precedent — the App's own record
// of its own decisions lives beside the workspace, not inside it.
//
// ---- the audit line ---------------------------------------------------------
// The saved record *is* the audit line: `env`, `argvDigest` (never `argv`),
// `label`, `egress`, `authorityExited`, the limits that were in force and every
// timestamp. `argv` is deliberately absent — a command line is where a credential
// leaks (bridge.md §5's "no credential" rule for messages applies to the audit
// too), and the digest is enough to correlate a job with the tool call that
// asked for it.

package com.phonedsh.dsh.localexec

import com.phonedsh.dsh.host.HostLog
import com.phonedsh.platform.Durability
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Reads and writes one JSON record per job under [dir]. */
class UbuntuJobStore(
    val dir: Path,
    private val durability: Durability,
    private val logger: HostLog = HostLog.None,
) {
    /** The file one job's record lives in. */
    fun file(jobId: String): Path = dir.resolve("$jobId.json")

    /** Persists [record]; `false` means the previous file is still there. */
    suspend fun save(record: UbuntuJobRecord): Boolean {
        val bytes = encode(record).toByteArray(Charsets.UTF_8)
        return try {
            Files.createDirectories(dir)
            durability.atomicReplace(file(record.jobId)) { temporary -> Files.write(temporary, bytes) }
            true
        } catch (failure: IOException) {
            logger.error(
                "cannot persist job ${record.jobId} (${failure.javaClass.simpleName}); " +
                    "the in-memory record is unchanged",
            )
            false
        }
    }

    /** Every readable record, in job-id order; unreadable files are skipped and logged. */
    suspend fun loadAll(): List<UbuntuJobRecord> {
        val files = dir.toFile().listFiles { candidate -> candidate.isFile && candidate.name.endsWith(".json") }
            ?: return emptyList()
        return files.sortedBy { it.name }.mapNotNull { candidate -> read(candidate.toPath()) }
    }

    /** One record, or `null` when there is none this build can trust. */
    suspend fun load(jobId: String): UbuntuJobRecord? = read(file(jobId))

    private fun read(path: Path): UbuntuJobRecord? {
        if (!Files.isRegularFile(path)) return null
        val text = try {
            String(Files.readAllBytes(path), Charsets.UTF_8)
        } catch (failure: IOException) {
            logger.warn("job record $path is unreadable (${failure.javaClass.simpleName}); skipping")
            return null
        }
        return try {
            decode(JSONObject(text))
        } catch (failure: JSONException) {
            logger.warn("job record $path does not parse (${failure.javaClass.simpleName}); skipping")
            null
        }
    }

    companion object {
        /** The record version; a reader refuses anything else instead of guessing. */
        const val VERSION: Int = 1

        private const val KEY_VERSION = "version"
        private const val KEY_JOB_ID = "job_id"
        private const val KEY_ENV = "env"
        private const val KEY_STATE = "state"
        private const val KEY_SEQ = "seq"
        private const val KEY_CREATED_AT = "created_at_ms"
        private const val KEY_UPDATED_AT = "updated_at_ms"
        private const val KEY_EGRESS = "egress"
        private const val KEY_AUTHORITY_EXITED = "authority_exited"
        private const val KEY_ARGV_DIGEST = "argv_digest"
        private const val KEY_ARGV_LENGTH = "argv_length"
        private const val KEY_CWD = "cwd"
        private const val KEY_WORKSPACE = "workspace"
        private const val KEY_LABEL = "label"
        private const val KEY_JOB_TIMEOUT = "job_timeout_ms"
        private const val KEY_LIMITS = "limits"
        private const val KEY_LIMIT_FILE = "file"
        private const val KEY_LIMIT_WORKSPACE = "workspace"
        private const val KEY_LIMIT_RSS = "rss"
        private const val KEY_EXIT_CODE = "exit_code"
        private const val KEY_LOG_TAIL = "log_tail"
        private const val KEY_ARTIFACTS = "artifacts"
        private const val KEY_ARTIFACT_NAME = "name"
        private const val KEY_ARTIFACT_BYTES = "bytes"
        private const val KEY_ARTIFACT_SHA = "sha256"
        private const val KEY_ARTIFACT_STATE = "state"
        private const val KEY_ARTIFACT_PATH = "path"
        private const val KEY_ARTIFACT_REFUSAL = "refusal"
        private const val KEY_REFUSAL_CODE = "code"
        private const val KEY_REFUSAL_REASON = "reason"
        private const val KEY_REFUSAL_LIMIT = "limit"
        private const val KEY_REFUSAL_BYTES = "bytes"
        private const val KEY_FAILURE = "failure"
        private const val KEY_FAILURE_CODE = "code"
        private const val KEY_FAILURE_MESSAGE = "message"
        private const val KEY_FAILURE_OUTCOME = "outcome"
        private const val KEY_FAILURE_RETRYABLE = "retryable"
        private const val KEY_FAILURE_FOREGROUND = "foreground_required"
        private const val KEY_FAILURE_CAUSE = "cause"
        private const val KEY_OBSERVED = "internal_access_observed"
        private const val KEY_SEAL_STATE = "seal_state"
        private const val KEY_SEAL_REASON = "seal_reason"
        private const val KEY_APPROVAL = "approval"
        private const val KEY_APPROVAL_STATE = "state"
        private const val KEY_APPROVAL_SESSION = "session_id"
        private const val KEY_APPROVAL_AT = "at_ms"

        /** The record as canonical-ish JSON; the member names are this file's, not the wire's. */
        fun encode(record: UbuntuJobRecord): String {
            val limits = JSONObject()
                .put(KEY_LIMIT_FILE, record.limits.fileLimitBytes)
                .put(KEY_LIMIT_WORKSPACE, record.limits.workspaceLimitBytes)
                .put(KEY_LIMIT_RSS, record.limits.rssLimitBytes ?: JSONObject.NULL)
            val artifacts = JSONArray()
            record.artifacts.forEach { artifact ->
                val entry = JSONObject()
                    .put(KEY_ARTIFACT_NAME, artifact.name)
                    .put(KEY_ARTIFACT_BYTES, artifact.bytes)
                    .put(KEY_ARTIFACT_SHA, artifact.sha256 ?: JSONObject.NULL)
                    .put(KEY_ARTIFACT_STATE, artifact.state.wire)
                    .put(KEY_ARTIFACT_PATH, artifact.path ?: JSONObject.NULL)
                val refusal = artifact.refusal
                entry.put(
                    KEY_ARTIFACT_REFUSAL,
                    if (refusal == null) {
                        JSONObject.NULL
                    } else {
                        JSONObject()
                            .put(KEY_REFUSAL_CODE, refusal.code)
                            .put(KEY_REFUSAL_REASON, refusal.reason)
                            .put(KEY_REFUSAL_LIMIT, refusal.limit)
                            .put(KEY_REFUSAL_BYTES, refusal.bytes)
                    },
                )
                artifacts.put(entry)
            }
            val failure = record.failure
            val failureJson = if (failure == null) {
                JSONObject.NULL
            } else {
                JSONObject()
                    .put(KEY_FAILURE_CODE, failure.code)
                    .put(KEY_FAILURE_MESSAGE, failure.message)
                    .put(KEY_FAILURE_OUTCOME, failure.outcome)
                    .put(KEY_FAILURE_RETRYABLE, failure.retryable)
                    .put(KEY_FAILURE_FOREGROUND, failure.foregroundRequired)
                    .put(KEY_FAILURE_CAUSE, failure.cause ?: JSONObject.NULL)
            }
            // The session approval is part of the audit: who allowed this job,
            // when, and whether the user was asked now or earlier in the session.
            val approval = record.approval
            val approvalJson = if (approval == null) {
                JSONObject.NULL
            } else {
                JSONObject()
                    .put(KEY_APPROVAL_STATE, approval.state.wire)
                    .put(KEY_APPROVAL_SESSION, approval.sessionId ?: JSONObject.NULL)
                    .put(KEY_APPROVAL_AT, approval.atMs)
            }
            return JSONObject()
                .put(KEY_VERSION, VERSION)
                .put(KEY_JOB_ID, record.jobId)
                .put(KEY_ENV, record.env)
                .put(KEY_STATE, record.state.wire)
                .put(KEY_SEQ, record.seq)
                .put(KEY_CREATED_AT, record.createdAtMs)
                .put(KEY_UPDATED_AT, record.updatedAtMs)
                .put(KEY_EGRESS, record.egress)
                .put(KEY_AUTHORITY_EXITED, record.authorityExited ?: JSONObject.NULL)
                .put(KEY_ARGV_DIGEST, record.argvDigest)
                .put(KEY_ARGV_LENGTH, record.argvLength)
                .put(KEY_CWD, record.cwd)
                .put(KEY_WORKSPACE, record.workspace)
                .put(KEY_LABEL, record.label ?: JSONObject.NULL)
                .put(KEY_JOB_TIMEOUT, record.jobTimeoutMs)
                .put(KEY_LIMITS, limits)
                .put(KEY_EXIT_CODE, record.exitCode ?: JSONObject.NULL)
                .put(KEY_LOG_TAIL, record.logTail)
                .put(KEY_ARTIFACTS, artifacts)
                .put(KEY_FAILURE, failureJson)
                .put(KEY_OBSERVED, record.internalAccessObserved ?: JSONObject.NULL)
                .put(KEY_SEAL_STATE, record.seal.wire)
                .put(KEY_SEAL_REASON, record.sealReason ?: JSONObject.NULL)
                .put(KEY_APPROVAL, approvalJson)
                .toString()
        }

        /** The record [json] describes, or `null` when this build cannot claim it. */
        fun decode(json: JSONObject): UbuntuJobRecord? {
            if (json.optInt(KEY_VERSION, -1) != VERSION) return null
            val state = UbuntuJobState.ofWire(json.optString(KEY_STATE, "")) ?: return null
            val seal = UbuntuSealState.ofWire(json.optString(KEY_SEAL_STATE, "")) ?: return null
            val limits = json.getJSONObject(KEY_LIMITS)
            val limitsValue = UbuntuJobLimits(
                fileLimitBytes = limits.getLong(KEY_LIMIT_FILE),
                workspaceLimitBytes = limits.getLong(KEY_LIMIT_WORKSPACE),
                rssLimitBytes = limits.optionalLong(KEY_LIMIT_RSS),
            )
            val artifacts = mutableListOf<UbuntuArtifactRecord>()
            val array = json.optJSONArray(KEY_ARTIFACTS) ?: JSONArray()
            for (index in 0 until array.length()) {
                val entry = array.getJSONObject(index)
                val entryState = UbuntuArtifactState.ofWire(entry.optString(KEY_ARTIFACT_STATE, ""))
                    ?: return null
                val refusal = entry.optJSONObject(KEY_ARTIFACT_REFUSAL)?.let { refusalJson ->
                    UbuntuVfsRefusal(
                        reason = refusalJson.getString(KEY_REFUSAL_REASON),
                        limit = refusalJson.getLong(KEY_REFUSAL_LIMIT),
                        bytes = refusalJson.getLong(KEY_REFUSAL_BYTES),
                        code = refusalJson.optString(KEY_REFUSAL_CODE, UbuntuVfsRefusal.CODE),
                    )
                }
                artifacts += UbuntuArtifactRecord(
                    name = entry.getString(KEY_ARTIFACT_NAME),
                    bytes = entry.getLong(KEY_ARTIFACT_BYTES),
                    sha256 = entry.optionalString(KEY_ARTIFACT_SHA),
                    state = entryState,
                    path = entry.optionalString(KEY_ARTIFACT_PATH),
                    refusal = refusal,
                )
            }
            val failureJson = json.optJSONObject(KEY_FAILURE)
            val failure = failureJson?.let {
                UbuntuJobFailure(
                    code = it.getString(KEY_FAILURE_CODE),
                    message = it.getString(KEY_FAILURE_MESSAGE),
                    outcome = it.getString(KEY_FAILURE_OUTCOME),
                    retryable = it.getBoolean(KEY_FAILURE_RETRYABLE),
                    foregroundRequired = it.optBoolean(KEY_FAILURE_FOREGROUND, false),
                    cause = it.optionalString(KEY_FAILURE_CAUSE),
                )
            }
            // A record written before the approval gate has no member: `null` is
            // "this record cannot say", never "the user approved".
            val approval = json.optJSONObject(KEY_APPROVAL)?.let { approvalJson ->
                val approvalState = UbuntuApprovalState.ofWire(approvalJson.optString(KEY_APPROVAL_STATE, ""))
                    ?: return null
                UbuntuJobApproval(
                    state = approvalState,
                    sessionId = approvalJson.optionalString(KEY_APPROVAL_SESSION),
                    atMs = approvalJson.getLong(KEY_APPROVAL_AT),
                )
            }
            return UbuntuJobRecord(
                jobId = json.getString(KEY_JOB_ID),
                env = json.getString(KEY_ENV),
                state = state,
                seq = json.getInt(KEY_SEQ),
                createdAtMs = json.getLong(KEY_CREATED_AT),
                updatedAtMs = json.getLong(KEY_UPDATED_AT),
                egress = json.getBoolean(KEY_EGRESS),
                authorityExited = json.optionalString(KEY_AUTHORITY_EXITED),
                argvDigest = json.getString(KEY_ARGV_DIGEST),
                argvLength = json.getInt(KEY_ARGV_LENGTH),
                cwd = json.getString(KEY_CWD),
                workspace = json.getString(KEY_WORKSPACE),
                limits = limitsValue,
                label = json.optionalString(KEY_LABEL),
                exitCode = json.optionalInt(KEY_EXIT_CODE),
                logTail = json.optString(KEY_LOG_TAIL, ""),
                artifacts = artifacts,
                failure = failure,
                internalAccessObserved = json.optionalBoolean(KEY_OBSERVED),
                seal = seal,
                sealReason = json.optionalString(KEY_SEAL_REASON),
                jobTimeoutMs = json.getLong(KEY_JOB_TIMEOUT),
                approval = approval,
            )
        }

        private fun JSONObject.optionalString(key: String): String? =
            if (!has(key) || isNull(key)) null else optString(key)

        private fun JSONObject.optionalLong(key: String): Long? =
            if (!has(key) || isNull(key)) null else optLong(key)

        private fun JSONObject.optionalInt(key: String): Int? =
            if (!has(key) || isNull(key)) null else optInt(key)

        private fun JSONObject.optionalBoolean(key: String): Boolean? =
            if (!has(key) || isNull(key)) null else optBoolean(key)
    }
}
