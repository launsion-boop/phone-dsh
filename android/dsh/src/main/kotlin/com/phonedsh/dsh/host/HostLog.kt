// phone-dsh — :dsh / com.phonedsh.dsh.host: the facade's log seam.
// SPDX-License-Identifier: MIT
//
// :dsh must not link :engine whose EngineLogger lives there (the whole point of
// this lane is that the facade depends on the :platform EngineHost interface
// instead), so the facade declares the four levels it actually writes. The
// Android adapter is a five-line object in :app; the JVM tests inject [None] or
// a recorder. Nothing here is a log framework: no tags, no formatting, no IO.

package com.phonedsh.dsh.host

/** The four log levels the host facade writes. Messages are token-free by contract. */
interface HostLog {
    fun debug(message: String)

    fun info(message: String)

    fun warn(message: String)

    fun error(message: String)

    companion object {
        /** Drops every line. The default in tests, so an assertion never depends on stdout. */
        val None: HostLog = object : HostLog {
            override fun debug(message: String) = Unit

            override fun info(message: String) = Unit

            override fun warn(message: String) = Unit

            override fun error(message: String) = Unit
        }

        /**
         * Writes to stdout with a `PhoneDSH` prefix.
         *
         * This is the default because a facade that silently drops its own
         * `mseq-watermark: not-wired` warning would hide exactly the provenance
         * this lane exists to make visible. On Android, `System.out` is routed to
         * logcat; a production App should still inject a logcat-tagged adapter.
         */
        val Println: HostLog = object : HostLog {
            override fun debug(message: String) = log("D", message)

            override fun info(message: String) = log("I", message)

            override fun warn(message: String) = log("W", message)

            override fun error(message: String) = log("E", message)

            private fun log(level: String, message: String) {
                println("$level/PhoneDSH: $message")
            }
        }
    }
}
