// The decoded capability JSON of the linked Rust accelerator registry.
// SPDX-License-Identifier: MIT

package com.phonedsh.shell

import org.json.JSONObject

/**
 * The capability object `pdsh-ffi` publishes (`shell/include/xzshell.h`).
 *
 * ```json
 * {"accelerators":["jaq","jq","rg"],"version":"0.1.0",
 *  "limits":{"timeout":30000,"max_output_bytes":1048576,
 *            "max_files":10000,"max_file_bytes":15728640}}
 * ```
 *
 * This is a fact read from the linked library, not a constant of this module:
 * [accelerators] is the set the native registry says it can run, [version] is
 * that registry's version, and [limits] are the budgets it advertises. The
 * names are never copied into `:shell` by hand.
 *
 * @property version the pdsh-shell version string of the linked library.
 * @property accelerators the advertised names, sorted by the Rust side.
 * @property limits the limits the library advertises with the same JSON.
 */
data class NativeShellCaps(
    val version: String,
    val accelerators: List<String>,
    val limits: AcceleratorLimits,
) {
    /** Whether [name] is in the advertised set. */
    fun says(name: String): Boolean = name in accelerators

    companion object {
        /**
         * Parses one capability JSON object.
         *
         * @throws org.json.JSONException the payload is not the documented
         *   shape; the binding treats that as "the library is unavailable"
         *   rather than inventing an accelerator set.
         */
        fun parse(json: String): NativeShellCaps {
            val payload = JSONObject(json)
            val version = payload.getString("version")
            val array = payload.getJSONArray("accelerators")
            val accelerators = ArrayList<String>(array.length())
            for (index in 0 until array.length()) {
                accelerators.add(array.getString(index))
            }
            val limits = payload.getJSONObject("limits")
            return NativeShellCaps(
                version = version,
                accelerators = accelerators,
                limits = AcceleratorLimits(
                    timeoutMs = limits.getLong("timeout"),
                    maxOutputBytes = limits.getLong("max_output_bytes"),
                    maxFiles = limits.getLong("max_files"),
                    maxFileBytes = limits.getLong("max_file_bytes"),
                ),
            )
        }
    }
}
