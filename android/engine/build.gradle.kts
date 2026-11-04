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

fun displayPath(path: File): String =
    runCatching { path.relativeTo(repoRoot).path }.getOrElse { path.absolutePath }

/**
 * Required real Worker entries. The bundle is generated, but an existing empty
 * directory is not a bundle: a Zip task with no source is NO-SOURCE and would
 * otherwise produce no `assets/worker-bundle.zip` while still succeeding.
 * `image.tar.gz` is also checked for the gzip magic so a zero-byte or text file
 * cannot pass. Keep this in sync with examples/probe-app/Bundle/README.md.
 */
fun requireWorkerBundle(directory: File) {
    check(directory.isDirectory) {
        "the prebuilt worker bundle is missing: " + displayPath(directory) + "\n" +
            "The APK needs it; it is not committed because it is ~65 MB.\n" +
            "Generate it with the documented copy step (needs the pinned DSH checkout):\n" +
            "  bash examples/probe-app/scripts/copy-bundle-assets.sh\n" +
            "For a full DSH Web page, build the Web dist first:\n" +
            "  bash scripts/ci/build-web-dist.sh\n" +
            "then re-run the copy step. Nothing is copied into android/."
    }
    val required = listOf(
        "index.html",
        "boot.js",
        "worker-entry.js",
        "tool-worker-python.js",
        "workflow-isolate.js",
        "image.tar.gz",
    )
    val missing = required.filter { name ->
        val file = File(directory, name)
        !file.isFile || file.length() == 0L
    }
    check(missing.isEmpty()) {
        "the prebuilt worker bundle is incomplete: " + displayPath(directory) + "\n" +
            "Missing or empty required entries: " + missing.joinToString(", ") + "\n" +
            "Re-run: bash examples/probe-app/scripts/copy-bundle-assets.sh"
    }
    val image = File(directory, "image.tar.gz")
    val magic = ByteArray(2)
    val read = image.inputStream().use { it.read(magic) }
    check(read == 2 && magic[0] == 0x1f.toByte() && magic[1] == 0x8b.toByte()) {
        "the prebuilt worker bundle has an invalid image.tar.gz (not gzip): " +
            displayPath(image)
    }
}

// A Zip task whose `from(dir)` is missing/empty is NO-SOURCE, and Gradle does not
// run its actions (including doFirst) for a NO-SOURCE task. Keep the fail-loud
// check in an always-running validator that packageWorkerBundle depends on, so an
// APK can never ship an empty asset. The validator is deliberately not part of
// JVM test graphs: only asset merge consumers depend on packageWorkerBundle.
val verifyWorkerBundle = tasks.register("verifyWorkerBundle") {
    description = "Fails if the prebuilt worker bundle is missing, empty or incomplete (asset packaging only)"
    group = "verification"
    doLast {
        requireWorkerBundle(workerBundleDir)
    }
}

// Test-only fixture entry point; NOT a dependency of packageWorkerBundle or any
// asset merge. Production packaging always reads the canonical path above, so no
// Gradle property can replace the shipped bundle. The fixture task shares
// [requireWorkerBundle] with the real packaging validator.
tasks.register("verifyWorkerBundleFixture") {
    description = "Test-only: validate a fixture Worker directory through the packaging validator"
    group = "verification"
    doLast {
        val raw = providers.gradleProperty("pdsh.test.workerBundleDir").orNull
            ?: error("pass -Ppdsh.test.workerBundleDir=<path> for the test-only Worker validator")
        val fixture = File(raw)
        requireWorkerBundle(fixture)
    }
}

val packageWorkerBundle = tasks.register<Zip>("packageWorkerBundle") {
    description = "Packs the prebuilt worker bundle into assets/worker-bundle.zip"
    group = "build"
    dependsOn(verifyWorkerBundle)
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
