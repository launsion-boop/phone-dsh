// The CI guard for the L69 wiring: the chat page must be fed, not opened.
// SPDX-License-Identifier: MIT
//
// The defect this lane removes was not a missing class — every class existed. It
// was that `ChatRoute` handed `ChatPage` an empty projection and four empty
// lambdas, and `HostSessionsScreen` handed every session gesture to a
// 「宿主未实现」 line. A grep of the source would pass on a commented-out call, and
// a compile of the library alone cannot see the app. So this test reads the
// **compiled** entry points through reflection and asserts the shape a page needs
// to be alive:
//
//   * `PdshNavHost` (the router) really takes a folded `ChatScreenState`;
//   * the app's view model really owns the three commands (send/stop/import);
//   * the turn runner keeps the two strings that make streaming and stop real
//     (`assistantStream`, `session/cancel`).
package com.phonedsh.probe

import com.phonedsh.ui.state.ChatScreenState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatWiringTest {
    @Test
    fun theRouterTakesTheFoldedChatState() {
        val hostKt = Class.forName("com.phonedsh.ui.nav.PdshNavHostKt")
        val entry = hostKt.methods.firstOrNull { it.name == "PdshNavHost" }
        assertNotNull("PdshNavHost is no longer a top-level function", entry)
        assertTrue(
            "PdshNavHost no longer takes a ChatScreenState: the chat route would " +
                "fall back to its empty projection and the dock would be dead again",
            entry!!.parameterTypes.any { it == ChatScreenState::class.java },
        )
        assertTrue(
            "PdshNavHost no longer takes a title: the page head would always say 新会话",
            entry.parameterTypes.any { it == String::class.java },
        )
    }

    @Test
    fun theChatRouteForwardsTheComposerGestures() {
        val chatRoute = Class.forName("com.phonedsh.ui.nav.PdshNavHostKt")
            .declaredMethods
            .firstOrNull { it.name == "ChatRoute" }
        assertNotNull("the router has no ChatRoute function any more", chatRoute)
        // A slot the page must be able to call: at least eight function-typed
        // parameters (draft/send/stop/rename/files/images/remove/dismiss) beyond the
        // state and the navigator.
        val callbacks = chatRoute!!.parameterTypes.count {
            it.name == "kotlin.jvm.functions.Function0" || it.name == "kotlin.jvm.functions.Function1"
        }
        assertTrue(
            "ChatRoute forwards only $callbacks composer callbacks; send/stop/rename/" +
                "add-files/add-images/remove/dismiss are no longer all wired",
            callbacks >= 8,
        )
    }

    @Test
    fun theViewModelOwnsTheThreeChatCommands() {
        val vm = Class.forName("com.phonedsh.probe.ProbeEngineViewModel")
        for (name in listOf(
            "chatSurfaceState",
            "sendChat",
            "stopChat",
            "importIntoWorkspace",
            "newChatSession",
            "openChatSession",
            "renameChatSession",
        )) {
            assertTrue(
                "ProbeEngineViewModel no longer declares $name(): the page's gesture " +
                    "or the session lifecycle would have no host command behind it",
                vm.declares(name),
            )
        }
        assertTrue(
            "ProbeEngineViewModel no longer takes a prompt String on runTurn(): the " +
                "composer's text would never reach the Worker",
            vm.declaredMethods.any { method ->
                method.name.startsWith("runTurn") && method.parameterTypes.size == 1 &&
                    method.parameterTypes[0] == String::class.java
            },
        )
    }

    @Test
    fun theTurnRunnerKeepsTheStreamingOptInAndCancelEndpoint() {
        val runner = Class.forName("com.phonedsh.probe.ChatTurnRunner")
        assertTrue("ChatTurnRunner no longer declares run()", runner.declares("run"))
        assertTrue("ChatTurnRunner no longer declares cancel()", runner.declares("cancel"))
        assertTrue(
            "ChatTurnRunner no longer opts into the Worker's assistant frames: the " +
                "answer would arrive as one block after the turn ended",
            runner.getResourceAsStream("ChatTurnRunner.class")!!.use {
                String(it.readBytes(), Charsets.ISO_8859_1).contains("sessionFollowOpenFrame")
            } && "assistantStream" in stringsOf(Class.forName("com.phonedsh.dsh.turn.DshTurnClientKt")),
        )
        assertTrue(
            "ChatTurnRunner no longer names the Worker's cancel endpoint: 停止 would " +
                "stop the phone from listening while the Worker kept generating",
            "session/cancel" in stringsOf(runner),
        )
    }

    /**
     * True when [type] declares [name], under the module-mangled JVM name too.
     *
     * Kotlin mangles an `internal` member to `name$module`, so the screen's
     * command would be invisible to a plain name comparison even though it exists.
     */
    private fun Class<*>.declares(name: String): Boolean =
        declaredMethods.any { it.name == name || it.name.startsWith("$name$") }

    /** Every `CONSTANT_String` of one compiled class. */
    private fun stringsOf(type: Class<*>): Set<String> {
        val bytes = type.classLoader
            ?.getResourceAsStream(type.name.replace('.', '/') + ".class")
            ?.use { it.readBytes() }
            ?: throw AssertionError("${type.name} is not on the test classpath")
        return classStrings(bytes)
    }

    /**
     * Reads the constant pool and returns its UTF-8 string entries.
     *
     * Only the pool layout is parsed: tags this reader does not need are skipped by
     * their fixed sizes, which is enough to reach every `CONSTANT_String` without a
     * bytecode library on the unit-test classpath.
     */
    private fun classStrings(bytes: ByteArray): Set<String> {
        var index = 8 // magic + minor + major
        val poolCount = readU2(bytes, index).also { index += 2 }
        val utf8 = HashMap<Int, String>()
        val stringIndexes = ArrayList<Int>()
        var slot = 1
        while (slot < poolCount) {
            when (val tag = bytes[index].toInt() and 0xFF) {
                1 -> {
                    val length = readU2(bytes, index + 1)
                    utf8[slot] = String(bytes, index + 3, length, Charsets.UTF_8)
                    index += 3 + length
                }

                7, 8, 16, 19, 20 -> {
                    if (tag == 8) stringIndexes.add(readU2(bytes, index + 1))
                    index += 3
                }

                15 -> index += 4
                3, 4, 9, 10, 11, 12, 17, 18 -> index += 5
                5, 6 -> {
                    index += 9
                    slot++ // long/double take two slots
                }

                else -> throw AssertionError("unknown constant-pool tag $tag at slot $slot")
            }
            slot++
        }
        val strings = stringIndexes.mapNotNull { utf8[it] }.toSet()
        // Sanity: a class whose pool parsed to nothing would make every call-site
        // assertion below vacuous.
        assertTrue("no UTF-8 constants were read", utf8.isNotEmpty())
        assertEquals("the class should have at least its own name", true, strings.isNotEmpty())
        return strings
    }

    private fun readU2(bytes: ByteArray, at: Int): Int =
        ((bytes[at].toInt() and 0xFF) shl 8) or (bytes[at + 1].toInt() and 0xFF)
}
