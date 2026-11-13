// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.bot.store.BotDomainStore
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** K6b: composition and the foreground/background lifecycle, without Android. */
class AppBotRuntimeCompositionTest {
    private lateinit var file: File
    private lateinit var sql: JdbcBotSqlDriver
    private lateinit var store: BotDomainStore
    private lateinit var driver: AppBotChatDriver

    @Before
    fun setUp() {
        file = Files.createTempFile("pdsh-app-bot-runtime-", ".sqlite").toFile()
        sql = JdbcBotSqlDriver.open(file)
        store = BotDomainStore(sql)
        driver = AppBotChatDriver(
            store = store,
            transport = LocalBotSessionTransport(clock = { 1_000L }),
            clock = { 1_000L },
        )
    }

    @After
    fun tearDown() {
        runCatching { driver.close() }
        runCatching { store.close() }
    }

    @Test
    fun startAndStopAreIdempotentAndPublishTheWorkerEnvironmentOnlyWhileLive() {
        val mcp = FakeMcpServer(url = "http://127.0.0.1:18888/mcp")
        val routines = FakeRoutineService()
        val runtime = newRuntime(mcp, routines)

        assertTrue(runtime.workerEnvironment().isEmpty())
        assertTrue(mcp.url != null)
        assertNotNull(runtime.mcpUrl)

        runtime.start()
        runtime.start()
        assertEquals(1, mcp.starts)
        assertEquals(1, routines.starts)
        assertEquals(
            "http://127.0.0.1:18888/mcp",
            runtime.workerEnvironment()["PDSH_PHONE_MCP_URL"],
        )
        assertEquals(
            "phone-host-injects-bot-mcp-token",
            runtime.workerEnvironment()["PDSH_PHONE_MCP_TOKEN"],
        )

        runtime.stop()
        runtime.stop()
        assertEquals(1, mcp.stops)
        assertEquals(1, routines.stops)
        assertTrue(runtime.workerEnvironment().isEmpty())
    }

    @Test
    fun aFailedListenerDoesNotStopTheRoutineServiceOrCrashTheApp() {
        val mcp = FakeMcpServer(url = null, failStart = true)
        val routines = FakeRoutineService()
        val logs = mutableListOf<String>()
        val runtime = newRuntime(mcp, routines, logs)

        runtime.start()

        assertEquals(1, routines.starts)
        assertEquals(0, mcp.starts)
        assertTrue(logs.any { it.contains("bot mcp start failed") })
        assertTrue(runtime.workerEnvironment().isEmpty())
    }

    @Test
    fun closeReleasesTheListenerAndDriver() {
        val mcp = FakeMcpServer(url = "http://127.0.0.1:18889/mcp")
        val routines = FakeRoutineService()
        val runtime = newRuntime(mcp, routines)
        runtime.start()
        runtime.close()
        assertEquals(1, routines.stops)
        assertTrue(mcp.stops >= 1)

        // The driver is closed: its projection still answers but no live
        // session is open. Closing twice is a no-op.
        runtime.close()
    }

    private fun newRuntime(
        mcp: FakeMcpServer,
        routines: FakeRoutineService,
        logs: MutableList<String> = mutableListOf(),
    ): AppBotRuntime {
        val roster = AppBotRoster.roster()
        val context = AppBotRoster.context(roster)
        val profile = roster.bots.first()
        val platform = BotPlatformConfig(
            driver = driver,
            context = context,
            appearance = com.phonedsh.bot.profile.BotFishAppearance.resolve(profile),
            roster = AppBotRoster.entries(roster),
            isMainBot = true,
            close = {
                runCatching { driver.close() }
                runCatching { store.close() }
            },
        )
        return AppBotRuntime(
            store = store,
            driver = driver,
            roster = platform.roster,
            platformConfig = platform,
            proactiveSettings = com.phonedsh.bot.proactive.InMemoryProactiveSettingsStore(),
            mcpServer = mcp,
            routines = routines,
            logger = { logs += it },
        )
    }

    private class FakeMcpServer(
        override val url: String?,
        private val failStart: Boolean = false,
    ) : AppBotMcpServer {
        var starts = 0
        var stops = 0

        override fun start() {
            if (failStart) throw IllegalStateException("port occupied")
            starts += 1
        }

        override fun stop() {
            stops += 1
        }
    }

    private class FakeRoutineService : AppBotRoutineService {
        var starts = 0
        var stops = 0

        override fun start() {
            starts += 1
        }

        override fun stop() {
            stops += 1
        }
    }
}
