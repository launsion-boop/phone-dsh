// The model-service device record: save, read back, delete and the rules that
// refuse a draft before anything is written.
// SPDX-License-Identifier: MIT
//
// This is the (a) half of the model-provider answer: `writable = YES` is only
// honest when a save really lands and the next facts walk really sees it. The
// tests below drive the store the app installs, over a temp directory, and the
// pure rules the host applies before the store: an accepted save must be readable
// byte-for-byte, a refused one must leave no record behind, and a corrupt file
// must be 未知 rather than "no service".
package com.phonedsh.probe

import com.phonedsh.ui.page.ProviderDraft
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderConfigStoreTest {

    private lateinit var directory: File

    private fun store(): ProviderConfigStore {
        directory = Files.createTempDirectory("provider-store").toFile()
        return ProviderConfigStore(File(directory, "settings/model-provider.v1.properties")) { }
    }

    private fun record(
        id: String = "local",
        name: String = "DeepSeek（本机）",
        model: String = "deepseek-flash",
        endpoint: String = "https://api.deepseek.com/anthropic",
    ): ProviderRecord = ProviderRecord(id = id, name = name, model = model, endpoint = endpoint)

    // ------------------------------------------------------------------ save

    @Test
    fun `save then read returns the same record`() {
        val store = store()
        assertEquals(ProviderWriteOutcome.Saved, store.save(record()))

        val read = store.read()
        assertTrue(read is ProviderStoreRead.Stored)
        assertEquals(record(), (read as ProviderStoreRead.Stored).record)
        assertEquals(record(), store.current())
    }

    @Test
    fun `save replaces the previous record`() {
        val store = store()
        store.save(record())
        assertEquals(
            ProviderWriteOutcome.Saved,
            store.save(record(name = "换了一个名字", endpoint = "https://api.deepseek.com/v1/messages")),
        )
        assertEquals("换了一个名字", store.current()?.name)
        assertEquals("https://api.deepseek.com/v1/messages", store.current()?.endpoint)
    }

    @Test
    fun `save leaves no temporary file behind`() {
        val store = store()
        store.save(record())
        val settings = File(directory, "settings")
        val names = settings.list()?.toList().orEmpty()
        assertEquals(listOf("model-provider.v1.properties"), names)
    }

    @Test
    fun `a missing file is empty, not unreadable`() {
        val store = store()
        assertEquals(ProviderStoreRead.Empty, store.read())
        assertNull(store.current())
    }

    @Test
    fun `a corrupt file is unreadable, never an empty service list`() {
        val failures = mutableListOf<String>()
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        file.writeText("{not json")
        val store = ProviderConfigStore(file) { failures += it }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
        assertNull(store.current())
        assertTrue(failures.any { it.contains("unreadable") })
    }

    @Test
    fun `malformed v2 profile collections fail closed and a save preserves the bytes`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        file.writeText("version=2\ndocument={\"version\":2,\"selectedId\":null,\"profiles\":\"bad\"}\n")
        val before = file.readBytes()
        val store = ProviderConfigStore(file) { }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
        assertTrue(store.save(record()) is ProviderWriteOutcome.Rejected)
        assertTrue(before.contentEquals(file.readBytes()))
    }

    @Test
    fun `unknown v2 document fields are rejected instead of erased on the next write`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        file.writeText(
            "version=2\ndocument={\"version\":2,\"selectedId\":\"one\",\"profiles\":[" +
                "{\"id\":\"one\",\"name\":\"One\",\"model\":\"m\"," +
                "\"endpoint\":\"https://one.example.test/v1\",\"reasoningEffort\":null," +
                "\"credentialRef\":null,\"models\":[{\"id\":\"m\",\"name\":null," +
                "\"contextWindow\":null,\"maxTokens\":null,\"textInput\":true," +
                "\"imageInput\":false,\"reasoningEffort\":null,\"futureModelField\":1}]," +
                "\"futureProfileField\":true}]}\n",
        )
        val before = file.readBytes()
        val store = ProviderConfigStore(file) { }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
        assertTrue(store.delete("one") is ProviderWriteOutcome.Rejected)
        assertTrue(before.contentEquals(file.readBytes()))
    }

    @Test
    fun `unknown legacy properties fail closed rather than disappearing on migration`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        file.writeText(
            "version=1\nid=local\nname=Legacy\nmodel=deepseek-flash\n" +
                "endpoint=https://api.deepseek.com/anthropic\nfuture=preserve-me\n",
        )
        val before = file.readBytes()
        val store = ProviderConfigStore(file) { }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
        assertTrue(store.save(record()) is ProviderWriteOutcome.Rejected)
        assertTrue(before.contentEquals(file.readBytes()))
    }

    @Test
    fun `malformed v2 profile collections fail closed and writes preserve the original bytes`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        val raw = "version=2\ndocument={\"version\":2,\"selectedId\":null,\"profiles\":\"bad\"}\n"
        file.writeText(raw)
        val before = file.readBytes()
        val store = ProviderConfigStore(file) { }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
        assertTrue(store.save(record()) is ProviderWriteOutcome.Rejected)
        assertTrue(before.contentEquals(file.readBytes()))
    }

    @Test
    fun `unknown v2 profile and model members are rejected instead of erased`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        val document = """{"version":2,"selectedId":"one","profiles":[{"id":"one","name":"One","model":"m","endpoint":"https://one.example.test/v1","reasoningEffort":null,"credentialRef":null,"futureProfileField":true,"models":[{"id":"m","name":null,"contextWindow":null,"maxTokens":null,"textInput":true,"imageInput":false,"reasoningEffort":null,"futureModelField":1}]}]}"""
        file.writeText("version=2\ndocument=$document\n")
        val before = file.readBytes()
        val store = ProviderConfigStore(file) { }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
        assertTrue(store.delete("one") is ProviderWriteOutcome.Rejected)
        assertTrue(before.contentEquals(file.readBytes()))
    }

    @Test
    fun `a record with a non-http endpoint is unreadable`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        file.writeText(
            "version=1\nid=local\nname=x\nmodel=m\nendpoint=file:///etc/passwd\n",
        )
        val store = ProviderConfigStore(file) { }

        assertEquals(ProviderStoreRead.Unreadable, store.read())
    }

    @Test
    fun `an unwritable location reports unavailable instead of a silent success`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val blocker = File(directory, "blocker")
        blocker.writeText("not a directory")
        val store = ProviderConfigStore(File(blocker, "settings/model-provider.v1.properties")) { }

        assertEquals(ProviderWriteOutcome.Unavailable, store.save(record()))
        assertEquals(ProviderStoreRead.Empty, store.read())
    }

    // ---------------------------------------------------------------- delete

    @Test
    fun `delete removes the record and reports the requested state`() {
        val store = store()
        store.save(record())
        assertEquals(ProviderWriteOutcome.Deleted, store.delete())
        assertEquals(ProviderStoreRead.Empty, store.read())
    }

    @Test
    fun `deleting an absent record is already the requested state`() {
        val store = store()
        assertEquals(ProviderWriteOutcome.Deleted, store.delete())
    }

    // -------------------------------------------------------------- the draft

    @Test
    fun `a saved draft becomes the record the page will read`() {
        val draft = ProviderDraft(
            id = "local",
            name = "  我的服务  ",
            endpoint = "https://api.deepseek.com/anthropic",
            model = "deepseek-flash",
            isNew = true,
        )

        val built = ProviderConfigStore.recordOf(
            draft = draft,
            previous = null,
            launchEndpoint = null,
            launchModel = "launch-model",
        )

        assertEquals("我的服务", built.name)
        assertEquals("https://api.deepseek.com/anthropic", built.endpoint)
        assertEquals("deepseek-flash", built.model)
        assertEquals("local", built.id)
    }

    @Test
    fun `new profile identity and credential reference never inherit the selected profile`() {
        val selected = record(id = "selected").copy(credentialRef = "legacy.selected")
        val built = ProviderConfigStore.recordOf(
            draft = ProviderDraft(
                id = "", name = "Added", endpoint = "https://added.example.test/v1",
                model = "added-model", isNew = true,
            ),
            previous = selected,
            launchEndpoint = null,
            launchModel = "ignored",
        )
        assertNotEquals(selected.id, built.id)
        assertEquals(ProviderRecord.providerCredentialRef(built.id), built.credentialAccount())
        assertNotEquals(selected.credentialAccount(), built.credentialAccount())
    }

    @Test
    fun `a blank endpoint on an existing service keeps what was stored`() {
        val previous = record(endpoint = "https://api.deepseek.com/anthropic")
        val draft = ProviderDraft(id = "local", name = "改名", endpoint = "", model = "", isNew = false)

        val built = ProviderConfigStore.recordOf(
            draft = draft,
            previous = previous,
            launchEndpoint = "https://ignored.example",
            launchModel = "ignored",
        )

        assertEquals("https://api.deepseek.com/anthropic", built.endpoint)
        // An empty model keeps the row's model, never a blank id.
        assertEquals("deepseek-flash", built.model)
    }

    @Test
    fun `a blank endpoint with no record falls back to the launch service`() {
        val draft = ProviderDraft(id = "", name = "本机", endpoint = "", model = "", isNew = false)

        val built = ProviderConfigStore.recordOf(
            draft = draft,
            previous = null,
            launchEndpoint = "https://api.deepseek.com/anthropic",
            launchModel = "deepseek-flash",
        )

        assertEquals("https://api.deepseek.com/anthropic", built.endpoint)
        assertEquals("deepseek-flash", built.model)
        assertEquals(ProviderConfigStore.DEFAULT_ID, built.id)
    }

    // ---------------------------------------------------------------- rules

    @Test
    fun `the endpoint rule accepts public https and loopback http`() {
        assertNull(ProviderDraftRules.endpointRejection("https://api.deepseek.com/anthropic"))
        assertNull(ProviderDraftRules.endpointRejection("http://127.0.0.1:8080/v1"))
    }

    @Test
    fun `the endpoint rule refuses schemes, missing hosts and embedded credentials`() {
        listOf(
            "",
            "api.deepseek.com",
            "file:///etc/passwd",
            "https://",
            "https://user:pass@api.deepseek.com",
            "https://api.deepseek.com/v1?token=secret",
            "https://api.deepseek.com/v1#secret",
            "http://public.example.test/v1",
        ).forEach { raw ->
            assertNotNull("expected a rejection for '$raw'", ProviderDraftRules.endpointRejection(raw))
        }
    }

    @Test
    fun `the key rule matches the keystore floor`() {
        assertNull(ProviderDraftRules.keyRejection("sk-1234567890"))
        assertNotNull(ProviderDraftRules.keyRejection("short"))
        assertNotNull(ProviderDraftRules.keyRejection("has space in it"))
    }

    @Test
    fun `two profiles persist and selection moves without losing either`() {
        val store = store()
        assertEquals(ProviderWriteOutcome.Saved, store.save(record(id = "one", name = "One")))
        assertEquals(ProviderWriteOutcome.Saved, store.save(record(id = "two", name = "Two")))
        val snapshot = requireNotNull(store.snapshot())
        assertEquals(listOf("one", "two"), snapshot.profiles.map { it.id })
        assertEquals("one", snapshot.selected?.id)

        assertEquals(ProviderWriteOutcome.Saved, store.select("two"))
        assertEquals("two", store.current()?.id)
        assertEquals("two", store.snapshot()?.selectedId)
        assertEquals(2, store.snapshot()?.profiles?.size)

        assertEquals(ProviderWriteOutcome.Saved, store.delete("one"))
        assertEquals(listOf("two"), store.snapshot()?.profiles?.map { it.id })
        assertEquals("two", store.snapshot()?.selectedId)
    }

    @Test
    fun `creating a profile can select it atomically without rewriting the prior profile`() {
        val store = store()
        val original = record(id = "one", name = "One")
        val added = record(id = "two", name = "Two")
        assertEquals(ProviderWriteOutcome.Saved, store.save(original))
        assertEquals(ProviderWriteOutcome.Saved, store.save(added, selectAsDefault = true))
        assertEquals("two", store.snapshot()?.selectedId)
        assertEquals(listOf("one", "two"), store.snapshot()?.profiles?.map { it.id })
        assertEquals(original, store.snapshot()?.profiles?.first { it.id == "one" })
    }

    @Test
    fun `version one migrates to one profile with its legacy key account and is not rewritten on read`() {
        directory = Files.createTempDirectory("provider-store").toFile()
        val file = File(directory, "settings/model-provider.v1.properties")
        file.parentFile!!.mkdirs()
        file.writeText("version=1\nid=local\nname=Legacy\nmodel=deepseek-flash\nendpoint=https://api.deepseek.com/anthropic\n")
        val store = ProviderConfigStore(file) { }

        val stored = store.read() as ProviderStoreRead.Stored
        assertEquals("Legacy", stored.record.name)
        assertEquals(ApiKeyStore.ACCOUNT, stored.record.credentialAccount())
        assertEquals(1, stored.snapshot.profiles.size)
        // A read is not a write: an old document stays old until a deliberate save.
        assertTrue(file.readText(Charsets.UTF_8).contains("version=1"))
        assertEquals(ProviderWriteOutcome.Saved, store.select("local"))
        assertTrue(file.readText(Charsets.UTF_8).contains("version=2"))
    }

    @Test
    fun `model definitions effort and credential ref survive the document round trip`() {
        val store = store()
        val models = listOf(
            ProviderModel(id = "deepseek-chat", name = "Chat", contextWindow = 128000, maxTokens = 8192,
                textInput = true, imageInput = true, reasoningEffort = "high"),
            ProviderModel(id = "deepseek-reasoner", contextWindow = 64000),
        )
        val record = record(id = "rich", name = "Rich").copy(
            reasoningEffort = "low",
            models = models,
            credentialRef = "provider.rich",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(record))
        assertEquals(record, store.current())
        assertEquals("provider.rich", store.current()?.credentialAccount())
    }

    @Test
    fun `an empty record file is not left half written`() {
        val store = store()
        store.save(record())
        val file = File(directory, "settings/model-provider.v1.properties")
        assertTrue(file.isFile)
        assertFalse(File(file.parentFile, file.name + ".tmp").exists())
    }
}
