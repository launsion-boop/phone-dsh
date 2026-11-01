// SPDX-License-Identifier: MIT
// :core merges the PhoneDSHWire, PhoneDSHLog and PhoneDSHAgentCore packages.
// The packages keep the 1:1 Swift mirror; the module is only a build boundary.
plugins {
    id("java-library")
    alias(libs.plugins.kotlin.jvm)
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
