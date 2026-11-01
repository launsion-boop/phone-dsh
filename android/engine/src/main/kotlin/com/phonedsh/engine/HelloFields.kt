// phone-dsh — :engine / com.phonedsh.engine: HELLO fields out of the codec's JSON.
// SPDX-License-Identifier: MIT
//
// WireCodec.decode() returns the canonical JSON of a frame's `fields`
// (spec/v1/channel.md §4.1 for HELLO). The wire layer is the Rust codec; this
// file only reads five members of an already-decoded object with the platform
// JSON parser (org.json) — it does not parse frames, validate magic, or check
// CRCs. Android provides org.json; the JVM unit tests put the reference org.json
// implementation on the test classpath (engine/build.gradle.kts).
//
// Missing members answer their zero value: a worker HELLO has no next_mseq /
// acked_mseq and a host HELLO has no last_mseq (channel.md §4.1 table).

package com.phonedsh.engine

import org.json.JSONObject

/** Field reads for a decoded HELLO object. Never throws on a missing member. */
internal object HelloFields {
    fun proto(json: String): Int = JSONObject(json).optInt("proto", 0)

    /** `"worker"` or `"host"`; null when the member is absent or not a string. */
    fun role(json: String): String? = JSONObject(json).optString("role", "").ifEmpty { null }

    /** The `caps` array as strings, in wire order; empty when absent. */
    fun caps(json: String): List<String> {
        val array = JSONObject(json).optJSONArray("caps") ?: return emptyList()
        val caps = ArrayList<String>(array.length())
        for (index in 0 until array.length()) {
            val value = array.opt(index)
            if (value is String) caps.add(value)
        }
        return caps
    }

    /** `next_mseq` of the host HELLO; 0 on the worker HELLO. */
    fun nextMseq(json: String): Long = JSONObject(json).optLong("next_mseq", 0L)

    /** `acked_mseq` of the host HELLO; 0 on the worker HELLO. */
    fun ackedMseq(json: String): Long = JSONObject(json).optLong("acked_mseq", 0L)
}
