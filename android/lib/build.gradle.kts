// SPDX-License-Identifier: MIT
// :lib is the only published AAR entry point:
//   com.phonedsh:lib:0.0.0-SNAPSHOT
// The composition-root app depends on this coordinate only; sibling modules
// are transitive POM entries with the same version. Android library.
//
// Compose is declared `api` because the AAR's public surface is a composable
// UI package (com.phonedsh.ui): a consumer that wants to embed a page must be
// able to compile against the same Compose runtime, never a second copy.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

group = "com.phonedsh"
version = "0.0.0-SNAPSHOT"
// The maven-publish block (release component + POM) lands when the first AAR
// is cut; P0 fixes only the coordinate and the public api surface.

android {
    namespace = "com.phonedsh.lib"
    compileSdk = 35

    defaultConfig {
        // The AAR must carry its own R8 rules: :lib is what another app depends on,
        // and the JNI keep rules for com.phonedsh.wire live with the library, not in
        // every consumer's proguard file. See consumer-rules.pro.
        consumerProguardFiles("src/main/consumer-rules.pro")
        minSdk = 26
        // Declared for the WP-12 contract. At runtime the consuming app's
        // targetSdk is authoritative; AGP may ignore this field for an AAR.
        targetSdk = 35
        // The pixel baselines are captured by instrumented tests on a real
        // emulator renderer (`captureToImage` -> PixelCopy), never by Robolectric:
        // Robolectric's text metrics are fake and do not scale with fontScale.
        // See android/tools/screenshot-capture.sh and src/androidTest/README.md.
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        buildConfig = false
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        // Robolectric drives real Compose semantics, so the unit tests need the
        // merged resources and the android-all runtime.
        unitTests.isIncludeAndroidResources = true
        // Instrumented screenshots compare pixels: a system animation running on
        // top of the frame is the one source of flake no fixed density can remove.
        animationsDisabled = true
    }
}

// The Compose UI tests need `ui-test-manifest` (it contributes the
// `androidx.activity.ComponentActivity` that `createComposeRule` hosts), and that
// AAR must never reach a consumer's release manifest. Release unit tests are
// therefore disabled: `:lib:test` runs the debug suite, which is the same code.
androidComponents {
    beforeVariants(selector().withBuildType("release")) { variant ->
        variant.enableUnitTest = false
    }
}

// ---------------------------------------------------------------------------
// Token codegen: spec/ui/v1/tokens.json is the single source of truth.
//
// The UI never re-types a colour, a size or a radius: every value the six
// signature surfaces read is emitted from the spec into UiTokenData.kt at build
// time, so a spec edit either flows through or breaks the build. Nothing under
// src/main carries a hand-written copy of a token value.
//
// The spec lives at <repo>/spec; the repo root is derived from the Gradle root
// so no machine-local path is committed.
// ---------------------------------------------------------------------------
val repoRoot: File = rootProject.projectDir.parentFile
val tokensJson: File = repoRoot.resolve("spec/ui/v1/tokens.json")
val generatedTokensDir: File = layout.buildDirectory.dir("generated/ui-tokens/kotlin").get().asFile

fun upperSnake(name: String): String =
    name.replace(Regex("([a-z0-9])([A-Z])"), "$1_$2").uppercase()

fun camel(key: String): String = key.replaceFirstChar { it.uppercase() }

fun argb(hex: String): String = "0xFF" + hex.removePrefix("#").uppercase()

fun kotlinString(value: String?): String =
    value?.let { "\"" + it.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"" } ?: "null"

val generateUiTokens = tasks.register("generateUiTokens") {
    description = "Generates Compose token accessors from spec/ui/v1/tokens.json."
    group = "build"
    inputs.file(tokensJson)
    outputs.dir(generatedTokensDir)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val spec = groovy.json.JsonSlurper().parse(tokensJson) as Map<String, Any?>
        val colors = spec["colors"] as Map<String, Any?>
        val typography = spec["typography"] as Map<String, Any?>
        val styles = typography["styles"] as Map<String, Any?>
        val scale = typography["scale"] as Map<String, Any?>
        val drivers = scale["drivers"] as Map<String, Any?>
        val spacing = spec["spacing"] as Map<String, Any?>
        val radius = spec["radius"] as Map<String, Any?>
        val stroke = spec["stroke"] as Map<String, Any?>
        val motion = spec["motion"] as Map<String, Any?>
        val geometry = spec["geometry"] as Map<String, Any?>
        val surfaces = spec["signatureSurfaces"] as Map<String, Any?>

        val names = StringBuilder()
        val fields = StringBuilder()
        val colorMap = StringBuilder()
        val typeMap = StringBuilder()
        val spacingMap = StringBuilder()
        val radiusMap = StringBuilder()
        val strokeMap = StringBuilder()
        val motionMap = StringBuilder()
        val geometryMap = StringBuilder()
        val surfaceFields = StringBuilder()
        val surfaceList = StringBuilder()

        fun nameConst(family: String, key: String): String {
            val token = "$family.$key"
            names.append(
                "    public const val ${upperSnake(family)}_${upperSnake(key)}: String = \"$token\"\n"
            )
            return token
        }

        colors.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            val token = nameConst("colors", key)
            val light = entry["light"] as String?
            val dark = entry["dark"] as String?
            val unmeasured = light == null || dark == null
            fields.append(
                "    public val color${camel(key)}: TokenColor = TokenColor(\n" +
                    "        name = \"$token\",\n" +
                    "        light = ${light?.let { argb(it) } ?: "null"},\n" +
                    "        dark = ${dark?.let { argb(it) } ?: "null"},\n" +
                    "        unmeasured = $unmeasured,\n" +
                    "        note = ${kotlinString(entry["note"] as String?)},\n" +
                    "    )\n"
            )
            colorMap.append("        \"$token\" to color${camel(key)},\n")
        }

        styles.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            val token = nameConst("typography", key)
            val baseSize = (entry["baseSize"] as Number).toFloat()
            val weight = (entry["weight"] as Number).toInt()
            val mono = entry["mono"] as Boolean
            fields.append(
                "    public val type${camel(key)}: TokenType = TokenType(\"$token\", ${baseSize}f, $weight, $mono)\n"
            )
            typeMap.append("        \"$token\" to type${camel(key)},\n")
        }

        fun dpFamily(family: String, source: Map<String, Any?>, sink: StringBuilder) {
            source.forEach { (key, raw) ->
                val token = nameConst(family, key)
                fields.append(
                    "    public val ${family}${camel(key)}: TokenDp = TokenDp(\"$token\", ${(raw as Number).toFloat()}f)\n"
                )
                sink.append("        \"$token\" to ${family}${camel(key)},\n")
            }
        }
        dpFamily("spacing", spacing, spacingMap)
        dpFamily("radius", radius, radiusMap)
        dpFamily("stroke", stroke, strokeMap)

        motion.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            val token = nameConst("motion", key)
            fields.append(
                "    public val motion${camel(key)}: TokenMotion = TokenMotion(\n" +
                    "        name = \"$token\",\n" +
                    "        durationMs = ${(entry["durationMs"] as Number).toInt()},\n" +
                    "        curve = \"${entry["curve"]}\",\n" +
                    "        repeat = \"${entry["repeat"]}\",\n" +
                    "    )\n"
            )
            motionMap.append("        \"$token\" to motion${camel(key)},\n")
        }

        geometry.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            val token = nameConst("geometry", key)
            fields.append(
                "    public val geometry${camel(key)}: TokenGeometry = TokenGeometry(\n" +
                    "        name = \"$token\",\n" +
                    "        value = ${(entry["value"] as Number).toFloat()}f,\n" +
                    "        unit = \"${entry["unit"]}\",\n" +
                    "        scalesWith = ${kotlinString(entry["scalesWith"] as String?)},\n" +
                    "    )\n"
            )
            geometryMap.append("        \"$token\" to geometry${camel(key)},\n")
        }

        surfaces.forEach { (id, raw) ->
            val entry = raw as Map<String, Any?>
            val tokens = (entry["tokens"] as List<*>).map { it.toString() }
            surfaceFields.append(
                "    public val surface${camel(id)}: TokenSurface = TokenSurface(\n" +
                    "        id = \"$id\",\n" +
                    "        parity = \"${entry["parity"]}\",\n" +
                    "        tokens = listOf(${tokens.joinToString(", ") { "\"$it\"" }}),\n" +
                    "        note = ${kotlinString(entry["note"] as String?)},\n" +
                    "    )\n"
            )
            surfaceList.append("        surface${camel(id)},\n")
        }

        val out = StringBuilder()
        out.append("// GENERATED FILE - do not edit. Source: spec/ui/v1/tokens.json\n")
        out.append("// SPDX-License-Identifier: MIT\n")
        out.append("// Regenerate with: ./gradlew :lib:generateUiTokens\n")
        out.append("package com.phonedsh.ui.theme.generated\n\n")
        out.append("/** One colour token; a null channel is `tier: unmeasured` and MUST NOT be invented. */\n")
        out.append("public data class TokenColor(\n")
        out.append("    public val name: String,\n    public val light: Long?,\n    public val dark: Long?,\n")
        out.append("    public val unmeasured: Boolean,\n    public val note: String?,\n)\n\n")
        out.append("/** One typography token: a base size in pt that the platform scale multiplies. */\n")
        out.append("public data class TokenType(\n")
        out.append("    public val name: String,\n    public val baseSize: Float,\n    public val weight: Int,\n")
        out.append("    public val mono: Boolean,\n)\n\n")
        out.append("/** A spacing/radius/stroke token, in dp on Android. */\n")
        out.append("public data class TokenDp(public val name: String, public val value: Float)\n\n")
        out.append("/** A motion token; `curve` is the spec's curve name, resolved by the theme. */\n")
        out.append("public data class TokenMotion(\n")
        out.append("    public val name: String,\n    public val durationMs: Int,\n")
        out.append("    public val curve: String,\n    public val repeat: String,\n)\n\n")
        out.append("/** A page-layer geometry token; `unit` is `pt` or `screenRatio`. */\n")
        out.append("public data class TokenGeometry(\n")
        out.append("    public val name: String,\n    public val value: Float,\n    public val unit: String,\n")
        out.append("    public val scalesWith: String?,\n)\n\n")
        out.append("/** A signature surface and the exact token names it is allowed to read. */\n")
        out.append("public data class TokenSurface(\n")
        out.append("    public val id: String,\n    public val parity: String,\n")
        out.append("    public val tokens: List<String>,\n    public val note: String?,\n)\n\n")
        out.append("/** The platform scale rule from `typography.scale`; rendering multiplies by it. */\n")
        out.append("public object UiTypeScale {\n")
        out.append("    public const val MODE: String = \"${scale["mode"]}\"\n")
        out.append("    public const val UNIT: String = \"${scale["unit"]}\"\n")
        out.append("    public const val IOS_DRIVER: String = \"${drivers["ios"]}\"\n")
        out.append("    public const val ANDROID_DRIVER: String = \"${drivers["android"]}\"\n")
        out.append("    public const val RULE: String = ${kotlinString(scale["rule"] as String?)}\n")
        out.append("}\n\n")
        out.append("public object UiTokenNames {\n").append(names).append("}\n\n")
        out.append("public object UiTokenData {\n").append(fields).append(surfaceFields)
        out.append("    public val surfaces: List<TokenSurface> = listOf(\n").append(surfaceList)
        out.append("    )\n")
        out.append("\n    public val colors: Map<String, TokenColor> = mapOf(\n").append(colorMap).append("    )\n")
        out.append("    public val types: Map<String, TokenType> = mapOf(\n").append(typeMap).append("    )\n")
        out.append("    public val spacing: Map<String, TokenDp> = mapOf(\n").append(spacingMap).append("    )\n")
        out.append("    public val radius: Map<String, TokenDp> = mapOf(\n").append(radiusMap).append("    )\n")
        out.append("    public val stroke: Map<String, TokenDp> = mapOf(\n").append(strokeMap).append("    )\n")
        out.append("    public val motion: Map<String, TokenMotion> = mapOf(\n").append(motionMap).append("    )\n")
        out.append("    public val geometry: Map<String, TokenGeometry> = mapOf(\n").append(geometryMap).append("    )\n")
        out.append("    /** Every leaf token name, in the spec's own spelling. */\n")
        out.append("    public val allNames: Set<String> =\n")
        out.append("        colors.keys + types.keys + spacing.keys + radius.keys + stroke.keys + motion.keys + geometry.keys\n")
        out.append("}\n")

        val target = generatedTokensDir.resolve("com/phonedsh/ui/theme/generated/UiTokenData.kt")
        target.parentFile.mkdirs()
        target.writeText(out.toString())
    }
}

android.sourceSets.getByName("main").java.srcDir(generatedTokensDir)

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    dependsOn(generateUiTokens)
}

// The projection tests read the normative fixtures (tokens.json, the trajectory
// goldens and the ui-state schema) straight from the repo; the root is passed in
// as a system property so no test hard-codes a machine path.
tasks.withType<Test>().configureEach {
    systemProperty("pdsh.repo.root", repoRoot.absolutePath)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// The UI lane only needs the host contract (:core) and the SPI (:platform).
// `-Ppdsh.uiCoreOnly=true` narrows the graph to those two so a mid-flight
// compile break in a sibling lane (:net, :engine) cannot block the UI contract
// from being built and tested. It is a local diagnostic switch: the shipped AAR
// always keeps the `:dsh` facade, which is the default below.
val uiCoreOnly: Boolean = providers.gradleProperty("pdsh.uiCoreOnly").orNull == "true"

dependencies {
    // Public surface: facade + SPI only. Internal packages stay transitive
    // through :dsh so the app cannot bypass the facade.
    if (uiCoreOnly) {
        api(project(":core"))
    } else {
        api(project(":dsh"))
    }
    api(project(":platform"))
    implementation(libs.androidx.core.ktx)

    // Compose: the AAR's public surface is composable, so the runtime and the
    // theme primitives are `api`. Versions come from the catalog BOM.
    api(platform(libs.androidx.compose.bom))
    api("androidx.compose.ui:ui")
    api("androidx.compose.foundation:foundation")
    api("androidx.compose.ui:ui-text")
    api("androidx.compose.animation:animation")
    api("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation(libs.junit)
    testImplementation(platform(libs.androidx.compose.bom))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("org.robolectric:robolectric:4.14.1")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Pixel baselines: the same Compose test rule, but executed on a device
    // renderer. `ui-test-manifest` (debugImplementation above) contributes the
    // host `ComponentActivity`; `ui-test-junit4` supplies `captureToImage`, which
    // is a PixelCopy of the window region (real glyph raster + real layout).
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
}
