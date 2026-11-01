// phone-dsh — :engine tests: the `env` page parameter and the launch token.
// SPDX-License-Identifier: MIT
//
// The contract is boot.js's: `?env=` is a JSON object
// (`examples/probe-app/Bundle/worker/boot.js:75,120-136,158-170`), the worker
// entry re-validates it as an object of strings
// (`plugins/worker-entry/src/entry.ts:1659,1900-1911`), and the resident phone
// surface reads PDSH_DSH_LAUNCH_TOKEN from it
// (`plugins/surface-phone/src/index.js:365`).

package com.phonedsh.engine

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkerEnvironmentTest {
    @Test
    fun theEnvParameterCarriesTheLaunchTokenAsAJsonObject() {
        val json = WorkerEnvironment.pageParam("0123456789abcdef0123456789abcdef")
        val parsed = JSONObject(json)
        assertEquals(
            "0123456789abcdef0123456789abcdef",
            parsed.getString(WorkerEnvironment.LAUNCH_TOKEN),
        )
        assertEquals("only the engine-owned key is added", 1, parsed.length())
        assertEquals(
            "the variable name the resident phone surface requires",
            "PDSH_DSH_LAUNCH_TOKEN",
            WorkerEnvironment.LAUNCH_TOKEN,
        )
    }

    @Test
    fun aHostSuppliedEnvObjectIsMergedAndTheTokenWins() {
        val json = WorkerEnvironment.pageParam(
            launchToken = "aa".repeat(32),
            hostSupplied = """{"PDSH_CHANNEL_URL":"ws://127.0.0.1:1/channel","PDSH_DSH_LAUNCH_TOKEN":"stale"}""",
        )
        val parsed = JSONObject(json)
        assertEquals("ws://127.0.0.1:1/channel", parsed.getString("PDSH_CHANNEL_URL"))
        assertEquals("the per-start token replaces a stale host value", "aa".repeat(32), parsed.getString(WorkerEnvironment.LAUNCH_TOKEN))
    }

    @Test
    fun aHostEnvWithoutTheKeyIsJustTheToken() {
        val parsed = JSONObject(WorkerEnvironment.pageParam("bb", null))
        assertEquals("bb", parsed.getString(WorkerEnvironment.LAUNCH_TOKEN))
        assertEquals(1, parsed.length())
    }

    @Test
    fun aNonObjectEnvIsRefusedAndTheFailureDoesNotEchoIt() {
        val secret = "cc".repeat(32)
        val failure = try {
            WorkerEnvironment.pageParam("dd".repeat(32), """["$secret"]""")
            null
        } catch (expected: IllegalArgumentException) {
            expected
        }
        assertTrue("an array is not an env object", failure != null)
        assertTrue(failure!!.message!!.contains("must be a JSON object"))
        assertFalse("the failure must not echo the host value", failure.message!!.contains(secret))
    }

    @Test
    fun freshTokensAreHexAndDifferPerStart() {
        val source = LaunchTokenSource.fresh()
        val first = source.nextLaunchToken()
        val second = source.nextLaunchToken()
        assertEquals("32 bytes as 64 lowercase hex characters", 64, first.length)
        assertTrue("lowercase hex only", first.all { it in '0'..'9' || it in 'a'..'f' })
        assertNotEquals("every start gets a new secret", first, second)
    }

    // ---------------------------------------------------------- model edge (M2)

    /**
     * The M2 contract: with a mounted model proxy the Worker must address the
     * loopback origin, never the real provider. Everything else in the host
     * object survives, including the placeholder the Worker is given instead of
     * a key.
     */
    @Test
    fun aMountedModelEdgeRewritesOnlyTheBaseUrlAndKeepsTheOtherEnvMembers() {
        val placeholder = "phone-host-injects-mcp-key"
        val hostEnv = JSONObject()
            .put(WorkerEnvironment.MODEL_BASE_URL, "https://api.deepseek.com")
            .put("DEEPSEEK_API_KEY", placeholder)
            .put("PDSH_MODEL_KEY_STATE", "configured")
            .put("DSH_TELEMETRY_DISABLED", "1")
            .toString()
        val json = WorkerEnvironment.pageParam(
            launchToken = "ee".repeat(32),
            hostSupplied = hostEnv,
            modelBaseUrl = "http://127.0.0.1:41234",
        )
        val parsed = JSONObject(json)
        assertEquals(
            "the Worker only ever sees the loopback origin",
            "http://127.0.0.1:41234",
            parsed.getString(WorkerEnvironment.MODEL_BASE_URL),
        )
        assertEquals(
            "the key placeholder is untouched: the Worker never holds a key",
            placeholder,
            parsed.getString("DEEPSEEK_API_KEY"),
        )
        assertEquals("configured", parsed.getString("PDSH_MODEL_KEY_STATE"))
        assertEquals("1", parsed.getString("DSH_TELEMETRY_DISABLED"))
        assertEquals("ee".repeat(32), parsed.getString(WorkerEnvironment.LAUNCH_TOKEN))
    }

    /**
     * The pre-M2 path stays byte-compatible: no mounted proxy means the host's
     * base URL is the one the Worker sees (a scripted upstream in the acceptance
     * runs), so this lane cannot break that launch shape.
     */
    @Test
    fun withoutAMountedModelEdgeTheHostBaseUrlIsLeftAlone() {
        val hostEnv = JSONObject()
            .put(WorkerEnvironment.MODEL_BASE_URL, "http://127.0.0.1:9999")
            .put("DEEPSEEK_API_KEY", "phone-host-injects-mcp-key")
            .toString()
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = "ff".repeat(32),
                hostSupplied = hostEnv,
                modelBaseUrl = null,
            ),
        )
        assertEquals(
            "a launch without a proxy keeps its scripted-upstream value",
            "http://127.0.0.1:9999",
            parsed.getString(WorkerEnvironment.MODEL_BASE_URL),
        )
        assertEquals("ff".repeat(32), parsed.getString(WorkerEnvironment.LAUNCH_TOKEN))
    }

    /** A proxy with no host env at all still points the Worker at the origin. */
    @Test
    fun aMountedModelEdgeIsAddedEvenWhenTheHostSuppliedNoEnv() {
        val parsed = JSONObject(
            WorkerEnvironment.pageParam(
                launchToken = "gg",
                hostSupplied = null,
                modelBaseUrl = "http://127.0.0.1:1",
            ),
        )
        assertEquals("http://127.0.0.1:1", parsed.getString(WorkerEnvironment.MODEL_BASE_URL))
        assertEquals("gg", parsed.getString(WorkerEnvironment.LAUNCH_TOKEN))
        assertEquals(2, parsed.length())
    }

    /** The variable name is the provider's own, not a second spelling. */
    @Test
    fun theModelBaseUrlVariableIsTheProviderEnvironmentName() {
        assertEquals("DEEPSEEK_BASE_URL", WorkerEnvironment.MODEL_BASE_URL)
    }
}
