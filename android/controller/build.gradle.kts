// SPDX-License-Identifier: MIT
// :controller mirrors Sources/PhoneDSHController. Android library.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    id("maven-publish")
}

android {
    namespace = "com.phonedsh.controller"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
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

dependencies {
    api(project(":core"))
    api(project(":net"))
    api(project(":platform"))
    testImplementation(libs.junit)
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
