// phone-dsh — :app: the launch-time configuration of the demo host.
// SPDX-License-Identifier: MIT
//
// The App stays a probe: it has no accounts and no account UI. The non-secret
// launch values are read once, in the composition root, from explicit Intent
// extras (the model service the settings page saves is a device record that
// overrides two of them — see `ProviderConfigStore`):
//
//   pdsh.deepseek.baseUrl  the provider's Messages base (may carry a path prefix)
//   pdsh.egress.origin     the exact origin the `/v1/http` gateway may reach
//   pdsh.prompt            the text of the one turn the button starts
//   pdsh.model.name        the model id the Worker reports
//   pdsh.model.proxy       mount the host model edge (default true)
//   pdsh.face.web          open the DSH Web surface once the engine is ready
//   pdsh.face.probe        open the engine probe as the launch face (L62: the
//                          product home is the session list, so the device scripts
//                          that tap 跑一轮 at launch ask for this)
//   pdsh.boot.overlay      hand the recovered workspace to the Worker (default true)
//
// **Only a debuggable install reads these extras.** The launcher activity is
// exported (it must be, to appear in the launcher), so any app or `adb`
// invocation can deliver them. `MainActivity` passes the install's
// `FLAG_DEBUGGABLE` fact into [ProbeLaunchConfig.install], and a release install
// ignores every override above: it uses the defaults plus the user's saved
// provider record. The device scripts keep the diagnostic behaviour because
// they run a debuggable build.
//
// ---- the base URL is the Messages base, not the origin ---------------------
// The launch value is forwarded verbatim to the provider endpoint the host edge
// addresses; this host never appends or guesses a path prefix. That spelling is
// the provider's contract: the public DeepSeek Messages base is
// `https://api.deepseek.com/anthropic`, not `https://api.deepseek.com`, and the
// bare origin answers 404 for `/v1/messages` (measured 2026-10-31; a bogus key
// hides it behind a 401 because authentication is checked before routing). The
// engine logs a WARN at start when a mounted edge sees a bare-origin base.
//
// `pdsh.model.proxy=false` is the scripted/diagnostic escape hatch: no
// `LoopbackModelProxy` is mounted, `DEEPSEEK_BASE_URL` is passed through as
// given, and the Worker talks to that upstream directly. The acceptance script
// uses it so a device holding a real key never sends that key to
// `android/tools/scripted-model-upstream.py` (a test fixture must not see a real
// credential). It defaults to true, so a normal launch always gets the host edge.
//
// The model **key is never one of them**: not an Intent extra, not a literal in
// this file, not a page query parameter of its own. It comes from the device key
// store through [ApiKeyStore] (AndroidKeyStore AES-GCM over a ciphertext file in
// `noBackupFilesDir`; see that file for why it is unreadable off the Keystore).
// Exactly three states reach this object, and all three put the **same non-secret
// placeholder** in `DEEPSEEK_API_KEY` - the Worker never holds the key
// (`gateway-security.md` §2). `PDSH_MODEL_KEY_STATE` is the honest part:
//
//   valid    `DEEPSEEK_API_KEY=phone-host-injects-mcp-key` plus
//            `PDSH_MODEL_KEY_STATE=configured`;
//   absent   the same placeholder plus `PDSH_MODEL_KEY_STATE=absent` - no empty
//            value and nothing invented;
//   invalid  a key exists but cannot be used (Keystore entry gone, GCM tag failed,
//            stored value blank/short): the same placeholder plus
//            `PDSH_MODEL_KEY_STATE=invalid` recording the fail-closed reason.
//
// Those two members are facts about the key, not about the endpoint, so they are
// emitted even when the launch named no `baseUrl`; only the endpoint members
// (`DEEPSEEK_BASE_URL`, `PDSH_MODEL_NAME`, `DSH_TELEMETRY_DISABLED`) are gated on it.
//
// `baseUrl` reaches the Worker through the ordinary `pageParams["env"]` path
// (the same one the launch token uses); it is never a page query parameter of
// its own and is never logged. When the host model edge is mounted this object
// leaves `DEEPSEEK_BASE_URL` **out** of the env entirely ([workerEnvironment]'s
// `modelProxyMounted` argument): the engine puts the loopback origin in at the
// one moment the port is known, so the real base lives only in the composition
// root's memory. The egress origin is not a wildcard and is parsed by the same
// `GatewayHostRule` the gateway uses, so an intent cannot widen the allow-list
// beyond one exact scheme/host/port.
//
// Nothing on this path logs: the launch URL's query - which carries the env
// object - is stripped by `EngineLogText.baseUrl` before any engine log line, and
// this file plus [ApiKeyStore] contain no logging call at all
// (`KeyMaterialLoggingTest` pins it).
//
// The acceptance script passes these extras; a production host would replace
// this object with its settings flow, never with a second code path in the turn
// runner. [keyFact] is the only key-shaped value the settings page may read.

package com.phonedsh.probe

import android.content.Intent
import com.phonedsh.account.TonoAccountKeySource
import com.phonedsh.dsh.host.HostBudgetTier
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayHostRule
import com.phonedsh.gateway.GatewayRequestHeaders
import com.phonedsh.ui.page.ProviderKeyFact
import java.net.URI
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/**
 * The diagnostic values an Intent may carry.
 *
 * Kept separate from [Intent] so the release gate can be exercised by JVM tests
 * without Android stubs. Every member keeps [ProbeLaunchConfig]'s default when
 * the Intent did not name it.
 */
internal data class LaunchExtras(
    val baseUrl: String? = null,
    val egressOrigin: String? = null,
    val prompt: String? = null,
    val modelName: String? = null,
    val egressProbe: Boolean = false,
    val modelProxy: Boolean = true,
    val webFace: Boolean = false,
    val probeFace: Boolean = false,
    val bootOverlay: Boolean = true,
)

/** The non-secret values a launch may supply. All are empty by default. */
internal data class ProbeLaunchConfig(
    val deepseekBaseUrl: String? = null,
    val egressOrigin: String? = null,
    val prompt: String = DEFAULT_PROMPT,
    val modelName: String = DEFAULT_MODEL,
    val egressProbe: Boolean = false,
    val webFace: Boolean = false,
    /**
     * Open the engine probe (the D3 diagnostic console) as the launch face.
     *
     * The product home is the session list (L62), and the probe is one drawer tap
     * away at 引擎探针. This switch exists for the device scripts that tap
     * 跑一轮 on the launch face (`android/tools/run-app-turn.sh` and the demo
     * runners): they pass `--ez pdsh.face.probe true` and get the pre-L62 start
     * face back, with the product default unchanged. It is a diagnostic, not a
     * setting, exactly like [bootOverlay] and [webFace].
     */
    val probeFace: Boolean = false,
    /** Mount the model edge for this launch. A scripted launch passes `false`. */
    val modelProxy: Boolean = true,
    /**
     * Seed the Worker from the recovered materialized tree (`wal.md` §8).
     *
     * `true` is the only correct production value: without the boot overlay the
     * Worker mounts the base image alone, sees an empty `/dsh/workspace`, and
     * writes that empty view back through `VFS_MUT` — which is how a cold start
     * after a reload loses every file the WAL replayed (P28).
     *
     * The switch exists so the *reverse* validation can reproduce that failure on
     * one device (`--ez pdsh.boot.overlay false`): with the overlay off, the same
     * `ls /dsh/workspace` must see nothing. It is a diagnostic, not a setting.
     */
    val bootOverlay: Boolean = true,
    /** Credential account captured with this process's endpoint at launch. Null means no key binding. */
    val credentialAccount: String? = null,
    /** Stored provider that supplied this launch's endpoint/model, if any. */
    val providerProfileId: String? = null,
) {
    /**
     * The `env` object the engine merges with `PDSH_DSH_LAUNCH_TOKEN`.
     *
     * **The real key never enters this map.** `gateway-security.md` §2 says the Worker never holds
     * the key: the iOS baseline hands it `phone-host-injects-mcp-key` and the *host* injects the
     * real credential at the network edge. This method therefore reports only the key's *state*
     * (`PDSH_MODEL_KEY_STATE`) and leaves `DEEPSEEK_API_KEY` at the placeholder for every state,
     * including `configured`. An earlier revision put the real key here because the model traffic
     * currently bypasses the host gateway; that traded a spec rule for a demo convenience, and a
     * Worker that can read the key can also log it, whatever this side does.
     *
     * The three states stay apart so the Worker can say "not configured" instead of "wrong key":
     * a missing key and a key that exists but cannot be read are different answers to the user, and
     * neither invents a value. `modelCredentialProvider()` is what carries the real credential, and
     * only for the model endpoint's origin and protocol path.
     *
     * **`DEEPSEEK_BASE_URL` is omitted when [modelProxyMounted] is true.** The engine mounts the
     * proxy on the loopback origin and fills that key with the origin in `launchUrl()`, so the real
     * upstream base never enters this string at all: it stays in the composition root and in the
     * credential provider, which is a smaller surface than "write it, then overwrite it". The
     * default is false so a caller that does not mount an edge (the instrumented env tests, a
     * scripted launch) still gets the host's value; the engine remains the backstop that rewrites
     * the key whenever an edge is mounted.
     *
     * **The key members are emitted whenever an env is emitted at all.** They describe the key, not
     * the endpoint: a launch that named no base URL still knows whether the device holds a key, and
     * saying `absent` there would be the same "unknown folded into known" mistake this object exists
     * to avoid (the Worker then reports "no API key" when the missing fact is the base URL). Only
     * `DEEPSEEK_BASE_URL`, `PDSH_MODEL_NAME` and `DSH_TELEMETRY_DISABLED` — the endpoint facts — stay
     * behind `base != null`.
     *
     * **[singleFileLimitBytes] is the budgets.md §4 tier value, and it is published only here.**
     * `channel.md` §4.1 has no HELLO member and no capability string for a file limit, so the
     * Worker environment is the host's publication channel: `plugins/wasi-toolbox/src/limits.ts`
     * names `PDSH_SINGLE_FILE_LIMIT_BYTES` as "the environment name the host uses to publish its
     * `single_file_limit` (D4)", the Worker entry clamps it into 16 MiB…256 MiB and every Worker
     * write surface refuses an over-limit write with `EFBIG` before the VFS sees it. The value is
     * the one `HostBudgetTier` selected from `MemoryInfo.totalMem`, not a constant here.
     *
     * @param modelProxyMounted the engine mounted the model edge, so the Worker env must not carry
     *   the real upstream base.
     * @param singleFileLimitBytes the selected `single_file_limit`; `null` omits the key (the
     *   Worker then applies its 8 GiB default) and is only for callers with no device.
     * @return the JSON object, or `null` when there is nothing to send at all.
     */
    fun workerEnvironment(
        modelProxyMounted: Boolean = false,
        singleFileLimitBytes: Long? = null,
    ): String? {
        val base = deepseekBaseUrl
        if (base == null && singleFileLimitBytes == null) return null
        val env = JSONObject()
        // The key members are independent of the endpoint. Gating them on `base != null` made a launch
        // without a base URL report "no key" — folding "the key state is unknown here" into "there is
        // no key", which is exactly the confusion the state variable was added to remove. The
        // placeholder is non-secret and the state below is a fact of this device, so both are always
        // true statements about the launch, whatever it named as a base.
        //
        // Placeholder for every state: the shape is what `gateway-security.md` §2 fixes, and the
        // state variable below is the honest part of the answer. A Worker that needs the real
        // credential asks the host for it one request at a time at the network edge.
        env.put(DEEPSEEK_API_KEY, WORKER_KEY_PLACEHOLDER)
        // spec/v1/tono-account.md §4: a signed-in account is the cloud origin's credential.
        val accountCovers = base != null && TonoAccountKeySource.usesAccount(base, TonoAccountHost.activeSession())
        if (accountCovers) {
            env.put(MODEL_KEY_STATE, KEY_STATE_CONFIGURED)
        } else {
            when (credentialAccount?.let { ApiKeyStore.activeState(it) } ?: ApiKeyState.Absent) {
                is ApiKeyState.Valid -> env.put(MODEL_KEY_STATE, KEY_STATE_CONFIGURED)
                ApiKeyState.Absent -> env.put(MODEL_KEY_STATE, KEY_STATE_ABSENT)
                is ApiKeyState.Invalid, is ApiKeyState.Unreadable -> env.put(MODEL_KEY_STATE, KEY_STATE_INVALID)
            }
        }
        // The endpoint facts stay gated: they are only true when the launch named a base URL.
        if (base != null) {
            env.put("DSH_TELEMETRY_DISABLED", "1").put("PDSH_MODEL_NAME", modelName)
            if (!modelProxyMounted) env.put("DEEPSEEK_BASE_URL", base)
        }
        if (singleFileLimitBytes != null) {
            require(singleFileLimitBytes > 0L) {
                "singleFileLimitBytes must be positive when present, was $singleFileLimitBytes"
            }
            env.put(HostBudgetTier.SINGLE_FILE_LIMIT_ENV, singleFileLimitBytes.toString())
        }
        return env.toString()
    }

    /**
     * The host credential provider for the launch's model endpoint.
     *
     * `null` when the launch named no model endpoint or the composition root did
     * not install [ApiKeyStore]: with no store there is no key to inject, and the
     * gateway must keep the anonymous provider instead of inventing one.
     *
     * The launch's egress origin is passed as a deliberately key-free host: a
     * second allow-listed origin is a diagnostic/search target, never a model
     * endpoint, so it must not receive the model key even though the gateway
     * allows the hop.
     */
    fun modelCredentialProvider(): GatewayCredentialProvider? {
        val base = deepseekBaseUrl ?: return null
        val store = ApiKeyStore.active() ?: return null
        val account = credentialAccount ?: return null
        val anonymous = egressGrant()?.host?.let { setOf(it) } ?: emptySet()
        return store.credentialProvider(base, anonymous, account)
    }

    /**
     * The key fact the settings page may render.
     *
     * Four characters at most (`maskKeySuffix`), never the key and never the
     * store path. This is the only key-shaped value this object exposes; the
     * injection paths above use [ApiKeyStore] directly, so a page cannot obtain
     * plaintext from a fact.
     */
    fun keyFact(): ProviderKeyFact = credentialAccount?.let { ApiKeyStore.activeFact(it) }
        ?: ProviderKeyFact(com.phonedsh.ui.page.ProviderKeyStatus.NOT_CONFIGURED, null)

    /** The parsed egress grant, or `null` when the launch supplied none/wildcard. */
    fun egressGrant(): GatewayHostRule? {
        val origin = egressOrigin ?: return null
        if (origin.contains('*')) return null
        parseHttpUrl(origin) ?: return null
        return GatewayHostRule.parse(origin)
    }

    companion object {
        const val EXTRA_BASE_URL: String = "pdsh.deepseek.baseUrl"

        /**
         * Whether the host mounts the model edge for this launch (default `true`).
         *
         * A **scripted** launch must pass `false`. Otherwise the edge mounts, the host
         * injects the real key into whatever `DEEPSEEK_BASE_URL` names, and the scripted
         * upstream — a test fixture — receives a production credential. A fixture must
         * never see one, even over `adb reverse`.
         */
        const val EXTRA_MODEL_PROXY: String = "pdsh.model.proxy"
        const val EXTRA_EGRESS_ORIGIN: String = "pdsh.egress.origin"
        const val EXTRA_PROMPT: String = "pdsh.prompt"
        const val EXTRA_MODEL_NAME: String = "pdsh.model.name"

        /** Ask the App to exercise its own `/v1/http` route once (diagnostic). */
        const val EXTRA_EGRESS_PROBE: String = "pdsh.egress.probe"

        /**
         * Hand the recovered workspace to the Worker as its boot overlay
         * (`wal.md` §8), default `true`.
         *
         * `false` reproduces the pre-P28 shape on the same device: no
         * `?overlay=`, an empty Worker view, and the writes that follow overwrite
         * the materialized tree. It exists only for that reverse validation.
         */
        const val EXTRA_BOOT_OVERLAY: String = "pdsh.boot.overlay"

        /**
         * Open the DSH Web surface as the engine-ready face.
         *
         * The demo launch (and every acceptance run) leaves this unset, so the
         * native probe screen — the one that owns the 跑一轮 button — stays the
         * start face. A launch that sets it gets §1's 引擎就绪时的默认面.
         */
        const val EXTRA_WEB_FACE: String = "pdsh.face.web"

        /**
         * Open the engine probe as the launch face (L62).
         *
         * The product home is the session list now, so a device script that taps
         * 跑一轮 straight after launch must ask for the probe. One tap on the
         * drawer's 引擎探针 row reaches it by hand; this switch is what keeps the
         * scripted runs a single command.
         */
        const val EXTRA_PROBE_FACE: String = "pdsh.face.probe"

        const val DEFAULT_PROMPT: String = "Run phone info and tell me what it says."
        const val DEFAULT_MODEL: String = "deepseek-flash"

        /** The Worker variable that holds the placeholder, never a credential. */
        const val DEEPSEEK_API_KEY: String = "DEEPSEEK_API_KEY"

        /**
         * The value the Worker sees instead of a key (iOS baseline: `phone-host-injects-mcp-key`).
         *
         * It is deliberately recognisable: if it ever shows up in a request, the host edge failed to
         * substitute the real credential, and the upstream will reject it loudly instead of the
         * request quietly working with a Worker-visible key.
         *
         * The value is the gateway's own constant, not a second literal: the `/v1/http` sanitizer
         * drops exactly `GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER` per value, so the value
         * this side sends and the value that side filters cannot drift apart
         * (`KeyMaterialLoggingTest` pins the single source).
         */
        const val WORKER_KEY_PLACEHOLDER: String = GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER

        /**
         * The non-secret key state the Worker env records.
         *
         * `configured` / `absent` / `invalid`: one of the three, always present,
         * so the page and the Worker can tell 未配置 from 已配置 without the env
         * ever carrying a key in the two non-valid states.
         */
        const val MODEL_KEY_STATE: String = "PDSH_MODEL_KEY_STATE"

        const val KEY_STATE_CONFIGURED: String = "configured"
        const val KEY_STATE_ABSENT: String = "absent"
        const val KEY_STATE_INVALID: String = "invalid"

        private val current = AtomicReference(ProbeLaunchConfig())

        /** Installs the values of [intent] before the composition root is built. */
        fun install(intent: Intent?, debuggable: Boolean = false) {
            current.set(from(intent, debuggable))
        }

        /** The values installed for this process; safe to read repeatedly. */
        fun active(): ProbeLaunchConfig = current.get()

        /** Parses [intent] without trusting any value: a malformed one is ignored. */
        fun from(intent: Intent?, debuggable: Boolean = false): ProbeLaunchConfig =
            from(intent, ProviderConfigStore.active()?.current(), debuggable)

        /**
         * Launch resolver; the selected profile and its key account are captured together.
         *
         * The launcher is exported, so a release install must not even read the
         * diagnostic extras: with [debuggable] false this resolves exactly as if the
         * Intent carried none. The stored profile is the user's saved configuration,
         * not a launch override, so it is always honoured.
         */
        internal fun from(
            intent: Intent?,
            storedProfile: ProviderRecord?,
            debuggable: Boolean = false,
        ): ProbeLaunchConfig = fromExtras(
            extras = if (debuggable) intent.readLaunchExtras() else null,
            storedProfile = storedProfile,
            debuggable = debuggable,
        )

        /**
         * The release gate shared with the JVM tests.
         *
         * Only a debuggable launch keeps [extras]; every other install resolves the
         * no-extras shape and falls through to defaults plus the stored profile.
         */
        internal fun fromExtras(
            extras: LaunchExtras?,
            storedProfile: ProviderRecord?,
            debuggable: Boolean,
        ): ProbeLaunchConfig {
            val allowed = extras?.takeIf { debuggable }
            return fromValues(
                extraBaseUrl = allowed?.baseUrl,
                extraEgressOrigin = allowed?.egressOrigin,
                extraPrompt = allowed?.prompt,
                extraModelName = allowed?.modelName,
                egressProbe = allowed?.egressProbe ?: false,
                modelProxy = allowed?.modelProxy ?: true,
                webFace = allowed?.webFace ?: false,
                probeFace = allowed?.probeFace ?: false,
                bootOverlay = allowed?.bootOverlay ?: true,
                storedProfile = storedProfile,
            )
        }

        /** Reads the diagnostic extras; only a debuggable launch calls this. */
        private fun Intent?.readLaunchExtras(): LaunchExtras = LaunchExtras(
            baseUrl = this?.getStringExtra(EXTRA_BASE_URL),
            egressOrigin = this?.getStringExtra(EXTRA_EGRESS_ORIGIN),
            prompt = this?.getStringExtra(EXTRA_PROMPT),
            modelName = this?.getStringExtra(EXTRA_MODEL_NAME),
            egressProbe = this?.getBooleanExtra(EXTRA_EGRESS_PROBE, false) ?: false,
            modelProxy = this?.getBooleanExtra(EXTRA_MODEL_PROXY, true) ?: true,
            webFace = this?.getBooleanExtra(EXTRA_WEB_FACE, false) ?: false,
            probeFace = this?.getBooleanExtra(EXTRA_PROBE_FACE, false) ?: false,
            bootOverlay = this?.getBooleanExtra(EXTRA_BOOT_OVERLAY, true) ?: true,
        )

        /** Pure value resolver shared by the Intent adapter and loopback regression tests. */
        internal fun fromValues(
            extraBaseUrl: String?,
            extraEgressOrigin: String? = null,
            extraPrompt: String? = null,
            extraModelName: String? = null,
            egressProbe: Boolean = false,
            modelProxy: Boolean = true,
            webFace: Boolean = false,
            probeFace: Boolean = false,
            bootOverlay: Boolean = true,
            storedProfile: ProviderRecord? = null,
        ): ProbeLaunchConfig {
            val explicitBase = extraBaseUrl?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?.takeIf { parseHttpUrl(it) != null }
            // An explicit endpoint override is not a provider selection. Never attach
            // the saved profile's credential (or model) to an unrelated launch origin.
            val stored = storedProfile.takeIf { explicitBase == null }
            val base = explicitBase ?: stored?.endpoint
            val egress = extraEgressOrigin?.trim()
                ?.takeIf { it.isNotEmpty() && !it.contains('*') }
                ?.takeIf { parseHttpUrl(it) != null }
            val prompt = extraPrompt?.trim()?.takeIf { it.isNotEmpty() } ?: DEFAULT_PROMPT
            val model = extraModelName?.trim()?.takeIf { it.isNotEmpty() }
                ?: stored?.model?.takeIf { it.isNotEmpty() }
                ?: DEFAULT_MODEL
            return ProbeLaunchConfig(
                deepseekBaseUrl = base,
                egressOrigin = egress,
                prompt = prompt,
                modelName = model,
                egressProbe = egressProbe,
                modelProxy = modelProxy,
                webFace = webFace,
                probeFace = probeFace,
                bootOverlay = bootOverlay,
                credentialAccount = when {
                    explicitBase != null -> null
                    stored != null -> stored.credentialAccount()
                    else -> null
                },
                providerProfileId = stored?.id,
            )
        }

        private fun parseHttpUrl(raw: String): URI? = try {
            val uri = URI(raw)
            val scheme = uri.scheme?.lowercase()
            if ((scheme == "http" || scheme == "https") && !uri.host.isNullOrEmpty()) uri else null
        } catch (_: Exception) {
            null
        }
    }
}
