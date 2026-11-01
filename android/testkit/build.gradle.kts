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
val nativeLibraryDir: File = repoRoot.resolve("shell/target/debug")
val nativeLibrary: File = nativeLibraryDir.resolve(System.mapLibraryName("pdsh_jni"))

tasks.withType<Test>().configureEach {
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
    systemProperty("java.library.path", nativeLibraryDir.absolutePath)
    // Not declared as an input: Gradle validates a declared input BEFORE doFirst
    // runs, so a missing dylib surfaced as "file ... does not exist" and buried the
    // actionable message below. The doFirst check is the one people need to see.
    doFirst {
        check(nativeLibrary.isFile) {
            "missing ${nativeLibrary.path}; build it first with: cd shell && cargo build -p pdsh-jni"
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

val packageWorkerBundleForTests = tasks.register<Zip>("packageWorkerBundleForTests") {
    description = "Packs the prebuilt worker bundle into the test APK's assets/worker-bundle.zip"
    group = "verification"
    from(workerBundleDirectory)
    archiveFileName.set("worker-bundle.zip")
    destinationDirectory.set(workerBundleAssetDirectory)
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
    doFirst {
        check(workerBundleDirectory.isDirectory) {
            "the prebuilt worker bundle is missing: " +
                workerBundleDirectory.relativeTo(repoRoot).path +
                " (it is a gitignored build input; copy it with " +
                "examples/probe-app/scripts/copy-bundle-assets.sh)"
        }
    }
}

val stageAndroidTestJni = tasks.register<Copy>("stageAndroidTestJni") {
    description = "Stages libpdsh_jni.so into the androidTest jniLibs (arm64-v8a)"
    group = "verification"
    from(androidJniLibrary)
    into(androidTestJniDirectory.resolve("arm64-v8a"))
    doFirst {
        check(androidJniLibrary.isFile) {
            "missing " + androidJniLibrary.relativeTo(repoRoot).path +
                "; build it first with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
        }
    }
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
    from(scenarioCatalogSource)
    into(scenarioCatalogAssetDirectory.resolve("scenario-catalog"))
    doFirst {
        check(scenarioCatalogSource.isFile) {
            "the scenario catalog is missing: " + scenarioCatalogSource.relativeTo(repoRoot).path
        }
    }
}

android {
    // `assets/worker-bundle.zip` is generated; the source bundle stays where it is.
    sourceSets["androidTest"].assets.srcDir(workerBundleAssetDirectory)
    // `assets/scenario-catalog/catalog.json` is generated from the checked-in catalog.
    sourceSets["androidTest"].assets.srcDir(scenarioCatalogAssetDirectory)
    sourceSets["androidTest"].jniLibs.srcDir(androidTestJniDirectory)
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("AndroidTestAssets") }
    .configureEach { dependsOn(packageWorkerBundleForTests, packageScenarioCatalogForTests) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("AndroidTestJniLibFolders") }
    .configureEach { dependsOn(stageAndroidTestJni) }
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("AndroidTestNativeLibs") }
    .configureEach { dependsOn(stageAndroidTestJni) }
tasks.named("preBuild").configure {
    dependsOn(packageWorkerBundleForTests, packageScenarioCatalogForTests, stageAndroidTestJni)
}

dependencies {
    // The turn lane constructs the real engine (WebViewEngine via its factory) and
    // the real host facade. :dsh is already an `api` dependency; :engine is added
    // for the instrumented test only, because a JVM test must never link a WebView.
    androidTestImplementation(project(":engine"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test:core:1.6.1")
}
