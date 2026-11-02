// SPDX-License-Identifier: MIT
// :app is the demo vehicle: one Compose screen over the :engine contract. It
// renders DemoEngine.state/channel/handshake and never sees the engine view type.
import java.util.Properties
import javax.inject.Inject
import org.gradle.api.DefaultTask
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.gradle.api.tasks.Copy
import org.gradle.api.tasks.testing.Test
import org.gradle.process.ExecOperations

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// The prebuilt worker bundle is a 65 MB, gitignored build input owned by
// :engine. It is referenced there in place (never copied into the repository)
// and :engine's packageWorkerBundle task fails loudly when it is absent, so an
// APK without a worker bundle cannot be produced. This module deliberately does
// NOT check the bundle at configuration time: a host JVM test
// (:app:testDebugUnitTest) must configure and run without the 65 MB asset, and
// only APK/asset packaging is allowed to require it. :app consumes :engine, so
// assembleDebug/assembleRelease and the instrumented APK still depend on that
// real packaging task and still fail when the bundle is missing.
//
// The one Wire codec is Rust (:core's JNI facade); :core is a pure JVM module and
// cannot carry jniLibs, so the demo APK has to package the .so itself. The path is
// cargo-ndk's arm64 output; other ABIs are not packaged (the demo target is the
// arm64-v8a emulator). Missing here means HELLO stays undecodable at runtime,
// which the screen would show as "libpdsh_jni not packaged"; the packaging task
// below fails instead of shipping that APK.
val repoRoot: File = rootProject.projectDir.parentFile
val pdshJniSo: File = repoRoot.resolve("shell/target/aarch64-linux-android/debug/libpdsh_jni.so")
val hostPdshJni: File = repoRoot.resolve("shell/target/debug/${System.mapLibraryName("pdsh_jni")}")
val hostJniTestDirectory: File = layout.buildDirectory.dir("generated/host-jni-test").get().asFile
val stageHostJniForTests = tasks.register("stageHostJniForTests") {
    description = "Stages the real host Rust JNI artifact for app JVM tests"
    doLast {
        check(hostPdshJni.isFile) {
            "missing real Rust JNI artifact ${hostPdshJni.path}; build it with: " +
                "bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni"
        }
        hostJniTestDirectory.mkdirs()
        hostPdshJni.copyTo(hostJniTestDirectory.resolve(hostPdshJni.name), overwrite = true)
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
fun displayPath(path: File): String =
    runCatching { path.relativeTo(repoRoot).path }.getOrElse { path.absolutePath }
val pdshJniRelative: String = displayPath(pdshJniSo)

/**
 * One validator for production packaging and the test-only fixture task: the
 * installed APK must never contain an empty, truncated or non-ELF library.
 *
 * A plain `object` (not a script-level function) keeps PackagePdshJni a static
 * nested class; a task class that captures the build-script instance cannot be
 * instantiated by Gradle.
 */
object PdshJniValidation {
    fun require(input: File, relativePath: String) {
        check(input.isFile) {
            "the Rust JNI library is missing: $relativePath\n" +
                "Without it HELLO cannot be decoded and the demo screen cannot show the\n" +
                "handshake summary. Build it with the pinned NDK + cargo-ndk:\n" +
                "  cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni\n" +
                "The .so is a build product and is not committed."
        }
        check(input.length() > 0L) {
            "the Rust JNI library is empty: $relativePath\n" +
                "Rebuild it with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
        }
        val magic = ByteArray(4)
        val magicRead = input.inputStream().use { it.read(magic) }
        check(
            magicRead == 4 &&
                magic[0] == 0x7f.toByte() &&
                magic[1] == 'E'.code.toByte() &&
                magic[2] == 'L'.code.toByte() &&
                magic[3] == 'F'.code.toByte(),
        ) {
            "the Rust JNI library is not an ELF shared object: $relativePath\n" +
                "Rebuild it with: cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni"
        }
    }
}

// Test-only validator entry point. It is deliberately NOT a dependency of any
// package/assemble task: production packaging always reads the canonical path
// above, so no Gradle property can replace the shipped .so. The fixture task
// shares [PdshJniValidation.require] with the real packaging action.
tasks.register("verifyPdshJniFixture") {
    description = "Test-only: validate a fixture .so through the packaging validator"
    group = "verification"
    doLast {
        val raw = providers.gradleProperty("pdsh.test.pdshJniSo").orNull
            ?: error("pass -Ppdsh.test.pdshJniSo=<path> for the test-only JNI validator")
        val fixture = File(raw)
        PdshJniValidation.require(fixture, displayPath(fixture))
    }
}

// ---- release .so packaging: copy for every variant, strip for release -------
//
// The source .so is cargo's *debug* output (16.9 MB on 2026-10-31, with DWARF).
// A release APK must not ship that: `llvm-strip --strip-unneeded` takes it to
// ~1.5 MB and keeps the 16 KB PT_LOAD alignment. AGP only runs its own strip
// task when it has an NDK it knows about, so the demo does the copy itself and
// strips the generated copy (never the source artifact) for release variants.
//
// Tool discovery never hard-codes a machine path:
//   1. local.properties ndk.dir            (the documented machine-local key)
//   2. ANDROID_NDK_HOME / ANDROID_NDK_ROOT
//   3. <sdk>/ndk/<version>/... for local.properties sdk.dir, ANDROID_HOME,
//      ANDROID_SDK_ROOT and the platform-default Android Studio SDK directory.
// The first NDK that has toolchains/llvm/prebuilt/*/bin/llvm-strip wins.
// When none is found the build still succeeds: the task prints a WARNING with
// the reason and packages the unstripped .so, because CI may not have an NDK and
// a missing *optimisation* must not break the APK.
val localPropertiesFile: File = rootProject.projectDir.resolve("local.properties")
val localProperties: Properties = Properties().apply {
    if (localPropertiesFile.isFile) localPropertiesFile.inputStream().use { load(it) }
}

fun localProperty(name: String): String? =
    localProperties.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }

fun findLlvmStripInNdk(ndkRoot: File): File? {
    val prebuilt = File(ndkRoot, "toolchains/llvm/prebuilt")
    val hosts = prebuilt.listFiles()?.sortedBy { it.name } ?: return null
    return hosts.firstNotNullOfOrNull { host ->
        File(host, "bin/llvm-strip").takeIf { it.isFile }
    }
}

// Monotonic key for NDK directory names such as "27.0.12077973": the first
// three numeric components packed into a Long. Lexicographic order would rank
// "9.0..." above "30.0...", which is the classic version-sort bug.
fun ndkVersionKey(name: String): Long =
    name.split('.').take(3).fold(0L) { key, part ->
        key * 1000 + (part.takeWhile { it.isDigit() }.toIntOrNull() ?: 0)
    }

fun findLlvmStripInSdk(sdkRoot: File): File? {
    val versions = File(sdkRoot, "ndk").listFiles()
        ?.filter { it.isDirectory }
        ?.sortedByDescending { ndkVersionKey(it.name) }
        ?: return null
    return versions.firstNotNullOfOrNull(::findLlvmStripInNdk)
}

val llvmStrip: File? = run {
    val directRoots = listOfNotNull(
        localProperty("ndk.dir")?.let { File(it) },
        System.getenv("ANDROID_NDK_HOME")?.takeIf { it.isNotBlank() }?.let { File(it) },
        System.getenv("ANDROID_NDK_ROOT")?.takeIf { it.isNotBlank() }?.let { File(it) },
    )
    directRoots.firstNotNullOfOrNull(::findLlvmStripInNdk)
        ?: listOfNotNull(
            localProperty("sdk.dir")?.let { File(it) },
            System.getenv("ANDROID_HOME")?.takeIf { it.isNotBlank() }?.let { File(it) },
            System.getenv("ANDROID_SDK_ROOT")?.takeIf { it.isNotBlank() }?.let { File(it) },
            File(System.getProperty("user.home"), "Library/Android/sdk"),
            File(System.getProperty("user.home"), "Android/Sdk"),
        ).distinct().firstNotNullOfOrNull(::findLlvmStripInSdk)
}

val stripReleaseNativeLibs: Boolean =
    providers.gradleProperty("pdsh.stripNative").map { it.toBoolean() }.getOrElse(true)

/**
 * Copies the single prebuilt JNI library into the variant's generated jniLibs
 * directory, stripping the copy for release. A separate task per variant keeps
 * the debug APK's symbols intact and makes the release output independent of
 * whichever variant ran first.
 */
abstract class PackagePdshJni @Inject constructor(
    private val execOps: ExecOperations,
) : DefaultTask() {
    /**
     * cargo's unstripped debug artifact.
     *
     * A file collection (not `@InputFile`) so Gradle does not fail on the
     * missing artifact before the task action runs: the action prints the
     * cargo-ndk command that produces it, and every APK packaging task still
     * fails. When the artifact exists its content is part of the up-to-date
     * fingerprint.
     */
    @get:InputFiles
    @get:Optional
    abstract val source: ConfigurableFileCollection

    /** Repository-relative path used in the fail-loud message. */
    @get:Input
    abstract val sourceRelativePath: Property<String>

    /** jniLibs source root; the task writes `arm64-v8a/<name>` below it. */
    @get:OutputDirectory
    abstract val destination: DirectoryProperty

    /**
     * Which strip mode this variant uses: `unneeded` (release), `debug` (debug), or
     * `none`.
     *
     * Debug used to keep DWARF "for symbolication". That stopped being affordable
     * when the library grew past the JNI codec: `pdsh-ffi` pulls in rg/jaq/ts, and
     * the unstripped arm64 debug artifact is **104 MB**, which would double the demo
     * APK. `--strip-debug` removes the DWARF while keeping the dynamic symbol table
     * (so JNI lookup still works and a native crash still has a symbol), which is
     * the useful half of symbolication for a fraction of the size.
     */
    @get:Input
    abstract val stripMode: Property<String>

    /** Absolute path to the NDK's llvm-strip, absent when no NDK is installed. */
    @get:Input
    @get:Optional
    abstract val stripExecutable: Property<String>

    @TaskAction
    fun packageLibrary() {
        val input = source.files.singleOrNull()
            ?: error("the Rust JNI library is missing: ${sourceRelativePath.get()}")
        PdshJniValidation.require(input, sourceRelativePath.get())
        val target = destination.get().asFile
            .resolve("arm64-v8a")
            .resolve(input.name)
        target.parentFile.mkdirs()
        input.copyTo(target, overwrite = true)

        val tool = stripExecutable.orNull
        val mode = stripMode.get()
        if (mode == "none") {
            logger.lifecycle("[jni] ${target.name}: stripping disabled by -Ppdsh.stripNative=false")
            return
        }
        if (tool.isNullOrBlank()) {
            logger.warn(
                "[jni] WARNING: no Android NDK llvm-strip found (looked at " +
                    "local.properties ndk.dir, ANDROID_NDK_HOME, ANDROID_NDK_ROOT and the " +
                    "SDK ndk/ directories). Packaging ${target.name} UNSTRIPPED " +
                    "(${target.length() / (1024 * 1024)} MB): JNI still works, the release APK " +
                    "is just larger. Install an NDK or point ANDROID_NDK_HOME at one to strip.",
            )
            return
        }
        val flag = if (mode == "debug") "--strip-debug" else "--strip-unneeded"
        execOps.exec {
            commandLine(tool, flag, target.absolutePath)
            isIgnoreExitValue = false
        }
        logger.lifecycle(
            "[jni] stripped ${target.name} to ${target.length() / 1024} KiB with $tool",
        )
    }
}

// ---- identity ------------------------------------------------------------
//
// `applicationId` is the product identity; `namespace` above it stays
// `com.phonedsh.probe`. Those are two different things and they are allowed to
// differ: the namespace names the Kotlin package and the generated R /
// BuildConfig class (18 files' worth of `package com.phonedsh.probe`), while the
// applicationId is what the launcher, the installer and the store see. Renaming
// the namespace would be a move-only diff with no user-visible effect.
//
// The source manifest therefore names its own components fully qualified
// (`com.phonedsh.probe.MainActivity`) instead of `.MainActivity`: a leading dot
// resolves against the *applicationId*, so the relative form would look for
// `com.phonedsh.app.MainActivity` and die with ClassNotFoundException at launch.
//
// Changing the applicationId makes this a different app to Android: an installed
// `com.phonedsh.probe` stays behind as its own, data and all. That is intended —
// the probe was never the product.

// ---- release signing: two roads, no secrets in the repository ------------
//
// (a) 开箱可装. With nothing configured, `release` is signed with AGP's own
//     **debug** signing config (`signingConfigs.getByName("debug")`, the
//     `~/.android/debug.keystore` AGP generates on demand). The APK then
//     `adb install`s on a real device, which is what device-debug work needs.
//     That key is not a publishing key, so the fallback is stated *in the APK*:
//     `BuildConfig.SIGNING_MODE` / `SIGNING_RELEASABLE` / `SIGNING_NOTICE`, the
//     same sentence in `res/values/strings.xml` (`pdsh_signing_notice_debug`),
//     and two `<meta-data>` entries in the manifest that survive resource
//     shrinking because they are manifest placeholders, not resource references.
//
// (b) 真发布. `android/keystore.properties` (gitignored; see
//     `android/keystore.properties.example`) or the `PDSH_KEYSTORE_FILE` /
//     `PDSH_KEYSTORE_PASSWORD` / `PDSH_KEY_ALIAS` / `PDSH_KEY_PASSWORD`
//     environment variables carry a real keystore. A *partially* filled file, a
//     path that does not exist, or a missing password is treated exactly like
//     "not configured": a warning names the reason and the build falls back to
//     (a). A configuration problem therefore never fails `assembleRelease`.
//
// No credential is ever written to a committed file: the fallback borrows AGP's
// debug config (whose well-known defaults live in AGP, not here) and
// keystore.properties is only *read*, at configuration time.
val keystorePropertiesFile: File = rootProject.projectDir.resolve("keystore.properties")
val keystoreProperties: Properties = Properties().apply {
    if (keystorePropertiesFile.isFile) keystorePropertiesFile.inputStream().use { load(it) }
}

/** Reads one signing setting from keystore.properties first, then the environment. */
fun signingSetting(propertyKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propertyKey)?.trim()?.takeIf { it.isNotEmpty() }
        ?: System.getenv(envKey)?.trim()?.takeIf { it.isNotEmpty() }

/** A relative `storeFile` resolves against `android/`, next to the project it signs. */
val releaseStoreFile: File? = signingSetting("storeFile", "PDSH_KEYSTORE_FILE")?.let { configured ->
    val asFile = File(configured)
    if (asFile.isAbsolute) asFile else rootProject.projectDir.resolve(configured)
}
val releaseStorePassword: String? = signingSetting("storePassword", "PDSH_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? = signingSetting("keyAlias", "PDSH_KEY_ALIAS")
val releaseKeyPassword: String? = signingSetting("keyPassword", "PDSH_KEY_PASSWORD")

/**
 * Why the release build cannot use a real keystore, or `null` when it can.
 *
 * One reason string drives both the warning and the `BuildConfig` value, so the
 * build log and what the shipped APK says about itself cannot disagree.
 */
val releaseSigningProblem: String? = when {
    keystorePropertiesFile.isFile -> when {
        releaseStoreFile == null -> "keystore.properties has no storeFile"
        !releaseStoreFile.isFile -> "storeFile does not exist: ${releaseStoreFile.path}"
        releaseStorePassword == null -> "keystore.properties has no storePassword"
        releaseKeyAlias == null -> "keystore.properties has no keyAlias"
        releaseKeyPassword == null -> "keystore.properties has no keyPassword"
        else -> null
    }
    // No file at all: the fallback must still happen when the *environment* is
    // only half set, so an incomplete set is a reason, not an exception.
    releaseStoreFile == null || releaseStorePassword == null ||
        releaseKeyAlias == null || releaseKeyPassword == null ->
        "no keystore.properties and no complete PDSH_KEYSTORE_* environment"
    !releaseStoreFile.isFile -> "PDSH_KEYSTORE_FILE points at a missing file: ${releaseStoreFile.path}"
    else -> null
}
val releaseSigningConfigured: Boolean = releaseSigningProblem == null

/** The one sentence the app states about its own signature; `strings.xml` repeats it. */
val releaseSigningNotice: String =
    if (releaseSigningConfigured) "正式签名，可发布" else "调试签名，不可发布"

/** Machine-readable form of the same fact, mirrored by `BuildConfig.SIGNING_MODE`. */
val releaseSigningMode: String =
    if (releaseSigningConfigured) "release-keystore" else "debug-keystore-fallback"

logger.lifecycle(
    if (releaseSigningConfigured) {
        "[signing] release: road (b), keystore ${releaseStoreFile?.name} alias $releaseKeyAlias"
    } else {
        "[signing] release: road (a), debug keystore — reason: $releaseSigningProblem. " +
            "The APK installs on a device but must not be published; " +
            "see android/keystore.properties.example."
    },
)

android {
    namespace = "com.phonedsh.probe"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.phonedsh.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        // Created only on road (b): a config with a null storeFile would fail at
        // signing time instead of falling back.
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            // The same three fields as release, pointing at this variant's truth:
            // a debug APK is never releasable.
            buildConfigField("String", "SIGNING_MODE", "\"debug\"")
            buildConfigField("boolean", "SIGNING_RELEASABLE", "false")
            buildConfigField("String", "SIGNING_NOTICE", "\"调试签名，不可发布\"")
            // The manifest's SIGNING_* meta-data is substituted per build type,
            // and the merger rejects an unsubstituted placeholder in *any*
            // variant it builds, so debug has to declare its own pair.
            manifestPlaceholders["pdshSigningMode"] = "debug"
            manifestPlaceholders["pdshSigningNotice"] = "调试签名，不可发布"
        }
        release {
            // Road (b) when a keystore is configured, road (a) otherwise. The
            // debug signing config is AGP's, not a copy: its key material and
            // its well-known credentials stay out of this file.
            signingConfig = if (releaseSigningConfigured) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // AGP's release default. Stated explicitly because "the release APK
            // is not debuggable" is a shipping property, not an accident of the
            // current default.
            isDebuggable = false

            // The app's own statement about the signature, per build. Read by the
            // 关于 page (BuildConfig.SIGNING_NOTICE) and mirrored by the two
            // manifest <meta-data> entries below.
            buildConfigField("String", "SIGNING_MODE", "\"$releaseSigningMode\"")
            buildConfigField("boolean", "SIGNING_RELEASABLE", releaseSigningConfigured.toString())
            buildConfigField("String", "SIGNING_NOTICE", "\"$releaseSigningNotice\"")
            // Manifest placeholders, not resource references: a released APK
            // whose only marker were an unreferenced string resource would have
            // that string shrunk away by `isShrinkResources = true`.
            manifestPlaceholders["pdshSigningMode"] = releaseSigningMode
            manifestPlaceholders["pdshSigningNotice"] = releaseSigningNotice

            // R8 shrinks and obfuscates the app (and :core's JNI facade classes
            // unless proguard-rules.pro pins their native names). Resource
            // shrinking drops unreferenced resources only; assets such as
            // assets/worker-bundle.zip are never touched by it.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures {
        compose = true
        // BuildConfig carries the version and the signing facts
        // (SIGNING_MODE / SIGNING_RELEASABLE / SIGNING_NOTICE). MainActivity's
        // comment about this module compiling with `buildConfig = false` is now
        // out of date; that file is L62's and is left untouched.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    androidResources {
        // The worker bundle is already a zip; the demo never deflates it twice.
        noCompress += "zip"
    }

    // No loose worker assets here: :engine already packs the same bundle into a
    // single `assets/worker-bundle.zip` (byte-identical entries) and reads that at
    // runtime. Adding the directory again would ship the bundle twice and, worse,
    // AGP's asset merger un-gzips `*.tar.gz` on the way in (image.tar.gz ->
    // image.tar), which corrupts the names the bundle resolves. :engine's
    // verifyWorkerBundle dependency validates the real bundle before packaging,
    // so a silent empty APK is impossible.
    //
    // The generated jniLibs root is wired per variant in `androidComponents`
    // below: AGP registers the task output as that variant's jniLibs source, so
    // `merge<Variant>JniLibFolders` depends on it automatically.
}

// One generated jniLibs source directory per application variant. Registering it
// through the variant API (instead of a global sourceSets["main"] dir) is what
// lets the release copy be stripped while the debug copy keeps its DWARF.
androidComponents {
    onVariants { variant ->
        val suffix = variant.name.replaceFirstChar { it.uppercaseChar() }
        val packageTask = tasks.register<PackagePdshJni>("package${suffix}PdshJni") {
            group = "build"
            description = "Copies libpdsh_jni.so into the ${variant.name} APK"
            source.from(pdshJniSo)
            sourceRelativePath.set(pdshJniRelative)
            // AGP owns the output directory location when the task is wired via
            // addGeneratedSourceDirectory; the task writes arm64-v8a/<name> under it.
            stripMode.set(
                when {
                    !stripReleaseNativeLibs -> "none"
                    variant.buildType == "release" -> "unneeded"
                    else -> "debug"
                },
            )
            stripExecutable.set(llvmStrip?.absolutePath)
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(
            packageTask,
            PackagePdshJni::destination,
        )
    }
}

dependencies {
    // The local DomainStore and the transcript cache over it. `:app` is the
    // composition root and therefore the only module allowed to choose a backend:
    // `:domain` declares the `ConnectionFactory` seam and ships both the SQLite
    // factory and the in-memory fake, and this module is where one of them is
    // picked. The edge does not exist in `:dsh` on purpose — a library that chose
    // a backend would take the decision away from every app that links it.
    implementation(project(":domain"))
    implementation(project(":engine"))
    // The real host. DefaultPhoneDshHost owns the host HELLO, the WAL seam
    // (wal/1) and the exec/1 bridge; :app constructs it and hands its
    // channelHandler to createDemoEngine, so the HELLO's caps are host-derived.
    implementation(project(":dsh"))
    // The device implementations of the :platform SPI the host takes: Clock,
    // LifecycleSignals and Durability. SecureStore is not part of the host's
    // constructor today, so this module's AndroidSecureStore is not constructed.
    implementation(project(":platform-android"))
    // The token layer only: ProbeScreen reads every colour, length and text style
    // from PdshTheme (`com.phonedsh.ui.theme`), which resolves the generated
    // UiTokenData over spec/ui/v1/tokens.json. The screen keeps no copy of a
    // token value, and the AAR was already on this module's classpath.
    implementation(project(":lib"))
    // No :testkit edge: no :app source imports it, so the dependency only shipped
    // the scenario runner into the debug APK. The module's own host-side tests need
    // plain JUnit only (they run against the `:domain` reading value types and the
    // `:lib` page state, never against a device), so the runner stays out.
    // implementation(project(":testkit"))

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    // BasicText / Column / clickable / WindowInsets: this screen is built from
    // Foundation on purpose, so every color and size comes from PdshTheme
    // (spec/ui/v1/tokens.json) instead of Material defaults. The Compose BOM pins
    // the version; no catalog entry is added.
    implementation("androidx.compose.foundation:foundation")
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.core.ktx)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.espresso.core)

    // Host-side unit tests: the permission matrix's row-by-row mapping and what the
    // page prints for it. Pure JVM, no Robolectric and no device.
    testImplementation(libs.junit)
}
