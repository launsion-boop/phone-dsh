// D3 entry point: one activity, one Compose screen, zero view construction here.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue

class MainActivity : ComponentActivity() {
    private val engine: ProbeEngineViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The key store must exist before the launch config, because the config
        // asks it for the key's *state* while building the Worker env, and before
        // the view model constructs the gateway that asks it for the credential.
        ApiKeyStore.install(applicationContext)
        // Development only: a key dropped into the app's own files dir is imported and
        // the plaintext is deleted. Gated on the *install's* debuggable flag rather than
        // BuildConfig (this module compiles with `buildConfig = false`); a release APK
        // therefore has no such path at all.
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable) ApiKeyStore.importDevelopmentKey(applicationContext)
        // The fail-loud collector: one developmental vault operation named by the
        // launch (reclaim-token matrix), then the previous-death audit. Both run on
        // their own threads and only ever log lookup state, never token bytes.
        ProbeRecovery.handleDiagnosticIntent(applicationContext, intent, debuggable)
        ProbeRecovery.auditAsync(applicationContext)
        // The launch values must be installed before the view model's first
        // access constructs the engine and its `env` page parameter.
        ProbeLaunchConfig.install(intent)
        // targetSdk 35 enforces edge-to-edge; consume the insets in ProbeScreen.
        enableEdgeToEdge()
        setContent {
            val state by engine.state.collectAsState()
            val hostState by engine.hostState.collectAsState()
            val handshake by engine.handshake.collectAsState()
            val channel by engine.channel.collectAsState()
            val turn by engine.turn.collectAsState()
            val recoveryNotice by ProbeRecovery.notice.collectAsState()
            HostShell(
                engine = engine,
                state = state,
                hostState = hostState,
                handshake = handshake,
                channel = channel,
                turn = turn,
                recoveryNotice = recoveryNotice,
                onStart = engine::start,
                onStop = engine::stop,
                onRunTurn = engine::runTurn,
            )
        }
    }
}
