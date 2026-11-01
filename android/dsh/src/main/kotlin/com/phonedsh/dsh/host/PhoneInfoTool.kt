// phone-dsh — :dsh / com.phonedsh.dsh.host: the first real exec accelerator.
// SPDX-License-Identifier: MIT
//
// `phone info` is the smallest honest `phone` accelerator: it reads facts the
// Android framework already exposes and returns a JSON document. It starts no
// process, writes no file and needs no permission.
//
// ---- why the Android read sits behind a fun interface ----------------------
// A JVM unit test cannot call `android.os.Build` or `Resources.getSystem()`
// (the stubs throw), and the tool should be tested for its argv/result contract,
// not for the device it runs on. [PhoneInfoSource] is that seam; the default is
// the Android implementation, and a JVM test injects a fixed JSON string. This
// file has no `Context` parameter because `Build` and `Resources.getSystem()` are
// static; BatteryManager would need a Context and is deliberately not part of
// this first version (reported as a gap, not faked).

package com.phonedsh.dsh.host

import android.content.res.Resources
import android.os.Build
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** The device-fact read behind `phone info`; injectable so JVM tests run. */
fun interface PhoneInfoSource {
    /** Returns one JSON object string; may throw if the platform read fails. */
    fun readJson(): String
}

/**
 * The read-only `phone info` accelerator (`exec.md` §3: `phone`).
 *
 * It accepts exactly `argv = ["phone", "info"]`. The result follows
 * [com.phonedsh.dsh.exec.ExecToolResult]'s contract: stdout is the base64 of the
 * JSON document followed by a newline, stderr is empty, and the exit is
 * `exited`/0/quiescent.
 *
 * @param source the platform read; [AndroidPhoneInfoSource] by default.
 */
class PhoneInfoTool(
    private val source: PhoneInfoSource = AndroidPhoneInfoSource,
) : PhoneTool {
    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        val argv = try {
            JSONObject(invocation.argumentsJson).getJSONArray("argv")
        } catch (malformed: RuntimeException) {
            return ToolOutcome.Failure(CODE_UNSUPPORTED, MESSAGE_UNSUPPORTED)
        }
        if (argv.length() != 2 ||
            argv.optString(0) != NAME ||
            argv.optString(1) != COMMAND_INFO
        ) {
            // argv is never copied into the message: a command can carry a path.
            return ToolOutcome.Failure(CODE_UNSUPPORTED, MESSAGE_UNSUPPORTED)
        }

        val info = try {
            source.readJson()
        } catch (failure: Exception) {
            return ToolOutcome.Failure(
                code = CODE_INFO_FAILED,
                message = failure.javaClass.simpleName,
            )
        }
        val stdout = Base64.getEncoder().encodeToString(
            (info + "\n").toByteArray(Charsets.UTF_8),
        )
        val result = JSONObject()
            .put("status", "exited")
            .put("code", 0)
            .put("signal", JSONObject.NULL)
            .put("quiescent", true)
            .put("stdout", stdout)
            .put("stderr", "")
        return ToolOutcome.Success(result.toString())
    }

    companion object {
        /** The accelerator name; also the `argv[0]` value. */
        const val NAME: String = "phone"

        /** The only subcommand this first version implements. */
        const val COMMAND_INFO: String = "info"

        /** Stable refusal: not `phone info`. */
        const val CODE_UNSUPPORTED: String = "unsupported"

        /** Stable refusal: the platform read threw. */
        const val CODE_INFO_FAILED: String = "phone_info_failed"

        const val MESSAGE_UNSUPPORTED: String = "only `phone info` is implemented"
    }
}

/**
 * The Android implementation of [PhoneInfoSource].
 *
 * Only static APIs are used, so no `Context` leaks into the host object:
 * `Build` for the device/OS identity and `Resources.getSystem()` for the display
 * metrics. Battery state would require a `Context`-backed `BatteryManager` and is
 * a documented gap rather than a fabricated value.
 */
object AndroidPhoneInfoSource : PhoneInfoSource {
    override fun readJson(): String {
        val metrics = Resources.getSystem().displayMetrics
        val display = JSONObject()
            .put("density_dpi", metrics.densityDpi)
            .put("density", metrics.density.toDouble())
            .put("width_px", metrics.widthPixels)
            .put("height_px", metrics.heightPixels)
        return JSONObject()
            .put("model", Build.MODEL)
            .put("manufacturer", Build.MANUFACTURER)
            .put("device", Build.DEVICE)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("release", Build.VERSION.RELEASE)
            .put("abis", JSONArray(Build.SUPPORTED_ABIS.toList()))
            .put("display", display)
            .toString()
    }
}
