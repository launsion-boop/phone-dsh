// SPDX-License-Identifier: MIT
// :dsh mirrors Sources/PhoneDSH: the facade that aggregates the other packages.
// Android library; the published AAR entry is :lib, not :dsh.
//
// ---- background execution (P4) --------------------------------------------
// The background lane adds three dependencies, pinned here rather than in
// gradle/libs.versions.toml because that catalog is shared with the other lanes
// and this module's exact versions are its own evidence:
//   androidx.core 1.15.0   ServiceCompat / NotificationCompat / NotificationManagerCompat
//   androidx.work 2.10.0   the tombstone: a persistent, reboot-surviving task
//   androidx.test 1.6.x    the instrumented tests below (device evidence, not mocks)
// WorkManager is only ever a tombstone/reporting mechanism; the turn itself runs on
// UIDT (API 34+) or the dataSync foreground service (API 26-33).
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.phonedsh.dsh"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        // targetSdk is what the self-instrumenting test APK runs as. Left unset it
        // falls back to minSdk (26), which would test a legacy app: no Android 13
        // notification permission model, no Android 14 foreground-service type
        // enforcement. The lane's contracts only exist at 35.
        targetSdk = 35
        // The background lane's evidence is instrumented: a notification that was
        // never posted to a real NotificationManager proves nothing.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
}

// ---- the host HELLO unit tests drive the real Rust codec --------------------
// The HELLO assertions decode the frame the facade produced with
// `WireCodec.decode` (the Rust codec through JNI), so the host build of
// `libpdsh_jni` is an input of :dsh's unit tests, exactly as it is for :core.
// Build it first with: cd shell && cargo build -p pdsh-jni
// The path is derived from the Gradle root, so no machine-local absolute path is
// committed.
val repoRoot: File = rootProject.projectDir.parentFile
val nativeLibraryDir: File = repoRoot.resolve("shell/target/debug")
val nativeLibrary: File = nativeLibraryDir.resolve(System.mapLibraryName("pdsh_jni"))

tasks.withType<Test>().configureEach {
    systemProperty("java.library.path", nativeLibraryDir.absolutePath)
    // A rebuilt dylib changes the assertions (the codec is what produced the
    // bytes), so it is an input rather than just an environment property.
    // Not declared as an input: Gradle validates a declared input BEFORE doFirst
    // runs, so a missing dylib surfaced as "file ... does not exist" and buried the
    // actionable message below. The doFirst check is the one people need to see.
    doFirst {
        check(nativeLibrary.isFile) {
            "missing ${nativeLibrary.path}; the host HELLO tests decode through the Rust codec. " +
                "Build it first with: cd shell && cargo build -p pdsh-jni"
        }
    }
}

dependencies {
    api(project(":platform"))
    api(project(":core"))
    api(project(":net"))
    api(project(":controller"))
    // :engine is deliberately NOT a dependency: the facade aggregates the
    // :platform `EngineHost` interface and the App injects `createDemoEngine(...)`.
    // Naming :engine here would rebuild the inversion the :platform SPI exists for
    // (F5 report: the dependency was still hanging).
    api(project(":shell"))

    implementation(libs.androidx.core.ktx)
    implementation("androidx.work:work-runtime:2.10.0")

    testImplementation(libs.junit)
    // Android provides org.json on device; the JVM unit tests read the decoded
    // HELLO fields with the reference implementation (same pin as :engine).
    testImplementation("org.json:json:20240303")

    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation(libs.androidx.test.ext.junit)
}
