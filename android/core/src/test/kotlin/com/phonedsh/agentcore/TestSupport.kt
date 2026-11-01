// D1-c tests — synchronous bridges for suspend functions and Flow collection.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

/**
 * Drives a suspending block to completion on the calling thread.
 *
 * `Flow` is the real `kotlinx.coroutines.flow.Flow`, but the test doubles in
 * this package never really suspend: every `emit` and every `send` returns
 * immediately. This minimal continuation runner avoids `runBlocking` and makes
 * a fake that unexpectedly suspends fail loudly instead of hanging the suite.
 */
internal fun <T> runSuspendValue(block: suspend () -> T): T {
    var outcome: Result<T>? = null
    block.startCoroutine(
        object : Continuation<T> {
            override val context: CoroutineContext = EmptyCoroutineContext

            override fun resumeWith(result: Result<T>) {
                outcome = result
            }
        },
    )
    return requireNotNull(outcome) {
        "the test coroutine suspended; fake harness flows must be synchronous"
    }.getOrThrow()
}

internal fun runSuspendBlocking(block: suspend () -> Unit) {
    runSuspendValue { block() }
}

/** Collects a [Flow] synchronously, running [onEach] for every event. */
internal fun <T> Flow<T>.collectBlocking(onEach: (T) -> Unit = {}): Unit =
    runSuspendBlocking {
        collect { value -> onEach(value) }
    }
