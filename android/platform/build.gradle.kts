// SPDX-License-Identifier: MIT
// :platform is the SPI layer: Durability, Clock, SecureStore,
// LifecycleSignals, EngineHost, Notifier. Pure Kotlin/JVM so P1 tests need no
// device.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
    id("maven-publish")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // `Flow` / `StateFlow` are part of the published SPI (LifecycleSignals and
    // EngineHost), so consumers such as :dsh collect them without declaring
    // coroutines themselves.
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
    testImplementation(libs.junit)
}

// ---- the published coordinate ------------------------------------------------
// `com.phonedsh:<module>:0.1.0`, packaging=jar. The repository and the version
// come from android/build.gradle.kts (root `subprojects` block). `java` exists
// as soon as `java-library` is applied, so no `afterEvaluate` is needed;
// `from(components["java"])` is what turns this module's `api` edges into
// `compile` scope in the POM — a hand-written POM would have to re-derive that
// split and would drift.
publishing {
    publications {
        create<MavenPublication>("release") {
            from(components["java"])
        }
    }
}
