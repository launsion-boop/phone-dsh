// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real attachment policy, prompt codec and workspace layout with
 * `bot-attachments.json` plus its `bot-attachments.phone.json` overlay.
 */
class BotAttachmentGoldenTest {
    @Test
    fun goldenLimitsMatchThePolicy() {
        val fixture = GoldenFixture.mergedObject("bot-attachments")
        val limits = GoldenFixture.objectValue(fixture, "limits")
        assertEquals(GoldenFixture.requireLong(limits, "maxAttachments").toInt(),
            BotAttachmentPolicy.MAX_COUNT)
        assertEquals(GoldenFixture.requireLong(limits, "maxBytes"), BotAttachmentPolicy.MAX_BYTES)
    }

    @Test
    fun goldenPromptBlockUsesTheFrozenPhoneBytes() {
        val fixture = GoldenFixture.mergedObject("bot-attachments")
        val prompt = GoldenFixture.objectValue(fixture, "promptBlock")
        val items = GoldenFixture.objects(prompt, "items").map(BotAttachment::fromJson)
        val upstream = GoldenFixture.requireString(prompt, "prompt")
        assertTrue("the upstream export keeps the Mac sentence",
            upstream.contains("saved on this Mac"))
        val expected = GoldenFixture.requireString(fixture, "promptBlockPhone")
        assertTrue(expected.contains(BotAttachmentPrompt.EXPLANATION))
        assertEquals(expected, BotAttachmentPrompt.block(items))
        assertEquals(GoldenFixture.requireString(fixture, "emptyBlock"),
            BotAttachmentPrompt.block(emptyList()))
    }

    @Test
    fun everyGoldenSafeNameCaseUsesTheRealSanitizer() {
        val cases = GoldenFixture.objects(GoldenFixture.mergedObject("bot-attachments"), "safeNameCases")
        assertTrue("safeNameCases must not be empty", cases.isNotEmpty())
        for ((index, vector) in cases.withIndex()) {
            val input = GoldenFixture.requireString(vector, "input")
            val expected = GoldenFixture.requireString(vector, "safeName")
            assertEquals("safeNameCases[$index] $input", expected, BotAttachmentPolicy.safeName(input))
        }
    }

    @Test
    fun everyGoldenImportPathCaseUsesTheRealWorkspaceLayout() {
        val cases = GoldenFixture.objects(GoldenFixture.mergedObject("bot-attachments"), "importPathCases")
        assertTrue("importPathCases must not be empty", cases.isNotEmpty())
        for ((index, vector) in cases.withIndex()) {
            val botID = GoldenFixture.requireString(vector, "botID")
            val messageID = GoldenFixture.requireString(vector, "messageID")
            val expectedRoot = GoldenFixture.requireString(vector, "botRoot")
            val expectedDirectory = GoldenFixture.requireString(vector, "directory")
            val root = BotWorkspaceLayout.botRoot(botID)
            assertEquals("importPathCases[$index].botRoot", expectedRoot, root)
            assertEquals("importPathCases[$index].directory", expectedDirectory,
                "$root/imports/attachments-$messageID")
        }
    }

    @Test
    fun everyGoldenParseVectorUsesTheRealParser() {
        val cases = GoldenFixture.objects(GoldenFixture.mergedObject("bot-attachments"), "parse")
        assertTrue("parse vectors must not be empty", cases.isNotEmpty())
        for ((index, vector) in cases.withIndex()) {
            val input = GoldenFixture.requireString(vector, "input")
            val output = GoldenFixture.objectValue(vector, "output")
            val parsed = BotAttachmentPrompt.parse(input)
            assertEquals("parse[$index].text", GoldenFixture.string(output, "text"), parsed.text)
            val expected = GoldenFixture.objects(output, "attachments").map(BotAttachment::fromJson)
            assertEquals("parse[$index].attachments", expected, parsed.attachments)
        }
    }

    @Test
    fun textWithoutMarkersIsReturnedUnchanged() {
        val text = "no attachments here"
        val parsed = BotAttachmentPrompt.parse(text)
        assertEquals(text, parsed.text)
        assertTrue(parsed.attachments.isEmpty())
    }

    @Test
    fun everyGoldenKindForVectorUsesTheRealClassifier() {
        val cases = GoldenFixture.objects(GoldenFixture.mergedObject("bot-attachments"), "kindFor")
        assertTrue("kindFor must not be empty", cases.isNotEmpty())
        for ((index, vector) in cases.withIndex()) {
            val name = GoldenFixture.requireString(vector, "name")
            val mimeType = GoldenFixture.requireString(vector, "mimeType")
            val expected = GoldenFixture.requireString(vector, "kind")
            assertEquals("kindFor[$index] $name", expected, BotAttachmentPolicy.kind(name, mimeType))
        }
    }

    @Test
    fun goldenPhonePromptIsNotSynthesizedFromTheUpstreamSentence() {
        val fixture = GoldenFixture.mergedObject("bot-attachments")
        val upstream = GoldenFixture.requireString(fixture, "promptBlock", "prompt")
        val phone = GoldenFixture.requireString(fixture, "promptBlockPhone")
        assertFalse("phone bytes must not equal the Mac export", upstream == phone)
    }
}
