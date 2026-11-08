// phone-dsh — :net / com.phonedsh.adb: the 26 android_* MCP tools.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBTools.swift` and `ADBPackageTools.swift`.
// Names, order, descriptions, input schemas, argument validation and the exact
// Android shell command of every tool follow the Swift catalog; the shared
// vectors in `spec/v1/golden/native-mcp/{tap,connect,package-management}.json`
// pin the commands and responses and run against this file in AdbMcpGoldenTest.

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.net.URI
import java.util.Base64

internal fun obj(vararg members: Pair<String, JsonValue>): JsonObject = JsonObject(linkedMapOf(*members))

internal object AdbTools {
    fun property(type: String, description: String): JsonValue =
        obj("type" to JsonString(type), "description" to JsonString(description))

    fun tool(
        name: String,
        description: String,
        properties: List<Pair<String, JsonValue>> = emptyList(),
        required: List<String> = emptyList(),
    ): JsonObject = obj(
        "name" to JsonString(name),
        "description" to JsonString(description),
        "inputSchema" to obj(
            "type" to JsonString("object"),
            "properties" to JsonObject(linkedMapOf(*properties.toTypedArray())),
            "required" to JsonArray(required.map { JsonString(it) }),
            "additionalProperties" to JsonBool(false),
        ),
    )

    private val coordinate = property("integer", "Pixel coordinate in the latest Android screenshot, from 0 to 32767.")

    val descriptors: List<JsonObject> = listOf(
        tool(
            "android_connect",
            "Enable Android control, save the TCP/IP ADB target and check its connection directly from iPhone. Use this when the user supplies an address or control is disabled; no Settings visit is required. Android must accept this iPhone debugging key.",
            listOf(
                "host" to property("string", "Android IP address or hostname, without adb prefix or port."),
                "port" to property("integer", "TCP/IP ADB port, 1–65535; default 5555. Pairing-code/TLS ports are unsupported."),
            ),
            listOf("host"),
        ),
        tool("android_status", "Check the Android device configured in iPhone Settings; returns model, Android release and screen size."),
        tool("android_screenshot", "Capture the configured Android screen as a PNG image. Inspect it before choosing tap/swipe pixel coordinates."),
        tool(
            "android_tap", "Tap the Android screen at pixel coordinates from a recent screenshot.",
            listOf("x" to coordinate, "y" to coordinate), listOf("x", "y"),
        ),
        tool(
            "android_swipe", "Swipe or long-press (same start/end) on Android. Coordinates are screenshot pixels.",
            listOf(
                "x" to coordinate, "y" to coordinate, "endX" to coordinate, "endY" to coordinate,
                "durationMs" to property("integer", "Gesture duration 1–10000 ms; default 300."),
            ),
            listOf("x", "y", "endX", "endY"),
        ),
        tool(
            "android_input_text",
            "Type printable ASCII text into the focused Android field. Unicode requires a device IME and is rejected, not silently lost.",
            listOf("text" to property("string", "Printable ASCII text, at most 1000 characters. Literal %s is unsupported by Android input.")),
            listOf("text"),
        ),
        tool(
            "android_key",
            "Press an Android key: HOME, BACK, ENTER, APP_SWITCH, DEL, POWER, VOLUME_UP, VOLUME_DOWN, WAKEUP, or a numeric key code.",
            listOf("key" to property("string", "Android key name or decimal code 0–400.")), listOf("key"),
        ),
        tool(
            "android_launch_app", "Open the launcher activity of an installed Android package.",
            listOf("packageName" to property("string", "Application package ID, e.g. com.android.settings.")), listOf("packageName"),
        ),
        tool("android_ui_dump", "Read Android's UI hierarchy XML for accessible text and element bounds. Some apps expose limited content."),
        tool(
            "android_shell",
            "Run a shell command on the configured Android device as the ADB shell user. It can change device state. No automatic retries; after timeout/disconnect inspect state before repeating.",
            listOf(
                "command" to property("string", "Android shell command, under 3800 UTF-8 bytes; this is not the iPhone workspace shell."),
                "timeoutMs" to property("integer", "Wall-clock timeout from 100 to 120000 ms; default 30000."),
            ),
            listOf("command"),
        ),
    ) + AdbPackageTools.descriptors

    class Plan(
        val command: String,
        val connection: AdbConfiguration? = null,
        val timeoutMillis: Long = 30_000,
        val image: Boolean = false,
        val workspaceApk: String? = null,
        val sha256: String? = null,
        val requiresSuccess: Boolean = false,
    ) {
        val outputLimit: Int get() = if (image) 8 * 1024 * 1024 else 256 * 1024
    }

    private const val STATUS_COMMAND = "getprop ro.product.model; getprop ro.build.version.release; wm size"

    fun plan(name: String, arguments: JsonValue): Plan {
        val args = (arguments as? JsonObject)?.members
        val descriptor = descriptors.firstOrNull { (it["name"] as JsonString).value == name }
        if (args == null || descriptor == null) throw AdbFailure("Unknown Android tool or invalid arguments")
        val properties = ((descriptor["inputSchema"] as JsonObject)["properties"] as JsonObject).members
        if (!properties.keys.containsAll(args.keys)) throw AdbFailure("Unknown Android tool argument")
        fun text(key: String): String {
            val value = (args[key] as? JsonString)?.value
            if (value.isNullOrEmpty() || value.contains('\u0000')) throw AdbFailure("$key must be a nonempty string without NUL")
            return value
        }
        fun integer(key: String, range: IntRange, fallback: Int? = null): Int {
            if (args[key] == null && fallback != null) return fallback
            return AdbPackageTools.Arguments.integerOf(args[key], range)
                ?: throw AdbFailure("$key must be an integer in ${range.first}...${range.last}")
        }
        return when (name) {
            "android_connect" -> {
                val endpoint = AdbEndpoint.of(text("host"), integer("port", 1..65535, 5555))
                Plan(STATUS_COMMAND, connection = AdbConfiguration(true, endpoint.host, endpoint.port))
            }
            "android_status" -> Plan(STATUS_COMMAND)
            "android_screenshot" -> Plan("screencap -p", image = true)
            // shell_v2 raw has no controlling terminal. Use a unique shell-owned
            // temporary file; /dev/tty would fail on otherwise valid devices.
            "android_ui_dump" -> Plan(
                "p=\$(mktemp /data/local/tmp/phone-dsh-ui.XXXXXX) || exit 1; trap 'rm -f \"\$p\"' EXIT; " +
                    "uiautomator dump \"\$p\" >/dev/null && cat \"\$p\"",
            )
            "android_tap" -> Plan("input tap ${integer("x", 0..32767)} ${integer("y", 0..32767)}")
            "android_swipe" -> Plan(
                "input swipe ${integer("x", 0..32767)} ${integer("y", 0..32767)} ${integer("endX", 0..32767)} " +
                    "${integer("endY", 0..32767)} ${integer("durationMs", 1..10000, 300)}",
            )
            "android_input_text" -> {
                val value = text("text")
                val bytes = value.toByteArray(Charsets.UTF_8)
                if (bytes.size > 1000 || bytes.any { it < 32 || it > 126 } || value.contains("%s")) {
                    throw AdbFailure(
                        "Android input text supports printable ASCII only (1000 characters max, no literal %s); Unicode needs a device IME",
                    )
                }
                Plan("input text " + quote(value.replace(" ", "%s")))
            }
            "android_key" -> {
                val key = text("key").uppercase().replace("KEYCODE_", "")
                val known = listOf("HOME", "BACK", "ENTER", "APP_SWITCH", "DEL", "POWER", "VOLUME_UP", "VOLUME_DOWN", "WAKEUP")
                val numeric = key.isNotEmpty() && key.all { it in '0'..'9' } && key.toIntOrNull()?.let { it in 0..400 } == true
                if (key !in known && !numeric) throw AdbFailure("Unsupported Android key")
                Plan("input keyevent " + if (key in known) "KEYCODE_$key" else key)
            }
            "android_launch_app" -> {
                val pkg = text("packageName")
                if (pkg.length > 255 || !PACKAGE.matches(pkg)) throw AdbFailure("Invalid Android package name")
                Plan("monkey -p ${quote(pkg)} -c android.intent.category.LAUNCHER 1")
            }
            "android_shell" -> {
                val command = text("command")
                if (command.toByteArray(Charsets.UTF_8).size >= 3800) throw AdbFailure("Android command is too long")
                Plan(command, timeoutMillis = integer("timeoutMs", 100..120000, 30000).toLong())
            }
            else -> AdbPackageTools.plan(name, args)
        }
    }

    private val PACKAGE = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")

    fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    fun textResult(message: String, error: Boolean = false): JsonValue = obj(
        "content" to JsonArray(listOf(obj("type" to JsonString("text"), "text" to JsonString(message)))),
        "isError" to JsonBool(error),
    )

    private val PNG = byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10)

    fun result(result: AdbShellResult, plan: Plan): JsonValue {
        if (plan.image && result.exitCode == 0) {
            if (result.stdout.size < 24 || !result.stdout.copyOfRange(0, 8).contentEquals(PNG)) {
                throw AdbFailure("Android screenshot did not return a PNG image")
            }
            return obj(
                "content" to JsonArray(
                    listOf(
                        obj(
                            "type" to JsonString("image"),
                            "mimeType" to JsonString("image/png"),
                            "data" to JsonString(Base64.getEncoder().encodeToString(result.stdout)),
                        ),
                    ),
                ),
                "isError" to JsonBool(false),
            )
        }
        val stdout = String(result.stdout, Charsets.UTF_8)
        val stderr = String(result.stderr, Charsets.UTF_8)
        // Some vendor pm wrappers print Failure while returning zero. Never
        // report an installation/uninstallation as successful without its ack.
        val success = stdout.lines().any { it.trim(' ', '\t') == "Success" }
        val failed = result.exitCode != 0 ||
            (plan.requiresSuccess && (!success || stdout.contains("Failure") || stderr.contains("Failure")))
        return textResult(
            "exitCode: ${result.exitCode}\n" + stdout +
                (if (stderr.isEmpty()) "" else "\nstderr:\n$stderr") +
                (if (plan.requiresSuccess && !success) "\nPackage manager did not confirm Success; inspect device state." else ""),
            error = failed,
        )
    }

    fun numberOrNull(value: JsonValue?): JsonNumber? = value as? JsonNumber

    fun uriHasScheme(uri: String): Boolean = try {
        !URI(uri).scheme.isNullOrEmpty()
    } catch (failure: java.net.URISyntaxException) {
        false
    }
}
