// SPDX-License-Identifier: MIT
// :domain is the P6 platform layer: the domain key/value store (session, memory,
// task, ...) and the DeviceCapabilities SPI. There is no Room and no SQLDelight:
// the only SQL is `android.database.sqlite`, chosen because the platform layer
// must not add a code generator or a second SQL dialect to the build (task
// constraint; the plan's §8.2 SQLDelight decision is recorded as an open
// question in the K3 report).
//
// The store's whole behavioural core sits above one typed connection seam
// (`ConnectionFactory` / `Connection` / `Transaction`) so the JVM suite can run
// every case with no Android API at all. `android.database.sqlite` appears in
// exactly one file, `SqliteConnection.kt`, and that file is what the
// instrumented suite drives.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    id("maven-publish")
}

android {
    namespace = "com.phonedsh.domain"

    compileSdk = 35

    defaultConfig {
        minSdk = 26
        targetSdk = 35
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

    testOptions {
        // The host suite must never silently receive an Android stub: the core
        // is pure Kotlin and a defaulted android.jar would hide a leaked import.
        unitTests.isReturnDefaultValues = false
    }

    sourceSets {
        // One behavioural contract, two drivers: the host suite runs it on the
        // in-memory fake, the instrumented suite on real SQLite. Both compile
        // this exact file, so a case cannot be forgotten on one side.
        getByName("test").java.srcDir("src/contractTest/kotlin")
        getByName("androidTest").java.srcDir("src/contractTest/kotlin")
    }
}

// The device-capability test reads the normative schema straight from spec/.
// The root is derived from the Gradle root so no machine-local path is committed.
val repoRoot: File = rootProject.projectDir.parentFile

tasks.withType<Test>().configureEach {
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
}

dependencies {
    // Clock appears in DomainStoreCore's constructor: updated_at is read through
    // the only time source the upper layers may observe (no module calls the OS
    // clock directly).
    api(project(":platform"))

    testImplementation(libs.junit)

    // Instrumented evidence, same pins as :platform-android. The annotation pin
    // is deliberate: androidx.test 1.6.x asks for annotation 1.7.0-beta01, whose
    // jar is not in the offline cache.
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.annotation:annotation:1.8.1")
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
