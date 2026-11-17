// SPDX-License-Identifier: MIT
// One `ExternalAdmissionJournal` object per admissions directory in this process.
//
// The journal serialises its operations on its own monitor, so two objects over
// the same directory would be two writers. The send queue (dispatch) and the
// cloud task bridge (admission, terminal reports, sign-out cancel) both take
// theirs from here. Opening needs a directory and nothing else: no engine.
package com.phonedsh.probe.admission

import java.io.File

internal object ProcessAdmissionJournal {
    private val journals = HashMap<String, ExternalAdmissionJournal>()

    /**
     * The journal under [root] (`<root>/admissions`), or null when it cannot be
     * opened now. A failure is not remembered: the next call tries again.
     */
    @Synchronized
    fun get(root: File): ExternalAdmissionJournal? {
        val key = runCatching { root.canonicalPath }.getOrElse { root.absolutePath }
        journals[key]?.let { return it }
        val opened = runCatching { ExternalAdmissionJournal(root) }.getOrNull() ?: return null
        journals[key] = opened
        return opened
    }
}
