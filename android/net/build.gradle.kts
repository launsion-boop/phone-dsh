// SPDX-License-Identifier: MIT
// :net merges the PhoneDSHLoopback and PhoneDSHGateway packages. Pure
// Kotlin/JVM so loopback + gateway conformance tests run without a device.
//
// The Ktor pins live here, not in gradle/libs.versions.toml: the version
// catalog is shared with the Android modules, and other lanes edit it.
//
// Why Ktor 3.2.3: it is the newest 3.x built against Kotlin 2.1.21, so its
// class metadata (2.1.0) is readable by the Kotlin 2.1.0 compiler pinned in
// libs.versions.toml. Ktor 3.3.x is built with Kotlin 2.2.21 (metadata 2.2.0)
// and fails to compile against a 2.1.0 compiler.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api(project(":core"))
    api(project(":platform"))

    // Embedded HTTP/1.1 origin: CIO engine, static assets, one WS endpoint.
    implementation("io.ktor:ktor-server-core:3.2.3")
    implementation("io.ktor:ktor-server-cio:3.2.3")
    implementation("io.ktor:ktor-server-websockets:3.2.3")

    testImplementation(libs.junit)
    // Channel conformance probes (order, backpressure, half-close) and the
    // HTTP-level gate checks.
    testImplementation("io.ktor:ktor-client-core:3.2.3")
    testImplementation("io.ktor:ktor-client-cio:3.2.3")
    testImplementation("io.ktor:ktor-client-websockets:3.2.3")
}
