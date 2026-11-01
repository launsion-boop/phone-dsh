// phone-dsh Android — :controller test locator for the normative spec files.
// SPDX-License-Identifier: MIT
//
// The controller's oracles are the repository's normative files, not a copy of
// them: the perturbation fixtures and the budgets.md §4 table are read in place.
// Gradle runs a test with the module directory as `user.dir`, so the locator
// walks up from every plausible start and fails loudly when the file is absent.

package com.phonedsh.controller

import java.io.File

internal object RepoRoot {

    /** Resolves [relative] from the repository root; fails when it does not exist. */
    fun file(relative: String): File {
        val starts = buildList {
            System.getProperty("pdsh.repo.root")?.let { add(File(it)) }
            System.getProperty("user.dir")?.let { add(File(it)) }
            runCatching {
                RepoRoot::class.java.protectionDomain?.codeSource?.location?.toURI()?.let {
                    add(File(it))
                }
            }
        }
        starts.forEach { start ->
            findFrom(start, relative)?.let { return it }
        }
        error("cannot locate $relative from ${starts.joinToString { it.absolutePath }}")
    }

    /** Reads [relative] from the repository root as UTF-8. */
    fun text(relative: String): String = file(relative).readText(Charsets.UTF_8)

    private fun findFrom(start: File, relative: String): File? {
        var current: File? = start.absoluteFile
        repeat(8) {
            val directory = current ?: return null
            val candidate = File(directory, relative)
            if (candidate.isFile || candidate.isDirectory) return candidate
            current = directory.parentFile
        }
        return null
    }
}
