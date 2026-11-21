// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.content.Context
import android.os.UserManager
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.workDataOf
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.phonedsh.probe.admission.ProcessAdmissionJournal
import com.phonedsh.probe.cloudtasks.CloudTaskCenter
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Process-owned wake projection. WorkManager sees deadlines, not engine state or credentials. */
internal class HostWakeScheduler private constructor(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val ledger by lazy { WakeDemandLedger(File(context.filesDir, "host-wake/demands.json")) }
    private var residentWake: (suspend () -> Unit)? = null
    private var timer: Job? = null
    private var lastFired: List<WakeDemand> = emptyList()
    private var projectedDemandAt: Long? = null

    val isUnlocked: Boolean get() = context.getSystemService(UserManager::class.java).isUserUnlocked

    fun enterForeground(wake: suspend () -> Unit) {
        schedule { residentWake = wake; lastFired = emptyList() }
    }

    fun leaveForeground() {
        schedule { residentWake = null }
    }

    fun set(demand: WakeDemand) = schedule { ledger.update(demand.identity, demand) }

    fun keepEarliest(demand: WakeDemand) = schedule {
        val previous = ledger.read().firstOrNull { it.identity == demand.identity }
        if (previous == null || previous.dueAtMs > demand.dueAtMs) {
            ledger.update(demand.identity, demand)
        }
    }

    suspend fun consumeDue(key: WakeDemandKey): Boolean {
        if (!isUnlocked) return false
        val consumed = CompletableDeferred<Boolean>()
        schedule {
            try {
                val record = ledger.read().firstOrNull { it.identity == key }
                val due = record != null && record.dueAtMs <= System.currentTimeMillis()
                if (due) ledger.update(key, null)
                consumed.complete(due)
            } catch (failure: Exception) {
                consumed.completeExceptionally(failure)
            }
        }.invokeOnCompletion { cause ->
            if (!consumed.isCompleted) {
                if (cause != null) consumed.completeExceptionally(cause)
                else consumed.complete(false)
            }
        }
        return consumed.await()
    }

    fun remove(key: WakeDemandKey) = schedule { ledger.update(key, null) }

    fun refresh() = schedule {}

    fun read(): List<WakeDemand> {
        check(isUnlocked) { "Wake demands are unavailable before unlock" }
        return ledger.read()
    }

    private fun schedule(update: () -> Unit): Job {
        // Mutations and their projections are serialized in enqueue order.
        return synchronized(this) {
            val previous = projection
            scope.launch {
                previous?.join()
                if (!isUnlocked) return@launch
                try {
                    update()
                    reproject()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    Log.w(TAG, "Wake demand unavailable: ${failure.javaClass.simpleName}")
                }
            }.also { projection = it }
        }
    }

    private var projection: Job? = null

    private fun reproject() {
        val now = System.currentTimeMillis()
        val records = read()
        lastFired = lastFired.intersect(records.toSet()).toList()
        val wake = residentWake
        val plan = WakeProjection.plan(now, wake != null, records)
        val earliestDemand = records.minOfOrNull { it.dueAtMs }
        if (earliestDemand != projectedDemandAt || earliestDemand == null) {
            submit(plan.backgroundEarliestMs, ExistingWorkPolicy.REPLACE)
            projectedDemandAt = earliestDemand
        }
        timer?.cancel()
        timer = null
        if (wake == null) return
        // An unchanged overdue demand must not spin the resident timer while
        // its owner is still waiting for execution eligibility.
        val remaining = records.filterNot { it in lastFired }
        val next = WakeProjection.plan(now, true, remaining).residentTimerAtMs ?: return
        timer = scope.launch {
            delay((next - System.currentTimeMillis()).coerceAtLeast(0))
            val dueAt = System.currentTimeMillis()
            schedule {
                lastFired = (lastFired + remaining.filter { it.dueAtMs <= dueAt }).distinct()
                if (residentWake === wake) scope.launch { wake() }
            }
        }
    }

    fun projectAfterWorker() {
        val now = System.currentTimeMillis()
        val future = read().filter { it.dueAtMs > now }
        val next = WakeProjection.plan(now, false, future).backgroundEarliestMs
        if (next != null) submit(next, ExistingWorkPolicy.APPEND_OR_REPLACE)
    }

    fun onCloudPush() {
        try {
            val request = OneTimeWorkRequestBuilder<HostWakeWorker>()
                .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
                .setInputData(workDataOf("cloudPush" to true))
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                CLOUD_PUSH, ExistingWorkPolicy.APPEND_OR_REPLACE, request,
            )
        } catch (failure: IllegalStateException) {
            Log.w(TAG, "Push scheduling unavailable: ${failure.javaClass.simpleName}")
        }
    }

    /** Periodic polling is the v1 cloud fallback when no push transport exists. */
    fun setCloudPolling(enabled: Boolean) {
        try {
            val manager = WorkManager.getInstance(context)
            if (!enabled) {
                manager.cancelUniqueWork(CLOUD_POLL)
                return
            }
            val request = PeriodicWorkRequestBuilder<HostWakeWorker>(15, TimeUnit.MINUTES)
                .setInitialDelay(15, TimeUnit.MINUTES)
                .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
                .setInputData(workDataOf("cloudPoll" to true))
                .build()
            manager.enqueueUniquePeriodicWork(CLOUD_POLL, ExistingPeriodicWorkPolicy.KEEP, request)
        } catch (failure: IllegalStateException) {
            Log.w(TAG, "Cloud poll scheduling unavailable: ${failure.javaClass.simpleName}")
        }
    }

    private fun submit(deadline: Long?, policy: ExistingWorkPolicy) {
        val manager = WorkManager.getInstance(context)
        if (deadline == null) {
            manager.cancelUniqueWork(WORK)
            return
        }
        val request = OneTimeWorkRequestBuilder<HostWakeWorker>()
            .setInitialDelay((deadline - System.currentTimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
            .build()
        manager.enqueueUniqueWork(WORK, policy, request)
    }

    companion object {
        private const val TAG = "PhoneDshWake"
        private const val WORK = "pdsh.host.wake"
        private const val CLOUD_POLL = "pdsh.host.cloud-poll"
        private const val CLOUD_PUSH = "pdsh.host.cloud-push"
        @Volatile private var instance: HostWakeScheduler? = null

        fun get(context: Context): HostWakeScheduler = instance ?: synchronized(this) {
            instance ?: HostWakeScheduler(context.applicationContext).also { instance = it }
        }
    }
}

/** A worker can settle native stores and admit cloud tasks without constructing the ViewModel. */
class HostWakeWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val scheduler = HostWakeScheduler.get(applicationContext)
        if (!scheduler.isUnlocked) return@withContext Result.retry()
        try {
            scheduler.read()
            ProcessAdmissionJournal.get(applicationContext.filesDir)?.sweep()
                ?: return@withContext Result.retry()
            coroutineContext.ensureActive()
            val push = inputData.getBoolean("cloudPush", false)
            val center = CloudTaskCenter.get(applicationContext)
            val report = center.pullForWake(dispatch = push && center.hasForegroundHost)
            coroutineContext.ensureActive()
            if (!push && !inputData.getBoolean("cloudPoll", false)) scheduler.projectAfterWorker()
            if (push && report.status == com.phonedsh.cloudtasks.CloudTaskPassStatus.UNREACHABLE) {
                return@withContext Result.retry()
            }
            Result.success()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            Result.retry()
        }
    }
}
