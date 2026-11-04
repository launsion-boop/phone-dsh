// SPDX-License-Identifier: MIT
// :testkit merges PhoneDSHScenario (scenario runner) and PhoneDSHHarness
// (UI-state recording / fault driver). Not published. Android library so the
// probe app can drive instrumentation on a device.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.phonedsh.testkit"
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
}

dependencies {
    api(project(":dsh"))
    api(project(":platform"))
    // The scenario catalog is decoded with :core's dependency-free JSON value
    // parser (JsonValue.parse). :core is a pure JVM java-library, so the runner
    // keeps its "no engine, no device" property and adds no external coordinate.
    // The package is already visible transitively through :dsh; declaring it
    // explicitly keeps the scenario package honest about what it uses.
    implementation(project(":core"))

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}

// The scenario runner is pure JVM, but its fixture is the checked-in catalog:
// tests resolve scripts/ci/scenarios/catalog.json from the repository root. The
// root is derived from the Gradle project tree at build time, so no machine-local
// absolute path is committed and a test never guesses the working directory.
tasks.withType<Test>().configureEach {
    systemProperty("pdsh.repo.root", rootProject.projectDir.parentFile.absolutePath)
}

// An Android library writes JUnit XML per variant
// (build/test-results/testDebugUnitTest/). The Android lane's result gate reads
// the JVM-module convention build/test-results/test/*.xml, so publish the debug
// report there once the test task has finished. Both variants run the same suite.
val publishUnitTestReports = tasks.register<Sync>("publishUnitTestReports") {
    description = "Copies the JVM unit-test JUnit XML to the aggregate test-results/test path"
    group = "verification"
    from(layout.buildDirectory.dir("test-results/testDebugUnitTest"))
    into(layout.buildDirectory.dir("test-results/test"))
    include("*.xml")
}
// `test` is the AGP-created lifecycle task over testDebugUnitTest +
// testReleaseUnitTest; it does not exist yet at configuration time, so match it
// as it is realized.
tasks.matching { it.name == "test" }.configureEach {
    finalizedBy(publishUnitTestReports)
}

// The harness tests drive the real host: VFS_MUT frames go through the Rust codec
// via JNI, so the JVM needs the host build of `pdsh-jni` on its library path. The
// directory is derived from the Gradle root (no machine-local path is committed).
// Build it first with: cd shell && cargo build -p pdsh-jni
val repoRoot: File = rootProject.projectDir.parentFile
val nativeLibrary: File = repoRoot.resolve("shell/target/debug/${System.mapLibraryName("pdsh_jni")}")
val hostJniTestDirectory: File = layout.buildDirectory.dir("generated/host-jni-test").get().asFile
val stageHostJniForTests = tasks.register("stageHostJniForTests") {
    description = "Stages the real host Rust JNI artifact for testkit JVM tests"
    doLast {
        check(nativeLibrary.isFile) {
            "missing real Rust JNI artifact ${nativeLibrary.path}; build it with: " +
                "bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni"
        }
        hostJniTestDirectory.mkdirs()
        nativeLibrary.copyTo(hostJniTestDirectory.resolve(nativeLibrary.name), overwrite = true)
    }
}

tasks.withType<Test>().configureEach {
    dependsOn(stageHostJniForTests)
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
    systemProperty("java.library.path", hostJniTestDirectory.absolutePath)
    doFirst {
        val staged = hostJniTestDirectory.resolve(System.mapLibraryName("pdsh_jni"))
        check(staged.isFile && staged.length() > 0L) {
            "real host JNI artifact was not staged at ${staged.path}; build it with: " +
                "bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni"
        }
    }
}

// ---- the instrumented lanes' inputs ----------------------------------------
// `TurnOverChannelInstrumentedTest` drives the REAL prebuilt worker on a device:
// the page, the ordered channel, the `/api` lane and the host's `phone info`
// exec are the product ones. `CatalogOnDeviceTest` additionally evaluates the
// checked-in scenario catalog on the device. Three build inputs make that
// possible and every one of them is derived from the Gradle root (no
// machine-local path is committed):
//
//   1. the worker bundle, packaged as ONE asset (`assets/worker-bundle.zip`),
//      exactly as :engine and :app do it — :testkit is not published, so the
//      65 MB asset only ever lands in a test APK;
//   2. the Rust wire codec (`libpdsh_jni.so`, cargo-ndk arm64-v8a output) in the
//      test APK's jniLibs. Without it the host HELLO cannot be encoded and the
//      worker never starts its tree, so the turn lane cannot exist. :app does
//      the same copy for the demo APK; :core is pure JVM and cannot carry it;
//   3. the scenario catalog (`assets/scenario-catalog/catalog.json`), copied
//      from `scripts/ci/scenarios/catalog.json`, so the device lane reads the
//      same document the JVM and macOS lanes read instead of a second copy.
val workerBundleDirectory: File = repoRoot.resolve("examples/probe-app/Bundle/worker")
val workerBundleAssetDirectory: File =
    layout.buildDirectory.dir("generated/worker-bundle").get().asFile
val androidJniLibrary: File =
    repoRoot.resolve("shell/target/aarch64-linux-android/debug/libpdsh_jni.so")
val androidTestJniDirectory: File =
    layout.buildDirectory.dir("generated/test-jniLibs").get().asFile

fun displayPath(path: File): String =
    runCatching { path.relativeTo(repoRoot).path }.getOrElse { path.absolutePath }

fun requireWorkerBundleForTests(directory: File) {
    check(directory.isDirectory) {
        "the prebuilt worker bundle is missing: " + displayPath(directory) +
            " (it is a gitignored build input; copy it with " +
            "examples/probe-app/scripts/copy-bundle-assets.sh)"
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
        "the prebuilt worker bundle is incomplete: " + displayPath(directory) +
            " (missing or empty: " + missing.joinToString(", ") + ")"
    }
    val image = File(directory, "image.tar.gz")
    val magic = ByteArray(2)
    val read = image.inputStream().use { it.read(magic) }
    check(read == 2 && magic[0] == 0x1f.toByte() && magic[1] == 0x8b.toByte()) {
        "the prebuilt worker bundle has an invalid image.tar.gz (not gzip): " +
            displayPath(image)
    }
}

fun requireElfLibrary(file: File) {
    check(file.isFile) {
        "missing " + displayPath(file) +
            "; build it first with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
    }
    check(file.length() > 0L) {
        "the JNI library is empty: " + displayPath(file) +
            "; rebuild it with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
    }
    val magic = ByteArray(4)
    val read = file.inputStream().use { it.read(magic) }
    check(
        read == 4 &&
            magic[0] == 0x7f.toByte() &&
            magic[1] == 'E'.code.toByte() &&
            magic[2] == 'L'.code.toByte() &&
            magic[3] == 'F'.code.toByte(),
    ) {
        "the JNI library is not an ELF shared object: " + displayPath(file) +
            "; rebuild it with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
    }
}

// A Copy/Zip task whose source is missing is NO-SOURCE, and Gradle skips its
// actions (including doFirst) for NO-SOURCE. The fail-loud checks therefore live
// in always-running validators that the staging tasks depend on. Only the
// Android-test packaging graph reaches these validators; a pure JVM test does
// not, which is the preBuild split this module needs.
val verifyWorkerBundleForTests = tasks.register("verifyWorkerBundleForTests") {
    description = "Fails if the device test Worker bundle is missing, empty or incomplete"
    group = "verification"
    doLast {
        requireWorkerBundleForTests(workerBundleDirectory)
    }
}

val verifyAndroidTestJni = tasks.register("verifyAndroidTestJni") {
    description = "Fails if the Android arm64 JNI library is absent, empty or not ELF"
    group = "verification"
    doLast {
        requireElfLibrary(androidJniLibrary)
    }
}

// Test-only fixture entry points; NOT dependencies of any Android-test merge or
// packaging task. Production staging always uses the canonical paths above, so
// no Gradle property can replace the shipped inputs. Both tasks share the real
// validators.
tasks.register("verifyWorkerBundleForTestsFixture") {
    description = "Test-only: validate a fixture Worker directory through the device-test validator"
    group = "verification"
    doLast {
        val raw = providers.gradleProperty("pdsh.test.testkitWorkerBundleDir").orNull
            ?: error("pass -Ppdsh.test.testkitWorkerBundleDir=<path> for the test-only Worker validator")
        requireWorkerBundleForTests(File(raw))
    }
}

tasks.register("verifyAndroidTestJniFixture") {
    description = "Test-only: validate a fixture .so through the device-test JNI validator"
    group = "verification"
    doLast {
        val raw = providers.gradleProperty("pdsh.test.testkitAndroidJni").orNull
            ?: error("pass -Ppdsh.test.testkitAndroidJni=<path> for the test-only JNI validator")
        requireElfLibrary(File(raw))
    }
}

val verifyScenarioCatalog = tasks.register("verifyScenarioCatalog") {
    description = "Fails if the checked-in scenario catalog is absent"
    group = "verification"
    doLast {
        check(scenarioCatalogSource.isFile) {
            "the scenario catalog is missing: " + scenarioCatalogSource.relativeTo(repoRoot).path
        }
    }
}

val packageWorkerBundleForTests = tasks.register<Zip>("packageWorkerBundleForTests") {
    description = "Packs the prebuilt worker bundle into the test APK's assets/worker-bundle.zip"
    group = "verification"
    dependsOn(verifyWorkerBundleForTests)
    from(workerBundleDirectory)
    archiveFileName.set("worker-bundle.zip")
    destinationDirectory.set(workerBundleAssetDirectory)
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

val stageAndroidTestJni = tasks.register<Copy>("stageAndroidTestJni") {
    description = "Stages libpdsh_jni.so into the androidTest jniLibs (arm64-v8a)"
    group = "verification"
    dependsOn(verifyAndroidTestJni)
    from(androidJniLibrary)
    into(androidTestJniDirectory.resolve("arm64-v8a"))
}

// ---- the catalog as a device asset -----------------------------------------
// `CatalogOnDeviceTest` must evaluate the SAME checked-in catalog the JVM and
// macOS lanes read, so the source stays `scripts/ci/scenarios/catalog.json` and
// only a generated copy travels in the test APK
// (`assets/scenario-catalog/catalog.json`). Fixtures are deliberately not
// packaged: every scenario the device lane runs declares none, and
// `ScenarioRunner` fails loud rather than running a fixture scenario against an
// empty fixture root.
val scenarioCatalogSource: File = repoRoot.resolve("scripts/ci/scenarios/catalog.json")
val scenarioCatalogAssetDirectory: File =
    layout.buildDirectory.dir("generated/scenario-catalog").get().asFile

val packageScenarioCatalogForTests = tasks.register<Copy>("packageScenarioCatalogForTests") {
    description = "Copies the scenario catalog into the test APK's assets/scenario-catalog/"
    group = "verification"
    dependsOn(verifyScenarioCatalog)
    from(scenarioCatalogSource)
    into(scenarioCatalogAssetDirectory.resolve("scenario-catalog"))
}

android {
    // `assets/worker-bundle.zip` is generated; the source bundle stays where it is.
    sourceSets["androidTest"].assets.srcDir(workerBundleAssetDirectory)
    // `assets/scenario-catalog/catalog.json` is generated from the checked-in catalog.
    sourceSets["androidTest"].assets.srcDir(scenarioCatalogAssetDirectory)
    sourceSets["androidTest"].jniLibs.srcDir(androidTestJniDirectory)
}

// Only the Android test *packaging* consumers depend on the real device-only
// inputs. preBuild deliberately does not: it is a parent of every variant,
// including testDebugUnitTest, and attaching the 65 MB Worker image + Android
// .so there made a pure host JVM test fail (or do expensive staging) for inputs
// it cannot use. The merge tasks below are the actual packaging edges, so a
// connected/instrumented test APK still fails loudly when an input is missing.
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("AndroidTestAssets") }
    .configureEach { dependsOn(packageWorkerBundleForTests, packageScenarioCatalogForTests) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("AndroidTestJniLibFolders") }
    .configureEach { dependsOn(stageAndroidTestJni) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("AndroidTestNativeLibs") }
    .configureEach { dependsOn(stageAndroidTestJni) }

dependencies {
    // The turn lane constructs the real engine (WebViewEngine via its factory) and
    // the real host facade. :dsh is already an `api` dependency; :engine is added
    // for the instrumented test only, because a JVM test must never link a WebView.
    androidTestImplementation(project(":engine"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test:core:1.6.1")
}
