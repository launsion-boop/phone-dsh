// SPDX-License-Identifier: MIT
// :shell mirrors Sources/PhoneDSHShell: the JNI binding surface for the Rust
// accelerator. It carries no native code of its own -- `:app`'s PackagePdshJni
// copies the prebuilt .so in per variant -- so there is no CMake here and no
// src/main/jniLibs/.
//
// 16 KB pages (plan P2a). Android 15+ can run on a 16 KB-page kernel, and a .so
// whose PT_LOAD segments are aligned below 16 KB fails to load there; Google Play
// requires the alignment for new uploads from 2025-11. NDK r28+ links shared
// libraries 16 KB-aligned by default (verified against the NDK in this
// workspace, 30.0.16248370, whose bare `-shared` link yields p_align 0x4000, and
// against r28's changelog), but nothing here pins the NDK version: `:app` takes
// the first NDK it finds under local.properties ndk.dir, ANDROID_NDK_HOME or the
// SDK, and an r27-or-older NDK would link 4 KB again. The flag is therefore
// pinned explicitly, for Android targets only, in
// `shell/crates/pdsh-jni/build.rs` -- not in `shell/.cargo/config.toml`, which
// would also reach the host dylib and the wasm products and is hashed by the jq
// wasi fingerprint.
//
// Three checks keep it from regressing; none needs a device:
//   * `android-16k-link-arg` (android/tools/structure_check.py): build.rs still
//     carries the flag and its Android-only gate;
//   * `android-16k-artifact` (android/tools/check-native-alignment.py): the cargo
//     .so has PT_LOAD p_align >= 0x4000;
//   * scripts/ci/check-android-16k.py: the .so that actually ships -- the
//     post-strip member inside the APK must be STORED, 16 KB aligned in the zip
//     and 16 KB aligned in the ELF; its mutation suite proves each half goes red.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    id("maven-publish")
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
        // `:shell` ships no jniLibs today, so this is the AAR-side guard: if one
        // is ever added here it must stay uncompressed, because a compressed zip
        // entry cannot be mapped from the archive. The APK-side guarantee
        // (STORED + 16 KB-aligned zip entry + 16 KB-aligned ELF) is checked by
        // scripts/ci/check-android-16k.py; the link flag itself is explained at
        // the top of this file.
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

// ---- the published coordinate ------------------------------------------------
// `com.phonedsh:<module>:0.1.0`, packaging=aar. The repository and the version
// come from android/build.gradle.kts (root `subprojects` block); this script
// only names the software component. `afterEvaluate` is required, not
// defensive: AGP creates the `release` component from its variant API after
// this script has been evaluated, so a script-level
// `from(components["release"])` fails with
// "SoftwareComponent with name 'release' not found".
publishing {
    publications {
        create<MavenPublication>("release") {
            afterEvaluate { from(components["release"]) }
        }
    }
}
