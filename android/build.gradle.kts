// SPDX-License-Identifier: MIT
// Root build. Plugin versions live in gradle/libs.versions.toml; modules apply
// them. No repositories here: settings.gradle.kts owns repository policy.

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// One coordinate line for the module set. :lib pins the same values explicitly
// because its AAR coordinate is the public entry point.
subprojects {
    group = "com.phonedsh"
    version = "0.0.0-SNAPSHOT"
}
