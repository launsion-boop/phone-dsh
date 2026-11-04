// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the `phone` tool's catalog dispatch.
// SPDX-License-Identifier: MIT
//
// ---- why the catalog lives here ----
// `phone` is the one advertised host tool (`accelerator:phone`), and its
// documented contract is `phone <tool> <args...>`. Until now `info` was the only
// tool. The local environment is the second one, and it is a *host tool*, not an
// accelerator: it writes, so it must not join the read-only accelerator set
// (exec.md §3) and it must not invent a capability string (channel.md §4.1).
//
// The discovery half of that is `ubuntu-probe`: the Worker asks
// `phone ubuntu probe` at boot and registers the `ubuntu` command only when the
// answer says the tool is there. This class is the answering half.
//
// ---- the refusal stays the same shape ----
// An argv that is neither `phone info` nor `phone ubuntu ...` is refused with
// the existing `unsupported` code and a message that now names both tools. The
// Worker turns that into 127 `not-available` for `phone`, so an old host that
// has no environment keeps answering exactly what it answered before.

package com.phonedsh.dsh.localexec

import com.phonedsh.dsh.host.PhoneInfoTool
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.ToolInvocation
import com.phonedsh.dsh.tools.ToolOutcome
import org.json.JSONObject

/**
 * The host's `phone` tool surface: `info` plus the local environment.
 *
 * @param info the read-only device-fact tool; the default is the production
 *   `phone info`.
 * @param ubuntu the local-environment tool. Null keeps the old single-tool
 *   behaviour (and the old refusal), which is what a test that only exercises
 *   `phone info` wants.
 */
class UbuntuPhoneCatalog(
    private val info: PhoneTool = PhoneInfoTool(),
    private val ubuntu: PhoneTool? = null,
) : PhoneTool {
    override suspend fun invoke(invocation: ToolInvocation): ToolOutcome {
        val argv = try {
            JSONObject(invocation.argumentsJson).getJSONArray("argv")
        } catch (malformed: RuntimeException) {
            return ToolOutcome.Failure(PhoneInfoTool.CODE_UNSUPPORTED, MESSAGE_UNSUPPORTED)
        }
        if (argv.length() >= 1 && argv.optString(0) != PhoneInfoTool.NAME) {
            return ToolOutcome.Failure(PhoneInfoTool.CODE_UNSUPPORTED, MESSAGE_UNSUPPORTED)
        }
        if (argv.length() == 2 && argv.optString(1) == PhoneInfoTool.COMMAND_INFO) {
            return info.invoke(invocation)
        }
        val tool = ubuntu
        if (tool != null && argv.length() >= 3 && argv.optString(1) == UbuntuHostTool.UBUNTU_TOOL) {
            return tool.invoke(invocation)
        }
        return ToolOutcome.Failure(PhoneInfoTool.CODE_UNSUPPORTED, MESSAGE_UNSUPPORTED)
    }

    companion object {
        /** Stable refusal for every shape this catalog does not implement. */
        const val MESSAGE_UNSUPPORTED: String =
            "only `phone info` and `phone ubuntu <probe|run|status|fetch|close>` are implemented"
    }
}
