// SPDX-License-Identifier: MIT
// :core merges the PhoneDSHWire, PhoneDSHLog and PhoneDSHAgentCore packages.
// The packages keep the 1:1 Swift mirror; the module is only a build boundary.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
    id("maven-publish")
}

kotlin {
    jvmToolchain(17)
}

// The wire tests run the real Rust codec through JNI against the host build of
// `pdsh-jni`. Both paths are derived from the Gradle root, so no machine-local
// absolute path is committed; build the library first with:
//   cd shell && cargo build -p pdsh-jni
val repoRoot: File = rootProject.projectDir.parentFile
val nativeLibraryDir: File = repoRoot.resolve("shell/target/debug")
val nativeLibrary: File = nativeLibraryDir.resolve(System.mapLibraryName("pdsh_jni"))

tasks.test {
    // The recovery tests read a 128 MiB workspace inside a child JVM (so they can
    // prove the reader streams), but the runner that drives them also holds the
    // 128 MiB fixture and Gradle's own state. Left at the default heap the suite
    // fails with `NoClassDefFoundError` cascades under a loaded machine — a
    // false red on the very tests that guard the OOM fix. Measured: 12 failures
    // at default vs 0 at 2g on the same tree.
    maxHeapSize = "2g"
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
    systemProperty("java.library.path", nativeLibraryDir.absolutePath)
    // Re-run the suite when the native library changes: the JVM tests exercise
    // the Rust codec, so a rebuilt dylib is an input, not just an environment.
    // Not declared as an input: Gradle validates a declared input BEFORE doFirst
    // runs, so a missing dylib surfaced as "file ... does not exist" and buried the
    // actionable message below. The doFirst check is the one people need to see.
    doFirst {
        check(nativeLibrary.isFile) {
            "missing ${nativeLibrary.path}; build it first with: cd shell && cargo build -p pdsh-jni"
        }
    }
}

dependencies {
    api(project(":platform"))
    // `Flow` is part of the published `:agentcore` API (the harness event stream and
    // `DemoEngine.state`), so coroutines must be an `api` dependency, not `implementation`:
    // a consumer such as `:app` collects the stream in Compose without declaring it itself.
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
