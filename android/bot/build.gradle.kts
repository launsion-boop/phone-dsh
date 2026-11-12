// SPDX-License-Identifier: MIT
// :bot is the JVM (not Android) home of the P27/P26 Bot value types and
// codecs whose contracts are already frozen by shared goldens. It has no
// `android.*` import: the rows, user actions, card payloads, display
// projection, attachment policy, profile/roster rules and fish director all
// run on the host JVM.
//
// The build shape follows :pclink deliberately:
//  * `java-library` + kotlin-jvm, toolchain 17;
//  * `:core` for `com.phonedsh.agentcore.JsonValue` (the repository's JSON
//    value model) and kotlinx-coroutines (an `api` of `:core`);
//  * the tests read `spec/bot/v1/golden` from disk through
//    `pdsh.repo.root`, never a copy, so the real codecs are driven by the
//    shared vectors.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

val repoRoot: File = rootProject.projectDir.parentFile

tasks.test {
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
    useJUnit()
}

dependencies {
    api(project(":core"))
    testImplementation(libs.junit)
}
