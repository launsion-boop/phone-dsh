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
        // The in-tree publish repository. `./gradlew publishLocalRepository`
        // (android/build.gradle.kts) writes the eight `com.phonedsh` artifacts
        // here, and `:lib-consumer-test` resolves `com.phonedsh:lib:0.1.0` from
        // it — the same way an external app would from a real repository.
        //
        // It is a path inside the build tree, not a URL and not ~/.m2: the
        // artifact is a product of this checkout (the root .gitignore rule
        // `build/` covers it), resolving needs no network, nothing is written
        // outside the tree, and no stale 0.1.0 from another project on the
        // machine can satisfy a resolve. The content filter keeps Gradle from
        // asking this directory about androidx/google artifacts.
        maven {
            name = "pdshLocal"
            url = uri(rootDir.resolve("build/repo"))
            content { includeGroup("com.phonedsh") }
        }
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
// PCLink (P28) is its own JVM module: it is the phone end of the relay/E2E
// protocol and must not double-own the P05 loopback/gateway surface in `:net`
// or pull its Ktor/crypto dependencies into the published `:lib` AAR graph.
include(":pclink")
// Bot (P25/P26/P27) is a pure JVM module for the value types and codecs whose
// contracts are already frozen by the shared `spec/bot/v1` goldens. It has no
// `android.*` import; the Bot store, MCP listener and UI are later lanes.
include(":bot")
include(":controller")
include(":engine")
include(":shell")
include(":dsh")
include(":lib")
include(":testkit")
include(":app")
// The consumer probe. `:lib` is the deliverable, but nothing in this tree
// consumed it the way another product would: `:app` depends on project(":lib"),
// which shares this build's classpath and variant attributes. This module
// depends on `lib-release.aar` as a *file* and declares its own Compose
// dependencies, so it is the only place where "someone else can use the AAR" is
// actually compiled. It publishes nothing and runs no tests; see
// docs/design/android-aar-consumer-api-2026-11-02.md.
include(":lib-consumer-test")
