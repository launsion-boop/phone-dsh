// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import com.phonedsh.ui.page.ProviderDraft
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.net.URL

class HostProviderConnectionTest {
    private val key = "sk-test-NOT-A-REAL-KEY-0000"

    @Test
    fun `openai probe uses the ios path header and one token ping`() = runBlocking {
        val transport = RecordingTransport(listOf(200))
        val result = testProviderConnection(
            draft = draft(endpoint = "https://api.example.test/v1", key = key),
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        val request = transport.requests.single()
        assertTrue(result is ProviderConnectionTestResult.Success)
        assertEquals("https://api.example.test/v1/chat/completions", request.url.toString())
        assertEquals("Bearer $key", request.headers["Authorization"])
        assertEquals("application/json", request.headers["Content-Type"])
        val body = request.body.toString(Charsets.UTF_8)
        assertTrue(body.contains("\"max_tokens\":1"))
        assertTrue(body.contains("\"content\":\"ping\""))
        assertFalse((result as ProviderConnectionTestResult.Success).message.contains(key))
    }

    @Test
    fun `anthropic probe avoids a duplicated v1 and uses the messages headers`() = runBlocking {
        val transport = RecordingTransport(listOf(200))
        val result = testProviderConnection(
            draft = draft(endpoint = "https://api.example.test/anthropic/v1", key = key),
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        val request = transport.requests.single()
        assertTrue(result is ProviderConnectionTestResult.Success)
        assertEquals("https://api.example.test/anthropic/v1/messages", request.url.toString())
        assertEquals(key, request.headers["x-api-key"])
        assertEquals("2023-06-01", request.headers["anthropic-version"])
        assertEquals("Bearer $key", request.headers["Authorization"])
    }

    @Test
    fun `a not found falls through to the alternate protocol without exposing response data`() = runBlocking {
        val transport = RecordingTransport(listOf(404, 200))
        val result = testProviderConnection(
            draft = draft(endpoint = "https://api.example.test/service", key = key),
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        assertTrue(result is ProviderConnectionTestResult.Success)
        assertEquals(2, transport.requests.size)
        assertEquals("https://api.example.test/service/chat/completions", transport.requests[0].url.toString())
        assertEquals("https://api.example.test/service/v1/messages", transport.requests[1].url.toString())
    }

    @Test
    fun `an existing provider reads its stored key only when the editor has no replacement`() = runBlocking {
        val secure = ApiKeyStore(FakeSecureStore(SecureLookup.Found(key.toByteArray())))
        val transport = RecordingTransport(listOf(200))
        val result = testProviderConnection(
            draft = draft(endpoint = "https://api.example.test", key = "", isNew = false),
            keyProvider = { secure.readKey() },
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        assertTrue(result is ProviderConnectionTestResult.Success)
        assertEquals("Bearer $key", transport.requests.single().headers["Authorization"])
    }

    @Test
    fun `nonselected profile uses its own credential account instead of the selected profile key`() = runBlocking {
        val profileA = ProviderRecord(
            id = "profile-a", name = "A", model = "model-a", endpoint = "https://a.example.test/v1",
            credentialRef = "provider.profile-a",
        )
        val profileB = ProviderRecord(
            id = "profile-b", name = "B", model = "model-b", endpoint = "https://b.example.test/v1",
            credentialRef = "provider.profile-b",
        )
        val snapshot = ProviderSnapshot(listOf(profileA, profileB), selectedId = profileA.id)
        val providerRead = ProviderStoreRead.Stored(profileA, snapshot)
        val secure = ApiKeyStore(MapSecureStore())
        val keyA = "sk-profile-a-secret-0000"
        val keyB = "sk-profile-b-secret-1111"
        secure.save(keyA, profileA.credentialAccount())
        secure.save(keyB, profileB.credentialAccount())
        val draft = draft(endpoint = "https://b.example.test/v1", key = "", isNew = false)
            .copy(id = profileB.id, model = profileB.model)
        val transport = RecordingTransport(listOf(200))

        val result = testProviderConnection(
            draft = draft,
            keyProvider = {
                secure.readKey(requireNotNull(providerAccountFor(draft, providerRead, profileA.credentialAccount())))
            },
            storedEndpointProvider = { profileB.endpoint },
            launchEndpointProvider = { profileA.endpoint },
            transport = transport,
        )

        assertTrue(result is ProviderConnectionTestResult.Success)
        assertEquals("Bearer $keyB", transport.requests.single().headers["Authorization"])
        assertFalse(transport.requests.single().headers["Authorization"].orEmpty().contains(keyA))
    }

    @Test
    fun `new providers never borrow an unrelated stored key`() = runBlocking {
        val secure = ApiKeyStore(FakeSecureStore(SecureLookup.Found(key.toByteArray())))
        var reads = 0
        val transport = RecordingTransport(listOf(200))
        val result = testProviderConnection(
            draft = draft(endpoint = "https://api.example.test", key = "", isNew = true),
            keyProvider = { reads += 1; secure.readKey() },
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        assertTrue(result is ProviderConnectionTestResult.Failure)
        assertEquals("还没有可用于测试的密钥。", result.message)
        assertEquals(0, reads)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `embedded credentials query strings and public cleartext are rejected before sending`() = runBlocking {
        val invalidEndpoints = listOf(
            "https://user:pass@api.example.test/v1",
            "https://api.example.test/v1?token=secret",
            "http://api.example.test/v1",
        )
        invalidEndpoints.forEach { endpoint ->
            val transport = RecordingTransport(listOf(200))
            val result = testProviderConnection(
                draft = draft(endpoint = endpoint, key = key),
                storedEndpointProvider = { null },
                launchEndpointProvider = { null },
                transport = transport,
            )
            assertTrue(result is ProviderConnectionTestResult.Failure)
            assertFalse(result.message.contains("user"))
            assertFalse(result.message.contains("pass"))
            assertFalse(result.message.contains("secret"))
            assertTrue(transport.requests.isEmpty())
        }
    }

    @Test
    fun `the only cleartext probe accepted by app policy is loopback`() = runBlocking {
        val transport = RecordingTransport(listOf(200))
        val result = testProviderConnection(
            draft = draft(endpoint = "http://127.0.0.1:8000/v1", key = key),
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        assertTrue(result is ProviderConnectionTestResult.Success)
        assertEquals("http://127.0.0.1:8000/v1/chat/completions", transport.requests.single().url.toString())
    }

    @Test
    fun `get models uses native get and binds result to its request and profile`() = runBlocking {
        val transport = RecordingTransport(
            statuses = listOf(200),
            bodies = listOf("""{"data":[{"id":"model-a"},{"id":"model-b"},{"id":"model-a"}]}"""),
        )
        val result = getProviderModels(
            draft = draft(endpoint = "https://api.example.test/anthropic", key = key, isNew = false),
            requestId = "models-request-7",
            transport = transport,
        )
        val request = transport.requests.single()
        assertEquals("GET", request.method)
        assertEquals("https://api.example.test/anthropic/models", request.url.toString())
        assertEquals("Bearer $key", request.headers["Authorization"])
        assertEquals(key, request.headers["x-api-key"])
        assertEquals("2023-06-01", request.headers["anthropic-version"])
        assertArrayEquals(byteArrayOf(), request.body)
        assertEquals("models-request-7", result.requestId)
        assertEquals("saved-profile", result.profileId)
        assertEquals(listOf("model-a", "model-b"), result.models)
        assertTrue(result.succeeded)
        assertFalse(result.message.contains(key))
    }

    @Test
    fun `provider test result keeps request and profile identity`() = runBlocking {
        val result = testProviderConnectionBound(
            draft(endpoint = "https://api.example.test/v1", key = key, isNew = false),
            requestId = "test-request-2",
            transport = RecordingTransport(listOf(200)),
        )
        assertEquals("test-request-2", result.requestId)
        assertEquals("saved-profile", result.profileId)
        assertTrue(result.result is ProviderConnectionTestResult.Success)
    }

    @Test
    fun `generated new profile receipt matches its original blank-id draft`() {
        val draft = ProviderDraft(id = "", name = "New", isNew = true)
        val result = HostProviderSaveResult(
            recordWritten = true,
            succeeded = true,
            message = "saved",
            requestId = "request-1",
            profileId = "generated-id",
            isNew = true,
        )
        assertTrue(providerSaveResultMatchesDraft(result, draft))
        assertFalse(providerSaveResultMatchesDraft(result.copy(isNew = false), draft))
        assertFalse(providerSaveResultMatchesDraft(result, draft.copy(isNew = false, id = "existing")))
    }

    @Test
    fun `provider save receipt follows a real store write and readback`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-bound-save").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "", name = "Fixture service", endpoint = "https://api.example.test/v1",
                model = "fixture-model", models = listOf(com.phonedsh.ui.page.ProviderModelDraft("fixture-model")),
                apiKey = "", isNew = true,
            ),
            requestId = "save-request-9",
            store = store,
            keyStore = null,
            launch = ProbeLaunchConfig(modelName = "launch-model"),
        )
        assertTrue(result.succeeded)
        assertTrue(result.recordWritten)
        assertEquals("save-request-9", result.requestId)
        assertNotNull(result.profileId)
        assertTrue(result.isNew)
        assertEquals(result.profileId, store.current()?.id)
        assertEquals(result.profileId, store.snapshot()?.selectedId)
        assertEquals("fixture-model", store.current()?.model)
    }

    @Test
    fun `provider profile write is reported as partial when key write fails`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-partial-save").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val keyStore = ApiKeyStore(MutableFailingSecureStore())
        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "", name = "Fixture service", endpoint = "https://api.example.test/v1",
                model = "fixture-model", models = listOf(com.phonedsh.ui.page.ProviderModelDraft("fixture-model")),
                apiKey = key, isNew = true,
            ),
            requestId = "save-request-partial",
            store = store,
            keyStore = keyStore,
        )
        assertFalse(result.succeeded)
        assertTrue("profile write is called out separately", result.recordWritten)
        assertEquals("save-request-partial", result.requestId)
        assertNotNull(result.profileId)
        assertTrue(result.isNew)
        assertEquals(result.profileId, store.current()?.id)
        assertEquals("Fixture service", store.current()?.name)
        assertTrue(result.message.contains("密钥写入失败"))
    }

    @Test
    fun `blank new profile is added without replacing selected service or sharing its key`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-profile-isolation").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val secure = MapSecureStore()
        val keyStore = ApiKeyStore(secure)
        val oldAccount = "provider.existing"
        val oldKey = "sk-existing-key-0000"
        val newKey = "sk-newprofile-key-1111"
        keyStore.save(oldKey, oldAccount)
        val old = ProviderRecord(
            id = "existing", name = "Existing", model = "existing-model",
            endpoint = "https://existing.example.test/v1", credentialRef = oldAccount,
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(old))

        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "", name = "Added", endpoint = "https://added.example.test/v1",
                model = "added-model", models = listOf(com.phonedsh.ui.page.ProviderModelDraft("added-model")),
                apiKey = newKey, isNew = true,
            ),
            requestId = "new-profile-request",
            store = store,
            keyStore = keyStore,
            launch = ProbeLaunchConfig(modelName = "launch-model"),
        )

        val snapshot = requireNotNull(store.snapshot())
        assertTrue(result.succeeded)
        assertTrue(result.isNew)
        assertEquals("new-profile-request", result.requestId)
        assertNotNull(result.profileId)
        assertNotEquals(old.id, result.profileId)
        assertEquals(listOf("existing", result.profileId), snapshot.profiles.map { it.id })
        assertEquals(result.profileId, snapshot.selectedId)
        assertEquals(old, snapshot.profiles.first { it.id == old.id })
        val newRecord = snapshot.profiles.first { it.id == result.profileId }
        assertEquals(ProviderRecord.providerCredentialRef(newRecord.id), newRecord.credentialAccount())
        assertNotEquals(old.credentialAccount(), newRecord.credentialAccount())
        assertEquals(oldKey, keyStore.readKey(oldAccount))
        assertEquals(newKey, keyStore.readKey(newRecord.credentialAccount()))
    }

    @Test
    fun `editing the empty store local launch row creates its first profile with the captured key account`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-local-launch-edit").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val launch = ProbeLaunchConfig(
            deepseekBaseUrl = "https://legacy.example.test/v1",
            modelName = "legacy-model",
            credentialAccount = ApiKeyStore.ACCOUNT,
        )
        val secure = MapSecureStore()
        val keyStore = ApiKeyStore(secure)
        val key = "sk-legacy-local-0000"
        keyStore.save(key, ApiKeyStore.ACCOUNT)
        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "local", name = "Legacy edited", endpoint = "", model = "",
                models = listOf(com.phonedsh.ui.page.ProviderModelDraft(id = "legacy-model")),
                isNew = false,
            ),
            requestId = "edit-local-launch",
            store = store,
            keyStore = keyStore,
            launch = launch,
        )

        assertTrue(result.succeeded)
        assertEquals("local", result.profileId)
        assertEquals("https://legacy.example.test/v1", store.current()?.endpoint)
        assertEquals("legacy-model", store.current()?.model)
        assertEquals(ApiKeyStore.ACCOUNT, store.current()?.credentialAccount())
        assertEquals(key, keyStore.readKey(ApiKeyStore.ACCOUNT))
    }

    @Test
    fun `updating a nonselected profile reads back by profile id and preserves selection`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-nonselected-update").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val selected = ProviderRecord("one", "One", "m1", "https://one.example.test/v1")
        val edited = ProviderRecord("two", "Two", "m2", "https://two.example.test/v1")
        assertEquals(ProviderWriteOutcome.Saved, store.save(selected))
        assertEquals(ProviderWriteOutcome.Saved, store.save(edited))
        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "two", name = "Two updated", endpoint = "", model = "m2",
                models = listOf(com.phonedsh.ui.page.ProviderModelDraft("m2")), isNew = false,
            ),
            requestId = "update-two",
            store = store,
            keyStore = null,
            launch = ProbeLaunchConfig(modelName = "launch-model"),
        )
        assertTrue(result.succeeded)
        assertFalse(result.isNew)
        assertEquals("two", result.profileId)
        assertEquals("one", store.snapshot()?.selectedId)
        assertEquals("Two updated", store.snapshot()?.profiles?.first { it.id == "two" }?.name)
    }

    @Test
    fun `new blank id never falls back to selected endpoint or stored key for test or catalog reads`() = runBlocking {
        var endpointReads = 0
        var keyReads = 0
        val request = draft(endpoint = "", key = "", isNew = true)
        val transport = RecordingTransport(listOf(200), listOf("{\"data\":[{\"id\":\"wrong\"}]"))
        val test = testProviderConnection(
            draft = request,
            keyProvider = { keyReads++; key },
            storedEndpointProvider = { endpointReads++; "https://selected.example.test/v1" },
            launchEndpointProvider = { "https://launch.example.test/v1" },
            transport = transport,
        )
        assertTrue(test is ProviderConnectionTestResult.Failure)
        assertEquals(0, endpointReads)
        assertEquals(0, keyReads)
        assertTrue(transport.requests.isEmpty())

        val catalog = getProviderModels(
            draft = request,
            requestId = "new-catalog",
            keyProvider = { keyReads++; key },
            storedEndpointProvider = { endpointReads++; "https://selected.example.test/v1" },
            launchEndpointProvider = { "https://launch.example.test/v1" },
            transport = transport,
        )
        assertNull(catalog.models)
        assertEquals(0, endpointReads)
        assertEquals(0, keyReads)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `explicit override endpoint does not bind a stored selected profile key`() {
        val selected = ProviderRecord(
            id = "profile-b", name = "B", model = "model-b",
            endpoint = "https://b.example.test/v1", credentialRef = "provider.profile-b",
        )
        val launch = ProbeLaunchConfig.fromValues(
            extraBaseUrl = "https://override.example.test/v1",
            storedProfile = selected,
        )
        assertEquals("https://override.example.test/v1", launch.deepseekBaseUrl)
        assertNull(launch.providerProfileId)
        assertNull(launch.credentialAccount)
        assertNull(launch.modelCredentialProvider())
    }

    @Test
    fun `stale unreadable key removal fails before changing service metadata`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-save-unreadable-key").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val record = ProviderRecord(
            id = "locked", name = "Before", model = "m", endpoint = "https://locked.example.test/v1",
            credentialRef = "provider.locked",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(record))
        val before = file.readBytes()
        val secure = MapSecureStore(unreadable = true)
        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "locked", name = "After", endpoint = "", model = "m",
                models = listOf(com.phonedsh.ui.page.ProviderModelDraft(id = "m")),
                removeStoredKey = true, isNew = false,
            ),
            requestId = "stale-delete",
            store = store,
            keyStore = ApiKeyStore(secure),
        )
        assertFalse(result.succeeded)
        assertFalse(result.recordWritten)
        assertFalse(result.isNew)
        assertEquals("stale-delete", result.requestId)
        assertEquals(record, store.current())
        assertTrue(before.contentEquals(file.readBytes()))
        assertEquals(0, secure.deleteCalls)
    }

    @Test
    fun `save rejects query fragment and public cleartext before any config or key write`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-save-url-policy").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val original = ProviderRecord(
            id = "existing", name = "Existing", model = "m", endpoint = "https://api.example.test/v1",
            credentialRef = "provider.existing",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(original))
        val secure = MapSecureStore()
        val keyStore = ApiKeyStore(secure)
        val invalidUrls = listOf(
            "https://api.example.test/v1?token=query-secret",
            "https://api.example.test/v1#fragment-secret",
            "http://public.example.test/v1",
        )
        for ((index, endpoint) in invalidUrls.withIndex()) {
            val before = file.readBytes()
            val result = saveProviderDraft(
                draft = ProviderDraft(
                    id = original.id, name = "Changed", endpoint = endpoint, model = "m",
                    models = listOf(com.phonedsh.ui.page.ProviderModelDraft(id = "m")),
                    apiKey = "sk-valid-replacement-0000", isNew = false,
                ),
                requestId = "unsafe-url-$index",
                store = store,
                keyStore = keyStore,
                launch = ProbeLaunchConfig(modelName = "launch-model"),
            )
            assertFalse(result.succeeded)
            assertFalse(result.recordWritten)
            assertTrue(before.contentEquals(file.readBytes()))
            assertFalse(result.message.contains("query-secret"))
            assertFalse(result.message.contains("fragment-secret"))
        }
        assertEquals(0, secure.putCalls)
        assertEquals(original, store.current())
    }

    @Test
    fun `provider deletion blocks unreadable keys and leaves both profile and key untouched`() {
        val file = File(Files.createTempDirectory("provider-delete-unreadable").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val record = ProviderRecord(
            id = "locked", name = "Locked", model = "m", endpoint = "https://locked.example.test/v1",
            credentialRef = "provider.locked",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(record))
        val secure = MapSecureStore(unreadable = true)
        val result = deleteProviderRecord(record.id, store, ApiKeyStore(secure))
        assertFalse(result.profileRemoved)
        assertFalse(result.keyRemoved)
        assertEquals(1, store.snapshot()?.profiles?.size)
        assertEquals(0, secure.deleteCalls)
    }

    @Test
    fun `provider deletion keeps the profile when credential removal is not confirmed`() {
        val file = File(Files.createTempDirectory("provider-delete-write-failure").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val record = ProviderRecord(
            id = "delete-fail", name = "Keep me", model = "m", endpoint = "https://delete.example.test/v1",
            credentialRef = "provider.delete-fail",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(record))
        val secure = MapSecureStore(failDelete = true)
        val keyStore = ApiKeyStore(secure)
        keyStore.save("sk-delete-failure-0000", record.credentialAccount())

        val receipt = deleteProviderRecord(record.id, store, keyStore)

        assertFalse(receipt.profileRemoved)
        assertFalse(receipt.keyRemoved)
        assertEquals(record, store.snapshot()?.profiles?.single())
        assertEquals("sk-delete-failure-0000", keyStore.readKey(record.credentialAccount()))
    }

    @Test
    fun `deleting one of two provider services succeeds and keeps the other selected`() {
        val file = File(Files.createTempDirectory("provider-delete-one-of-two").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val removed = ProviderRecord(
            id = "delete-one", name = "Remove me", model = "m", endpoint = "https://one.example.test/v1",
            credentialRef = "provider.delete-one",
        )
        val kept = ProviderRecord(
            id = "keep-me", name = "Keep me", model = "m", endpoint = "https://keep.example.test/v1",
            credentialRef = "provider.keep-me",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(removed))
        assertEquals(ProviderWriteOutcome.Saved, store.save(kept, selectAsDefault = true))
        val keyStore = ApiKeyStore(MapSecureStore())
        keyStore.save("sk-delete-removed-0000", removed.credentialAccount())
        keyStore.save("sk-delete-kept-0000", kept.credentialAccount())

        val receipt = deleteProviderRecord(removed.id, store, keyStore)

        assertTrue(receipt.profileRemoved)
        assertTrue(receipt.keyRemoved)
        assertEquals("已删除本机保存的模型服务与密钥", receipt.message)
        val snapshot = requireNotNull(store.snapshot())
        assertEquals(listOf(kept), snapshot.profiles)
        assertEquals(kept.id, snapshot.selectedId)
        assertNull(keyStore.readKey(removed.credentialAccount()))
        assertEquals("sk-delete-kept-0000", keyStore.readKey(kept.credentialAccount()))
    }

    @Test
    fun `deleting the last provider service still succeeds`() {
        val file = File(Files.createTempDirectory("provider-delete-last").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val record = ProviderRecord(
            id = "only-one", name = "Only one", model = "m", endpoint = "https://only.example.test/v1",
            credentialRef = "provider.only-one",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(record))
        val keyStore = ApiKeyStore(MapSecureStore())
        keyStore.save("sk-delete-only-0000", record.credentialAccount())

        val receipt = deleteProviderRecord(record.id, store, keyStore)

        assertTrue(receipt.profileRemoved)
        assertTrue(receipt.keyRemoved)
        assertEquals("已删除本机保存的模型服务与密钥", receipt.message)
        assertNull(store.current())
        assertNull(store.snapshot())
        assertNull(keyStore.readKey(record.credentialAccount()))
    }

    @Test
    fun `provider deletion fails when readback still contains the profile`() {
        val directory = Files.createTempDirectory("provider-delete-stale-readback").toFile()
        val file = File(directory, ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val removed = ProviderRecord(
            id = "stale-delete", name = "Still here", model = "m", endpoint = "https://stale.example.test/v1",
            credentialRef = "provider.stale-delete",
        )
        val kept = ProviderRecord(
            id = "stale-keep", name = "Other", model = "m", endpoint = "https://other.example.test/v1",
            credentialRef = "provider.stale-keep",
        )
        assertEquals(ProviderWriteOutcome.Saved, store.save(removed))
        assertEquals(ProviderWriteOutcome.Saved, store.save(kept, selectAsDefault = true))
        val staleFile = File(directory, "stale-readback.properties")
        staleFile.writeBytes(file.readBytes())
        val staleStore = ProviderConfigStore(StaleReadbackFile(file.path, staleFile.path)) { }
        val keyStore = ApiKeyStore(MapSecureStore())
        keyStore.save("sk-delete-stale-0000", removed.credentialAccount())

        val receipt = deleteProviderRecord(removed.id, staleStore, keyStore)

        assertFalse(receipt.profileRemoved)
        assertTrue(receipt.keyRemoved)
        assertEquals("密钥已删除；模型服务配置删除结果无法确认，请刷新后检查", receipt.message)
        assertEquals(listOf(kept), ProviderConfigStore(file) { }.snapshot()?.profiles)
        assertNull(keyStore.readKey(removed.credentialAccount()))
    }

    @Test
    fun `provider save rejection retains request identity and writes no record`() = runBlocking {
        val file = File(Files.createTempDirectory("provider-bound-reject").toFile(), ProviderConfigStore.FILE_NAME)
        val store = ProviderConfigStore(file) { }
        val result = saveProviderDraft(
            draft = ProviderDraft(
                id = "new-profile", name = "Fixture service", endpoint = "https://user:pass@api.example.test",
                model = "fixture-model", models = listOf(com.phonedsh.ui.page.ProviderModelDraft("fixture-model")),
                apiKey = "", isNew = true,
            ),
            requestId = "save-request-bad",
            store = store,
            keyStore = null,
        )
        assertFalse(result.succeeded)
        assertFalse(result.recordWritten)
        assertEquals("save-request-bad", result.requestId)
        assertEquals("new-profile", result.profileId)
        assertNull(store.current())
    }

    @Test
    fun `get models does not read stored key for a new profile and rejects an empty catalog`() = runBlocking {
        var keyReads = 0
        val transport = RecordingTransport(listOf(200), listOf("""{"data":[]}"""))
        val result = getProviderModels(
            draft = draft(endpoint = "https://api.example.test/v1", key = "", isNew = true),
            requestId = "models-request-new",
            keyProvider = { keyReads++; key },
            transport = transport,
        )
        assertEquals(0, keyReads)
        assertTrue(transport.requests.isEmpty())
        assertNull(result.models)
        assertEquals("models-request-new", result.requestId)
        assertNull(result.profileId)
        assertFalse(result.succeeded)
    }

    @Test
    fun `anthropic model lookup retries the origin catalog only after profile path 404`() = runBlocking {
        val transport = RecordingTransport(
            statuses = listOf(404, 200),
            bodies = listOf("", """{"data":[{"id":"deepseek-chat"}]}"""),
        )
        val result = getProviderModels(
            draft(endpoint = "https://api.example.test/anthropic", key = key, isNew = false),
            requestId = "models-anthropic-fallback",
            transport = transport,
        )
        assertEquals(
            listOf("https://api.example.test/anthropic/models", "https://api.example.test/models"),
            transport.requests.map { it.url.toString() },
        )
        assertTrue(transport.requests.all { it.headers["x-api-key"] == key })
        assertEquals(listOf("deepseek-chat"), result.models)
    }

    @Test
    fun `get models rejects malformed catalogs and never returns upstream error text`() = runBlocking {
        val transport = RecordingTransport(listOf(502), listOf("provider secret payload"))
        val result = getProviderModels(
            draft(endpoint = "https://api.example.test/v1", key = key),
            requestId = "models-failed",
            transport = transport,
        )
        assertNull(result.models)
        assertFalse(result.message.contains("provider secret payload"))

        val malformed = getProviderModels(
            draft(endpoint = "https://api.example.test/v1", key = key),
            requestId = "models-malformed",
            transport = RecordingTransport(listOf(200), listOf("""{"models":[{"name":"fake"}]}""")),
        )
        assertNull(malformed.models)
        assertEquals("models-malformed", malformed.requestId)
    }

    @Test
    fun `transport exceptions are reported without echoing a key or raw exception`() = runBlocking {
        val transport = RecordingTransport(emptyList(), failure = IllegalStateException("failed for $key"))
        val result = testProviderConnection(
            draft = draft(endpoint = "https://api.example.test", key = key),
            storedEndpointProvider = { null },
            launchEndpointProvider = { null },
            transport = transport,
        )
        assertTrue(result is ProviderConnectionTestResult.Failure)
        assertFalse(result.message.contains(key))
        assertFalse(result.message.contains("failed for"))
    }

    private fun draft(endpoint: String, key: String, isNew: Boolean = true) = ProviderDraft(
        id = if (isNew) "" else "saved-profile",
        name = "Fake provider",
        endpoint = endpoint,
        model = "fake-model",
        apiKey = key,
        isNew = isNew,
    )

    private class RecordingTransport(
        private val statuses: List<Int>,
        private val bodies: List<String> = emptyList(),
        private val failure: Exception? = null,
    ) : ProviderProbeTransport {
        val requests = mutableListOf<ProviderProbeRequest>()

        override suspend fun execute(request: ProviderProbeRequest): ProviderProbeResponse {
            requests += request
            failure?.let { throw it }
            val index = requests.lastIndex
            return ProviderProbeResponse(statuses[index], bodies.getOrNull(index).orEmpty())
        }
    }

    /**
     * A [File] view that starts reading the live document and switches to a
     * pre-delete copy on the readback after the third existence check. It models
     * the failure this regression covers: the delete write returns Saved, but
     * the following readback still observes the profile.
     */
    private class StaleReadbackFile(
        livePath: String,
        private val stalePath: String,
    ) : File(livePath) {
        private var fileChecks = 0
        private var servingStale = false

        override fun isFile(): Boolean {
            fileChecks++
            if (fileChecks >= 3) servingStale = true
            return super.isFile()
        }

        override fun getPath(): String = if (servingStale) stalePath else super.getPath()
    }

    private class MapSecureStore(
        private val unreadable: Boolean = false,
        private val failDelete: Boolean = false,
    ) : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE
        private val values = mutableMapOf<String, ByteArray>()
        var deleteCalls: Int = 0
            private set
        var putCalls: Int = 0
            private set

        override suspend fun put(key: String, value: ByteArray) { putCalls++; values[key] = value.copyOf() }
        override suspend fun get(key: String): SecureLookup = when {
            unreadable -> SecureLookup.Unreadable("fixture")
            values[key] == null -> SecureLookup.Absent
            else -> SecureLookup.Found(requireNotNull(values[key]).copyOf())
        }
        override suspend fun delete(key: String) {
            deleteCalls++
            if (failDelete) throw IllegalStateException("fixture delete failure")
            values.remove(key)
        }
    }

    private class FakeSecureStore(private val lookup: SecureLookup) : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE
        override suspend fun put(key: String, value: ByteArray) = Unit
        override suspend fun get(key: String): SecureLookup = lookup
        override suspend fun delete(key: String) = Unit
    }

    private class MutableFailingSecureStore : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE
        override suspend fun put(key: String, value: ByteArray) { throw IllegalStateException("fixture write failure") }
        override suspend fun get(key: String): SecureLookup = SecureLookup.Absent
        override suspend fun delete(key: String) = Unit
    }
}
