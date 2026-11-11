// SPDX-License-Identifier: MIT
// :pclink is the JVM (not Android) implementation of the PCLink v1 phone end
// (P28). It has no `android.*` import: the protocol, its golden-vector tests and
// the pairing/E2E state machines run on the host JVM.
//
// Dependencies are deliberately narrow:
//  * `:core` for `com.phonedsh.agentcore.JsonValue` and kotlinx-coroutines (an
//    `api` of `:core`); it does not depend on `:net` (P05) or `:dsh` (P14/P06).
//  * Bouncy Castle 1.86 lightweight API (`org.bouncycastle.crypto.*`) for
//    Ed25519/X25519/ChaCha20-Poly1305/HKDF. minSdk 26 has no platform
//    X25519/Ed25519 and ChaCha20-Poly1305 only from API 28, so a JCA path would
//    need two implementations of the same bytes; BC is already shipped by
//    `:app` for SSH. The version is pinned in `gradle/libs.versions.toml`.
//
// The WebSocket client (Ktor) is C3's dependency and is added with
// `PclinkWebSocket.kt`; C1 carries no transport code.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

// The tests read `spec/pclink/v1/golden` and `spec/pclink/v1/endpoints.json`
// from disk (never a copy), so the real parser/crypto is driven by the shared
// vectors. Same pattern as `:core`'s wire tests.
val repoRoot: File = rootProject.projectDir.parentFile

tasks.test {
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
    useJUnit()
}

dependencies {
    api(project(":core"))
    implementation(libs.bouncycastle.bcprov)

    // Relay transport (C3). Ktor 3.2.3 is the version `:net` already pins for
    // its server and test client; there is no separate version catalog entry.
    implementation("io.ktor:ktor-client-core:3.2.3")
    implementation("io.ktor:ktor-client-cio:3.2.3")
    implementation("io.ktor:ktor-client-websockets:3.2.3")

    // Test-only loopback relay for `PclinkKtorWebSocketTest`: the real Ktor
    // client against a local Ktor server WebSocket. Never a real relay.
    testImplementation("io.ktor:ktor-server-core:3.2.3")
    testImplementation("io.ktor:ktor-server-cio:3.2.3")
    testImplementation("io.ktor:ktor-server-websockets:3.2.3")

    testImplementation(libs.junit)
}
