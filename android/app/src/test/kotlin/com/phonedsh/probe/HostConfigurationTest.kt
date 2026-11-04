// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.ui.page.ConfigurationField
import com.phonedsh.ui.page.ConfigurationFieldKind
import com.phonedsh.ui.page.ConfigurationGroup
import com.phonedsh.ui.page.FactState
import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostConfigurationTest {
    @Test
    fun `projection admits only the four namespace field allowlists`() {
        assertEquals(
            setOf("subagent", "subagent-model-selection-settings", "agent-loop", "bash-sandbox"),
            CONFIGURATION_FIELD_ALLOWLIST.keys,
        )
        assertTrue(configurationFields(
            "provider-secret-store",
            value = JsonObject(mapOf("apiKey" to JsonString("not visible"))),
            base = null,
            user = null,
            properties = JsonObject(mapOf("apiKey" to JsonObject(mapOf("type" to JsonString("string"))))),
        ).isEmpty())
    }

    @Test
    fun `projection uses effective scalars and never renders unknown fields or json values`() {
        val fields = configurationFields(
            namespace = "agent-loop",
            value = JsonObject(mapOf(
                "maxParallelToolCalls" to JsonNumber("5"),
                "apiKey" to JsonString("should-not-render"),
                "extra" to JsonObject(mapOf("token" to JsonString("secret"))),
            )),
            base = JsonObject(mapOf("maxParallelToolCalls" to JsonNumber("1"))),
            user = JsonObject(mapOf("apiKey" to JsonString("secret"))),
            properties = JsonObject(mapOf(
                "maxParallelToolCalls" to JsonObject(mapOf("type" to JsonString("integer"))),
                "apiKey" to JsonObject(mapOf("type" to JsonString("string"))),
                "extra" to JsonObject(mapOf("type" to JsonString("object"))),
            )),
        )
        assertEquals(listOf("maxParallelToolCalls"), fields.map { it.id })
        assertEquals("5", fields.single().value)
        assertEquals(ConfigurationFieldKind.NUMBER, fields.single().kind)

        val absentEffective = configurationFields(
            namespace = "bash-sandbox",
            value = JsonObject(emptyMap()),
            base = JsonObject(mapOf("timeoutMs" to JsonNumber("12000"))),
            user = JsonObject(mapOf("timeoutMs" to JsonNumber("5000"))),
            properties = JsonObject(mapOf("timeoutMs" to JsonObject(mapOf("type" to JsonString("number"))))),
        )
        assertTrue(absentEffective.isEmpty())
    }

    @Test
    fun `missing known namespaces remain explicit unavailable groups`() {
        val groups = buildGroups(emptyList(), writable = true)
        assertEquals(
            listOf("subagent", "subagent-model-selection-settings", "agent-loop", "bash-sandbox"),
            groups.map { it.namespace },
        )
        assertTrue(groups.all { it.fields == null && it.writable == FactState.UNKNOWN })

        val partial = buildGroups(
            listOf(
                NamespaceDescriptor(
                    ns = "agent-loop",
                    revision = 3,
                    value = JsonObject(mapOf("maxParallelToolCalls" to JsonNumber("4"))),
                    base = null,
                    user = null,
                    properties = JsonObject(mapOf(
                        "maxParallelToolCalls" to JsonObject(mapOf("type" to JsonString("integer"))),
                    )),
                ),
            ),
            writable = true,
        )
        assertEquals(4, partial.size)
        assertEquals(listOf("maxParallelToolCalls"), partial.single { it.namespace == "agent-loop" }.fields?.map { it.id })
        assertTrue(partial.filterNot { it.namespace == "agent-loop" }.all { it.fields == null })
    }

    @Test
    fun `allowed models is retained as typed data and write confirmation compares route sets`() {
        val routes = JsonArray(listOf(
            JsonObject(mapOf("provider" to JsonString("p1"), "model" to JsonString("m1"))),
            JsonObject(mapOf("provider" to JsonString("p2"), "model" to JsonString("m2"))),
        ))
        val raw = routes.toJsonString()
        val field = configurationFields(
            namespace = "subagent-model-selection-settings",
            value = JsonObject(mapOf("allowedModels" to routes)),
            base = JsonObject(emptyMap()),
            user = JsonObject(emptyMap()),
            properties = JsonObject(mapOf("allowedModels" to JsonObject(mapOf("type" to JsonString("array"))))),
        ).single()
        assertEquals(ConfigurationFieldKind.MODEL_SELECTION, field.kind)
        assertEquals(raw, field.rawValue)
        assertTrue(configurationPatchMatches(
            ConfigurationGroup("subagent-model-selection-settings", "子 Agent 模型", fields = listOf(field)),
            mapOf("allowedModels" to raw),
            mapOf("allowedModels" to ConfigurationFieldKind.MODEL_SELECTION),
        ))
        assertFalse(configurationPatchMatches(
            ConfigurationGroup("subagent-model-selection-settings", "子 Agent 模型", fields = listOf(field)),
            mapOf("allowedModels" to "[]", "unexpected" to "true"),
            mapOf("allowedModels" to ConfigurationFieldKind.MODEL_SELECTION),
        ))
        assertFalse(configurationFields(
            "subagent-model-selection-settings",
            value = JsonObject(mapOf("allowedModels" to JsonObject(mapOf("token" to JsonString("secret"))))),
            base = null,
            user = null,
            properties = JsonObject(mapOf("allowedModels" to JsonObject(mapOf("type" to JsonString("object"))))),
        ).isNotEmpty())
    }

    @Test
    fun `configuration read cancellation propagates instead of becoming a partial failure`() = runBlocking {
        var propagated = false
        try {
            readConfigurationSource { throw CancellationException("route left") }
        } catch (_: CancellationException) {
            propagated = true
        }
        assertTrue(propagated)
        assertEquals(JsonBool(true), readConfigurationSource { JsonBool(true) }.getOrNull())
    }
}
