// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.attachments.BotModelAttachmentRequest
import com.phonedsh.bot.attachments.BotModelImage
import com.phonedsh.bot.attachments.BotModelImageError
import com.phonedsh.bot.attachments.BotModelImageException
import com.phonedsh.bot.authz.BotExecutionAuthorizer
import com.phonedsh.bot.authz.BotExecutionPrincipal
import com.phonedsh.bot.authz.BotGrant
import com.phonedsh.bot.authz.BotGrantDecision as AuthzGrantDecision
import com.phonedsh.bot.authz.BotGrantScope
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.authz.BotToolEffectClassifier
import com.phonedsh.bot.authz.BotToolMutability
import com.phonedsh.bot.authz.BotToolPolicy
import com.phonedsh.bot.session.BotSessionKind
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Focused P26 regression over the real catalog, classifier, runtime and grant
 * gate. The golden tests freeze the shared bytes; this class pins the
 * semantics the App relies on: one approval-classified effect, a two-image
 * turn cap, a task-session refusal, and a real MCP image content block.
 */
class BotModelImageToolTest {
    private val catalog = MCPTestSupport.catalog()

    @Test
    fun catalogAdvertisesAttachToModelAsARegisteredPurposeGatedTool() {
        assertTrue(BotToolCatalog.isRegistered(BotToolCatalog.ATTACH_TO_MODEL_NAME))
        val definition = catalog.definitions(null)
            .firstOrNull { it.name == BotToolCatalog.ATTACH_TO_MODEL_NAME }
        assertNotNull(definition)
        val schema = definition!!.inputSchema as JsonObject
        val properties = schema.members["properties"] as JsonObject
        assertTrue(properties.members.containsKey("path"))
        assertTrue(properties.members.containsKey("fileId"))
        assertTrue(properties.members.containsKey("photoId"))
        assertEquals(
            listOf(JsonString("purpose")),
            (schema.members["required"] as JsonArray).values,
        )
        val page = properties.members["page"] as JsonObject
        assertEquals(JsonNumber("8"), page.members["maximum"])
        assertEquals(JsonBool(false), schema.members["additionalProperties"])
        assertEquals(
            BotToolPolicy.ASK,
            BotToolEffectClassifier.policy(
                BotToolCatalog.ATTACH_TO_MODEL_NAME,
                jsonObject(
                    "path" to JsonString("/dsh/workspace/photo.jpg"),
                    "purpose" to JsonString("看看这张照片"),
                ),
            ),
        )
    }

    @Test
    fun bothImageToolsShareTheStableModelGrantScope() {
        val attach = BotToolEffectClassifier.effect(
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/photo.jpg"),
                "purpose" to JsonString("看看这张照片"),
            ),
        )
        assertEquals(BotToolMutability.EXTERNAL_SEND, attach.mutability)
        assertEquals(BotToolPolicy.ASK, attach.policy)
        assertEquals("model.image.attach", attach.operation)
        assertEquals("attachment=/dsh/workspace/photo.jpg", attach.resource)
        assertEquals("/dsh/workspace/photo.jpg", attach.target)
        assertEquals("model:image", attach.grantResource)
        assertTrue(attach.canUseStandingGrant)
        assertEquals("model:image", attach.stableGrantResource)

        val readImage = BotToolEffectClassifier.effect(
            "read_image",
            jsonObject("path" to JsonString("/dsh/workspace/another.jpg")),
        )
        assertEquals(BotToolMutability.EXTERNAL_SEND, readImage.mutability)
        assertEquals(BotToolPolicy.ASK, readImage.policy)
        assertEquals("model:image", readImage.stableGrantResource)
        assertEquals("attachment=/dsh/workspace/another.jpg", readImage.resource)
    }

    @Test
    fun aStandingModelImageGrantAuthorizesTheNextImagePath() {
        val clock = 1_760_000_000_000L
        val grants = BotGrantStore(now = { clock })
        grants.recover()
        grants.add(
            BotGrant(
                botId = "main",
                tool = BotToolCatalog.ATTACH_TO_MODEL_NAME,
                operation = "model.image.attach",
                resource = "model:image",
                scope = BotGrantScope.SESSION,
                sessionId = "gb-main",
                decision = AuthzGrantDecision.ALLOW,
            ),
        )
        val authorizer = BotExecutionAuthorizer(grants, now = { clock })
        val effect = BotToolEffectClassifier.effect(
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/other.jpg"),
                "purpose" to JsonString("再看一张"),
            ),
        )
        val decision = authorizer.authorizeExecution(
            BotExecutionPrincipal(
                botId = "main",
                sessionId = "gb-main",
                sessionKind = BotSessionKind.CHAT,
            ),
            listOf(effect),
        )
        assertTrue(decision.reason, decision.allowed)
        assertEquals("grant matched", decision.reason)
    }

    @Test
    fun attachReturnsTheMCPImageBlockAndStructuredFacts() = runBlocking {
        val calls = ArrayList<BotModelAttachmentRequest>()
        val image = BotModelImage(
            data = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01),
            name = "camera.jpg",
            pixelWidth = 800,
            pixelHeight = 600,
        )
        val tools = runtime { request ->
            calls += request
            image
        }
        val result = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/photo.jpg"),
                "page" to JsonNumber("2"),
                "purpose" to JsonString("看看这张照片"),
            ),
        )
        assertFalse(result.isError)
        assertEquals(2, result.content.size)
        val text = result.content[0] as JsonObject
        assertEquals(JsonString("text"), text.members["type"])
        assertTrue((text.members["text"] as JsonString).value.contains("camera.jpg"))
        assertTrue((text.members["text"] as JsonString).value.contains("800x600"))
        val block = result.content[1] as JsonObject
        assertEquals(JsonString("image"), block.members["type"])
        assertEquals(JsonString("image/jpeg"), block.members["mimeType"])
        assertEquals(JsonString("camera.jpg"), block.members["name"])
        assertEquals(
            JsonString(Base64.getEncoder().encodeToString(image.data)),
            block.members["data"],
        )
        val structured = result.structuredContent as JsonObject
        assertEquals(JsonString("image"), structured.members["kind"])
        assertEquals(JsonString("camera.jpg"), structured.members["name"])
        assertEquals(JsonNumber("3"), structured.members["bytes"])
        assertEquals(JsonNumber("800"), structured.members["width"])
        assertEquals(JsonNumber("600"), structured.members["height"])
        assertEquals(1, calls.size)
        assertEquals("/dsh/workspace/photo.jpg", calls[0].path)
        assertEquals(2, calls[0].page)
        assertEquals("看看这张照片", calls[0].purpose)
        assertNull(calls[0].fileId)
        assertNull(calls[0].photoId)
    }

    @Test
    fun exactlyOneSourceAndAPurposeAreRequiredBeforeTheReaderRuns() = runBlocking {
        val reads = AtomicInteger()
        val tools = runtime { _ ->
            reads.incrementAndGet()
            image()
        }
        val both = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "fileId" to JsonString("art_1"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertEquals("invalid_arguments", errorCode(both))
        val neither = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject("purpose" to JsonString("看看")),
        )
        assertEquals("invalid_arguments", errorCode(neither))
        val noPurpose = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject("path" to JsonString("/dsh/workspace/a.jpg")),
        )
        assertEquals("invalid_arguments", errorCode(noPurpose))
        assertEquals(0, reads.get())
    }

    @Test
    fun aReadFailureIsImageUnavailableAndReleasesTheTurnSlot() = runBlocking {
        var fail = true
        val tools = runtime { _ ->
            if (fail) {
                fail = false
                throw BotModelImageException(
                    BotModelImageError.UNAVAILABLE,
                    "decode failed",
                )
            }
            image()
        }
        val first = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertEquals("image_unavailable", errorCode(first))
        val second = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertFalse(second.isError)
        val third = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertFalse(third.isError)
        val fourth = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertEquals("too_many_images", errorCode(fourth))
    }

    @Test
    fun twoImagesPerTurnAndBeginTurnOpensAFreshBudget() = runBlocking {
        val tools = runtime { image() }
        repeat(2) {
            val result = call(
                tools,
                BotToolCatalog.ATTACH_TO_MODEL_NAME,
                jsonObject(
                    "path" to JsonString("/dsh/workspace/a.jpg"),
                    "purpose" to JsonString("看看"),
                ),
            )
            assertFalse(result.isError)
        }
        val capped = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertEquals("too_many_images", errorCode(capped))
        tools.tools.beginTurn("gb-main")
        val fresh = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertFalse(fresh.isError)
    }

    @Test
    fun aHostWithoutAReaderIsHonestlyUnsupported() = runBlocking {
        val tools = runtime(null)
        val result = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
        )
        assertEquals("unsupported", errorCode(result))
    }

    @Test
    fun aTaskSessionIsDeniedBeforeTheReaderRuns() = runBlocking {
        val reads = AtomicInteger()
        val tools = runtime { _ ->
            reads.incrementAndGet()
            image()
        }
        val principal = MCPTestSupport.principal(
            sessionId = "gb-task",
            kind = "task",
        )
        val result = call(
            tools,
            BotToolCatalog.ATTACH_TO_MODEL_NAME,
            jsonObject(
                "path" to JsonString("/dsh/workspace/a.jpg"),
                "purpose" to JsonString("看看"),
            ),
            principal = principal,
        )
        assertEquals("permission_denied", errorCode(result))
        assertTrue(errorMessage(result).orEmpty().contains("task_scope:model_image_denied"))
        assertEquals(0, reads.get())
    }

    @Test
    fun aDeniedGrantStopsBeforeTheReaderAndTheToolIsInTheCallerCatalog() = runBlocking {
        val reads = AtomicInteger()
        val attribution = FakeAttribution()
        val tools = BotMCPToolRuntime(
            catalogProvider = catalog,
            attribution = attribution,
            grants = object : BotGrantPort {
                override suspend fun authorize(
                    context: BotToolCallContext,
                    name: String,
                    arguments: JsonValue,
                ): BotGrantDecision = BotGrantDecision(false, "missing-grant")
            },
            modelImageReader = BotModelImageReader { request ->
                reads.incrementAndGet()
                BotModelImage(
                    data = byteArrayOf(0xFF.toByte(), 0xD8.toByte()),
                    name = "x.jpg",
                    pixelWidth = 1,
                    pixelHeight = 1,
                )
            },
        )
        val arguments = jsonObject(
            "path" to JsonString("/dsh/workspace/a.jpg"),
            "purpose" to JsonString("看看"),
        )
        attribution.register(
            callId = "denied-1",
            tool = BotToolCatalog.ATTACH_TO_MODEL_NAME,
            arguments = arguments,
            principal = MCPTestSupport.principal(),
        )
        val result = tools.execute(BotToolCatalog.ATTACH_TO_MODEL_NAME, arguments)
        assertEquals("permission_denied", errorCode(result))
        assertEquals("missing-grant", errorMessage(result))
        assertEquals(0, reads.get())
    }

    private fun runtime(
        reader: (suspend (BotModelAttachmentRequest) -> BotModelImage)?,
    ): TestRuntime {
        val attribution = FakeAttribution()
        val tools = BotMCPToolRuntime(
            catalogProvider = catalog,
            attribution = attribution,
            modelImageReader = reader?.let { BotModelImageReader(it) },
            now = { 1_000L },
        )
        return TestRuntime(attribution, tools)
    }

    private data class TestRuntime(
        val attribution: FakeAttribution,
        val tools: BotMCPToolRuntime,
    ) {
        suspend fun call(
            name: String,
            arguments: JsonValue,
            principal: BotMCPPrincipal = MCPTestSupport.principal(),
        ): BotMCPCallResult {
            val callId = "call-${System.nanoTime()}"
            attribution.register(
                callId = callId,
                tool = name,
                arguments = arguments,
                principal = principal,
            )
            return tools.execute(name, arguments, JsonString(callId))
        }
    }

    private suspend fun call(
        runtime: TestRuntime,
        name: String,
        arguments: JsonValue,
        principal: BotMCPPrincipal = MCPTestSupport.principal(),
    ): BotMCPCallResult = runtime.call(name, arguments, principal)

    private fun image(): BotModelImage = BotModelImage(
        data = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x02),
        name = "photo.jpg",
        pixelWidth = 640,
        pixelHeight = 480,
    )

    private fun errorCode(result: BotMCPCallResult): String? =
        MCPTestSupport.errorCode(result)

    private fun errorMessage(result: BotMCPCallResult): String? =
        MCPTestSupport.errorMessage(result)

    private fun jsonObject(vararg pairs: Pair<String, JsonValue>): JsonObject =
        BotJson.objectOf(*pairs)
}
