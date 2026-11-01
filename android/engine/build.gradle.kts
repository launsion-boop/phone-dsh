// SPDX-License-Identifier: MIT
// :engine mirrors Sources/PhoneDSHEngine: the WebView lifecycle, renderer-gone
// recovery and the loopback attachment live behind DemoEngine. Android library.
//
// ---- why the worker bundle is one zip asset, not loose assets --------------
// AGP's asset merge gunzips every asset whose file name ends in `.gz` and drops
// the suffix (`MergedAssetWriter`'s AssetWorkAction -> `AssetItem.shouldBeUnGzipped`;
// Guava `getNameWithoutExtension`). There is no Gradle switch for it. Measured on
// 2026-10-31: `assets/worker/image.tar.gz` (25.2 MB) landed in the AAR as
// `assets/worker/image.tar` (84.8 MB, inflated bytes), and `lazy/*.tar.gz` lost
// their suffix too. The bundle addresses its archives by their `.gz` names, so
// loose assets are unusable. `packageWorkerBundle` packs the prebuilt bundle into
// ONE asset (`assets/worker-bundle.zip`) whose entries keep both name and bytes;
// ZipWorkerAssetSource reads it back. Nothing is copied into the repository.
//
// Pins live here rather than in gradle/libs.versions.toml: the catalog is shared
// with the other lanes, and this module's exact versions are its own evidence.
//   androidx.webkit 1.12.1  - WebViewFeature probes only (telemetry, §6.3-3)
//   coroutines 1.10.2       - StateFlow + Dispatchers.Main (matches :net's Ktor 3.2.3)
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

val repoRoot: File = rootProject.projectDir.parentFile
val workerBundleDir: File = repoRoot.resolve("examples/probe-app/Bundle/worker")
val workerBundleAssetDir: File = layout.buildDirectory.dir("generated/worker-bundle").get().asFile

val packageWorkerBundle = tasks.register<Zip>("packageWorkerBundle") {
    description = "Packs the prebuilt worker bundle into assets/worker-bundle.zip"
    group = "build"
    from(workerBundleDir)
    archiveFileName.set("worker-bundle.zip")
    destinationDirectory.set(workerBundleAssetDir)
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

android {
    namespace = "com.phonedsh.engine"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
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

    androidResources {
        // The bundle zip is already compressed; do not deflate it a second time.
        noCompress += listOf("zip")
    }

    // `assets/worker-bundle.zip` is generated; the bundle itself stays where it is.
    sourceSets["main"].assets.srcDir(workerBundleAssetDir)
    // The instrumented test installs its own APK; it needs the bundle too.
    sourceSets["androidTest"].assets.srcDir(workerBundleAssetDir)
}

// Populate the generated asset directory before any task consumes assets.
tasks.configureEach {
    // Anything that reads the generated assets directory has to wait for the zip:
    // the merge tasks end in "Assets", and AGP's lint model tasks also read it. A
    // missing dependency there fails the *consumer's* build (it surfaced as
    // :app:assembleRelease failing), which is the sort of cross-module coupling
    // that is invisible until someone builds the app.
    val readsGeneratedAssets =
        (name.endsWith("Assets") || name.contains("lint", ignoreCase = true))
    if (readsGeneratedAssets && name != packageWorkerBundle.name) {
        dependsOn(packageWorkerBundle)
    }
}

dependencies {
    api(project(":net"))
    api(project(":platform"))
    // The HELLO summary is decoded by the one Wire implementation (Rust through
    // the JNI facade): the parent contract for D3 requires the real codec, not a
    // Kotlin re-implementation.
    api(project(":core"))

    implementation("androidx.webkit:webkit:1.12.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation(libs.junit)
    // Android provides org.json on device; the unit tests run on the JVM and use
    // the reference implementation (HelloFieldsTest).
    testImplementation("org.json:json:20240303")

    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
