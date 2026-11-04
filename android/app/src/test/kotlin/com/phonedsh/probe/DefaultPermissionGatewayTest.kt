// The new-session permission default is a startup-locked field on the phone.
// SPDX-License-Identifier: MIT
//
// `settings/describe.writable` describes the settings provider as a whole. The
// phone image's home patch owns `permission.defaultPreset` above the editable
// profile layer, so the provider flag is not evidence that this one field can be
// written. These tests drive the real state machine behind
// `ProbeEngineViewModel.refreshDefaultPermissionTier` / `writeDefaultPermissionTier`
// and assert the published facts and the wire calls: a locked state must not issue
// `settings/update`; a writable state must still write and read the catalog back;
// a failed write must keep the underlying `code: message`.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.PermissionDefaultsState
import com.phonedsh.ui.page.PermissionTier
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DefaultPermissionGatewayTest {
    @Test
    fun `a startup-locked field publishes the reason and never calls settings update`() = runBlocking<Unit> {
        val state = MutableStateFlow(PermissionDefaultsHostState())
        val gateway = DefaultPermissionGateway(state)
        val api = ScriptedPermissionApi(
            described = describe(writable = true),
            catalog = catalog(defaultPreset = "phone"),
        )

        assertNull(gateway.refresh(api))
        val locked = state.value
        assertFalse("the provider-wide writable flag is not this field's capability", locked.writable)
        assertTrue(locked.startupLocked)
        assertTrue(
            "the reason must name the startup source",
            locked.readOnlyReason.orEmpty().contains("启动配置"),
        )
        assertTrue(
            "the reason must ask for a restart",
            locked.readOnlyReason.orEmpty().contains("重启"),
        )
        assertTrue(
            "the reason must say existing sessions are unchanged",
            locked.readOnlyReason.orEmpty().contains("现有会话"),
        )
        assertEquals(listOf("permissionPresets/catalog", "settings/describe"), api.calls)

        try {
            gateway.write(api, PermissionTier.FULL_ACCESS)
            fail("a locked field must refuse the write")
        } catch (failure: IllegalStateException) {
            assertTrue(failure.message.orEmpty().contains("启动配置"))
        }
        assertEquals(
            "a locked write must not emit settings/update",
            listOf("permissionPresets/catalog", "settings/describe"),
            api.calls,
        )

        val page = PermissionDefaultsState.from(
            selected = PermissionTier.WORKSPACE_WRITE,
            languageId = "zh",
            availableTiers = setOf(PermissionTier.WORKSPACE_WRITE),
            writable = locked.writable,
            startupLocked = locked.startupLocked,
            readOnlyReason = locked.readOnlyReason,
        )
        assertFalse(page.options.any { it.enabled })
        assertTrue(page.statusMessage.orEmpty().contains("home patch"))
        assertTrue(page.statusMessage.orEmpty().contains("现有会话"))
    }

    @Test
    fun `an engine-reported writable field writes through and confirms by catalog readback`() = runBlocking<Unit> {
        val state = MutableStateFlow(PermissionDefaultsHostState())
        val gateway = DefaultPermissionGateway(state)
        val api = ScriptedPermissionApi(
            described = describe(writable = true, fieldWritable = true),
            catalog = catalog(defaultPreset = "phone"),
            readback = catalog(defaultPreset = "danger-full-access"),
        )

        assertNull(gateway.refresh(api))
        assertTrue(state.value.writable)
        assertFalse(state.value.startupLocked)
        assertNull(state.value.readOnlyReason)

        gateway.write(api, PermissionTier.FULL_ACCESS)
        assertEquals(
            listOf(
                "permissionPresets/catalog",
                "settings/describe",
                "permissionPresets/catalog",
                "settings/describe",
                "settings/update",
                "permissionPresets/catalog",
            ),
            api.calls,
        )
        val update = requireNotNull(api.updateArgs)
        assertEquals("permission", (update["ns"] as JsonString).value)
        assertEquals("3", (update["expectedRevision"] as JsonNumber).raw)
        assertEquals(
            "danger-full-access",
            ((update["patch"] as JsonObject)["defaultPreset"] as JsonString).value,
        )
        assertEquals("danger-full-access", state.value.currentModeId)
        assertTrue(state.value.writable)
        assertNull(state.value.failure)
    }

    @Test
    fun `a failed write shows the engine code and message and keeps the retry path`() = runBlocking<Unit> {
        val state = MutableStateFlow(PermissionDefaultsHostState())
        val gateway = DefaultPermissionGateway(state)
        val failure = DshTurnException(
            "settings/rejected",
            "Configuration for \"permission\" is overridden by a home patch or command-line overlay",
        )
        val api = ScriptedPermissionApi(
            described = describe(writable = true, fieldWritable = true),
            catalog = catalog(defaultPreset = "phone"),
            updateFailure = failure,
        )

        assertNull(gateway.refresh(api))
        try {
            gateway.write(api, PermissionTier.FULL_ACCESS)
            fail("the engine refusal must reach the caller")
        } catch (thrown: DshTurnException) {
            assertEquals("settings/rejected", thrown.code)
        }
        assertEquals(
            "settings/rejected: Configuration for \"permission\" is overridden by a home patch or command-line overlay",
            state.value.failure,
        )
        assertTrue("a failed write must leave a retry path", state.value.writable)

        val page = PermissionDefaultsState.from(
            selected = PermissionTier.WORKSPACE_WRITE,
            languageId = "zh",
            availableTiers = setOf(PermissionTier.WORKSPACE_WRITE),
            writable = state.value.writable,
            failure = state.value.failure,
        )
        assertEquals(state.value.failure, page.statusMessage)
    }

    @Test
    fun `an explicit engine override source is used instead of the default wording`() {
        val access = defaultPermissionAccess(
            describe(writable = true, overrideSource = "命令行覆盖（DSH_PROFILE）"),
        )
        assertFalse(access.writable)
        assertTrue(access.startupLocked)
        assertTrue(access.readOnlyReason.orEmpty().contains("命令行覆盖"))
        assertTrue(access.readOnlyReason.orEmpty().contains("重启"))
    }

    private fun describe(
        writable: Boolean,
        fieldWritable: Boolean? = null,
        overrideSource: String? = null,
    ): JsonObject = JsonObject(
        linkedMapOf<String, JsonValue>(
            "writable" to JsonBool(writable),
            "namespaces" to JsonArray(
                listOf(
                    JsonObject(
                        linkedMapOf<String, JsonValue>(
                            "ns" to JsonString("permission"),
                            "revision" to JsonNumber("3"),
                            "value" to JsonObject(mapOf("defaultPreset" to JsonString("phone"))),
                        ) + buildMap {
                            if (fieldWritable != null) put("defaultPermissionWritable", JsonBool(fieldWritable))
                            if (overrideSource != null) put("overrideSource", JsonString(overrideSource))
                        },
                    ),
                ),
            ),
        ),
    )

    private fun catalog(defaultPreset: String): JsonObject = JsonObject(
        linkedMapOf<String, JsonValue>(
            "defaultPreset" to JsonString(defaultPreset),
            "defaultOptions" to JsonArray(
                listOf("phone-read-only", "phone", "danger-full-access").map { id ->
                    JsonObject(mapOf("value" to JsonString(id), "name" to JsonString(id)))
                },
            ),
        ),
    )

    /** Scripted `/api` peer for the three endpoints the field reads and writes. */
    private class ScriptedPermissionApi(
        private val described: JsonObject,
        private val catalog: JsonObject,
        private val readback: JsonObject = catalog,
        private val updateFailure: Exception? = null,
    ) : DefaultPermissionApi {
        val calls = mutableListOf<String>()
        var updateArgs: JsonObject? = null
        private var updated = false

        override suspend fun call(endpoint: String, args: JsonObject, timeoutMillis: Long): JsonValue {
            calls += endpoint
            if (endpoint == "settings/update") updateArgs = args
            return when (endpoint) {
                "permissionPresets/catalog" -> if (updated) readback else catalog
                "settings/describe" -> described
                "settings/update" -> {
                    updateFailure?.let { throw it }
                    updated = true
                    JsonObject(mapOf("ns" to JsonString("permission")))
                }
                else -> error("unexpected endpoint $endpoint")
            }
        }
    }
}
