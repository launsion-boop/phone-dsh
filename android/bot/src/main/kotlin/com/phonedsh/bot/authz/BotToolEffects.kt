// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson

/** `BotToolMutability` (`BotToolEffects.swift`). */
public enum class BotToolMutability(public val wire: String) {
    READ("read"),
    WRITE("write"),
    EXTERNAL_SEND("external-send"),
    DESTRUCTIVE("destructive"),
    ;

    public companion object {
        public fun fromWire(value: String): BotToolMutability? =
            entries.firstOrNull { it.wire == value }
    }
}

/** `BotToolPolicy` (`BotToolEffects.swift`). */
public enum class BotToolPolicy(public val wire: String) {
    AUTO("auto"),
    ASK("ask"),
    ;

    public companion object {
        public fun fromWire(value: String): BotToolPolicy? =
            entries.firstOrNull { it.wire == value }
    }
}

/** Display language used by the frozen effect table. */
public enum class BotToolLanguage {
    ZH,
    EN,
}

/** One classified tool effect (`BotToolEffect`). */
public data class BotToolEffect(
    public val tool: String,
    public val operation: String,
    public val resource: String,
    public val target: String = resource,
    public val mutability: BotToolMutability,
    public val policy: BotToolPolicy,
    public val label: String = "",
    public val detail: String = "",
    public val ui: Boolean = false,
    public val execution: String? = null,
    public val known: Boolean = true,
    public val isMcp: Boolean = false,
    /**
     * Stable resource to store for an `always`/`session` grant. `null` keeps
     * the exact call resource, so bash/memory grants remain path-specific.
     * Image tools set `model:image` so the next image in the same scope does
     * not create a second approval card.
     */
    public val grantResource: String? = null,
) {
    /**
     * Whether a standing approval may cover more than this exact resource.
     * Unknown tools are never widened. Destructive bash/memory operations stay
     * exact; only external-send effects (images/network) and effects that
     * explicitly declare a grantResource get a stable scope.
     */
    public val canUseStandingGrant: Boolean
        get() {
            if (!known) return false
            if (grantResource != null) return true
            return mutability == BotToolMutability.EXTERNAL_SEND
        }

    /**
     * The stable scope a standing approval stores. Images opt into the
     * narrower `model:image`; other external sends use `operation:<id>`.
     * Destructive and unclassified effects return their exact resource, so a
     * standing decision never widens them.
     */
    public val stableGrantResource: String
        get() {
            grantResource?.let { return it }
            if (!canUseStandingGrant) return resource
            return if (operation.isEmpty()) resource else "operation:$operation"
        }

    /** The frozen members, including explicit `null` for `execution`. */
    public fun toJson(): JsonObject {
        val members = linkedMapOf<String, JsonValue>(
            "tool" to JsonString(tool),
            "operation" to JsonString(operation),
            "resource" to JsonString(resource),
            "target" to JsonString(target),
            "mutability" to JsonString(mutability.wire),
            "policy" to JsonString(policy.wire),
            "label" to JsonString(label),
            "detail" to JsonString(detail),
            "ui" to JsonBool(ui),
            "execution" to (execution?.let(::JsonString) ?: JsonNull),
            "known" to JsonBool(known),
            "isMcp" to JsonBool(isMcp),
        )
        // The shared tool-effects fixture predates P26: the member is absent
        // for every existing effect and appears only when it has a value.
        grantResource?.let { members["grantResource"] = JsonString(it) }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotToolEffect? {
            val members = (value as? JsonObject)?.members ?: return null
            val tool = BotJson.string(members["tool"]) ?: return null
            val operation = BotJson.string(members["operation"]) ?: return null
            val resource = BotJson.string(members["resource"]) ?: return null
            val mutability = BotJson.string(members["mutability"])
                ?.let(BotToolMutability::fromWire) ?: return null
            val policy = BotJson.string(members["policy"])
                ?.let(BotToolPolicy::fromWire) ?: return null
            return BotToolEffect(
                tool = tool,
                operation = operation,
                resource = resource,
                target = BotJson.string(members["target"]) ?: resource,
                mutability = mutability,
                policy = policy,
                label = BotJson.string(members["label"]) ?: "",
                detail = BotJson.string(members["detail"]) ?: "",
                ui = BotJson.bool(members["ui"]) ?: false,
                execution = BotJson.string(members["execution"]),
                known = BotJson.bool(members["known"]) ?: true,
                isMcp = BotJson.bool(members["isMcp"]) ?: true,
                grantResource = BotJson.string(members["grantResource"]),
            )
        }
    }
}

/**
 * The frozen P26 effect table (`BotToolEffectClassifier.swift`).
 *
 * `inputSchema` is only advertised metadata; this classifier is the runtime
 * rule. Unknown tools are write-class and ask, never auto.
 */
public object BotToolEffectClassifier {
    private const val DSHBOT_PREFIX = "mcp__dshbot__"
    private const val PHONE_PREFIX = "mcp__phone__"

    private val uiLabels: Map<String, Pair<String, String>> = linkedMapOf(
        "ask_user" to ("询问用户" to "Ask the user"),
        "show_attachment" to ("显示附件卡片" to "Show an attachment card"),
        "show_next_steps" to ("显示下一步建议" to "Show next-step suggestions"),
        "show_document" to ("显示文件卡片" to "Show a document card"),
        "show_library" to ("显示文件库卡片" to "Show a library card"),
        "show_info" to ("显示信息卡片" to "Show an info card"),
        "show_payload" to ("显示数据卡片" to "Show a payload card"),
        "show_progress" to ("显示进度卡片" to "Show a progress card"),
        "show_checklist" to ("显示清单卡片" to "Show a checklist card"),
        "show_link" to ("显示链接卡片" to "Show a link card"),
        "show_table" to ("显示表格卡片" to "Show a table card"),
        "show_callout" to ("显示提示卡片" to "Show a callout card"),
        "ReportVerification" to ("记录验证结论" to "Record a verification verdict"),
        "FishAction" to ("播放角色动作" to "Play a character action"),
        "RequestApproval" to ("请求用户授权" to "Request user approval"),
    )

    public fun policy(
        name: String,
        arguments: JsonValue = JsonObject(emptyMap()),
    ): BotToolPolicy = effect(name, arguments).policy

    public fun effect(
        name: String,
        arguments: JsonValue = JsonObject(emptyMap()),
        language: BotToolLanguage = BotToolLanguage.ZH,
    ): BotToolEffect {
        val args = (arguments as? JsonObject)?.members ?: emptyMap()
        val isMcp = name.startsWith("mcp__")
        val bareName = when {
            name.startsWith(DSHBOT_PREFIX) -> name.removePrefix(DSHBOT_PREFIX)
            name.startsWith(PHONE_PREFIX) -> name.removePrefix(PHONE_PREFIX)
            else -> name
        }
        uiLabels[bareName]?.let { labels ->
            return BotToolEffect(
                tool = bareName,
                operation = "ui.$bareName",
                resource = "*",
                mutability = BotToolMutability.READ,
                policy = BotToolPolicy.AUTO,
                label = if (language == BotToolLanguage.ZH) labels.first else labels.second,
                detail = defaultDetail(name, args, language),
                ui = true,
                isMcp = isMcp,
            )
        }
        return when (bareName) {
            "bluetooth.scan", "network.browse" -> discoveryEffect(bareName)
            "ble_devices", "ble_read", "ble_alert", "ble_link_tools", "ble_link_call", "ble_link_result" ->
                bleEffect(bareName, args, language, isMcp)
            "UpdateMemory" -> memoryEffect(args, forceForget = false, language = language, isMcp = isMcp)
            "ForgetMemory" -> memoryEffect(args, forceForget = true, language = language, isMcp = isMcp)
            "ReadMemory" -> readEffect(
                name, bareName, "memory.read", "读取记忆", args, language, isMcp,
            )
            "RecallMemory", "SortMemories" -> {
                val operation = if (bareName == "RecallMemory") "memory.recall" else "memory.sort"
                val zhLabel = if (bareName == "RecallMemory") "回想记忆" else "查看记忆顺序"
                BotToolEffect(
                    tool = bareName,
                    operation = operation,
                    resource = "*",
                    mutability = BotToolMutability.READ,
                    policy = BotToolPolicy.AUTO,
                    label = if (language == BotToolLanguage.ZH) zhLabel else bareName,
                    detail = defaultDetail(name, args, language),
                    isMcp = isMcp,
                )
            }
            "read_image" -> {
                // DSH's built-in fs tool commits an image and asks the model
                // route to inspect it. The Worker gate must present the same
                // external send effect so the approval card and grants agree.
                val target = clip(args["path"], 200)
                BotToolEffect(
                    tool = bareName,
                    operation = "model.image.attach",
                    resource = if (target.isEmpty()) "model:image" else "attachment=$target",
                    target = if (target.isEmpty()) "model:image" else target,
                    mutability = BotToolMutability.EXTERNAL_SEND,
                    policy = BotToolPolicy.ASK,
                    label = if (language == BotToolLanguage.ZH) {
                        "把图片发送给模型"
                    } else {
                        "Send an image to the model"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "把工作区图片发送给模型服务，让模型看到像素。"
                    } else {
                        "Sends a workspace image to the model service so the model can see its pixels."
                    },
                    isMcp = isMcp,
                    grantResource = "model:image",
                )
            }
            "attach_to_model" -> {
                val purpose = clip(args["purpose"], 120)
                val target = clip(firstNonEmpty(args["path"], args["fileId"], args["photoId"]), 200)
                BotToolEffect(
                    tool = bareName,
                    operation = "model.image.attach",
                    resource = if (target.isEmpty()) "model:image" else "attachment=$target",
                    target = if (target.isEmpty()) "model:image" else target,
                    mutability = BotToolMutability.EXTERNAL_SEND,
                    policy = BotToolPolicy.ASK,
                    label = if (language == BotToolLanguage.ZH) {
                        "把图片发送给模型"
                    } else {
                        "Send an image to the model"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "把图片发送给模型服务，让模型看到像素。" +
                            if (purpose.isEmpty()) "" else "用途：$purpose"
                    } else {
                        "Sends the image to the model service so the model can see its pixels." +
                            if (purpose.isEmpty()) "" else " Purpose: $purpose"
                    },
                    isMcp = isMcp,
                    grantResource = "model:image",
                )
            }
            "Task" -> {
                val title = clip(firstNonEmpty(args["description"], args["task_title"]), 80)
                val prompt = clip(firstNonEmpty(args["prompt"], args["task_description"]), 120)
                val resource = mergedResource(listOf("task=$title", "prompt=$prompt"))
                BotToolEffect(
                    tool = bareName,
                    operation = "dshbot.Task",
                    resource = resource.ifEmpty { "dshbot:task:*" },
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.AUTO,
                    label = when {
                        language != BotToolLanguage.ZH -> if (title.isEmpty()) {
                            "Start a subagent task"
                        } else {
                            "Start subagent task \"$title\""
                        }
                        title.isEmpty() -> "启动子代理任务"
                        else -> "启动子代理任务「$title」"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "会启动一个子代理并使用模型额度。"
                    } else {
                        "Starts a subagent and consumes model budget."
                    },
                    isMcp = isMcp,
                )
            }
            "AwaitTask" -> readEffect(
                name, bareName, "dshbot.AwaitTask", "等待子代理结果", args, language, isMcp,
            )
            "StopSubagent" -> {
                val id = clip(firstNonEmpty(args["task_id"], args["id"]), 120)
                BotToolEffect(
                    tool = bareName,
                    operation = "dshbot.StopSubagent",
                    resource = if (id.isEmpty()) "dshbot:stop-subagent:*" else "task=$id",
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.AUTO,
                    label = when {
                        language != BotToolLanguage.ZH -> if (id.isEmpty()) {
                            "Stop a subagent task"
                        } else {
                            "Stop subagent task $id"
                        }
                        id.isEmpty() -> "停止子代理任务"
                        else -> "停止子代理任务 $id"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "中止正在执行的子代理，保留可读的部分结果。"
                    } else {
                        "Aborts a running subagent and keeps its partial result readable."
                    },
                    isMcp = isMcp,
                )
            }
            "SendToUser" -> {
                val preview = clip(args["message"], 180)
                BotToolEffect(
                    tool = bareName,
                    operation = "dshbot.SendToUser",
                    resource = "dshbot:send-to-user",
                    mutability = BotToolMutability.EXTERNAL_SEND,
                    policy = BotToolPolicy.AUTO,
                    label = if (language == BotToolLanguage.ZH) "发送消息给用户" else "Send a message to the user",
                    detail = if (language == BotToolLanguage.ZH) {
                        "在对话中发送一条消息" + if (preview.isEmpty()) "" else "：$preview"
                    } else {
                        "Posts one message into the conversation" + if (preview.isEmpty()) "" else ": $preview"
                    },
                    isMcp = isMcp,
                )
            }
            "SendToAgent" -> {
                val target = clip(
                    firstNonEmpty(args["agent_id"], args["target_id"], args["bot_name"], args["agentId"]),
                    120,
                )
                val preview = clip(firstNonEmpty(args["message"], args["text"]), 180)
                val resource = mergedResource(
                    listOf(
                        if (target.isEmpty()) "dshbot:send-to-agent" else "agent=$target",
                        if (preview.isEmpty()) "" else "message=$preview",
                    ),
                )
                BotToolEffect(
                    tool = bareName,
                    operation = "dshbot.SendToAgent",
                    resource = resource.ifEmpty { "dshbot:send-to-agent" },
                    mutability = BotToolMutability.EXTERNAL_SEND,
                    policy = BotToolPolicy.AUTO,
                    label = if (language == BotToolLanguage.ZH) "发送消息给其他 Bot" else "Send a message to another bot",
                    detail = if (language == BotToolLanguage.ZH) {
                        "把消息发给另一个 Bot，对方回复后会以 agent-comm 行返回；这是对外动作，结果未知时不自动重试。"
                    } else {
                        "Sends a message to another Bot and records the reply as an agent-comm row; " +
                            "this is an external action and must not be retried automatically when the outcome is unknown."
                    },
                    isMcp = isMcp,
                )
            }
            "CreateTeammate" -> {
                val name = clip(args["name"], 80)
                val resource = mergedResource(
                    listOf("dshbot:create-teammate", if (name.isEmpty()) "" else "name=$name"),
                )
                BotToolEffect(
                    tool = bareName,
                    operation = "dshbot.CreateTeammate",
                    resource = resource.ifEmpty { "dshbot:create-teammate" },
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.AUTO,
                    label = if (language == BotToolLanguage.ZH) "创建队友 Bot" else "Create a teammate Bot",
                    detail = if (language == BotToolLanguage.ZH) {
                        "创建一个有独立对话与记忆的 Bot；只有主 Bot 可以调用。"
                    } else {
                        "Creates a Bot with its own transcript and memory; only the main Bot may call it."
                    },
                    isMcp = isMcp,
                )
            }
            "UpdateRoutine" -> {
                val title = clip(args["title"], 80)
                val action = args["action"]?.let { clip(it, 40) } ?: "update"
                val prompt = clip(args["prompt"], 120)
                val schedule = clip(args["schedule"], 120)
                val resource = mergedResource(
                    listOf(
                        "action=$action",
                        "routine=${clip(args["routine_id"], 120)}",
                        "title=$title",
                        if (schedule.isEmpty()) "" else "schedule=$schedule",
                        if (prompt.isEmpty()) "" else "prompt=$prompt",
                    ),
                )
                BotToolEffect(
                    tool = bareName,
                    operation = "dshbot.UpdateRoutine",
                    resource = resource.ifEmpty { "dshbot:routine:*" },
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.AUTO,
                    label = when {
                        language != BotToolLanguage.ZH -> if (title.isEmpty()) {
                            "Update a routine"
                        } else {
                            "Update routine \"$title\""
                        }
                        title.isEmpty() -> "更新例行任务"
                        else -> "更新例行任务「$title」"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "创建、修改或删除本机例行任务" +
                            (if (schedule.isEmpty()) "" else "；日程：$schedule") +
                            (if (prompt.isEmpty()) "" else "；指示：$prompt") + "。"
                    } else {
                        "Create, change or delete a local routine" +
                            (if (schedule.isEmpty()) "" else "; schedule: $schedule") +
                            (if (prompt.isEmpty()) "" else "; prompt: $prompt") + "."
                    },
                    isMcp = isMcp,
                )
            }
            "ListRoutines" -> BotToolEffect(
                tool = bareName,
                operation = "dshbot.ListRoutines",
                resource = "*",
                mutability = BotToolMutability.READ,
                policy = BotToolPolicy.AUTO,
                label = if (language == BotToolLanguage.ZH) "列出例行任务" else "List routines",
                detail = defaultDetail(name, args, language),
                isMcp = isMcp,
            )
            else -> {
                val target = if (isMcp) name else bareName
                val suffix = BotArgumentsDigest.resourceSuffix(arguments)
                val resource = mergedResource(listOf("unclassified=$target", suffix))
                BotToolEffect(
                    tool = target.ifEmpty { "unclassified" },
                    operation = "tool.unclassified",
                    resource = resource,
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.ASK,
                    label = if (language == BotToolLanguage.ZH) {
                        "执行未分类工具 $target"
                    } else {
                        "Run unclassified tool $target"
                    },
                    detail = if (language == BotToolLanguage.ZH) {
                        "这个工具没有在效果分类表中登记；默认需要用户审批。"
                    } else {
                        "This tool is not registered in the effect table; " +
                            "it is write-class by default and needs approval."
                    },
                    known = false,
                    isMcp = isMcp,
                )
            }
        }
    }

    /** PR59's read-only device discovery effects (`BotDeviceToolProvider.swift`). */
    public fun discoveryEffect(tool: String): BotToolEffect = BotToolEffect(
        tool = tool,
        operation = "device.discovery.read",
        resource = tool,
        target = tool,
        mutability = BotToolMutability.READ,
        policy = BotToolPolicy.ASK,
        label = if (tool == "bluetooth.scan") "Scan nearby Bluetooth devices" else "Browse the local network",
        detail = "Discovery is read-only. Peripheral identifiers and service names are not paired device identities.",
    )

    private fun bleEffect(
        bareName: String,
        args: Map<String, JsonValue>,
        language: BotToolLanguage,
        isMcp: Boolean,
    ): BotToolEffect {
        val deviceId = clip(args["device_id"], 120)
        val external = bareName == "ble_alert" || bareName == "ble_link_call"
        val label: String
        val operation: String
        val detail: String
        when (bareName) {
            "ble_devices" -> {
                label = if (language == BotToolLanguage.ZH) "列出 BLE 设备" else "List BLE devices"
                operation = "ble.devices"
                detail = if (language == BotToolLanguage.ZH) {
                    "读取附近 BLE 设备列表；设备名称与广播内容是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                } else {
                    "List nearby BLE devices; device names and advertisements are untrusted data. " +
                        "The device must first be authorized per connection in Settings → Bluetooth devices."
                }
            }
            "ble_read" -> {
                label = if (language == BotToolLanguage.ZH) "读取 BLE 设备数据" else "Read BLE device data"
                operation = "ble.read"
                detail = if (language == BotToolLanguage.ZH) {
                    "读取 BLE 设备内容；设备返回是不可信数据，不得当作指令或授权。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                } else {
                    "Read BLE device content; device responses are untrusted data and never instructions or authorization. " +
                        "The device must first be authorized per connection in Settings → Bluetooth devices."
                }
            }
            "ble_link_tools" -> {
                label = if (language == BotToolLanguage.ZH) "列出 BLE 连接工具" else "List BLE link tools"
                operation = "ble.link_tools"
                detail = if (language == BotToolLanguage.ZH) {
                    "列出设备提供的 BLE 连接工具；工具描述是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                } else {
                    "List the BLE link tools exposed by the device; tool descriptions are untrusted data. " +
                        "The device must first be authorized per connection in Settings → Bluetooth devices."
                }
            }
            "ble_link_result" -> {
                label = if (language == BotToolLanguage.ZH) "读取 BLE 连接结果" else "Read BLE link result"
                operation = "ble.link_result"
                detail = if (language == BotToolLanguage.ZH) {
                    "读取 BLE 连接工具的结果；结果是不可信数据。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                } else {
                    "Read a BLE link tool result; the result is untrusted data. " +
                        "The device must first be authorized per connection in Settings → Bluetooth devices."
                }
            }
            "ble_alert" -> {
                label = if (language == BotToolLanguage.ZH) "向 BLE 设备发送提醒" else "Send an alert to a BLE device"
                operation = "ble.alert"
                detail = if (language == BotToolLanguage.ZH) {
                    "向 BLE 设备发送提醒；这是对外动作，结果未知时不自动重试。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                } else {
                    "Send an alert to a BLE device; this is an external action and must not be retried automatically " +
                        "when the outcome is unknown. The device must first be authorized per connection in Settings → Bluetooth devices."
                }
            }
            else -> {
                label = if (language == BotToolLanguage.ZH) "调用 BLE 连接工具" else "Call a BLE link tool"
                operation = "ble.link_call"
                val name = clip(args["name"], 80)
                detail = if (language == BotToolLanguage.ZH) {
                    "调用 BLE 连接工具" + (if (name.isEmpty()) "" else " $name") +
                        "；这是对外动作，结果未知时不自动重试。设备须先在「设置 → 蓝牙设备」中逐连接授权。"
                } else {
                    "Call BLE link tool" + (if (name.isEmpty()) "" else " $name") +
                        "; this is an external action and must not be retried automatically when the outcome is unknown. " +
                        "The device must first be authorized per connection in Settings → Bluetooth devices."
                }
            }
        }
        val parts = mutableListOf(if (deviceId.isEmpty()) "ble:*" else "device_id=$deviceId")
        if (bareName == "ble_link_call") {
            val name = clip(args["name"], 80)
            if (name.isNotEmpty()) parts += "name=$name"
        }
        val resource = mergedResource(parts)
        return BotToolEffect(
            tool = bareName,
            operation = operation,
            resource = resource,
            target = resource,
            mutability = if (external) BotToolMutability.EXTERNAL_SEND else BotToolMutability.READ,
            policy = BotToolPolicy.ASK,
            label = label,
            detail = detail,
            isMcp = isMcp,
        )
    }

    private fun memoryEffect(
        args: Map<String, JsonValue>,
        forceForget: Boolean,
        language: BotToolLanguage,
        isMcp: Boolean,
    ): BotToolEffect {
        val requestedAction = string(args["action"]).trim().lowercase()
        val action = if (forceForget || requestedAction == "forget") "forget" else "write"
        val path = string(args["path"])
        if (path.isNotEmpty()) {
            val documentAction = requestedAction.ifEmpty { "write" }
            val scope = if (path.startsWith("user/")) "user" else "agent"
            val resource = mergedResource(
                listOf(
                    "path=$path",
                    if (documentAction == "move") "to=${string(args["to"])}" else "",
                ),
            )
            val mutability = when (documentAction) {
                "delete", "move" -> BotToolMutability.DESTRUCTIVE
                else -> BotToolMutability.WRITE
            }
            val label = if (language == BotToolLanguage.ZH) {
                when (documentAction) {
                    "delete" -> "忘记记忆文档 $path"
                    "move" -> "移动记忆文档 $path"
                    "restore" -> "恢复记忆版本 $path"
                    else -> "写入记忆：$path"
                }
            } else {
                when (documentAction) {
                    "delete" -> "Forget memory document $path"
                    "move" -> "Move memory document $path"
                    "restore" -> "Restore memory version $path"
                    else -> "Save memory: $path"
                }
            }
            return BotToolEffect(
                tool = "memory",
                operation = if (documentAction == "delete") "memory.forget" else "memory.write",
                resource = resource,
                mutability = mutability,
                policy = if (mutability == BotToolMutability.DESTRUCTIVE && scope == "user") {
                    BotToolPolicy.ASK
                } else {
                    BotToolPolicy.AUTO
                },
                label = label,
                detail = if (language == BotToolLanguage.ZH) {
                    "对 ${if (scope == "user") "用户共享" else "这个 Bot 的"}记忆文档执行 $documentAction。"
                } else {
                    "Apply $documentAction to a ${if (scope == "user") "shared user" else "Bot"} memory document."
                },
                execution = "memory",
                isMcp = isMcp,
            )
        }
        val scope = if (string(args["scope"]) == "user") "user" else "agent"
        if (action == "forget") {
            val fact = clip(firstNonEmpty(args["fact"], args["key"]), 300)
            val factId = clip(firstNonEmpty(args["fact_id"], args["factId"]), 200)
            val resource = mergedResource(
                listOf(
                    "memory:$scope",
                    if (factId.isEmpty()) "fact=$fact" else "fact_id=$factId",
                ),
            )
            return BotToolEffect(
                tool = "memory",
                operation = "memory.forget",
                resource = resource.ifEmpty { "memory:$scope:fact:*" },
                mutability = BotToolMutability.DESTRUCTIVE,
                policy = if (scope == "user") BotToolPolicy.ASK else BotToolPolicy.AUTO,
                label = if (language == BotToolLanguage.ZH) {
                    if (factId.isEmpty()) "忘记记忆「${clip(fact, 60)}」" else "忘记记忆（fact_id）"
                } else {
                    if (factId.isEmpty()) "Forget memory \"${clip(fact, 60)}\"" else "Forget a memory (fact_id)"
                },
                detail = if (language == BotToolLanguage.ZH) {
                    "从 ${if (scope == "user") "用户共享" else "这个 Bot 的"}记忆移除一条事实。"
                } else {
                    "Remove one fact from the ${if (scope == "user") "shared user" else "Bot"} memory."
                },
                execution = "memory",
                isMcp = isMcp,
            )
        }
        val fact = clip(args["fact"], 400)
        val requestedTier = string(args["tier"])
        val tier = if (requestedTier in setOf("profile", "log", "note")) requestedTier else "log"
        val key = clip(args["key"], 200)
        val resource = mergedResource(
            listOf(
                "memory:$scope",
                "tier=$tier",
                if (key.isEmpty()) "" else "key=$key",
                "fact=$fact",
            ),
        )
        return BotToolEffect(
            tool = "memory",
            operation = "memory.write",
            resource = resource,
            mutability = BotToolMutability.WRITE,
            policy = BotToolPolicy.AUTO,
            label = if (language == BotToolLanguage.ZH) {
                val clipped = clip(fact, 60)
                "写入记忆：" + clipped.ifEmpty { "一条事实" }
            } else {
                val clipped = clip(fact, 60)
                "Save a memory: " + clipped.ifEmpty { "one fact" }
            },
            detail = if (language == BotToolLanguage.ZH) {
                "写入 ${if (scope == "user") "用户共享" else "这个 Bot 的"}$tier 记忆。"
            } else {
                "Write one $tier fact into the ${if (scope == "user") "shared user" else "Bot"} memory."
            },
            execution = "memory",
            isMcp = isMcp,
        )
    }

    private fun readEffect(
        name: String,
        bareName: String,
        operation: String,
        zhLabel: String,
        args: Map<String, JsonValue>,
        language: BotToolLanguage,
        isMcp: Boolean,
    ): BotToolEffect = BotToolEffect(
        tool = bareName,
        operation = operation,
        resource = "*",
        mutability = BotToolMutability.READ,
        policy = BotToolPolicy.AUTO,
        label = if (language == BotToolLanguage.ZH) zhLabel else bareName,
        detail = defaultDetail(name, args, language),
        isMcp = isMcp,
    )

    private fun defaultDetail(
        name: String,
        args: Map<String, JsonValue>,
        language: BotToolLanguage,
    ): String {
        val preferred = listOf(
            "question", "options", "path", "caption", "title", "content",
            "query", "limit", "action", "detail",
        )
        val suppressed = setOf("body", "prompt", "message", "expectedStateToken", "acting_user_id")
        val keys = args.keys.filter { key ->
            key !in suppressed && args[key] !is JsonNull
        }.sortedWith { left, right ->
            val leftIndex = preferred.indexOf(left).let { if (it < 0) Int.MAX_VALUE else it }
            val rightIndex = preferred.indexOf(right).let { if (it < 0) Int.MAX_VALUE else it }
            if (leftIndex == rightIndex) left.compareTo(right) else leftIndex.compareTo(rightIndex)
        }
        val pairs = keys.take(6).map { key ->
            val value = args.getValue(key)
            val text = when (value) {
                is JsonObject, is JsonArray -> BotJson.canonical(value)
                else -> string(value)
            }
            "$key=${clip(text, 160)}"
        }
        val prefix = if (language == BotToolLanguage.ZH) "工具 $name" else "Tool $name"
        return if (pairs.isEmpty()) prefix else "$prefix（${pairs.joinToString(", ")}）"
    }

    private fun firstNonEmpty(vararg values: JsonValue?): JsonValue? =
        values.firstOrNull { string(it).isNotEmpty() }

    private fun string(value: JsonValue?): String = when (value) {
        null, JsonNull -> ""
        is JsonString -> value.value
        is JsonBool -> if (value.value) "true" else "false"
        is JsonNumber -> {
            val number = value.raw.toDoubleOrNull()
            if (number != null && number.isFinite() && number == Math.rint(number) &&
                number >= Long.MIN_VALUE.toDouble() && number < 9.223372036854775808E18
            ) {
                number.toLong().toString()
            } else {
                value.raw
            }
        }
        is JsonArray -> value.values.joinToString(",") { string(it) }
        is JsonObject -> BotJson.canonical(value)
    }

    private fun clip(value: JsonValue?, max: Int = 120): String = clip(string(value), max)

    private fun clip(value: String, max: Int): String {
        val text = value.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
        if (text.length <= max) return text
        return text.substring(0, maxOf(0, max - 1)) + "…"
    }

    private fun mergedResource(parts: List<String>): String =
        BotResourceNormalizer.normalize(parts.filter { it.isNotEmpty() }.joinToString("&"))
}

/** File-level facade matching the lane's `BotToolEffects` name. */
public object BotToolEffects {
    public fun policy(
        name: String,
        arguments: JsonValue = JsonObject(emptyMap()),
    ): BotToolPolicy = BotToolEffectClassifier.policy(name, arguments)

    public fun effect(
        name: String,
        arguments: JsonValue = JsonObject(emptyMap()),
        language: BotToolLanguage = BotToolLanguage.ZH,
    ): BotToolEffect = BotToolEffectClassifier.effect(name, arguments, language)
}
