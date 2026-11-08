// phone-dsh — :net / com.phonedsh.adb: pm/am entry points and bounded diagnostics.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBPackageTools.swift`. The device's own
// help remains available because OEMs and Android releases differ.

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.math.BigDecimal

internal object AdbPackageTools {
    private val pkg = AdbTools.property("string", "Installed application ID, e.g. com.example.app; not an APK filename.")
    private val user = AdbTools.property(
        "integer",
        "Android user/profile ID; omitted means the current foreground user. Use android_list_users to discover IDs.",
    )

    private fun choice(values: List<String>, description: String): JsonValue = obj(
        "type" to JsonString("string"),
        "enum" to JsonArray(values.map { JsonString(it) }),
        "description" to JsonString(description),
    )

    val descriptors: List<JsonObject> = listOf(
        AdbTools.tool(
            "android_list_packages",
            "List installed Android apps by package ID with APK paths and installer. This lists installed apps, not downloaded APK files.",
            listOf(
                "filter" to AdbTools.property("string", "Optional package-name substring."), "userId" to user,
                "kind" to choice(listOf("all", "third_party", "system"), "Default all."),
                "state" to choice(listOf("all", "enabled", "disabled"), "Default all."),
                "includeUninstalled" to AdbTools.property("boolean", "Include retained package records for uninstalled apps; default false."),
            ),
        ),
        AdbTools.tool(
            "android_package_info",
            "Show APK paths (including splits) and package metadata: version, permissions, activities and per-user state.",
            listOf("packageName" to pkg, "userId" to user), listOf("packageName"),
        ),
        AdbTools.tool(
            "android_install_apk",
            "Install a single APK or update an app. workspace streams an iPhone workspace APK over ADB; device reads an APK already on Android. Not an AAB/APKS/XAPK or split-APK set. Inspect state after an interruption before retrying.",
            listOf(
                "apkPath" to AdbTools.property("string", "workspace: absolute /dsh/workspace/...apk path. device: absolute Android path, preferably /data/local/tmp/...apk."),
                "source" to choice(listOf("workspace", "device"), "Required: distinguishes the two filesystems."),
                "sha256" to AdbTools.property("string", "Required for workspace: 64 hex characters from sha256sum in the Worker. Prevents installing stale mirrored bytes. Single APK limit 128 MiB."),
                "userId" to user,
                "replaceExisting" to AdbTools.property("boolean", "Default true (-r); false uses pm -R on supported Android versions."),
                "allowTest" to AdbTools.property("boolean", "Allow test-only APKs (-t); default false."),
                "grantPermissions" to AdbTools.property("boolean", "Grant runtime permissions at install (-g); default false."),
            ),
            listOf("apkPath", "source"),
        ),
        AdbTools.tool(
            "android_uninstall_app",
            "Uninstall a package for the current/specified Android user. App data is deleted unless keepData=true. System image APKs remain on disk. Does not delete a downloaded installer file.",
            listOf("packageName" to pkg, "userId" to user, "keepData" to AdbTools.property("boolean", "Keep app data/cache; default false.")),
            listOf("packageName"),
        ),
        AdbTools.tool(
            "android_force_stop", "Force-stop an app's processes for the selected user; preserves installed app and data.",
            listOf("packageName" to pkg, "userId" to user), listOf("packageName"),
        ),
        AdbTools.tool(
            "android_clear_app_data",
            "Delete an app's data and cache, including login state, for the selected user. Leaves the app installed.",
            listOf("packageName" to pkg, "userId" to user), listOf("packageName"),
        ),
        AdbTools.tool(
            "android_set_app_enabled", "Enable or disable an installed app for the selected user (pm enable/disable-user).",
            listOf("packageName" to pkg, "userId" to user, "enabled" to AdbTools.property("boolean", "true enables; false disables.")),
            listOf("packageName", "enabled"),
        ),
        AdbTools.tool(
            "android_install_existing_app",
            "Restore an existing system/shared package for a user using pm install-existing. Cannot restore an APK that is no longer on the device.",
            listOf("packageName" to pkg, "userId" to user), listOf("packageName"),
        ),
        AdbTools.tool(
            "android_app_permission",
            "Grant or revoke a runtime permission declared by an app. Android rejects signature/system permissions and policy-restricted changes.",
            listOf(
                "packageName" to pkg, "userId" to user,
                "permission" to AdbTools.property("string", "Full permission name, e.g. android.permission.CAMERA."),
                "action" to choice(listOf("grant", "revoke"), "Permission operation."),
            ),
            listOf("packageName", "permission", "action"),
        ),
        AdbTools.tool("android_list_users", "List Android users/profiles and report the current foreground user."),
        AdbTools.tool(
            "android_open_uri", "Open an Android VIEW intent (web URL or deep link) for the selected user.",
            listOf(
                "uri" to AdbTools.property("string", "URI with a scheme, up to 2048 UTF-8 bytes."), "userId" to user,
                "packageName" to pkg,
            ),
            listOf("uri"),
        ),
        AdbTools.tool(
            "android_logcat",
            "Read recent logcat lines, then exit; no infinite log stream. Logs may contain app/user data.",
            listOf(
                "lines" to AdbTools.property("integer", "Last 1–2000 lines; default 200."),
                "buffer" to choice(listOf("main", "system", "crash", "events", "all"), "Default main."),
                "priority" to choice(listOf("V", "D", "I", "W", "E", "F"), "Minimum priority; default I."),
            ),
        ),
        AdbTools.tool("android_device_info", "Read model, OS/API, display, battery and storage diagnostics."),
        AdbTools.tool(
            "android_list_apk_files",
            "Find APK installer files under an Android directory. Separate from listing installed packages; Android filesystem permissions apply.",
            listOf("directory" to AdbTools.property("string", "Absolute Android directory; default /sdcard/Download.")),
        ),
        AdbTools.tool(
            "android_delete_apk_file",
            "Delete one APK installer file on Android by its exact absolute path. This does not uninstall an app. Do not target installed package paths under /data/app or system partitions.",
            listOf("apkPath" to AdbTools.property("string", "Exact absolute .apk file path; wildcards are not expanded.")),
            listOf("apkPath"),
        ),
        AdbTools.tool(
            "android_command_help",
            "Read command help from this Android device to discover more supported options. Use android_shell for commands without a dedicated tool; omit the desktop 'adb shell' prefix.",
            listOf("topic" to choice(listOf("package", "activity", "input", "settings", "files", "logcat", "services"), "Default package (pm help).")),
        ),
    )

    fun plan(name: String, args: Map<String, JsonValue>): AdbTools.Plan {
        val a = Arguments(args)
        val user = a.user()
        fun pkg(): String = AdbTools.quote(a.identifier("packageName"))
        fun done(command: String, success: Boolean = false, timeout: Long = 30_000): AdbTools.Plan =
            AdbTools.Plan(command, timeoutMillis = timeout, requiresSuccess = success)
        return when (name) {
            "android_list_packages" -> {
                var command = "pm list packages -f -i$user"
                when (a.choice("kind", listOf("all", "third_party", "system"), "all")) {
                    "third_party" -> command += " -3"
                    "system" -> command += " -s"
                }
                when (a.choice("state", listOf("all", "enabled", "disabled"), "all")) {
                    "enabled" -> command += " -e"
                    "disabled" -> command += " -d"
                }
                if (a.bool("includeUninstalled")) command += " -u"
                if (args["filter"] != null) {
                    val filter = a.text("filter", 255)
                    if (!Regex("^[A-Za-z0-9_.]+$").matches(filter)) throw AdbFailure("Invalid package filter")
                    command += " " + AdbTools.quote(filter)
                }
                done(command)
            }
            "android_package_info" -> done("pm path$user ${pkg()} && dumpsys package ${pkg()}")
            "android_install_apk" -> {
                val source = a.choice("source", listOf("workspace", "device"))
                val path = a.path("apkPath", apk = true)
                var command = "pm install$user" + if (a.bool("replaceExisting", fallback = true)) " -r" else " -R"
                if (a.bool("allowTest")) command += " -t"
                if (a.bool("grantPermissions")) command += " -g"
                if (source == "workspace") {
                    if (!path.startsWith("/dsh/workspace/")) throw AdbFailure("Workspace APK must be under /dsh/workspace/")
                    val hash = a.text("sha256", 64).lowercase()
                    if (!Regex("^[0-9a-f]{64}$").matches(hash)) throw AdbFailure("sha256 must contain 64 hexadecimal characters")
                    return AdbTools.Plan(command, timeoutMillis = 120_000, workspaceApk = path, sha256 = hash, requiresSuccess = true)
                }
                if (args["sha256"] != null) throw AdbFailure("sha256 verification is supported for workspace APKs only")
                done(command + " " + AdbTools.quote(path), success = true, timeout = 120_000)
            }
            "android_uninstall_app" ->
                done("pm uninstall" + (if (a.bool("keepData")) " -k" else "") + user + " " + pkg(), success = true, timeout = 120_000)
            "android_force_stop" -> done("am force-stop$user ${pkg()}")
            "android_clear_app_data" -> done("pm clear$user ${pkg()}", success = true)
            "android_set_app_enabled" ->
                done("pm " + (if (a.bool("enabled", required = true)) "enable" else "disable-user") + user + " " + pkg())
            "android_install_existing_app" -> done("pm install-existing$user ${pkg()}")
            "android_app_permission" -> done(
                "pm " + a.choice("action", listOf("grant", "revoke")) + user + " " + pkg() + " " +
                    AdbTools.quote(a.identifier("permission")),
            )
            "android_list_users" -> done("pm list users && am get-current-user")
            "android_open_uri" -> {
                val uri = a.text("uri", 2048)
                if (!AdbTools.uriHasScheme(uri)) throw AdbFailure("uri must include a scheme")
                done(
                    "am start$user -a android.intent.action.VIEW -d " + AdbTools.quote(uri) +
                        (if (args["packageName"] == null) "" else " -p " + pkg()),
                )
            }
            "android_logcat" -> done(
                "logcat -d -v threadtime -t ${a.integer("lines", 1..2000, 200)} -b " +
                    a.choice("buffer", listOf("main", "system", "crash", "events", "all"), "main") + " " +
                    AdbTools.quote("*:" + a.choice("priority", listOf("V", "D", "I", "W", "E", "F"), "I")),
            )
            "android_device_info" -> done(
                "getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; wm size; " +
                    "wm density; dumpsys battery; df -h /data /sdcard",
            )
            "android_list_apk_files" -> done(
                "find " + AdbTools.quote(if (args["directory"] == null) "/sdcard/Download" else a.path("directory")) +
                    " -type f -iname '*.apk'",
            )
            "android_delete_apk_file" -> {
                val path = a.path("apkPath", apk = true)
                if (listOf("/sdcard/", "/storage/", "/data/local/tmp/").none { path.startsWith(it) }) {
                    throw AdbFailure("Delete APK files only in shared storage or /data/local/tmp; uninstall apps by packageName")
                }
                done("rm -- " + AdbTools.quote(path))
            }
            "android_command_help" -> {
                val topic = a.choice("topic", listOf("package", "activity", "input", "settings", "files", "logcat", "services"), "package")
                done(
                    mapOf(
                        "package" to "pm help", "activity" to "am help", "input" to "input", "settings" to "settings help",
                        "files" to "ls --help; find --help; cat --help; rm --help; df --help", "logcat" to "logcat --help",
                        "services" to "dumpsys -l; cmd -l",
                    ).getValue(topic),
                )
            }
            else -> throw AdbFailure("Unknown Android tool")
        }
    }

    class Arguments(private val values: Map<String, JsonValue>) {
        fun text(key: String, limit: Int = 1024): String {
            val value = (values[key] as? JsonString)?.value
            if (value.isNullOrEmpty() || value.toByteArray(Charsets.UTF_8).size > limit || value.any { isControl(it) }) {
                throw AdbFailure("$key must be nonempty text, at most $limit bytes, without control characters")
            }
            return value
        }

        fun bool(key: String, fallback: Boolean = false, required: Boolean = false): Boolean {
            if (values[key] == null && !required) return fallback
            return (values[key] as? JsonBool)?.value ?: throw AdbFailure("$key must be a boolean")
        }

        fun integer(key: String, range: IntRange, fallback: Int): Int {
            if (values[key] == null) return fallback
            return integerOf(values[key], range)
                ?: throw AdbFailure("$key must be an integer in ${range.first}...${range.last}")
        }

        fun choice(key: String, allowed: List<String>, fallback: String? = null): String {
            if (values[key] == null && fallback != null) return fallback
            val value = text(key)
            if (value !in allowed) throw AdbFailure("Invalid $key; expected ${allowed.joinToString(", ")}")
            return value
        }

        fun identifier(key: String): String {
            val value = text(key, 255)
            if (!IDENTIFIER.matches(value)) throw AdbFailure("Invalid $key")
            return value
        }

        fun user(): String =
            if (values["userId"] == null) " --user current" else " --user ${integer("userId", 0..Int.MAX_VALUE, 0)}"

        fun path(key: String, apk: Boolean = false): String {
            val value = text(key)
            if (!value.startsWith("/") || value.split("/").contains("..") || (apk && !value.lowercase().endsWith(".apk"))) {
                throw AdbFailure("$key must be an absolute ${if (apk) ".apk " else ""}path without .. components")
            }
            return value
        }

        companion object {
            private val IDENTIFIER = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$")

            /** Swift's CharacterSet.controlCharacters: Cc and Cf. */
            private fun isControl(c: Char): Boolean =
                Character.getType(c) == Character.CONTROL.toInt() || Character.getType(c) == Character.FORMAT.toInt()

            /** A JSON number that is integral and inside [range]; `1.0` counts, `1.5` and `true` do not. */
            fun integerOf(value: JsonValue?, range: IntRange): Int? {
                val number = (value as? JsonNumber)?.raw ?: return null
                val decimal = try {
                    BigDecimal(number)
                } catch (failure: NumberFormatException) {
                    return null
                }
                if (decimal.stripTrailingZeros().scale() > 0) return null
                if (decimal < BigDecimal(range.first) || decimal > BigDecimal(range.last)) return null
                return decimal.toInt()
            }
        }
    }
}
