// SPDX-License-Identifier: MIT
// PDSH Android adapter tree. Structure only in P0: no product code.
// The version catalog is auto-loaded from gradle/libs.versions.toml.

pluginManagement {
    repositories {
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "phonedsh-android"

// The include set must match the module directories with build.gradle.kts
// exactly; android/tools/structure_check.py enforces both directions.
// Kotlin packages, not the Gradle module count, carry the 1:1 mirror to the
// 11 Swift modules (see android/README.md).
include(":platform")
// The Android implementations of the six :platform SPI interfaces live in their own
// module on purpose. :platform stays a pure `java-library` so :core and :net (also JVM
// modules) can consume it without an Android variant; grafting AGP onto :platform and
// hand-registering jvmApiElements/jvmRuntimeElements to keep those consumers working
// would be custom Gradle that the next AGP upgrade can invalidate. An Android module
// that depends on the JVM interfaces is the standard shape and needs no trick.
include(":platform-android")
// P6's platform layer: the domain key/value store and the DeviceCapabilities SPI.
// It is an Android library because its only SQL surface is `android.database.sqlite`;
// the behavioural core sits above a typed connection seam so the JVM suite needs no
// Android API at all.
include(":domain")
include(":core")
include(":net")
include(":controller")
include(":engine")
include(":shell")
include(":dsh")
include(":lib")
include(":testkit")
include(":app")
