// The current process binds one endpoint and credential account at launch.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.ui.page.ProviderKeyStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProbeLaunchConfigTest {
    @Test
    fun `stored launch profile captures matching endpoint model and credential account`() {
        val profile = provider("profile-a", "https://a.example.test/v1", "model-a")
        val launch = ProbeLaunchConfig.fromValues(extraBaseUrl = null, storedProfile = profile)

        assertEquals(profile.endpoint, launch.deepseekBaseUrl)
        assertEquals(profile.model, launch.modelName)
        assertEquals(profile.credentialAccount(), launch.credentialAccount)
        assertEquals(profile.id, launch.providerProfileId)
    }

    @Test
    fun `explicit launch endpoint does not inherit another profile key or model`() {
        val unrelated = provider("profile-b", "https://b.example.test/v1", "model-b")
        val launch = ProbeLaunchConfig.fromValues(
            extraBaseUrl = "https://override.example.test/v1",
            storedProfile = unrelated,
        )

        assertEquals("https://override.example.test/v1", launch.deepseekBaseUrl)
        assertEquals(ProbeLaunchConfig.DEFAULT_MODEL, launch.modelName)
        assertNull(launch.credentialAccount)
        assertNull(launch.providerProfileId)
        assertNull(launch.modelCredentialProvider())
        assertEquals(ProviderKeyStatus.NOT_CONFIGURED, launch.keyFact().status)
    }

    @Test
    fun `launch profile identity remains process-local when persisted selection changes later`() {
        val atProcessStart = provider("profile-a", "https://a.example.test/v1", "model-a")
        val laterSelected = provider("profile-b", "https://b.example.test/v1", "model-b")
        val launch = ProbeLaunchConfig.fromValues(extraBaseUrl = null, storedProfile = atProcessStart)

        // Selection writes change ProviderConfigStore; they do not mutate this launch object.
        val afterSelection = laterSelected
        assertEquals("profile-a", launch.providerProfileId)
        assertEquals("provider.profile-a", launch.credentialAccount)
        assertEquals("https://a.example.test/v1", launch.deepseekBaseUrl)
        assertEquals("profile-b", afterSelection.id)
    }

    // ---- release vs diagnostic launches ---------------------------------
    //
    // The launcher is exported, so any app or `adb` invocation can deliver these
    // extras. A release install must treat every one of them as absent: only the
    // stored provider record is the user's saved configuration. A debuggable
    // install keeps the diagnostic overrides the device scripts rely on.

    @Test
    fun `release launch ignores every diagnostic override extra`() {
        val launch = ProbeLaunchConfig.fromExtras(
            extras = overrideExtras(),
            storedProfile = null,
            debuggable = false,
        )

        assertNull("no launch endpoint may reach a release worker", launch.deepseekBaseUrl)
        assertEquals(ProbeLaunchConfig.DEFAULT_PROMPT, launch.prompt)
        assertEquals(ProbeLaunchConfig.DEFAULT_MODEL, launch.modelName)
        assertNull("no launch origin may widen the egress allow-list", launch.egressOrigin)
        assertFalse("no launch may trigger an outbound probe", launch.egressProbe)
        assertTrue("the host model edge stays mounted", launch.modelProxy)
        assertFalse("no launch may pick the launch face", launch.webFace)
        assertFalse("no launch may pick the launch face", launch.probeFace)
        assertTrue("the boot overlay stays on", launch.bootOverlay)
    }

    @Test
    fun `debuggable launch still honours every diagnostic override extra`() {
        val launch = ProbeLaunchConfig.fromExtras(
            extras = overrideExtras(),
            storedProfile = null,
            debuggable = true,
        )

        assertEquals("https://override.example.test/v1", launch.deepseekBaseUrl)
        assertEquals("https://egress.example.test:8443", launch.egressOrigin)
        assertEquals("override prompt", launch.prompt)
        assertEquals("override-model", launch.modelName)
        assertTrue(launch.egressProbe)
        assertFalse(launch.modelProxy)
        assertTrue(launch.webFace)
        assertTrue(launch.probeFace)
        assertFalse(launch.bootOverlay)
    }

    @Test
    fun `release launch with a stored profile ignores override extras`() {
        val profile = provider("profile-a", "https://a.example.test/v1", "model-a")
        val launch = ProbeLaunchConfig.fromExtras(
            extras = overrideExtras(),
            storedProfile = profile,
            debuggable = false,
        )

        assertEquals("the user's saved endpoint wins", profile.endpoint, launch.deepseekBaseUrl)
        assertEquals("the user's saved model wins", profile.model, launch.modelName)
        assertEquals(profile.credentialAccount(), launch.credentialAccount)
        assertEquals(profile.id, launch.providerProfileId)
        assertNull("the override origin must not leak in", launch.egressOrigin)
        assertEquals(ProbeLaunchConfig.DEFAULT_PROMPT, launch.prompt)
        assertFalse(launch.egressProbe)
        assertTrue(launch.modelProxy)
        assertFalse(launch.webFace)
        assertFalse(launch.probeFace)
        assertTrue(launch.bootOverlay)
    }

    private fun overrideExtras() = LaunchExtras(
        baseUrl = "https://override.example.test/v1",
        egressOrigin = "https://egress.example.test:8443",
        prompt = "override prompt",
        modelName = "override-model",
        egressProbe = true,
        modelProxy = false,
        webFace = true,
        probeFace = true,
        bootOverlay = false,
    )

    private fun provider(id: String, endpoint: String, model: String) =
        ProviderRecord(
            id = id,
            name = id,
            model = model,
            endpoint = endpoint,
            credentialRef = ProviderRecord.providerCredentialRef(id),
        )
}
