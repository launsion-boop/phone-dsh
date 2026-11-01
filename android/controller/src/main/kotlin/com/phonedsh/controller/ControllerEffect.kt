// phone-dsh Android — :controller effects emitted by accepted D14 transitions.
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

/**
 * One externally visible action a transition obliges the facade to perform.
 * The state machine is pure: it never performs these itself, it only records
 * the D14 "Actions" column so a test (and the future facade) can execute and
 * audit them.
 */
enum class ControllerEffect(val label: String) {
    CLOSE_ADMISSION("close admission"),
    OPEN_ADMISSION("open admission"),
    ARM_DRAIN_DEADLINE("arm the 20 s drain deadline"),
    START_BACKGROUND_TASK("start the background task"),
    FORCE_DRAIN_DEADLINE("force the 20 s drain deadline"),
    CANCEL_IN_FLIGHT_REQUESTS("abort in-flight channel requests"),
    CLOSE_EPOCH("close the WAL epoch"),
    FSYNC_MATERIALIZED("fsync the materialized copy"),
    START_WORKER("start the worker"),
    STOP_WORKER("stop the worker"),
    RESTART_WORKER("restart the worker"),
    VERIFY_LEASE("verify the lease"),
    SEND_FENCE("send FENCE"),
    SEND_LIFECYCLE_OPEN("send LIFECYCLE open"),
    START_RETRY_SCHEDULE("start the retry schedule"),
    FREEZE_WAL_SEQ("freeze wal_seq"),
    REMOTE_HOLDS_AUTHORITY("the remote holds execution authority"),
    KEEP_WAL_READ_ONLY("keep the local WAL read-only"),
    POST_RECLAIM_TOKEN("POST the reclaim token"),
    APPLY_RECLAIM_RESPONSE("apply the reclaim response and segments"),
    PERSIST_HOST_STATE("persist host-state.json atomically"),
    RECORD_FAILURE("record the failure condition"),
    KEEP_DURABLE_BYTES("keep every durable WAL and journal byte"),
    RE_RUN_RECOVERY("re-run recovery"),
    LIMIT_SUB_AGENTS("cap sub-agents at 1"),
    NO_NEW_SUB_AGENTS("allow no new sub-agents"),
    PAUSE_ACCELERATORS("LIFECYCLE pause at the next tool-call boundary"),
    NO_OPTIONAL_ACCELERATORS("disable optional accelerators"),
}
