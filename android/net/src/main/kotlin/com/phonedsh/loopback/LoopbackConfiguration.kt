// phone-dsh — :loopback / com.phonedsh.loopback: configuration of the one origin.
// SPDX-License-Identifier: MIT
//
// spec/v1/README.md fixes the shape: the App hosts exactly ONE HTTP origin on
// 127.0.0.1 with a random port, and that one origin carries the launch page,
// the worker's static assets and the single ordered WebSocket of
// spec/v1/channel.md §7. Nothing here ever leaves the loopback interface.

package com.phonedsh.loopback

/**
 * Immutable configuration of one [LoopbackServer] instance.
 *
 * Every value is fixed before `start`; the bound port and the live token are
 * reported back through [LoopbackEndpoint]. An empty [token] asks the server to
 * generate a fresh 128-bit secret for every start; a caller-supplied token is
 * pinned instead (tests, restart with the same token).
 */
data class LoopbackConfiguration(
    /**
     * 0 asks the OS for a random ephemeral port. The bound port is reported by
     * [LoopbackEndpoint.port]; a fixed port is only useful for tests.
     */
    val port: Int = EPHEMERAL_PORT,

    /**
     * Empty generates a fresh 128-bit token per start. A pinned token must be
     * at least [MIN_PINNED_TOKEN_LENGTH] printable characters.
     */
    val token: String = "",

    /**
     * Emit `Cross-Origin-Opener-Policy: same-origin` and
     * `Cross-Origin-Embedder-Policy: require-corp` on the launch page, which is
     * what gives the worker page a cross-origin-isolated context.
     */
    val crossOriginIsolation: Boolean = true,

    /**
     * Accept `?token=` on the `/channel` upgrade.
     *
     * Default `false`: the upgrade needs `Authorization: Bearer` or the D22
     * launch cookie (the browser sends it on its own handshake), so the token
     * never has to appear in the channel URL. Browser `new WebSocket(...)`
     * cannot set an `Authorization` header, and the packaged worker can append
     * the launch token to its own channel URL
     * (`examples/probe-app/Bundle/worker/worker-entry.js`, `resolveUrl()`), so
     * `:engine` keeps this opt-in on for a page that still carries `?token=`.
     * See `net/README.md`.
     */
    val allowQueryTokenOnChannel: Boolean = false,

    /**
     * Largest accepted WebSocket payload, i.e. one whole channel frame with its
     * 16-byte header (spec/v1/channel.md §1: `1 ≤ len ≤ 16 MiB`).
     */
    val maxChannelFrameBytes: Int = MAX_CHANNEL_FRAME_BYTES,
) {
    init {
        require(port in EPHEMERAL_PORT..MAX_PORT) { "port must be 0...$MAX_PORT, was $port" }
        if (token.isNotEmpty()) {
            require(token.length >= MIN_PINNED_TOKEN_LENGTH) {
                "an injected token must be at least $MIN_PINNED_TOKEN_LENGTH characters"
            }
            require(token.none { it.isWhitespace() || it.isISOControl() }) {
                "an injected token must not contain whitespace or control characters"
            }
        }
        require(maxChannelFrameBytes in 1..MAX_CHANNEL_FRAME_BYTES) {
            "maxChannelFrameBytes must be 1...$MAX_CHANNEL_FRAME_BYTES, was $maxChannelFrameBytes"
        }
    }

    companion object {
        /** The listener is never bound to a wildcard address. */
        const val LOOPBACK_HOST: String = "127.0.0.1"

        const val EPHEMERAL_PORT: Int = 0
        const val MAX_PORT: Int = 65535
        const val MIN_PINNED_TOKEN_LENGTH: Int = 16

        /** 16-byte channel header plus a payload of at most 16 MiB (channel.md §1). */
        const val MAX_CHANNEL_FRAME_BYTES: Int = 16 * 1024 * 1024 + 16

        /** The one WebSocket endpoint of this origin (channel.md §7). */
        const val CHANNEL_PATH: String = "/channel"
    }
}
