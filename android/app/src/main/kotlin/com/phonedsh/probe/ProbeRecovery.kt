// phone-dsh — :app: the one surface that reports a previous process death.
// SPDX-License-Identifier: MIT
//
// Three things a killed process can no longer say out loud are collected here,
// and each of them becomes a log line AND a visible banner. Without this file the
// probe app recovers correctly but silently: the WAL truncates a torn tail with
// no sink, the reclaim-token vault answers `Unreadable` to nobody, and the
// interrupted-turn marker is never written because only `:dsh`'s background
// facade knows about it.
//
//   * torn WAL tail -- `wal.md` section 10 step 2 requires the truncation to be
//     logged with boot id, segment, byte offset and dropped bytes. `WorkspaceLog`
//     defaults to a sink that drops everything, so the composition root supplies
//     [walSink] and nothing is silent.
//   * interrupted turn -- `InterruptedTurnStore` is the durable tombstone written
//     before a turn starts and removed only when the turn ends explicitly. The
//     marker is written here and removed through `HostBackground`, which also
//     closes the turn's background window, so the marker and the window belong to
//     the same turn.
//   * reclaim token -- the vault's `SecureLookup.Unreadable` is fail-closed
//     (plan section 11-R11): it must never be shown as "no token". The probe has
//     no handoff endpoint, so what this file can prove is the vault primitive the
//     reclaim token uses, not an end-to-end token exchange.
//
// Nothing here writes token bytes to a log or to the UI: only the lookup state
// and the safe `reason` label are ever printed.

package com.phonedsh.probe

import android.content.Context
import android.content.Intent
import android.util.Log
import com.phonedsh.dsh.background.InterruptedTurnStore
import com.phonedsh.log.WalLogEvent
import com.phonedsh.log.WalLogSink
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.android.AndroidSecureStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.runBlocking

/**
 * One thing that must not be silent, in the form the banner renders.
 *
 * [priority] decides which notice wins when more than one fires; the banner keeps
 * the most severe one rather than replacing a token failure with a WAL warning.
 */
internal data class RecoveryNotice(
    val kind: Kind,
    val title: String,
    val detail: String,
) {
    enum class Kind(val priority: Int) {
        WAL_RECOVERY_FAILED(5),
        WAL_UNAVAILABLE(4),
        SECURE_UNREADABLE(3),
        WAL_TRUNCATED(2),
        TURN_INTERRUPTED(1),
    }
}

/**
 * The probe app's fail-loud collector.
 *
 * Installed by `MainActivity.onCreate` before the engine exists. Every method is
 * safe to call from any thread: [notice] is a `StateFlow`, and the blocking vault
 * read runs on its own thread.
 */
internal object ProbeRecovery {
    private const val TAG_RECOVERY = "PDSHRecovery"
    private const val TAG_WAL = "PDSHWal"
    private const val TAG_SECURE = "PDSHSecure"

    /** The vault account the handoff lane would use (`spec/v1/handoff.md` section 5). */
    const val RECLAIM_TOKEN_KEY: String = "reclaim-token"

    /** Launch extra: `put`, `get` or `del`. Development builds only. */
    private const val EXTRA_OP = "pdsh.secure.op"

    /** Launch extra: the value `put` stores. It is never logged. */
    private const val EXTRA_VALUE = "pdsh.secure.value"

    private val mutableNotice = MutableStateFlow<RecoveryNotice?>(null)

    /** The current notice, or `null` when nothing is wrong. */
    val notice: StateFlow<RecoveryNotice?> = mutableNotice.asStateFlow()

    /** The WAL's diagnostic sink; assigned into `WorkspaceLog` by the composition root. */
    val walSink: WalLogSink = WalLogSink { event ->
        when (event) {
            is WalLogEvent.TruncatedTail -> {
                // Boot id, segment, kept length and dropped bytes: exactly the four
                // values `wal.md` section 10 step 2 requires. No payload bytes.
                Log.w(
                    TAG_WAL,
                    "WAL_TORN_TAIL_TRUNCATED boot=${event.bootId} segment=${event.segment.fileName} " +
                        "keep_len=${event.keepLen} dropped_bytes=${event.droppedBytes} " +
                        "previous_len=${event.previousLength}",
                )
                raise(
                    RecoveryNotice(
                        kind = RecoveryNotice.Kind.WAL_TRUNCATED,
                        title = "WAL 尾部被截断",
                        detail = "纪元内最后一次写入不完整，已丢弃 ${event.droppedBytes} 字节；" +
                            "已确认的改动仍在。",
                    ),
                )
            }

            is WalLogEvent.EmptySegmentDropped -> Log.w(
                TAG_WAL,
                // `wal.md` §7.2's required diagnostic. An empty segment holds no
                // header and no record: dropping it is not data loss, so it is a
                // log line, not a banner. `removed=false` means only the cleanup
                // failed; the file was still excluded from recovery.
                "WAL_EMPTY_SEGMENT_DROPPED segment=${event.segment.fileName}" +
                    if (event.removed) "" else " removed=false",
            )

            is WalLogEvent.ResyncRequired -> Log.w(
                TAG_WAL,
                "WAL_RESYNC_REQUIRED mseq=${event.mseq}",
            )

            is WalLogEvent.RecoveryFailed -> {
                // The code alone is not a reason: a `WAL_RECORD_TOO_LARGE`
                // refusal has to say which record and which bound, or the user
                // cannot act on `Failed` (budgets.md §1). The detail is
                // workspace-relative and never carries payload bytes.
                Log.e(TAG_WAL, "WAL_RECOVERY_FAILED code=${event.code} detail=${event.detail}")
                raise(
                    RecoveryNotice(
                        kind = RecoveryNotice.Kind.WAL_RECOVERY_FAILED,
                        title = "工作区恢复失败（${event.code}）",
                        detail = event.detail,
                    ),
                )
            }
        }
    }

    /**
     * Reports a host HELLO without `wal/1`, which is the one state the screen
     * otherwise shows as healthy.
     *
     * Measured 2026-11-01 after an abrupt VM kill: WAL recovery failed
     * (`WAL_CORRUPT`, two zero-byte segment files left by the kill) and the host
     * advertised no `wal/1`, yet the screen said 「运行中」 while the packaged
     * worker refused to boot with `PROTO_MISMATCH: host HELLO lacks ... wal/1`.
     * A recovery failure must reach the user, not only logcat.
     */
    fun raiseWalUnavailable(hostCaps: List<String>) {
        Log.e(TAG_WAL, "WAL_UNAVAILABLE host_caps=${hostCaps.joinToString(",")}")
        raise(
            RecoveryNotice(
                kind = RecoveryNotice.Kind.WAL_UNAVAILABLE,
                title = "工作区不可用（wal/1 off）",
                detail = "宿主 HELLO 没有 wal/1：工作区恢复失败，Worker 会以 PROTO_MISMATCH 拒绝启动，" +
                    "本回合的任何改动都不会落盘。",
            ),
        )
    }

    /**
     * Withdraws [raiseWalUnavailable] when a merged HELLO does carry `wal/1`.
     *
     * The engine publishes an intermediate handshake with empty host capabilities
     * before the host caps merge, so "no wal/1" is only meaningful once the list is
     * non-empty. The caller applies that guard; this method undoes a notice the
     * intermediate summary raised.
     */
    fun clearWalUnavailable() {
        if (mutableNotice.value?.kind == RecoveryNotice.Kind.WAL_UNAVAILABLE) {
            Log.i(TAG_WAL, "WAL_UNAVAILABLE withdrawn: merged HELLO carries wal/1")
            mutableNotice.value = null
        }
    }

    /**
     * Writes the durable turn marker before the turn starts and returns its epoch.
     *
     * `commit()` inside the store is what makes this survive a process kill; a
     * turn that ends through an explicit path calls [endTurn]. The epoch is
     * returned because the background window is opened for the *same* turn: the
     * services write the marker again with the epoch in the request, and two
     * different epochs for one turn would make the tombstone name the wrong one.
     */
    fun beginTurn(context: Context): Long {
        val epoch = System.currentTimeMillis()
        InterruptedTurnStore(context.applicationContext).begin(epoch = epoch, step = 0)
        Log.i(TAG_RECOVERY, "TURN_MARKER_WRITTEN epoch=$epoch")
        return epoch
    }

    /**
     * Removes the marker and closes the turn's background window.
     *
     * Only an explicit end (completed, failed, cancelled) calls this. The window
     * is closed through `HostBackground` because that is the one place that knows
     * both channels; clearing the marker here as well is what keeps a turn that
     * never opened a window (foreground-only) from reporting a fake interruption
     * on the next launch.
     */
    fun endTurn(context: Context) {
        HostBackground.endTurn(context)
        Log.i(TAG_RECOVERY, "TURN_MARKER_CLEARED")
    }

    /**
     * Reports a previous process death and the vault state, once, on a worker
     * thread.
     *
     * The interrupted-turn marker is consumed: a report shown once must not
     * reappear on every launch (the store's own next-open contract).
     */
    fun auditAsync(context: Context) {
        val app = context.applicationContext
        val thread = Thread(
            {
                runCatching { runBlocking { audit(app) } }
                    .onFailure { failure ->
                        Log.e(TAG_RECOVERY, "AUDIT_FAILED reason=${failure.javaClass.simpleName}")
                    }
            },
            "pdsh-recovery-audit",
        )
        thread.isDaemon = true
        thread.start()
    }

    private suspend fun audit(context: Context) {
        reportInterruptedTurn(context)
        reportReclaimToken(context)
    }

    private fun reportInterruptedTurn(context: Context) {
        val store = InterruptedTurnStore(context.applicationContext)
        val turn = store.interrupted() ?: run {
            Log.i(TAG_RECOVERY, "TURN_INTERRUPTED_PREVIOUS none")
            return
        }
        // A null reason is the zero-callback case (force-stop, SIGKILL, LMK): the
        // platform gave the process no chance to explain, and the report says that
        // instead of guessing a reason.
        val reason = turn.reason?.name ?: "NO_CALLBACK"
        val age = (System.currentTimeMillis() - turn.recordedAt).coerceAtLeast(0L)
        Log.w(
            TAG_RECOVERY,
            "TURN_INTERRUPTED_PREVIOUS epoch=${turn.epoch} step=${turn.step} reason=$reason " +
                "recorded_at=${turn.recordedAt} age_ms=$age",
        )
        raise(
            RecoveryNotice(
                kind = RecoveryNotice.Kind.TURN_INTERRUPTED,
                title = "上次回合被中断",
                detail = "第 ${turn.step} 步之后进程被杀（原因：$reason）；会话已从 WAL 恢复，" +
                    "该回合没有 turn/end 记录。",
            ),
        )
        store.complete()
    }

    private suspend fun reportReclaimToken(context: Context) {
        val store = AndroidSecureStore(context.applicationContext) { message ->
            Log.d(TAG_SECURE, message)
        }
        when (val lookup = store.get(RECLAIM_TOKEN_KEY)) {
            is SecureLookup.Found -> Log.i(
                TAG_SECURE,
                "RECLAIM_TOKEN_FOUND bytes=${lookup.value.size} level=${store.level}",
            )

            SecureLookup.Absent -> Log.i(
                TAG_SECURE,
                "RECLAIM_TOKEN_ABSENT level=${store.level}",
            )

            is SecureLookup.Unreadable -> {
                // Fail-closed, never "no token": the user must be told, because the
                // only remaining path is a manual re-pair of the remote host.
                Log.e(
                    TAG_SECURE,
                    "RECLAIM_TOKEN_UNREADABLE reason=${lookup.reason} level=${store.level}",
                )
                raise(
                    RecoveryNotice(
                        kind = RecoveryNotice.Kind.SECURE_UNREADABLE,
                        title = "回收凭据失效",
                        detail = "reclaim token 存在但读不出（reason=${lookup.reason}）；" +
                            "不能当成「没有 token」重建，需要人工重新配对远端。",
                    ),
                )
            }
        }
    }

    /**
     * Runs one vault operation named by the launch intent; development builds only.
     *
     * This is the reclaim-token matrix's device harness: the scenarios (lock-screen
     * credential change, reinstall, restore without the Keystore key) each change
     * the device state behind the vault, and one `put`/`get` pair is the
     * observation. Only the lookup state and safe reason are logged.
     */
    fun handleDiagnosticIntent(context: Context, intent: Intent?, debuggable: Boolean) {
        if (!debuggable) return
        val op = intent?.getStringExtra(EXTRA_OP)?.trim()?.lowercase() ?: return
        if (op !in setOf("put", "get", "del")) {
            Log.w(TAG_SECURE, "SECURE_OP_UNKNOWN op=$op")
            return
        }
        val app = context.applicationContext
        val value = intent.getStringExtra(EXTRA_VALUE)
        val thread = Thread(
            {
                runBlocking {
                    val store = AndroidSecureStore(app) { message ->
                        Log.d(TAG_SECURE, message)
                    }
                    when (op) {
                        "put" -> {
                            if (value == null || value.isEmpty()) {
                                Log.e(TAG_SECURE, "SECURE_OP_FAILED op=put reason=no-value")
                                return@runBlocking
                            }
                            runCatching { store.put(RECLAIM_TOKEN_KEY, value.toByteArray()) }
                                .onSuccess {
                                    Log.i(TAG_SECURE, "SECURE_OP_OK op=put key=$RECLAIM_TOKEN_KEY")
                                }
                                .onFailure { failure ->
                                    Log.e(
                                        TAG_SECURE,
                                        "SECURE_OP_FAILED op=put reason=${failure.javaClass.simpleName}",
                                    )
                                }
                        }

                        "get" -> when (val lookup = store.get(RECLAIM_TOKEN_KEY)) {
                            is SecureLookup.Found -> Log.i(
                                TAG_SECURE,
                                "SECURE_OP_OK op=get key=$RECLAIM_TOKEN_KEY result=found " +
                                    "bytes=${lookup.value.size}",
                            )

                            SecureLookup.Absent -> Log.i(
                                TAG_SECURE,
                                "SECURE_OP_OK op=get key=$RECLAIM_TOKEN_KEY result=absent",
                            )

                            is SecureLookup.Unreadable -> Log.e(
                                TAG_SECURE,
                                "SECURE_OP_OK op=get key=$RECLAIM_TOKEN_KEY result=unreadable " +
                                    "reason=${lookup.reason}",
                            )
                        }

                        "del" -> {
                            runCatching { store.delete(RECLAIM_TOKEN_KEY) }
                                .onSuccess {
                                    Log.i(TAG_SECURE, "SECURE_OP_OK op=del key=$RECLAIM_TOKEN_KEY")
                                }
                                .onFailure { failure ->
                                    Log.e(
                                        TAG_SECURE,
                                        "SECURE_OP_FAILED op=del reason=${failure.javaClass.simpleName}",
                                    )
                                }
                        }
                    }
                }
            },
            "pdsh-secure-op",
        )
        thread.isDaemon = true
        thread.start()
    }

    private fun raise(notice: RecoveryNotice) {
        val current = mutableNotice.value
        if (current != null && current.kind.priority > notice.kind.priority) {
            Log.i(TAG_RECOVERY, "notice suppressed kind=${notice.kind} by=${current.kind}")
            return
        }
        mutableNotice.value = notice
    }
}
