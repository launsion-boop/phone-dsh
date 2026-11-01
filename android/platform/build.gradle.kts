// SPDX-License-Identifier: MIT
// :platform is the SPI layer: Durability, Clock, SecureStore,
// LifecycleSignals, EngineHost, Notifier. Pure Kotlin/JVM so P1 tests need no
// device.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
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
