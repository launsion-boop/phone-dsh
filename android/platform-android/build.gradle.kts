// SPDX-License-Identifier: MIT
// :platform-android is the device half of the :platform SPI: the six interfaces
// stay pure Kotlin/JVM so :core and :net keep running with no device, while the
// real OS primitives (Keystore, PowerManager, ConnectivityManager,
// android.system.Os) only exist here.
//
// The evidence for this module is instrumented: a StrongBox/TEE verdict, the
// SecureStore three-state and the first-frame LifecycleSnapshot cannot be
// produced by a host JVM.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.phonedsh.platform.android"

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
        // The host suite exercises AndroidClock and AndroidDurability through
        // injected lambdas/seams. The mockable android.jar must stay strict so a
        // forgotten injection fails loudly instead of returning a default.
        unitTests.isReturnDefaultValues = false
    }
}

dependencies {
    // The SPI types (Clock, Durability, SecureStore, LifecycleSignals, ...) are
    // part of this module's public surface, so the dependency is `api`.
    api(project(":platform"))

    testImplementation(libs.junit)

    // Instrumented evidence. All three coordinates are already resolved by
    // :dsh / :engine from the same offline cache.
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    // androidx.test 1.6.x asks for androidx.annotation 1.7.0-beta01, whose
    // `annotation-jvm` jar is not in the offline cache (only its metadata is).
    // 1.8.1 is API-compatible and its jar is cached, so pin it rather than
    // letting the test APK fail to assemble offline.
    androidTestImplementation("androidx.annotation:annotation:1.8.1")
}
