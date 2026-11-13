// 连接电脑's install command is the iOS guide's command, not a second copy.
// SPDX-License-Identifier: MIT
//
// The blank card (—) came from PdshNavHost receiving no command at all. This
// test pins the host's single constant to the reviewed iOS source so the two
// phone ends cannot drift, and the router test in `:lib` drives the copy action
// through the real page.
package com.phonedsh.probe

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostPclinkInstallCommandTest {
    private val repoRoot: File by lazy {
        File(System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set"))
    }

    @Test
    fun `the pairing install command is the iOS PCLinkInstallGuide command`() {
        val swift = File(
            repoRoot,
            "examples/probe-app/ProbeKit/Backends/PCLinkRelayConfiguration.swift",
        ).readText()
        val match = Regex("installCommand\\s*=\\s*\"([^\"]+)\"").find(swift)
            ?: error("PCLinkInstallGuide.installCommand is missing from the iOS guide")

        assertEquals(
            "the Android pairing page must paste the same reviewed command as iOS",
            match.groupValues[1],
            PCLINK_INSTALL_COMMAND,
        )
        assertTrue(
            "the command must run the repository's install script",
            PCLINK_INSTALL_COMMAND.contains("pclink/install.sh | bash"),
        )
    }
}
