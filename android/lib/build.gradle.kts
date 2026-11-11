// SPDX-License-Identifier: MIT
// :lib is the published AAR entry point:
//   com.phonedsh:lib:0.1.0
// The composition-root app depends on this coordinate only; the seven sibling
// modules on the `api` closure are transitive POM entries with the same version
// (android/build.gradle.kts applies maven-publish to all eight at once, so the
// coordinate cannot drift between :lib and the POM that names them). Android
// library.
//
// Compose is declared `api` because the AAR's public surface is a composable
// UI package (com.phonedsh.ui): a consumer that wants to embed a page must be
// able to compile against the same Compose runtime, never a second copy.
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    id("maven-publish")
}

group = "com.phonedsh"
// Same number as the app's `versionName`: a consumer pinning this coordinate is
// asking for the code version 0.1.0 of the app was built from.
version = "0.1.0"
// `maven-publish` is applied from android/build.gradle.kts (release component +
// POM for the AAR modules, `java` component for the JAR ones, one repository,
// one version). The publication this module produces is:
//   com.phonedsh:lib:0.1.0              packaging=aar
// and its POM's `compile` scope is exactly this block's `api` edges, which is
// what makes the seven siblings arrive for a consumer that declares one line.

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

    // Declare the one variant this module publishes, and nothing else. Besides
    // pinning the release variant, this is what keeps the `-sources` jar out of
    // the publication: AGP builds one when it is asked for it, and for this
    // module that jar would be malformed — the token codegen directory sits in
    // both the kotlin and the java source set, so the archive is assembled from
    // every source file twice (measured on the first publish: 248 entries, 78
    // duplicated). A consumer needs the AAR and the POM.
    publishing {
        singleVariant("release")
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
// PR22 values are reviewed from the iOS owners into `tokens.json` (HomeSpec for
// the page table; the still-active component files for their own roles). The
// generator reads only that reviewed JSON, so Swift/HTML never becomes a second
// Kotlin truth table. Compatibility names are declared as aliases to canonical
// leaves and are emitted as accessors, not duplicated token objects.
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
        val componentMetrics = spec["componentMetrics"] as? Map<String, Map<String, Any?>> ?: emptyMap()
        val shadows = spec["shadows"] as? Map<String, Map<String, Any?>> ?: emptyMap()
        val aliases = spec["aliases"] as? Map<String, Map<String, String>> ?: emptyMap()
        val surfaces = spec["signatureSurfaces"] as Map<String, Any?>

        // `interaction.drawer` is the drawer contract's one parameter table. It
        // is required (change PC-20261111-ui-drawer-interaction §3): the tokens
        // and the app ship from this repository, so there is no older file to
        // keep building. A missing group or an unresolved token reference is a
        // generation failure, never a silent fallback.
        val interaction = requireNotNull(spec["interaction"] as? Map<String, Any?>) {
            "tokens.json is missing 'interaction' (spec/ui/v1/tokens.json#interaction.drawer)"
        }
        val drawerSpec = requireNotNull(interaction["drawer"] as? Map<String, Any?>) {
            "tokens.json is missing 'interaction.drawer' (spec/ui/v1/tokens.json#interaction.drawer)"
        }

        // PC-20261112-ui-interaction-batch freezes six more groups. The schema
        // keeps them optional for older files, but this app requires all six at
        // contract revision ad5cd444: a missing group must fail generation, not
        // silently leave the Android components without values.
        fun interactionGroup(name: String): Map<String, Any?> = requireNotNull(interaction[name] as? Map<String, Any?>) {
            "tokens.json is missing 'interaction.$name' (required at contract revision ad5cd444)"
        }

        val sheetSpec = interactionGroup("sheet")
        val contextMenuSpec = interactionGroup("contextMenu")
        val pushSpec = interactionGroup("push")
        val composerSendSpec = interactionGroup("composerSend")
        val pressedSpec = interactionGroup("pressed")
        val disclosureSpec = interactionGroup("disclosure")

        fun objectField(path: String, raw: Any?): Map<*, *> = raw as? Map<*, *> ?: error("$path must be an object")
        fun listField(path: String, raw: Any?): List<*> = raw as? List<*> ?: error("$path must be an array")

        /**
         * Resolves one token reference and checks both the family and the leaf.
         * A wrong family (e.g. a motion name in `enabledFill`) fails here rather
         * than producing a Kotlin expression that does not compile.
         */
        fun tokenRef(path: String, raw: Any?, family: String): String {
            val entry = objectField(path, raw)
            val token = entry["token"] as? String ?: error("$path is missing its 'token' reference")
            require(entry["value"] == null) { "$path must not carry a 'value' next to a token reference" }
            require(entry["needsDeviceMeasure"] != true) { "$path is a token reference and cannot be needsDeviceMeasure" }
            val parts = token.split(".", limit = 2)
            require(parts.size == 2 && parts[0] == family) {
                "$path must reference a $family token, got '$token'"
            }
            val leaf = parts[1]
            val exists = when (family) {
                "colors" -> leaf in colors
                "geometry" -> leaf in geometry
                "radius" -> leaf in radius
                "motion" -> leaf in motion
                "shadows" -> leaf in shadows
                else -> false
            }
            require(exists) { "$path references missing token '$token'" }
            return when (family) {
                "colors" -> "color${camel(leaf)}"
                "geometry" -> "geometry${camel(leaf)}"
                "radius" -> "radius${camel(leaf)}"
                "motion" -> "motion${camel(leaf)}"
                "shadows" -> "shadow${camel(leaf)}"
                else -> error("$path: unsupported token family '$family'")
            }
        }

        fun valueEntry(path: String, raw: Any?, unit: String): Any {
            val entry = objectField(path, raw)
            require(entry["token"] == null) { "$path must be a parameter, not a token reference" }
            require(entry["needsDeviceMeasure"] != true) {
                "$path sets needsDeviceMeasure but carries a value; it must use the unmeasured marker"
            }
            require(entry["unit"] == unit) { "$path must use unit '$unit', got '${entry["unit"]}'" }
            return entry["value"] ?: error("$path is missing a 'value'")
        }

        fun floatValue(path: String, raw: Any?, unit: String): Float =
            (valueEntry(path, raw, unit) as? Number)?.toFloat()
                ?: error("$path must have a numeric 'value'")

        fun boolValue(path: String, raw: Any?, unit: String): Boolean =
            valueEntry(path, raw, unit) as? Boolean
                ?: error("$path must have a boolean 'value'")

        fun stringValue(path: String, raw: Any?, unit: String): String =
            valueEntry(path, raw, unit) as? String
                ?: error("$path must have a string 'value'")

        fun enumValue(path: String, raw: Any?, allowed: Map<String, String>): String {
            val text = raw as? String ?: error("$path must be a string")
            return allowed[text]
                ?: error("$path has unknown value '$text' (allowed: ${allowed.keys.joinToString()})")
        }

        fun enumParam(path: String, raw: Any?, unit: String, allowed: Map<String, String>): String =
            enumValue(path, stringValue(path, raw, unit), allowed)

        /** A `needsDeviceMeasure` member keeps its unit and note, never a number. */
        fun measuredExpression(path: String, raw: Any?): String {
            val entry = objectField(path, raw)
            require(entry["needsDeviceMeasure"] == true) { "$path must set needsDeviceMeasure: true" }
            require(entry["value"] == null) { "$path is needsDeviceMeasure and must not carry a 'value'" }
            require(entry["token"] == null) { "$path is needsDeviceMeasure and must not carry a 'token'" }
            val unit = entry["unit"] as? String ?: error("$path is missing its 'unit'")
            return "Measured.Unmeasured(unit = ${kotlinString(unit)}, note = ${kotlinString(entry["note"] as String?)})"
        }

        val detentSetIdNames = linkedMapOf(
            "default" to "DEFAULT",
            "medium" to "MEDIUM",
            "mediumLarge" to "MEDIUM_LARGE",
            "large" to "LARGE",
        )
        val detentValueNames = linkedMapOf(
            "default" to "DEFAULT",
            "medium" to "MEDIUM",
            "large" to "LARGE",
            "medium+large" to "MEDIUM_LARGE",
        )
        val grabberNames = linkedMapOf("visible" to "VISIBLE", "hidden" to "HIDDEN")
        val colorLiteralNames = linkedMapOf("black" to "BLACK", "clear" to "CLEAR")
        val previewNames = linkedMapOf("system" to "SYSTEM")
        val menuRoleNames = linkedMapOf("default" to "DEFAULT", "destructive" to "DESTRUCTIVE")
        val menuKindNames = linkedMapOf("action" to "ACTION", "share" to "SHARE", "info" to "INFO")
        val menuWhenNames = linkedMapOf(
            "always" to "ALWAYS",
            "foldersEnabled" to "FOLDERS_ENABLED",
            "notExternal" to "NOT_EXTERNAL",
            "hasAside" to "HAS_ASIDE",
            "hasText" to "HAS_TEXT",
            "notMainBot" to "NOT_MAIN_BOT",
            "notLastBot" to "NOT_LAST_BOT",
            "lastBot" to "LAST_BOT",
        )
        val stackScopeNames = linkedMapOf("perTab" to "PER_TAB")
        val rootBackNames = linkedMapOf("exit" to "EXIT")
        val backLayerNames = linkedMapOf(
            "sheet" to "SHEET",
            "drawer" to "DRAWER",
            "stack" to "STACK",
            "root" to "ROOT",
        )
        val predictiveBackNames = linkedMapOf("allowed" to "ALLOWED")
        val disabledRuleNames = linkedMapOf("canSubmit" to "CAN_SUBMIT")
        val stopRuleNames = linkedMapOf(
            "!canSubmit && model.turnRunning" to "TURN_RUNNING_WITHOUT_CAN_SUBMIT",
        )
        val reducedMotionNames = linkedMapOf("snap" to "SNAP")

        fun enumDefinition(name: String, allowed: Map<String, String>): String =
            "public enum class $name(public val spec: String) {\n" +
                allowed.entries.joinToString(",\n") { (spec, constant) ->
                    "    $constant(${kotlinString(spec)})"
                } +
                "\n}\n\n"

        fun drawerRef(key: String, family: String): String {
            val entry = drawerSpec[key] as? Map<*, *>
            require(entry != null) { "interaction.drawer.$key must be a token reference" }
            val token = entry["token"] as? String
            require(token != null) { "interaction.drawer.$key is missing its 'token' reference" }
            val parts = token.split(".", limit = 2)
            require(parts.size == 2 && parts[0] == family) {
                "interaction.drawer.$key must reference a $family token, got '$token'"
            }
            val leaf = parts[1]
            val exists = when (family) {
                "geometry" -> leaf in geometry
                "radius" -> leaf in radius
                "motion" -> leaf in motion
                "shadows" -> leaf in shadows
                else -> false
            }
            require(exists) { "interaction.drawer.$key references missing token '$token'" }
            return when (family) {
                "geometry" -> "geometry${camel(leaf)}"
                "radius" -> "radius${camel(leaf)}"
                "motion" -> "motion${camel(leaf)}"
                "shadows" -> "shadow${camel(leaf)}"
                else -> error("interaction.drawer.$key: unsupported token family '$family'")
            }
        }

        fun drawerParam(key: String, unit: String): Float {
            val entry = drawerSpec[key] as? Map<*, *>
            require(entry != null) { "interaction.drawer.$key must be a parameter" }
            require(entry["token"] == null) { "interaction.drawer.$key must be a parameter, not a token reference" }
            require(entry["unit"] == unit) {
                "interaction.drawer.$key must use unit '$unit', got '${entry["unit"]}'"
            }
            return (entry["value"] as? Number)?.toFloat()
                ?: error("interaction.drawer.$key is missing a numeric 'value'")
        }

        val names = StringBuilder()
        val fields = StringBuilder()
        val colorMap = StringBuilder()
        val typeMap = StringBuilder()
        val spacingMap = StringBuilder()
        val radiusMap = StringBuilder()
        val strokeMap = StringBuilder()
        val motionMap = StringBuilder()
        val geometryMap = StringBuilder()
        val shadowMap = StringBuilder()
        val surfaceFields = StringBuilder()
        val surfaceList = StringBuilder()

        fun aliasFor(family: String, key: String): String? = aliases[family]?.get(key)

        fun nameConst(family: String, key: String): String {
            val token = "$family.$key"
            // A canonical leaf that is also a compatibility spelling keeps the
            // canonical object; its legacy constant resolves to the canonical
            // role this surface should consume (e.g. success -> sessionSuccess).
            val target = aliasFor(family, key) ?: token
            names.append(
                "    public const val ${upperSnake(family)}_${upperSnake(key)}: String = \"$target\"\n"
            )
            return token
        }

        colors.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            val token = nameConst("colors", key)
            val light = entry["light"] as String?
            val dark = entry["dark"] as String?
            val unmeasured = light == null || dark == null
            val lightAlpha = (entry["lightAlpha"] as? Number)?.toFloat() ?: 1f
            val darkAlpha = (entry["darkAlpha"] as? Number)?.toFloat() ?: 1f
            fields.append(
                "    public val color${camel(key)}: TokenColor = TokenColor(\n" +
                    "        name = \"$token\",\n" +
                    "        light = ${light?.let { argb(it) } ?: "null"},\n" +
                    "        dark = ${dark?.let { argb(it) } ?: "null"},\n" +
                    "        lightAlpha = ${lightAlpha}f,\n" +
                    "        darkAlpha = ${darkAlpha}f,\n" +
                    "        semantic = ${kotlinString(entry["semantic"] as String?)},\n" +
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
            val lineHeight = (entry["lineHeight"] as Number?)?.toFloat()?.let { "${it}f" } ?: "null"
            fields.append(
                "    public val type${camel(key)}: TokenType = TokenType(\"$token\", ${baseSize}f, $weight, $mono, $lineHeight)\n"
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

        val knownMotionCurves = setOf("linear", "easeOut", "easeInOut")
        motion.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            val token = nameConst("motion", key)
            val curve = entry["curve"] as? String
                ?: error("motion.$key must have a string 'curve'")
            require(curve in knownMotionCurves) {
                "motion.$key has unknown curve '$curve' (UiTokens.easing can read: ${knownMotionCurves.joinToString()})"
            }
            fields.append(
                "    public val motion${camel(key)}: TokenMotion = TokenMotion(\n" +
                    "        name = \"$token\",\n" +
                    "        durationMs = ${(entry["durationMs"] as Number).toInt()},\n" +
                    "        curve = \"$curve\",\n" +
                    "        repeat = \"${entry["repeat"]}\",\n" +
                    "    )\n"
            )
            motionMap.append("        \"$token\" to motion${camel(key)},\n")
        }

        shadows.forEach { (key, entry) ->
            val token = nameConst("shadows", key)
            // `x` was added after the first two shadow roles; absent means the
            // source had no horizontal offset (0), never a guessed value.
            val x = (entry["x"] as? Number)?.toFloat() ?: 0f
            fields.append(
                "    public val shadow${camel(key)}: TokenShadow = TokenShadow(\n" +
                    "        name = \"$token\",\n" +
                    "        opacity = ${(entry["opacity"] as Number).toFloat()}f,\n" +
                    "        radius = ${(entry["radius"] as Number).toFloat()}f,\n" +
                    "        x = ${x}f,\n" +
                    "        y = ${(entry["y"] as Number).toFloat()}f,\n" +
                    "    )\n"
            )
            shadowMap.append("        \"$token\" to shadow${camel(key)},\n")
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

        // Tables are emitted in the JSON's order; their row identifiers and
        // string values are enums whose accepted spellings are fixed here, so a
        // new detent id, menu role/kind/condition or back layer fails generation.
        val sheetDetentSets = listField("interaction.sheet.detentSets", sheetSpec["detentSets"])
            .mapIndexed { index, raw ->
                val path = "interaction.sheet.detentSets[$index]"
                val row = objectField(path, raw)
                val id = enumValue("$path.id", row["id"], detentSetIdNames)
                val detents = enumValue("$path.detents", row["detents"], detentValueNames)
                "TokenDetentSet(id = TokenDetentSetId.$id, detents = TokenDetent.$detents)"
            }
        val sheetPageDetents = listField("interaction.sheet.pageDetents", sheetSpec["pageDetents"])
            .mapIndexed { index, raw ->
                val path = "interaction.sheet.pageDetents[$index]"
                val row = objectField(path, raw)
                val id = row["id"] as? String ?: error("$path.id must be a string")
                val detents = enumValue("$path.detents", row["detents"], detentSetIdNames)
                "TokenSheetPageDetent(id = ${kotlinString(id)}, detents = TokenDetentSetId.$detents)"
            }
        val contextMenuSurfaces = listField("interaction.contextMenu.surfaces", contextMenuSpec["surfaces"])
            .mapIndexed { surfaceIndex, raw ->
                val surfacePath = "interaction.contextMenu.surfaces[$surfaceIndex]"
                val surface = objectField(surfacePath, raw)
                val surfaceId = surface["id"] as? String ?: error("$surfacePath.id must be a string")
                val items = listField("$surfacePath.items", surface["items"]).mapIndexed { itemIndex, itemRaw ->
                    val path = "$surfacePath.items[$itemIndex]"
                    val item = objectField(path, itemRaw)
                    val label = item["label"] as? String ?: error("$path.label must be a string")
                    val altLabel = if (item.containsKey("altLabel")) {
                        item["altLabel"] as? String ?: error("$path.altLabel must be a string")
                    } else {
                        null
                    }
                    val role = enumValue("$path.role", item["role"], menuRoleNames)
                    val kind = enumValue("$path.kind", item["kind"], menuKindNames)
                    val whenCondition = enumValue("$path.when", item["when"], menuWhenNames)
                    val dividerBefore = if (item.containsKey("dividerBefore")) {
                        item["dividerBefore"] as? Boolean ?: error("$path.dividerBefore must be a boolean")
                    } else {
                        false
                    }
                    "TokenContextMenuItem(" +
                        "label = ${kotlinString(label)}, " +
                        "altLabel = ${kotlinString(altLabel)}, " +
                        "role = TokenContextMenuRole.$role, " +
                        "kind = TokenContextMenuKind.$kind, " +
                        "whenCondition = TokenContextMenuWhen.$whenCondition, " +
                        "dividerBefore = $dividerBefore)"
                }
                "TokenContextMenuSurface(id = ${kotlinString(surfaceId)}, items = listOf(${items.joinToString(", ")}))"
            }
        val backOrderEntry = pushSpec["backOrder"] as? Map<*, *>
        val backOrderValue = backOrderEntry?.let { stringValue("interaction.push.backOrder", it, "layerOrder") }
            ?: error("interaction.push.backOrder must be a parameter")
        val backOrder = backOrderValue.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            .map { layer ->
                backLayerNames[layer]
                    ?: error("interaction.push.backOrder has unknown layer '$layer' (allowed: ${backLayerNames.keys.joinToString()})")
            }
        require(backOrder.isNotEmpty()) { "interaction.push.backOrder must name at least one layer" }

        fields.append(
            "    public val drawer: TokenDrawerInteraction = TokenDrawerInteraction(\n" +
                "        width = ${drawerRef("width", "geometry")},\n" +
                "        panelTrailingRadius = ${drawerRef("panelTrailingRadius", "radius")},\n" +
                "        shadow = ${drawerRef("shadow", "shadows")},\n" +
                "        openMotion = ${drawerRef("openMotion", "motion")},\n" +
                "        closeMotion = ${drawerRef("closeMotion", "motion")},\n" +
                "        settleMotion = ${drawerRef("settleMotion", "motion")},\n" +
                "        closedOverhangPt = ${drawerParam("closedOverhang", "pt")}f,\n" +
                "        scrimMaxOpacity = ${drawerParam("scrimMaxOpacity", "opacity")}f,\n" +
                "        dragMinimumDistancePt = ${drawerParam("dragMinimumDistance", "pt")}f,\n" +
                "        closeThresholdFraction = ${drawerParam("closeThreshold", "widthFraction")}f,\n" +
                "        velocityProjectionSeconds = ${drawerParam("velocityProjection", "s")}f,\n" +
                "    )\n"
        )

        fields.append(
            "    public val sheet: TokenSheetInteraction = TokenSheetInteraction(\n" +
                "        defaultDetents = TokenDetentSetId.${enumParam("interaction.sheet.defaultDetents", sheetSpec["defaultDetents"], "detentSet", detentSetIdNames)},\n" +
                "        mediumFraction = ${measuredExpression("interaction.sheet.mediumFraction", sheetSpec["mediumFraction"])},\n" +
                "        detentSets = listOf(${sheetDetentSets.joinToString(", ")}),\n" +
                "        pageDetents = listOf(${sheetPageDetents.joinToString(", ")}),\n" +
                "        grabberVisible = TokenGrabberVisibility.${enumParam("interaction.sheet.grabberVisible", sheetSpec["grabberVisible"], "grabberVisibility", grabberNames)},\n" +
                "        grabberHidden = TokenGrabberVisibility.${enumParam("interaction.sheet.grabberHidden", sheetSpec["grabberHidden"], "grabberVisibility", grabberNames)},\n" +
                "        background = ${tokenRef("interaction.sheet.background", sheetSpec["background"], "colors")},\n" +
                "        backgroundClear = TokenColorLiteral.${enumParam("interaction.sheet.backgroundClear", sheetSpec["backgroundClear"], "color", colorLiteralNames)},\n" +
                "        cornerRadiusDefault = ${measuredExpression("interaction.sheet.cornerRadiusDefault", sheetSpec["cornerRadiusDefault"])},\n" +
                "        cornerRadiusConnector = ${floatValue("interaction.sheet.cornerRadiusConnector", sheetSpec["cornerRadiusConnector"], "pt")}f.dp,\n" +
                "        cornerRadiusCatalog = ${floatValue("interaction.sheet.cornerRadiusCatalog", sheetSpec["cornerRadiusCatalog"], "pt")}f.dp,\n" +
                "        presentMotion = ${measuredExpression("interaction.sheet.presentMotion", sheetSpec["presentMotion"])},\n" +
                "        dismissMotion = ${measuredExpression("interaction.sheet.dismissMotion", sheetSpec["dismissMotion"])},\n" +
                "    )\n"
        )
        fields.append(
            "    public val contextMenu: TokenContextMenuInteraction = TokenContextMenuInteraction(\n" +
                "        preview = TokenContextMenuPreview.${enumParam("interaction.contextMenu.preview", contextMenuSpec["preview"], "preview", previewNames)},\n" +
                "        surfaces = listOf(${contextMenuSurfaces.joinToString(", ")}),\n" +
                "    )\n"
        )
        fields.append(
            "    public val push: TokenPushInteraction = TokenPushInteraction(\n" +
                "        stackScope = TokenPushStackScope.${enumParam("interaction.push.stackScope", pushSpec["stackScope"], "scope", stackScopeNames)},\n" +
                "        rootBack = TokenPushRootBack.${enumParam("interaction.push.rootBack", pushSpec["rootBack"], "rootAction", rootBackNames)},\n" +
                "        backOrder = listOf(${backOrder.joinToString(", ") { "TokenBackLayer.$it" }}),\n" +
                "        barVisibleAtRoot = ${boolValue("interaction.push.barVisibleAtRoot", pushSpec["barVisibleAtRoot"], "bool")},\n" +
                "        barHiddenWhenPushed = ${boolValue("interaction.push.barHiddenWhenPushed", pushSpec["barHiddenWhenPushed"], "bool")},\n" +
                "        predictiveBack = TokenPredictiveBack.${enumParam("interaction.push.predictiveBack", pushSpec["predictiveBack"], "gesture", predictiveBackNames)},\n" +
                "        systemMotion = ${measuredExpression("interaction.push.systemMotion", pushSpec["systemMotion"])},\n" +
                "    )\n"
        )
        fields.append(
            "    public val composerSend: TokenComposerSendInteraction = TokenComposerSendInteraction(\n" +
                "        motion = ${tokenRef("interaction.composerSend.motion", composerSendSpec["motion"], "motion")},\n" +
                "        transitionScale = ${floatValue("interaction.composerSend.transitionScale", composerSendSpec["transitionScale"], "scale")}f,\n" +
                "        transitionOpacity = ${floatValue("interaction.composerSend.transitionOpacity", composerSendSpec["transitionOpacity"], "opacity")}f,\n" +
                "        buttonSize = ${tokenRef("interaction.composerSend.buttonSize", composerSendSpec["buttonSize"], "geometry")},\n" +
                "        enabledFill = ${tokenRef("interaction.composerSend.enabledFill", composerSendSpec["enabledFill"], "colors")},\n" +
                "        disabledFill = ${tokenRef("interaction.composerSend.disabledFill", composerSendSpec["disabledFill"], "colors")},\n" +
                "        enabledInk = ${tokenRef("interaction.composerSend.enabledInk", composerSendSpec["enabledInk"], "colors")},\n" +
                "        disabledInk = ${tokenRef("interaction.composerSend.disabledInk", composerSendSpec["disabledInk"], "colors")},\n" +
                "        disabledRule = TokenComposerDisabledRule.${enumParam("interaction.composerSend.disabledRule", composerSendSpec["disabledRule"], "enabledWhen", disabledRuleNames)},\n" +
                "        stopRule = TokenComposerStopRule.${enumParam("interaction.composerSend.stopRule", composerSendSpec["stopRule"], "showWhen", stopRuleNames)},\n" +
                "    )\n"
        )
        fields.append(
            "    public val pressed: TokenPressedInteraction = TokenPressedInteraction(\n" +
                "        motion = ${tokenRef("interaction.pressed.motion", pressedSpec["motion"], "motion")},\n" +
                "        pillOverlay = ${floatValue("interaction.pressed.pillOverlay", pressedSpec["pillOverlay"], "opacity")}f,\n" +
                "        pillOverlayColor = TokenColorLiteral.${enumParam("interaction.pressed.pillOverlayColor", pressedSpec["pillOverlayColor"], "color", colorLiteralNames)},\n" +
                "        rowFill = ${tokenRef("interaction.pressed.rowFill", pressedSpec["rowFill"], "colors")},\n" +
                "        rowFillOpacity = ${floatValue("interaction.pressed.rowFillOpacity", pressedSpec["rowFillOpacity"], "opacity")}f,\n" +
                "        primaryPressedOpacity = ${floatValue("interaction.pressed.primaryPressedOpacity", pressedSpec["primaryPressedOpacity"], "opacity")}f,\n" +
                "        primaryDisabledOpacity = ${floatValue("interaction.pressed.primaryDisabledOpacity", pressedSpec["primaryDisabledOpacity"], "opacity")}f,\n" +
                "        scale = ${floatValue("interaction.pressed.scale", pressedSpec["scale"], "scale")}f,\n" +
                "    )\n"
        )
        fields.append(
            "    public val disclosure: TokenDisclosureInteraction = TokenDisclosureInteraction(\n" +
                "        bodyMotion = ${tokenRef("interaction.disclosure.bodyMotion", disclosureSpec["bodyMotion"], "motion")},\n" +
                "        folderMotion = ${tokenRef("interaction.disclosure.folderMotion", disclosureSpec["folderMotion"], "motion")},\n" +
                "        chevronMotion = ${tokenRef("interaction.disclosure.chevronMotion", disclosureSpec["chevronMotion"], "motion")},\n" +
                "        reducedMotion = TokenReducedMotion.${enumParam("interaction.disclosure.reducedMotion", disclosureSpec["reducedMotion"], "a11yFallback", reducedMotionNames)},\n" +
                "    )\n"
        )

        // Compatibility accessors are generated from declared canonical JSON
        // leaves; aliases never add duplicate token objects to UiTokenData and
        // never become a second value table.
        for ((family, aliasMap) in aliases) {
            val canonicalKeys = when (family) {
                "colors" -> colors.keys
                "typography" -> styles.keys
                "spacing" -> spacing.keys
                "radius" -> radius.keys
                "stroke" -> stroke.keys
                "motion" -> motion.keys
                "geometry" -> geometry.keys
                else -> emptySet()
            }
            for ((alias, target) in aliasMap) {
                if (alias in canonicalKeys) continue
                val targetParts = target.split(".", limit = 2)
                val targetExists = targetParts.size == 2 && when (targetParts[0]) {
                    "colors" -> targetParts[1] in colors
                    "typography" -> targetParts[1] in styles
                    "spacing" -> targetParts[1] in spacing
                    "radius" -> targetParts[1] in radius
                    "stroke" -> targetParts[1] in stroke
                    "motion" -> targetParts[1] in motion
                    "geometry" -> targetParts[1] in geometry
                    else -> false
                }
                require(targetExists) { "aliases.$family.$alias targets missing token '$target'" }
                names.append(
                    "    public const val ${upperSnake(family)}_${upperSnake(alias)}: String = \"$target\"\n"
                )
                val property = when (family) {
                    "colors" -> "color${camel(alias)}"
                    "typography" -> "type${camel(alias)}"
                    "spacing", "radius", "stroke" -> "$family${camel(alias)}"
                    "geometry" -> "geometry${camel(alias)}"
                    else -> continue
                }
                val sourceMap = when (family) {
                    "colors" -> "colors"
                    "typography" -> "types"
                    else -> family
                }
                val tokenClass = when (family) {
                    "colors" -> "TokenColor"
                    "typography" -> "TokenType"
                    "spacing", "radius", "stroke" -> "TokenDp"
                    "geometry" -> "TokenGeometry"
                    else -> continue
                }
                fields.append("    public val $property: $tokenClass get() = $sourceMap.getValue(\"$target\")\n")
            }
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
        out.append("import androidx.compose.ui.unit.Dp\n")
        out.append("import androidx.compose.ui.unit.dp\n\n")
        out.append("/** One colour token; a null channel is `tier: unmeasured` and MUST NOT be invented. */\n")
        out.append("public data class TokenColor(\n")
        out.append("    public val name: String,\n    public val light: Long?,\n    public val dark: Long?,\n")
        out.append("    public val lightAlpha: Float = 1f,\n    public val darkAlpha: Float = 1f,\n")
        out.append("    public val semantic: String? = null,\n")
        out.append("    public val unmeasured: Boolean,\n    public val note: String?,\n)\n\n")
        out.append("/** One typography token: a base size in pt that the platform scale multiplies. */\n")
        out.append("public data class TokenType(\n")
        out.append("    public val name: String,\n    public val baseSize: Float,\n    public val weight: Int,\n")
        out.append("    public val mono: Boolean,\n")
        out.append("    /** Optional line box in pt (PR22 HomeSpec roles); null keeps the platform line height. */\n")
        out.append("    public val lineHeight: Float? = null,\n)\n\n")
        out.append("/** A spacing/radius/stroke token, in dp on Android. */\n")
        out.append("public data class TokenDp(public val name: String, public val value: Float)\n\n")
        out.append("/** A motion token; `curve` is the spec's curve name, resolved by the theme. */\n")
        out.append("public data class TokenMotion(\n")
        out.append("    public val name: String,\n    public val durationMs: Int,\n")
        out.append("    public val curve: String,\n    public val repeat: String,\n)\n\n")
        out.append("/** A shadow token: black at `opacity`, SwiftUI blur `radius`, offset x/y, in pt. */\n")
        out.append("public data class TokenShadow(\n")
        out.append("    public val name: String,\n    public val opacity: Float,\n")
        out.append("    public val radius: Float,\n    public val x: Float,\n    public val y: Float,\n)\n\n")
        out.append("/** `interaction.drawer`: every drawer parameter resolved to its generated token. */\n")
        out.append("public data class TokenDrawerInteraction(\n")
        out.append("    public val width: TokenGeometry,\n    public val panelTrailingRadius: TokenDp,\n")
        out.append("    public val shadow: TokenShadow,\n    public val openMotion: TokenMotion,\n")
        out.append("    public val closeMotion: TokenMotion,\n    public val settleMotion: TokenMotion,\n")
        out.append("    public val closedOverhangPt: Float,\n    public val scrimMaxOpacity: Float,\n")
        out.append("    public val dragMinimumDistancePt: Float,\n    public val closeThresholdFraction: Float,\n")
        out.append("    public val velocityProjectionSeconds: Float,\n)\n\n")

        // PC-20261112-ui-interaction-batch: typed enums keep every frozen string
        // spelling in one place. The generator's maps above are the accepted set;
        // an unknown spelling in tokens.json fails before Kotlin is written.
        out.append("/** A parameter the platform must measure; an unmeasured value is never a guessed number. */\n")
        out.append("public sealed interface Measured<out T> {\n")
        out.append("    public data class Known<T>(public val value: T) : Measured<T>\n")
        out.append("    public data class Unmeasured(public val unit: String, public val note: String?) : Measured<Nothing>\n")
        out.append("}\n\n")
        out.append(enumDefinition("TokenDetentSetId", detentSetIdNames))
        out.append(enumDefinition("TokenDetent", detentValueNames))
        out.append(enumDefinition("TokenGrabberVisibility", grabberNames))
        out.append(enumDefinition("TokenColorLiteral", colorLiteralNames))
        out.append(enumDefinition("TokenContextMenuPreview", previewNames))
        out.append(enumDefinition("TokenContextMenuRole", menuRoleNames))
        out.append(enumDefinition("TokenContextMenuKind", menuKindNames))
        out.append(enumDefinition("TokenContextMenuWhen", menuWhenNames))
        out.append(enumDefinition("TokenPushStackScope", stackScopeNames))
        out.append(enumDefinition("TokenPushRootBack", rootBackNames))
        out.append(enumDefinition("TokenBackLayer", backLayerNames))
        out.append(enumDefinition("TokenPredictiveBack", predictiveBackNames))
        out.append(enumDefinition("TokenComposerDisabledRule", disabledRuleNames))
        out.append(enumDefinition("TokenComposerStopRule", stopRuleNames))
        out.append(enumDefinition("TokenReducedMotion", reducedMotionNames))

        out.append("/** `interaction.sheet`: detent tables and the measured system values. */\n")
        out.append("public data class TokenDetentSet(\n")
        out.append("    public val id: TokenDetentSetId,\n    public val detents: TokenDetent,\n)\n\n")
        out.append("public data class TokenSheetPageDetent(\n")
        out.append("    public val id: String,\n    public val detents: TokenDetentSetId,\n)\n\n")
        out.append("public data class TokenSheetInteraction(\n")
        out.append("    public val defaultDetents: TokenDetentSetId,\n    public val mediumFraction: Measured<Float>,\n")
        out.append("    public val detentSets: List<TokenDetentSet>,\n    public val pageDetents: List<TokenSheetPageDetent>,\n")
        out.append("    public val grabberVisible: TokenGrabberVisibility,\n    public val grabberHidden: TokenGrabberVisibility,\n")
        out.append("    public val background: TokenColor,\n    public val backgroundClear: TokenColorLiteral,\n")
        out.append("    public val cornerRadiusDefault: Measured<Dp>,\n")
        out.append("    public val cornerRadiusConnector: Dp,\n    public val cornerRadiusCatalog: Dp,\n")
        out.append("    public val presentMotion: Measured<TokenMotion>,\n    public val dismissMotion: Measured<TokenMotion>,\n)\n\n")

        out.append("/** One long-press menu row; `whenCondition` is evaluated against the row state. */\n")
        out.append("public data class TokenContextMenuItem(\n")
        out.append("    public val label: String,\n    public val altLabel: String?,\n")
        out.append("    public val role: TokenContextMenuRole,\n    public val kind: TokenContextMenuKind,\n")
        out.append("    public val whenCondition: TokenContextMenuWhen,\n    public val dividerBefore: Boolean,\n)\n\n")
        out.append("public data class TokenContextMenuSurface(\n")
        out.append("    public val id: String,\n    public val items: List<TokenContextMenuItem>,\n)\n\n")
        out.append("public data class TokenContextMenuInteraction(\n")
        out.append("    public val preview: TokenContextMenuPreview,\n    public val surfaces: List<TokenContextMenuSurface>,\n)\n\n")

        out.append("/** `interaction.push`: the frozen back layer order and platform motion gap. */\n")
        out.append("public data class TokenPushInteraction(\n")
        out.append("    public val stackScope: TokenPushStackScope,\n    public val rootBack: TokenPushRootBack,\n")
        out.append("    public val backOrder: List<TokenBackLayer>,\n")
        out.append("    public val barVisibleAtRoot: Boolean,\n    public val barHiddenWhenPushed: Boolean,\n")
        out.append("    public val predictiveBack: TokenPredictiveBack,\n    public val systemMotion: Measured<TokenMotion>,\n)\n\n")

        out.append("/** `interaction.composerSend`: fill/ink roles, scale and the two visibility rules. */\n")
        out.append("public data class TokenComposerSendInteraction(\n")
        out.append("    public val motion: TokenMotion,\n    public val transitionScale: Float,\n")
        out.append("    public val transitionOpacity: Float,\n    public val buttonSize: TokenGeometry,\n")
        out.append("    public val enabledFill: TokenColor,\n    public val disabledFill: TokenColor,\n")
        out.append("    public val enabledInk: TokenColor,\n    public val disabledInk: TokenColor,\n")
        out.append("    public val disabledRule: TokenComposerDisabledRule,\n")
        out.append("    public val stopRule: TokenComposerStopRule,\n)\n\n")

        out.append("/** `interaction.pressed`: overlay/fill alphas and the no-scaling rule. */\n")
        out.append("public data class TokenPressedInteraction(\n")
        out.append("    public val motion: TokenMotion,\n    public val pillOverlay: Float,\n")
        out.append("    public val pillOverlayColor: TokenColorLiteral,\n")
        out.append("    public val rowFill: TokenColor,\n    public val rowFillOpacity: Float,\n")
        out.append("    public val primaryPressedOpacity: Float,\n    public val primaryDisabledOpacity: Float,\n")
        out.append("    public val scale: Float,\n)\n\n")

        out.append("/** `interaction.disclosure`: the three collapse motions and reduced-motion fallback. */\n")
        out.append("public data class TokenDisclosureInteraction(\n")
        out.append("    public val bodyMotion: TokenMotion,\n    public val folderMotion: TokenMotion,\n")
        out.append("    public val chevronMotion: TokenMotion,\n    public val reducedMotion: TokenReducedMotion,\n)\n\n")

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
        out.append("    public val shadows: Map<String, TokenShadow> = mapOf(\n").append(shadowMap).append("    )\n")
        out.append("    /** Every canonical leaf token name, in the spec's own spelling. */\n")
        out.append("    public val allNames: Set<String> =\n")
        out.append("        colors.keys + types.keys + spacing.keys + radius.keys + stroke.keys + motion.keys + geometry.keys + shadows.keys\n")
        out.append("}\n")

        // The HomeSpec compatibility facade is generated exclusively from the
        // reviewed JSON tokens above. It is a naming adapter, not a second source.
        val home = StringBuilder()
        home.append("// GENERATED FILE - do not edit. Source: spec/ui/v1/tokens.json\n")
        home.append("// SPDX-License-Identifier: MIT\n")
        home.append("// Regenerate with: ./gradlew :lib:generateUiTokens\n")
        home.append("package com.phonedsh.ui.theme.generated\n\n")
        home.append("/** PR22 HomeSpec compatibility names derived from canonical tokens. */\n")
        home.append("public object HomeSpecData {\n")
        geometry.forEach { (key, raw) ->
            home.append("    public const val ${upperSnake(key)}: Float = ${(raw as Map<*, *>)["value"]}f\n")
        }
        spacing.forEach { (key, raw) -> home.append("    public const val ${upperSnake(key)}: Float = ${raw}f\n") }
        radius.forEach { (key, raw) ->
            val constant = when (key) {
                "bubble" -> "BUBBLE_RADIUS"
                "listCard" -> "LIST_CARD_RADIUS"
                "composerOpen" -> "COMPOSER_OPEN_RADIUS"
                else -> upperSnake(key)
            }
            home.append("    public const val $constant: Float = ${raw}f\n")
        }
        componentMetrics.forEach { (key, raw) ->
            home.append("    public const val ${upperSnake(key)}: Float = ${(raw["value"] as Number).toFloat()}f\n")
        }
        fun homeType(name: String, constName: String, line: Boolean = false) {
            val entry = styles.getValue(name) as Map<*, *>
            val field = if (line) "lineHeight" else "baseSize"
            val value = entry[field] ?: return
            home.append("    public const val ${constName}: Float = ${(value as Number).toFloat()}f\n")
        }
        listOf(
            "navTitle" to "NAV_TITLE_SIZE", "navSubtitle" to "NAV_SUBTITLE_SIZE",
            "body" to "BODY_SIZE", "process" to "PROCESS_SIZE", "listItem" to "LIST_ITEM_SIZE",
            "tagLabel" to "TAG_LABEL_SIZE", "tabLabel" to "TAB_LABEL_SIZE",
        ).forEach { (name, constant) -> homeType(name, constant) }
        listOf(
            "navTitle" to "NAV_TITLE_LINE", "navSubtitle" to "NAV_SUBTITLE_LINE",
            "body" to "BODY_LINE", "listItem" to "LIST_ITEM_LINE",
        ).forEach { (name, constant) -> homeType(name, constant, line = true) }
        colors.forEach { (key, raw) ->
            val entry = raw as Map<String, Any?>
            fun asLong(channel: String): Long? =
                (entry[channel] as? String)?.removePrefix("#")?.let { ("FF" + it).toLong(16) }
            asLong("light")?.let { home.append("    public const val ${upperSnake(key)}_LIGHT: Long = ${it}L\n") }
            asLong("dark")?.let { home.append("    public const val ${upperSnake(key)}_DARK: Long = ${it}L\n") }
        }
        home.append("\n    /** Shadow helpers: black opacity, SwiftUI blur radius and x/y offset, in pt. */\n")
        home.append("    public object Shadow {\n")
        for ((role, prefix) in listOf("floating" to "FLOATING", "composer" to "COMPOSER", "drawer" to "DRAWER")) {
            val entry = shadows[role] ?: continue
            for (part in listOf("opacity", "radius", "x", "y")) {
                val value = (entry[part] as? Number)?.toFloat() ?: 0f
                home.append("        public const val ${prefix}_${part.uppercase()}: Float = ${value}f\n")
            }
        }
        home.append("    }\n")
        home.append("    public val types: Map<String, TokenType> = UiTokenData.types\n")
        home.append("}\n")

        val homeTarget = generatedTokensDir.resolve("com/phonedsh/ui/theme/generated/HomeSpecData.kt")
        homeTarget.parentFile.mkdirs()
        homeTarget.writeText(home.toString())

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
    // docs/parity/bench.md "Build input registration": a fixture edit alone must
    // not leave :lib:testDebugUnitTest UP-TO-DATE.
    inputs.dir(repoRoot.resolve("scripts/parity/fixtures"))
        .withPropertyName("parityFixtures")
        .withPathSensitivity(org.gradle.api.tasks.PathSensitivity.RELATIVE)
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
    // The device-connector pages take `:domain` **snapshot value types** as their
    // factory parameters (the connector's projected state, the transcript items, the
    // paging window), so a consumer that embeds a page compiles against the same
    // types instead of a private copy — that is why this is `api`.
    //
    // What they do *not* read is the connector machinery: `DeviceConnector`,
    // `ConnectorStateMachine` and `ReadOnlyDeviceSessionTransport` are referenced only
    // from `src/test` / `src/androidTest` here, against the in-memory fixtures. The
    // production wiring (`DeviceConnectionSource` / `DeviceSessionSource`) lives in
    // `:domain` itself, and the App hands the page an `InMemoryConnector`-backed
    // source. An earlier version of this comment claimed the pages read that seam —
    // they do not, and a maintainer who believed it would go looking for a binding
    // that isn't there.
    api(project(":domain"))
    implementation(libs.androidx.core.ktx)

    // Compose: the AAR's public surface is composable, so the runtime and the
    // theme primitives are `api`. Versions come from the catalog BOM.
    api(platform(libs.androidx.compose.bom))
    api("androidx.compose.ui:ui")
    api("androidx.compose.foundation:foundation")
    api("androidx.compose.ui:ui-text")
    api("androidx.compose.animation:animation")
    api("androidx.compose.material3:material3")
    // Temporary native Canvas math renderer spike; review before adoption.
    implementation("io.github.erweixin:ratex-android:0.1.15")
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

// ---- the published coordinate ------------------------------------------------
// `com.phonedsh:lib:0.1.0`, packaging=aar. Version, repository and POM metadata
// come from android/build.gradle.kts (root `subprojects` block); this module
// only names the software component. `afterEvaluate` is required, not
// defensive: AGP creates the `release` component from its variant API after this
// script has been evaluated, so a script-level
// `from(components["release"])` fails with
// "SoftwareComponent with name 'release' not found".
publishing {
    publications {
        create<MavenPublication>("release") {
            afterEvaluate { from(components["release"]) }
        }
    }
}

// ---- the local-only switch can never become a published artifact -------------
// `-Ppdsh.uiCoreOnly=true` (line ~325) narrows this module's `api` edge from
// `:dsh` to `:core` + `:platform` so a mid-flight compile break in a sibling lane
// cannot block the UI contract. That is a diagnostic build, not a product.
//
// Publishing it would write a `com.phonedsh:lib:0.1.0` POM whose `compile` scope
// is `:core` + `:platform` only — missing `dsh`, `controller`, `shell`, `net` and
// through `dsh` no `domain` either: five of the eight artifacts — under the SAME
// version number as the complete publication. The consumer would then fail in R8
// exactly the way L63 measured (44 missing classes), with nothing on disk saying
// which of the two 0.1.0 POMs it resolved.
//
// So the POM/publish tasks fail loudly instead of writing it. The flag stays
// usable for `assembleDebug` / `test`, which is all it was ever for.
tasks.matching {
    it.name.startsWith("generatePomFileFor") || it.name.startsWith("publish")
}.configureEach {
    doFirst {
        if (uiCoreOnly) {
            throw org.gradle.api.GradleException(
                "refusing to publish :lib with -Ppdsh.uiCoreOnly=true: that build's api edge is " +
                    ":core + :platform only, so the POM would be missing dsh, controller, shell, " +
                    "net and the domain edge — five of the eight com.phonedsh artifacts — while " +
                    "carrying the same 0.1.0 coordinate as the complete publication. Re-run " +
                    "without the flag to produce the real artifact.",
            )
        }
    }
}
