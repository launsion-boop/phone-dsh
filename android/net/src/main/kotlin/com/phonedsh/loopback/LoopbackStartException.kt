// phone-dsh — :loopback / com.phonedsh.loopback: a start that refused to fake success.
// SPDX-License-Identifier: MIT
//
// The origin used to hand back an endpoint as soon as Ktor's start() returned,
// so a bind failure surfaced later, inside a coroutine nobody observed, and took
// the whole process down (measured: `SocketException: Operation not permitted`
// when the App lacks INTERNET). This exception is the synchronous, reportable
// form of that same failure.

package com.phonedsh.loopback

/**
 * The origin could not be started *and* confirmed to serve.
 *
 * Thrown by [LoopbackServer.start] before it returns an endpoint. [cause] is the
 * underlying failure: the engine's own startup exception, the reason the
 * engine's accept coroutine died (a `BindException` when the port is taken, a
 * `SocketException: Operation not permitted` when the App lacks the `INTERNET`
 * permission, ...), or the failed liveness probe.
 *
 * When this is thrown [LoopbackServer.endpoint] is null, the engine has already
 * been stopped and this instance may be started again. Like every exception in
 * this package the message never contains the token.
 */
class LoopbackStartException(
    /** The configured port; 0 when the OS was asked for an ephemeral port. */
    val configuredPort: Int,
    cause: Throwable? = null,
) : RuntimeException(
    "the loopback origin failed to start on " + LoopbackConfiguration.LOOPBACK_HOST +
        if (configuredPort == LoopbackConfiguration.EPHEMERAL_PORT) {
            ":<ephemeral>"
        } else {
            ":$configuredPort"
        },
    cause,
)
