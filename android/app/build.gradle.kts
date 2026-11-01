// SPDX-License-Identifier: MIT
// :app is the demo vehicle: one Compose screen over the :engine contract. It
// renders DemoEngine.state/channel/handshake and never sees the engine view type.
import java.util.Properties
import javax.inject.Inject
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.gradle.process.ExecOperations

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// The prebuilt worker bundle is a 65 MB, gitignored build input. It is referenced
// in place (never copied into the repository) and the build fails loudly when it is
// absent: an APK without a worker bundle would otherwise install and then fail at
// runtime with a much less useful message.
val repoRoot: File = rootProject.projectDir.parentFile
val workerBundleDir: File = repoRoot.resolve("examples/probe-app/Bundle/worker")
val workerBundleRelative: String = workerBundleDir.relativeTo(repoRoot).path

check(workerBundleDir.isDirectory) {
    "the prebuilt worker bundle is missing: $workerBundleRelative\n" +
        "The demo APK needs it; it is not committed because it is ~65 MB.\n" +
        "Generate it with the documented copy step (needs the pinned DSH checkout):\n" +
        "  bash examples/probe-app/scripts/copy-bundle-assets.sh\n" +
        "For a full DSH Web page, build the Web dist first:\n" +
        "  bash scripts/ci/build-web-dist.sh\n" +
        "then re-run the copy step. Nothing is copied into android/."
}

// The one Wire codec is Rust (:core's JNI facade); :core is a pure JVM module and
// cannot carry jniLibs, so the demo APK has to package the .so itself. The path is
// cargo-ndk's arm64 output; other ABIs are not packaged (the demo target is the
// arm64-v8a emulator). Missing here means HELLO stays undecodable at runtime, which
// the screen would show as "libpdsh_jni not packaged"; fail the build instead.
val pdshJniSo: File = repoRoot.resolve("shell/target/aarch64-linux-android/debug/libpdsh_jni.so")
val pdshJniRelative: String = pdshJniSo.relativeTo(repoRoot).path
check(pdshJniSo.isFile) {
    "the Rust JNI library is missing: $pdshJniRelative\n" +
        "Without it HELLO cannot be decoded and the demo screen cannot show the\n" +
        "handshake summary. Build it with the pinned NDK + cargo-ndk:\n" +
        "  cd shell && cargo ndk -t arm64-v8a build -p pdsh-jni\n" +
        "The .so is a build product and is not committed."
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
    /** cargo's unstripped debug artifact. */
    @get:InputFile
    abstract val source: RegularFileProperty

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
        val target = destination.get().asFile
            .resolve("arm64-v8a")
            .resolve(source.get().asFile.name)
        target.parentFile.mkdirs()
        source.get().asFile.copyTo(target, overwrite = true)

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

android {
    namespace = "com.phonedsh.probe"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.phonedsh.probe"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
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
        // The worker bundle is already a zip; the demo never deflates it twice.
        noCompress += "zip"
    }

    // No loose worker assets here: :engine already packs the same bundle into a
    // single `assets/worker-bundle.zip` (byte-identical entries) and reads that at
    // runtime. Adding the directory again would ship the bundle twice and, worse,
    // AGP's asset merger un-gzips `*.tar.gz` on the way in (image.tar.gz ->
    // image.tar), which corrupts the names the bundle resolves. The `check` above
    // still fails the build when the bundle is absent, so a silent empty APK is
    // impossible.
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
            source.set(pdshJniSo)
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
    // No :testkit edge: :app has no test sources and no import from it, so the
    // dependency only shipped the scenario runner into the debug APK.
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
}
