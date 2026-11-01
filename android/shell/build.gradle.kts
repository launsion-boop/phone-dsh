// SPDX-License-Identifier: MIT
// :shell mirrors Sources/PhoneDSHShell: the JNI binding surface for the Rust
// accelerator. Prebuilt .so files land under src/main/jniLibs/<abi>/; no CMake.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.phonedsh.shell"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        // R8 keep rules travel with the AAR; without them release-only
        // UnsatisfiedLinkError appears.
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        debug {
            ndk {
                // Emulator and test hosts need x86_64 in addition to arm64-v8a.
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
        release {
            ndk {
                abiFilters += listOf("arm64-v8a")
            }
        }
    }

    buildFeatures {
        buildConfig = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        // Uncompressed libs keep the 16KB page-aligned .so mapping intact.
        // The alignment itself is a LINK property, not a packaging one: the JNI
        // crate's build script (`shell/crates/pdsh-jni/build.rs`) emits
        // `-Wl,-z,max-page-size=16384` for Android targets only, because the NDK
        // default page size has changed between releases and a workspace-level
        // Cargo config would apply to host/wasm links too. Two machine checks
        // guard it, both in android/tools/structure_check.py:
        // `android-16k-link-arg` (the flag *and* its Android-only gate are still
        // in that script, not just in a comment) and `android-16k-artifact`
        // (PT_LOAD p_align of the built .so is >= 0x4000).
        jniLibs {
            useLegacyPackaging = false
        }
    }
}

// ---- the unit tests drive the real Rust accelerators over JNI ----------------
// Same seam as :core and :dsh: the host build of `libpdsh_jni` is an input of
// this module's tests, because a stub that never ran `rg` proves nothing. Build
// it first with: cd shell && cargo build -p pdsh-jni
// The path is derived from the Gradle root, so no machine-local absolute path is
// committed.
val repoRoot: File = rootProject.projectDir.parentFile
val nativeLibraryDir: File = repoRoot.resolve("shell/target/debug")
val nativeLibrary: File = nativeLibraryDir.resolve(System.mapLibraryName("pdsh_jni"))

tasks.withType<Test>().configureEach {
    systemProperty("java.library.path", nativeLibraryDir.absolutePath)
    // Not declared as an input: Gradle validates a declared input BEFORE
    // doFirst runs, so a missing dylib would surface as "file ... does not
    // exist" and bury the actionable message below (KOTLIN-TRAPS.md #5).
    doFirst {
        check(nativeLibrary.isFile) {
            "missing ${nativeLibrary.path}; the :shell tests run the real Rust accelerators. " +
                "Build it first with: cd shell && cargo build -p pdsh-jni"
        }
    }
}

dependencies {
    api(project(":core"))
    api(project(":platform"))

    testImplementation(libs.junit)
    // Android provides org.json on device; the JVM tests parse the real
    // capability JSON with the reference implementation (same pin as :dsh).
    testImplementation("org.json:json:20240303")
}
