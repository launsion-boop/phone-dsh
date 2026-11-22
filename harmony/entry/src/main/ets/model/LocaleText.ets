// SPDX-License-Identifier: MIT
// Static UI copy lookup (zh / en). Pure module: no platform imports, so the
// dictionary and fallback rules are testable on their own.
//
// Callers pass *literal* chrome strings (labels, placeholders, empty states).
// User text, model output, provider names, file names and paths must never go
// through here: `tr` is an exact-match lookup with a Chinese fallback, not a
// translator that can rewrite arbitrary content.

export class LocaleText {
  static readonly ZH: string = 'zh';
  static readonly EN: string = 'en';

  private static readonly EN_BY_ZH: Record<string, string> = {
    "队列状态未知，不能执行队列操作。": "Queue state is unknown; queue actions are unavailable.",
    "队列操作未确认：{0}": "Queue change was not confirmed: {0}",
    "队列操作已提交，但无法重新读取队列确认结果。": "The queue change was submitted, but its result could not be read back.",
    "队列操作没有被 Worker 的 sequenced projection 确认": "The Worker projection did not confirm the queue change",
    "队列操作没有被 Worker 确认。": "The Worker did not confirm the queue change.",
    "队列需要迁移，暂时无法读取。": "The queue needs migration and cannot be read yet.",
    "队列状态读取失败：{0}": "Could not read the queue: {0}",
    "关闭自动换行": "Disable wrapping",
    "自动换行": "Wrap lines",
    "关闭换行": "Disable wrapping",
    "开启换行": "Enable wrapping",
    "展开全部 {0} 行": "Expand all {0} lines",
    "问题请求无效：{0}": "Invalid question request: {0}",
    "请先完成这道问题。": "Complete this question first.",
    "放弃整组问题": "Dismiss all questions",
    "自定义回答": "Custom answer",
    "上一题": "Previous",
    "下一题": "Next",
    "跳过": "Skip",
    "正在提交…": "Submitting\u2026",
    "这个问题没有可回答的选项。": "This question has no answer options.",
    "推荐": "Recommended",
    "模拟运行视图退出": "Simulate renderer exit",
    "正在读取已测量的写入…": "Loading measured writes…",
    "产物测量失败：宿主无法读取本会话的写入记录。": "Artifact measurement failed. This session’s write records could not be read.",
    "未测量：宿主没有报告本会话的写入范围，无法判断有没有产物。": "Not measured. No write range was reported for this session.",
    "已测量：本会话没有写入产物": "Measured: no artifacts were written in this session.",
    "测量范围来自宿主已确认的写入记录；空列表表示该范围内没有真实写入，而不是目录扫描为空。": "The range comes from confirmed write records. An empty list means no files were written in that range.",
    "只列出测量范围内真实写入 /dsh/workspace、当前仍存在的常规文件；已删除、工作区外或未测量的文件不会列出。": "Lists measured writes to /dsh/workspace that still exist as regular files. Deleted, unmeasured, or out-of-workspace files are excluded.",

    // Common chrome and state words.
    '未知': 'Unknown',
    '不可用': 'Unavailable',
    '未设置': 'Not set',
    '返回': 'Back',
    '完成': 'Done',
    '取消': 'Cancel',
    '保存': 'Save',
    '关闭': 'Close',
    '删除': 'Delete',
    '重命名': 'Rename',
    '刷新': 'Refresh',
    '重试': 'Retry',
    '更多': 'More',
    '进入': 'Open',
    '已选': 'Selected',
    '设置': 'Settings',
    '关闭提示': 'Close notice',
    '没有可显示的内容': 'Nothing to show',
    '正在读取…': 'Loading…',
    '正在读取文件…': 'Loading files…',
    '正在读取会话…': 'Loading sessions…',
    '读取失败': 'Load failed',
    '已就绪': 'Ready',
    '运行中': 'Running',
    '失败': 'Failed',
    '已停止': 'Stopped',
    '刚刚': 'just now',
    '{0} 分钟前': '{0} min ago',
    '{0} 小时前': '{0} hr ago',
    '{0}月{1}日': '{0}/{1}',
    '{0} 项': '{0} items',
    '{0} 个': '{0}',
    '{0} 个会话': '{0} sessions',
    '{0} 行': '{0} rows',
    '未命名文件夹': 'Untitled folder',
    '默认文件夹': 'Default folder',
    '当前': 'Current',
    '当前 {0} pt': 'Current {0} pt',
    '{0} pt': '{0} pt',

    // Engine / permission / appearance / language labels.
    '引擎就绪': 'Engine ready',
    '引擎启动中': 'Engine starting',
    '引擎恢复中': 'Engine recovering',
    '引擎未启动': 'Engine stopped',
    '引擎启动失败': 'Engine failed',
    '仅可查看': 'Read only',
    '工作区内修改': 'Workspace write',
    '完全权限': 'Full access',
    '跟随系统': 'System',
    '浅色': 'Light',
    '深色': 'Dark',
    '中文': '中文',
    'English': 'English',

    // Settings index.
    '通用': 'General',
    '模型与智能体': 'Models & agents',
    '模型服务': 'Model service',
    'Agent 预设': 'Agent presets',
    '插件与工具': 'Plugins & tools',
    '权限与隐私': 'Permissions & privacy',
    '新会话默认权限': 'Default new-session permission',
    '手机权限': 'Phone permissions',
    '网络访问': 'Network access',
    '对话': 'Conversation',
    '外观': 'Appearance',
    '语言': 'Language',
    '字号': 'Text size',
    '代码': 'Code',
    '终端': 'Terminal',
    '会话内容': 'Conversation',
    '工作过程': 'Work process',
    '快捷键': 'Shortcuts',
    '会话与文件': 'Sessions & files',
    '文件夹': 'Folders',
    '已归档会话': 'Archived sessions',
    '关于': 'About',
    '许可证': 'Licenses',
    '配置文档': 'Configuration document',
    '工作区': 'Workspace',
    '聊天外观': 'Chat appearance',
    '只影响之后新开的会话，当前会话保持不变。':
      'Only affects new sessions; the current session is unchanged.',
    '深色仍在适配中；默认浅色与官方 402pt 基线一致。':
      'Dark mode is still being tuned; the default light theme matches the official 402pt baseline.',
    '字号大小': 'Text size',
    '字体（留空使用系统默认）': 'Font (empty uses the system default)',

    // Font size page.
    '预览': 'Preview',
    '保存请求已提交': 'Save request submitted',
    '减小': 'Decrease',
    '增大': 'Increase',
    '减小字号': 'Decrease text size',
    '增大字号': 'Increase text size',
    'Phone DSH 在这台手机上原生显示。': 'Phone DSH renders natively on this phone.',
    '正文字号会作用于消息正文；工具详情使用更小的字号。':
      'Text size applies to message bodies; tool details use a smaller size.',
    '代码字号会作用于代码块与代码预览。':
      'Code size applies to code blocks and code previews.',
    '终端字号会作用于终端与命令输出。':
      'Terminal size applies to the terminal and command output.',

    // Drawer / sessions.
    '会话': 'Sessions',
    '会话列表': 'Sessions',
    '搜索会话': 'Search sessions',
    '新会话': 'New session',
    '本轮结束后可用': 'Available after this turn',
    '定时任务': 'Automations',
    '添加工作文件夹': 'Add workspace folder',
    '还没有文件夹。点右上角的 + 新建一个，会话和文件都能放进去。':
      'No folders yet. Tap + in the top-right to create one; sessions and files can live there.',
    '新建工作文件夹': 'New workspace folder',
    '没有匹配的会话': 'No matching sessions',
    '还没有会话': 'No sessions yet',
    '未分组': 'Ungrouped',
    '宿主没有报告会话列表，无法判断有没有会话。':
      'The host did not report a session list, so it is unknown whether sessions exist.',
    '名称': 'Name',
    '展开工作文件夹的会话': 'Expand folder sessions',
    '收起工作文件夹的会话': 'Collapse folder sessions',
    '在这里新建会话': 'New session here',
    '工作文件夹的选项': 'Folder options',
    '已置顶': 'Pinned',
    '会话选项': 'Session options',
    '已归档，可在 设置 › 已归档会话 里找回':
      'Archived. Find it under Settings › Archived sessions.',

    // Chat chrome.
    '复制': 'Copy',
    '已复制': 'Copied',
    '复制详情': 'Copy details',
    '复制代码': 'Copy code',
    '代码，复制': 'Code, copy',
    '{0} 代码，复制': '{0} code, copy',
    '思考': 'Thinking',
    '正在执行': 'Working',
    '还有 {0} 个待确认': '{0} more pending',
    '输入消息': 'Message',
    '发送': 'Send',
    '停止': 'Stop',
    '排队中': 'Queued',
    '排队中 {0} 条': '{0} queued',
    '已排队': 'Queued',
    '已并入当前任务': 'Merged into current task',
    '发送中…': 'Sending…',
    '需要你的回答': 'Your answer is needed',
    '需要授权': 'Approval needed',
    '需要回答': 'Answer needed',
    '允许一次': 'Allow once',
    '拒绝': 'Deny',
    '提交': 'Submit',
    '回合失败': 'Turn failed',
    '发送失败，草稿已保留': 'Send failed; draft kept',
    '工具失败': 'Tool failed',
    '展开': 'Expand',
    '收起': 'Collapse',
    '已展开': 'Expanded',
    '已折叠': 'Collapsed',
    '没有更多详情': 'No more details',
    '当前预览：{0}': 'Current preview: {0}',

    // Detail pages / workbench / preview.
    '文件': 'Files',
    '命令': 'Command',
    '在此运行命令': 'Run a command here',
    '运行': 'Run',
    '输出': 'Output',
    '运行结果会显示在这里。': 'Results will appear here.',
    '宿主没有报告本次回合写出的文件，无法判断有没有':
      'The host did not report files written this turn, so it is unknown whether any exist.',
    '本次回合还没有写出文件': 'No files written this turn',
    '工具写出文件后显示在这里': 'Files written by tools appear here',
    '打开': 'Open',
    '没有可预览的内容': 'Nothing to preview',
    '宿主没有为这个路径报告文本预览。':
      'The host did not report a text preview for this path.',
    '只读展示宿主 hello 报告的 shell 能力；本页不启动终端，也不执行命令。':
      'Read-only shell capabilities reported by the host; this page does not start a terminal or run commands.',

    // Secondary settings pages.
    '通知权限': 'Notification permission',
    '电池优化': 'Battery optimization',
    '返回手势': 'Back gesture',
    '已归档': 'Archived',

    // Additional core chrome used by the settings/detail slices.
    '当前预览：': 'Current preview: ',
    '重置': 'Reset',
    '打开文件列表': 'Open file list',
    '引擎': 'Engine',
    '引擎状态': 'Engine status',
    '重新启动引擎': 'Restart engine',
    '运行状态': 'Runtime status',
    '运行时详情': 'Runtime details',
    '配置文件': 'Config file',
    '导出诊断': 'Export diagnostics',
    '导出当前会话': 'Export current session',
    '设备连接': 'Device connection',
    '版本': 'Version',
    '开源许可': 'Open-source licenses',
    '关于 Phone DSH': 'About Phone DSH',
    '平台差异': 'Platform differences',
    '读取不到这项状态，未做任何假设':
      'This status is unavailable; no assumptions were made',
    '测试': 'Test',
    '添加': 'Add',
    '编辑': 'Edit',
    '状态': 'Status',
    '地址': 'Address',
    '服务 URL': 'Service URL',
    '密钥': 'API key',
    '密钥状态': 'Key status',
    '显示名称': 'Display name',
    '默认模型': 'Default model',
    '推理强度': 'Reasoning effort',
    '编码': 'Encoder',
    '当前策略': 'Current policy',
    '当前选择': 'Current selection',
    '最近出错': 'Last error',
    '导入': 'Import',
    '新建': 'New',
    '新建文件夹': 'New folder',
    '新建任务': 'New task',
    '新建自动化': 'New automation',
    '编辑自动化': 'Edit automation',
    '定时': 'Schedule',
    '文件读取失败': 'Failed to read file',
    '工作区还没有文件': 'No files in the workspace yet',
    '连接引擎后可导入或浏览工作区':
      'Connect the engine to import or browse the workspace',
    '搜索文件': 'Search files',
    '没有匹配的文件': 'No matching files',
    '搜索后端': 'Search backend',
    '网页搜索': 'Web search',
    '网页搜索与抓取': 'Web search & fetch',
    '白名单': 'Allowlist',
    '策略': 'Policy',
    '规则语法': 'Rule syntax',
    '精确主机': 'Exact host',
    '通配后缀': 'Wildcard suffix',
    '包含端口': 'Include port',
    '任意主机': 'Any host',
    '任意端口': 'Any port',
    '空名单': 'Empty allowlist',
    '可用': 'Available',
    '未提供': 'Not provided',
    '只读': 'Read only',
    '报告': 'Report',
    '产物': 'Artifacts',
    '本会话产物': 'Session artifacts',
    '配置': 'Configuration',
    '配置项已不存在，请刷新': 'The item no longer exists; refresh',
    '说明': 'Description',
    '操作': 'Action',
    '选择': 'Select',
    '切换': 'Switch',
    '置顶': 'Pin',
    '取消置顶': 'Unpin',
    '归档': 'Archive',
    '重命名会话': 'Rename session',
    '重命名文件夹': 'Rename folder',
    '文件夹名称': 'Folder name',
    '删除文件夹': 'Delete folder',
    '删除这个会话？': 'Delete this session?',
    '删除这个文件夹？': 'Delete this folder?',
    '删除后无法恢复': 'This cannot be undone',
    '进入设置': 'Open settings',
    '当前会话': 'Current session',
    '当前文件夹不能删除': 'The current folder cannot be deleted',
    '里面的会话会留着，只是不再放在这个文件夹里。':
      'Sessions inside are kept; they just leave this folder.',
    '还没有工作文件夹': 'No workspace folders yet',
    '还没有交互记录': 'No interaction records yet',
    '还没有定时任务': 'No scheduled tasks yet',
    '还没有 MCP 服务器': 'No MCP servers yet',
    '还没有可导出的诊断报告': 'No diagnostic report to export yet',
    '没有在线设备': 'No online devices',
    '正在读取产物…': 'Loading artifacts…',
    '正在读取命令…': 'Loading command…',
    '正在读取定时任务…': 'Loading scheduled tasks…',
    '正在读取探针结果…': 'Loading probe results…',
    '正在读取插件…': 'Loading plugins…',
    '正在读取 MCP 服务器…': 'Loading MCP servers…',
    '插件列表读取失败': 'Failed to load plugin list',
    '探针结果读取失败': 'Failed to load probe results',
    '定时任务读取失败': 'Failed to load scheduled tasks',
    '会话列表加载失败': 'Failed to load sessions',
    '上一级': 'Up one level',
    '导出请求已提交': 'Export request submitted',
    '运行请求已提交': 'Run request submitted',
    '尚未实现': 'Not implemented yet',
    '未接入设备连接器': 'No device connector connected',
    '局域网连接器': 'LAN connector',
    '蓝牙连接器': 'Bluetooth connector',
    '真实连接设备': 'Connect a real device',
    '真实传输': 'Real transport',
    '真实传输尚未实现。此页只展示已注入连接器发布的状态，不会主动发起扫描。':
      'Real transport is not implemented yet. This page only shows status published by an injected connector and never starts a scan.',
    '当前版本不会扫描、配对或伪造在线设备。':
      'This version does not scan, pair, or fake online devices.',
    '连接器未发布真实在线设备；打开设备会话需要宿主提供真实的 Session。':
      'The connector has not published a real online device; a real host session is required to open device sessions.',
    '设备会话 · 只读监视': 'Device session · read-only monitor',
    '只读监视，请在设备上处理输入与确认':
      'Read-only monitor; enter and confirm on the device',

    // Workspace, scheduler, plugin, shell and artifact copy.
    '工作文件夹': 'Workspace folder',
    '图片': 'Images',
    '图片预览': 'Image preview',
    '图片加载失败': 'Image failed to load',
    '图片加载失败：': 'Image failed to load: ',
    '图片加载中…': 'Loading image…',
    '未配置图片加载器': 'No image loader is configured',
    '图片地址为空': 'Image URL is empty',
    '图片数据为空': 'Image data is empty',
    '轻触关闭': 'Tap to close',
    '宿主没有报告工作区文件，无法判断有没有':
      'The host did not report workspace files, so it is unknown whether any exist.',
    '换个词再找。': 'Try another search term.',
    '会话把生成的文件放在文件夹里。新建一个文件夹给它用。':
      'Sessions put generated files in folders. Create a folder for it.',
    '删除当前文件夹会被宿主拒绝；先切换到其他文件夹再删除。':
      'The host will reject deleting the current folder; switch to another folder before deleting.',
    '任务名称（最多 120 字符）': 'Task name (up to 120 characters)',
    '提醒内容': 'Reminder content',
    '到点后要执行的内容': 'What to run when due',
    '重复规则': 'Repeat rule',
    '多少秒后提醒': 'Seconds until reminder',
    '例如 600': 'e.g. 600',
    '触发时间（ISO 8601，含时区）': 'Trigger time (ISO 8601, with time zone)',
    '每隔多少秒提醒': 'Reminder interval in seconds',
    '例如 3600': 'e.g. 3600',
    '本地时间（HH:mm:ss）': 'Local time (HH:mm:ss)',
    '时区（IANA）': 'Time zone (IANA)',
    '星期（1-7，逗号分隔）': 'Weekdays (1-7, comma-separated)',
    'Cron 表达式（五段）': 'Cron expression (five fields)',
    '保存走 Worker 已有的定时任务接口；失败时会保留这份草稿。':
      'Saving uses the Worker\'s existing scheduled-task API; the draft is kept if it fails.',
    '宿主没有报告定时任务，无法判断有没有；不会用 0 条代替':
      'The host did not report scheduled tasks, so it is unknown whether any exist; 0 is not substituted.',
    '到点让它自己跑,结果回到原会话。':
      'It runs on its own when due; results return to the original session.',
    '活动': 'Activity',
    '删除此自动化任务？': 'Delete this automation?',
    '最近投递': 'Recent deliveries',
    '宿主没有报告投递记录，无法判断有没有。':
      'The host did not report deliveries, so it is unknown whether any exist.',
    '新数值': 'New value',
    '数字': 'Number',
    '允许的模型路由': 'Allowed model routes',
    '安装、启用和配置插件': 'Install, enable, and configure plugins',
    '已加载插件': 'Loaded plugins',
    '宿主没有报告插件列表，无法判断有没有':
      'The host did not report a plugin list, so it is unknown whether any exist.',
    '引擎还没给出插件列表': 'The engine has not provided a plugin list yet',
    '只有真正加载起来的插件才会显示为已启用。':
      'Only plugins that actually load are shown as enabled.',
    '本机管理范围': 'Managed on this device',
    '已加载插件清单': 'Loaded plugin list',
    'MCP 网络与密钥': 'MCP network & keys',
    '这一页显示引擎里真正装着的插件。保存后马上生效。只有真正加载起来的插件才会显示为已启用；没装的,这里不会假装它在跑。':
      'This page shows the plugins actually installed in the engine. Changes apply immediately after saving. Only plugins that actually load are shown as enabled; anything not installed is not pretended to be running here.',
    '命令不能为空': 'Command cannot be empty',
    '命令读取失败': 'Failed to load command',
    '宿主没有报告 shell 能力，无法判断有没有':
      'The host did not report shell capabilities, so it is unknown whether any exist.',
    '没有可显示的 shell 能力': 'No shell capabilities to show',
    '宿主明确报告了空的加速器与挂载列表':
      'The host explicitly reported empty accelerator and mount lists',
    '宿主报告了空快照；不会用空报告冒充已测量':
      'The host reported an empty snapshot; an empty report is not passed off as measured',
    '写好的文件放进仓库的验收目录，文件名用日期和设备名。当前宿主提供的是导出对话记录动作；诊断包写入尚未提供，本页不伪造文件。':
      'Written files go into the repository\'s acceptance directory, named by date and device. The current host provides an export-conversation action; writing a diagnostic bundle is not yet available, and this page does not fake it.',
    '传输能力': 'Transport capabilities',
    '设备与这个固定 Session 的真实交互会显示在这里。':
      'Real interaction with this pinned Session will appear here.',
    '无法读取产物': 'Cannot load artifacts',
    '宿主没有报告本会话产物，无法判断有没有':
      'The host did not report session artifacts, so it is unknown whether any exist.',
    '本会话 还没有已确认归属的产物':
      'This session has no artifacts confirmed to belong to it',
    '此会话生成或导入的文件会显示在这里。没有真实会话来源的记录不会被归入本会话。':
      'Files generated or imported by this session will appear here. Records without a real session source are not attributed to this session.',
    '宿主没有报告探针结果，无法判断有没有跑过；不会显示 0 条':
      'The host did not report probe results, so it is unknown whether any have run; 0 is not shown.',
    '这次启动还没有跑过探针': 'No probes have run in this launch yet',
    '探针只在运行后产生记录；设备上的数值在运行前保持未知':
      'Probes produce records only after they run; device values stay unknown until then.',
    '未测量的值显示为未知，不会当成 0。':
      'Unmeasured values are shown as unknown, not as 0.',

    // Model services, web search, MCP, runtime and network-policy copy.
    '上次启动失败后引擎不会自动重试。重新启动会确认这次失败并重新启动，会话数据不受影响。':
      'The engine does not retry automatically after a failed start. Restarting acknowledges the failure and starts it again; session data is unaffected.',
    '显示名称、服务 URL 和默认模型不能为空':
      'Display name, service URL, and default model cannot be empty',
    '密钥需至少 8 个可打印 ASCII 字符，本次未保存':
      'The key must be at least 8 printable ASCII characters; nothing was saved',
    '已保存；地址与模型在下次启动本地引擎时生效；密钥用于同一服务的后续请求':
      'Saved; the address and model take effect the next time the local engine starts; the key is used on later requests to the same service',
    '先保存这个模型服务，再测试连接。':
      'Save this model service before testing the connection.',
    '测试请求已完成，结果见上方提示。':
      'The test request completed; see the notice above for the result.',
    '已选择；下次启动本地引擎时生效。':
      'Selected; takes effect the next time the local engine starts.',
    '已删除本机保存的模型服务与密钥。':
      'Deleted the model service and key saved on this device.',
    '已删除此模型服务的密钥。': 'Deleted this model service\'s key.',
    '已存密钥': 'Key saved',
    '无密钥': 'No key',
    '已选择': 'Selected',
    '删除这个模型服务与它的密钥？': 'Delete this model service and its key?',
    '只删除这个模型服务保存的密钥；其他模型服务的密钥不会被改动。运行中的模型服务需要先停止引擎。':
      'Deletes only the key saved for this model service; other model services\' keys are untouched. A running model service requires stopping the engine first.',
    '还没有保存的模型服务。添加一个后，下次启动本地引擎时生效。':
      'No saved model services yet. After adding one, it takes effect the next time the local engine starts.',
    '添加模型服务': 'Add model service',
    '生效方式': 'When it takes effect',
    '密钥只存在这台手机上；每个模型服务使用自己的 AssetStore 别名。配置、日志、网页里都没有它。':
      'The key exists only on this phone; each model service uses its own AssetStore alias. It appears nowhere in configuration, logs, or the web UI.',
    '连接信息': 'Connection info',
    '例如 DeepSeek': 'e.g. DeepSeek',
    '已保存，输入以替换': 'Saved; enter a new key to replace',
    '粘贴或输入 API 密钥': 'Paste or enter an API key',
    '删除密钥': 'Delete key',
    '删除已保存的密钥？': 'Delete the saved key?',
    '只删除这个模型服务的密钥；配置仍在，但在重新填入密钥前无法使用。':
      'Deletes only this model service\'s key; the configuration remains, but it cannot be used until a key is entered again.',
    '启动本地引擎': 'Start local engine',
    '密钥只存在这台手机上；配置、日志、网页里都没有它。':
      'The key exists only on this phone; it appears nowhere in configuration, logs, or the web UI.',
    '用哪一份搜索': 'Which search to use',
    '跟随官方模型服务（自动）': 'Follows the official model service (automatic)',
    'DeepSeek 官方 Search / Fetch API': 'Official DeepSeek Search / Fetch API',
    '与模型服务同一把（只读）': 'Same key as the model service (read only)',
    '当前引擎在启动时读取模型服务配置。':
      'The engine reads your model settings at startup.',
    '什么时候生效': 'When it takes effect',
    '保存或更换模型密钥后，需要重启本地引擎才生效；重启不会动文件夹和会话。':
      'After saving or replacing the model key, restart the local engine for it to take effect; restarting does not touch folders or sessions.',
    '停止本地引擎': 'Stop local engine',
    '还要知道': 'Also good to know',
    '搜索和抓取共用模型密钥。你只需要在「模型服务」保存一次。':
      'Search and fetch share your model key. Save it once under Model Services.',
    'MCP 服务器': 'MCP servers',
    '服务器': 'Server',
    '读取不到 MCP 服务器列表': 'Cannot load the MCP server list',
    '读取不到 MCP 服务器列表，未做任何假设':
      'Cannot load the MCP server list; no assumptions were made',
    '注册表由 Worker 的 /dsh/home/mcp.json 提供；本页只读读取':
      'The registry comes from the Worker\'s /dsh/home/mcp.json; this page only reads it',
    '已连接': 'Connected',
    '列表来自 Worker 的 phone/mcpList；状态和工具数都是宿主报告的实时值，本页不改写注册表。':
      'The list comes from the Worker\'s phone/mcpList; status and tool counts are live values reported by the host, and this page does not modify the registry.',
    '刷新注册表': 'Refresh registry',
    'MCP 服务器表单（只读）': 'MCP server form (read-only)',
    '本宿主没有 phone/mcpUpsert 与 phone/mcpRemove；保存或删除都不会落盘，也不会显示成功。':
      'This host has no phone/mcpUpsert or phone/mcpRemove; saving or deleting writes nothing and never shows success.',
    'MCP 服务器（只读）': 'MCP server (read-only)',
    '添加 MCP 服务器（只读）': 'Add MCP server (read-only)',
    '无': 'None',
    '宿主报告的注册表、地址与工具': 'Registry, address, and tools reported by the host',
    '停止本地引擎？': 'Stop the local engine?',
    '正在跑的任务会停下来；会话和文件都还在。':
      'Running tasks will stop; sessions and files are kept.',
    '没有可显示的运行时信息': 'No runtime information to show',
    '宿主没有报告这些值；不会用 0 或默认档位填充。':
      'The host did not report these values; they are not filled with 0 or default levels.',
    '本次运行': 'This run',
    '模型调用': 'Model calls',
    '输入 Token': 'Input tokens',
    '输出 Token': 'Output tokens',
    '宿主没有报告最近一次出错；本页不推断成功。':
      'The host did not report the latest error; this page does not infer success.',
    // Read-only network-policy facts (Egress page). The legacy egressHosts list
    // is not an active allowlist, so none of these rows present it as one.
    '出网策略（只读）': 'Egress policy (read only)',
    '正在读取出网策略…': 'Loading egress policy…',
    '宿主没有报告活动路由；未知不等于拒绝。下面只显示宿主实际执行的固定规则。':
      'The host does not report an active route; unknown is not denied. The fixed rules below are the ones the host actually enforces.',
    '没有可显示的策略事实': 'No policy facts to show',
    '宿主没有报告出网规则；本页不推断放行或拒绝。':
      'The host did not report egress rules; this page does not infer allow or deny.',
    '本页只读：显示宿主实际执行的规则；不提供白名单编辑或出网授权。':
      'Read only: shows the rules the host actually enforces; no allowlist editing or egress grant is offered.',
    '当前模型路由': 'Active model route',
    '未知（本地引擎未运行）': 'Unknown (local engine is not running)',
    '本地引擎未运行，没有活动路由可读取。这是未测量，不是出网被拒绝。':
      'The local engine is not running, so no active route can be read. This is unmeasured, not denied.',
    '无活动模型服务': 'No active model service',
    '本地引擎正在运行，但启动时没有模型服务；模型请求没有可转发的目标。':
      'The local engine is running, but no model service was configured at startup; model requests have no target to forward to.',
    '仅一个活动模型服务': 'One active model service',
    '只转发到 {0} 的模型协议路径；不会转发到其他主机或路径。':
      'Forwards only the model protocol paths of {0}; no other host or path is forwarded.',
    '启动记录不可用': 'Startup record is unusable',
    '启动记录里的模型服务地址不是可用的 https 地址；模型请求会被拒绝。':
      'The model service address recorded at startup is not a usable https address; model requests are denied.',
    '放行的模型路径': 'Admitted model paths',
    '模型协议路径 + 官方工具路径': 'Model protocol paths + official tool paths',
    '路径范围由当前模型服务的基地址和 HostHttpProxy 的模型协议表决定；官方 DeepSeek 模型服务在启动放行时另加 /v1/tools/search 与 /v1/tools/fetch 两条 POST。其余路径拒绝，不改道、不跟随重定向。':
      'The path scope comes from the active model service base URL and HostHttpProxy\'s model-protocol table; an eligible official DeepSeek service adds only POST /v1/tools/search and /v1/tools/fetch at boot. Anything else is refused, never rerouted or followed.',
    '其他 Worker 出网': 'Other Worker egress',
    '除官方工具外默认拒绝': 'Denied by default except the official tools',
    '没有通用白名单或 MCP 出网授权；官方 Search/Fetch 仅按上述精确路径复用模型密钥，Worker 不能把宿主密钥带到其他主机。':
      'There is no general allowlist or MCP egress grant; official Search/Fetch reuses the model key only on the exact paths above. The Worker cannot take host credentials to another host.',
    '传输与密钥': 'Transport and key',
    '仅 HTTPS；宿主逐请求注入': 'HTTPS only; host injects per request',
    '只接受 https；宿主每次模型请求从该服务的 AssetStore 别名读取密钥并注入；请求方自带的凭证头会被丢弃，重定向会被拒绝。':
      'Accepts https only; for each model request the host reads the key from that service\'s AssetStore alias and injects it; caller credential headers are dropped and redirects are refused.',
    'Markdown 远程图片': 'Markdown remote images',
    'UI 独立读取': 'Read independently by the UI',
    'http(s) 图片由界面直接读取，不经过模型代理、不带模型密钥；上限 8 MiB，最多 3 次已验证重定向，拒绝带用户信息的地址。':
      'http(s) images are read directly by the UI, not through the model proxy, and carry no model key; the bound is 8 MiB with at most 3 validated redirects, and addresses with user information are refused.',
    '连接测试': 'Connection test',
    '仅显式发起': 'Only on explicit request',
    '只在模型服务页点击测试时读取该服务已保存的密钥并请求该服务；本页不探测远端是否可达，也不报告可达。':
      'A test runs only when you tap test on the model service page; it reads that service\'s saved key and requests that service. This page does not probe or report remote reachability.',
    '旧 egressHosts 配置': 'Legacy egressHosts setting',
    '不参与本宿主出网': 'Not used for host egress',
    '本宿主不把 settings.egressHosts 当作生效白名单；旧配置既不放行也不拒绝任何请求。':
      'This host does not treat settings.egressHosts as the active allowlist; the legacy setting neither allows nor denies any request.',
    '与 Android 的差异': 'Difference from Android',
    '没有可写的通用白名单': 'No writable general allowlist',
    'Android 有 allowedUpstreamHosts 和 MCP 精确授权；本宿主没有可写的 HostGrant API，也不显示伪造的白名单。':
      'Android has allowedUpstreamHosts and exact MCP grants; this host has no writable HostGrant API and does not show a fabricated allowlist.',

    // Phone-permission matrix: groups, capability titles, read states, and the
    // fixed purposes/reasons published by HostPhonePermissions.
    '个人信息': 'Personal information',
    '设备与传感器': 'Devices & sensors',
    '系统与通知': 'System & notifications',
    '文件与数据': 'Files & data',
    '家庭与媒体': 'Home & media',
    '已允许': 'Allowed',
    '未授予': 'Not granted',
    '常开': 'Always on',
    '已开启': 'On',
    '已关闭': 'Off',
    '通讯录': 'Contacts',
    '日历': 'Calendar',
    '提醒事项': 'Reminders',
    '健康': 'Health',
    '照片': 'Photos',
    '相机': 'Camera',
    '麦克风': 'Microphone',
    '语音识别': 'Speech recognition',
    '定位': 'Location',
    '运动与健身': 'Motion & fitness',
    '蓝牙': 'Bluetooth',
    '本地网络': 'Local network',
    '通知': 'Notifications',
    '面容确认': 'Face confirmation',
    '专注模式': 'Focus mode',
    '实时活动': 'Live activities',
    '快捷指令': 'Shortcuts',
    '文件与文件夹': 'Files & folders',
    '剪贴板': 'Clipboard',
    '设备状态': 'Device status',
    '家庭': 'Home',
    '音乐': 'Music',
    '仅在你查询时读取联系人；电话和邮箱默认脱敏。':
      'Reads contacts only when you query them; phone numbers and emails are masked by default.',
    '读取你选择时间范围内的日程，并在确认后创建日程。':
      'Reads events in the time range you choose and creates events after confirmation.',
    '读取提醒事项，并在确认后创建或完成提醒。':
      'Reads reminders and creates or completes them after confirmation.',
    '将读取：步数、睡眠、心率、静息心率、HRV、训练、体重、正念；不写入健康数据。':
      'Will read: steps, sleep, heart rate, resting heart rate, HRV, workouts, weight, mindfulness; does not write health data.',
    '读取照片元数据，用于查找最近或指定日期的照片。':
      'Reads photo metadata to find recent photos or photos from a specific date.',
    '仅在你发起拍摄时采集照片或扫描文稿。':
      'Captures photos or scans documents only when you start a capture.',
    '仅在你发起录音时采集音频。': 'Captures audio only when you start a recording.',
    '将你选择的录音转换为文字。': 'Converts the recording you select to text.',
    '仅在你查询时获取一次当前位置。':
      'Gets your current location once, only when you query it.',
    '读取你指定时间内的活动与步数。':
      'Reads activity and steps for the time range you specify.',
    '仅在你发起扫描时发现附近蓝牙设备。':
      'Discovers nearby Bluetooth devices only when you start a scan.',
    '点击后通过系统网络浏览器实测局域网发现能力。':
      'Tests LAN discovery through the system network browser when tapped.',
    '仅在你确认后发送本地通知，不接收远程推送。':
      'Sends local notifications only after your confirmation; does not receive remote push.',
    '启用后，敏感写操作前需要系统生物识别确认；这不是单独系统授权。':
      'When enabled, sensitive write operations require system biometric confirmation; this is not a separate system grant.',
    '读取系统当前是否处于专注（勿扰）状态。':
      'Reads whether the system is currently in Focus (Do Not Disturb) mode.',
    '通过系统的实时活动机制创建和更新进行中的活动。':
      'Creates and updates ongoing activities through the system live-activities mechanism.',
    '打开指定的快捷指令；跨 App 执行结果无法观测，不承诺已完成。':
      'Opens the specified shortcut; cross-app execution results cannot be observed, so completion is not promised.',
    '通过系统选择器授权你选择的文件夹，不读取其它 App 容器。':
      'Grants access to the folder you choose via the system picker; does not read other apps\' containers.',
    '仅在你明确调用时读取或写入系统剪贴板。':
      'Reads or writes the system clipboard only when you explicitly invoke it.',
    '只读显示设备型号、系统版本和当前时间，始终启用。':
      'Shows device model, system version, and current time read-only; always enabled.',
    '读取你授权的家庭与配件，并在确认后写入指定特征。':
      'Reads homes and accessories you authorize and writes specified characteristics after confirmation.',
    '通过系统音乐目录播放你指定的真实曲目。':
      'Plays the actual tracks you specify via the system music library.',
    '读取本应用的通知开关（isNotificationEnabled）；通知不通过运行时权限授予，本页不弹系统对话框。':
      'Reads this app\'s notification switch (isNotificationEnabled); notifications are not granted through runtime permissions, and this page raises no system dialog.',
    '清单已声明，平台返回未授予；本宿主未发起权限请求，无法区分未请求与已拒绝。':
      'Declared in the manifest; the platform returned not granted. This host never requests permissions, so it cannot distinguish never requested from denied.',
    '平台授权状态由 checkAccessTokenSync 读取。':
      'The platform grant state is read via checkAccessTokenSync.',
    'INTERNET 为 normal 权限，实际授权已读；网络访问权限不代表局域网发现已验证。':
      'INTERNET is a normal permission and its grant has been read; network access permission does not mean LAN discovery is verified.',
    '本宿主没有可读取的授权状态。': 'This host has no readable grant state.',
    'HarmonyOS 无系统提醒事项授权；本宿主未接入该能力。':
      'HarmonyOS has no system reminders authorization; this host does not integrate this capability.',
    '宿主未声明健康数据权限，也未接入健康数据读取。':
      'The host declares no health data permission and has not integrated health data reads.',
    '本宿主未接入生物识别调用；没有可读的独立系统授权项。':
      'This host does not integrate biometric calls; there is no readable standalone system grant.',
    '本宿主未接入系统勿扰状态读取。':
      'This host does not integrate system Do Not Disturb status reads.',
    '本宿主未接入实时活动。': 'This host does not integrate live activities.',
    'HarmonyOS 无系统快捷指令授权；本宿主未接入。':
      'HarmonyOS has no system shortcuts authorization; this host does not integrate it.',
    '系统 Picker 按 URI 授权，不等同于整目录持久授权。':
      'The system picker grants by URI, which is not the same as persistent whole-directory access.',
    '剪贴板 API 无系统授权项；本宿主未接入。':
      'The clipboard API has no system grant item; this host does not integrate it.',
    'HarmonyOS 无家庭框架授权；本宿主未接入。':
      'HarmonyOS has no home framework authorization; this host does not integrate it.',
    '宿主未接入系统媒体目录；没有可读的音乐授权。':
      'The host does not integrate the system media library; there is no readable music grant.',

    // Chat composer, empty states, menus and state chips.
    '发消息或创建任务，/ 调用指令，@ 文件或对话':
      'Message or create a task; / for commands, @ for files or chats',
    '补充当前任务…': 'Add to the current task…',
    '排入下一轮…': 'Queue for the next turn…',
    '繁忙时的发送行为': 'Send while busy',
    '排到下一轮': 'Queue for the next turn',
    '补充当前任务': 'Add to the current task',
    '默认': 'Default',
    '导出对话记录': 'Export conversation',
    '打开会话列表': 'Open sessions',
    '连接设备': 'Connect device',
    '引擎还没启动': 'Engine not started',
    '启动之后就能开始。': 'Start it to begin.',
    '等待引擎连接…': 'Waiting for the engine…',
    '引擎就绪后这里显示对话': 'The conversation appears here once the engine is ready',
    '还差一步:配好模型服务': 'One step left: set up a model service',
    '选一个模型服务，就能开始。': 'Choose a model service to begin.',
    '去配置模型服务': 'Set up model service',
    '还没有消息': 'No messages yet',
    '发一条消息，开始这个会话。': 'Send a message to start this session.',
    '正在停止': 'Stopping',
    '问题': 'Question',
    '授权': 'Approval',
    '已选中': 'Selected',
    '未选中': 'Not selected',
    '输入你的答案': 'Enter your answer',
    '提交回答': 'Submit answer',
    '调用指令': 'Run command',
    '引用文件或对话': 'Reference file or chat',
    '没有匹配的文件或对话': 'No matching files or chats',
    '正在读取引用候选…': 'Loading reference candidates…',
    '引用候选读取失败': 'Reference candidates could not be loaded',
    '引用候选读取失败：{0}': 'Reference candidates failed to load: {0}',
    '本地运行时尚未就绪，无法读取引用候选':
      'The local runtime is not ready; reference candidates cannot be read',
    '添加图片': 'Add image',
    '添加文件（写入工作区）': 'Add file (written to workspace)',
    '本会话模型': 'Session model',
    '模型目录为空或尚未读取': 'The model catalog is empty or not loaded yet',
    '打开模型服务设置': 'Open model service settings',
    '本会话权限': 'Session permission',
    '权限目录为空或尚未读取': 'The permission catalog is empty or not loaded yet',
    '只影响当前会话；新会话默认值仍在设置里。':
      'Affects only this session; the new-session default stays in Settings.',
    '附件': 'Attachment',
    '移除附件': 'Remove attachment',
    '添加指令、引用或附件': 'Add command, reference, or attachment',
    '展开权限': 'Expand permission',
    '停止执行': 'Stop',
    '发送消息': 'Send message',
    '收起工作过程': 'Collapse work process',
    '展开工作过程': 'Expand work process',
    '错误': 'Error',
    '系统提示': 'System notice',
    '回合事件': 'Turn event',
    '工具': 'Tool',
    '{0} 个待确认': '{0} pending',
    '权限：{0}': 'Permission: {0}',
    '推理强度：{0}': 'Reasoning effort: {0}',
    '推理强度 {0}': 'Reasoning effort {0}',
    '{0} 档强度': '{0} levels',
    '缓存命中 {0}%': 'Cache hit {0}%',
    '{0} 轮 {1} 步': '{0} turns, {1} steps',

    // Appearance, text size, shortcuts, archive, about and licenses.
    '正文': 'Body',
    '正文字号作用于消息正文；代码字号由宿主配置决定。':
      'Body size applies to message bodies; code size is decided by the host configuration.',
    '过程折叠': 'Process folding',
    '性能与用量': 'Performance & usage',
    '详细显示轮次、步骤、速度、缓存与上下文；关闭后只显示速度与缓存':
      'Shows turns, steps, speed, cache, and context in detail; when off, only speed and cache are shown',
    '显示工作过程': 'Show work process',
    '思考与工具行在对话里折叠显示': 'Thinking and tool rows are folded in the conversation',
    '折叠时机': 'Fold timing',
    '折叠时机由宿主管理；本页不显示伪造的绑定。':
      'Fold timing is managed by the host; this page shows no fabricated binding.',
    'DSH 没有可显示的自定义设置': 'DSH has no custom settings to show',
    '宿主尚未提供设置描述，这里不显示编造的内容。':
      'The host has not provided a settings description; nothing is fabricated here.',
    '仅显示 DSH 已脱敏的设置描述与 revision；密钥和本机路径不会出现在这里。':
      'Shows only redacted DSH setting descriptions and revision; keys and local paths never appear here.',
    '只读：内容来自宿主的脱敏快照，不能在这里编辑。':
      'Read-only: content comes from the host\'s redacted snapshot and cannot be edited here.',
    '应用命令': 'App commands',
    '宿主没有报告快捷键存储，这里不显示默认绑定。':
      'The host did not report shortcut storage; default bindings are not shown here.',
    '固定输入操作（只读）': 'Fixed input actions (read-only)',
    '换行': 'New line',
    '另一种发送行为': 'Alternative send',
    '快捷键由宿主读写；本页只显示当前绑定，编辑入口尚未接入。':
      'Shortcuts are read and written by the host; this page only shows current bindings, and editing is not connected yet.',
    '正在读取已归档会话…': 'Loading archived sessions…',
    '宿主没有报告已归档的会话，无法判断有没有':
      'The host did not report archived sessions, so it is unknown whether any exist.',
    '没有已归档的会话': 'No archived sessions',
    '在侧边栏长按会话选「归档」，会话会收到这里，随时可以恢复。':
      'Long-press a session in the sidebar and choose Archive; it is collected here and can be restored anytime.',
    '恢复': 'Restore',
    '删除这个会话？删除后无法恢复': 'Delete this session? This cannot be undone.',
    '恢复后，会话回到原来的文件夹。':
      'After restoring, the session returns to its original folder.',
    '运行在手机端的 DeepSeek Harness': 'DeepSeek Harness running on the phone',
    '版本号': 'Version number',
    '构建号': 'Build number',
    '系统': 'System',
    '运行时地址': 'Runtime address',
    '主题': 'Theme',
    '版本号与构建号由宿主报告；当前宿主没有提供这两项，本页显示未知而不是编造值。':
      'Version and build numbers are reported by the host; this host does not provide them, so this page shows unknown instead of inventing values.',
    '会话记录和文件都保存在这台手机上。':
      'Session records and files are stored on this phone.',
    '本应用': 'This app',
    'Phone DSH 源码': 'Phone DSH source',
    '依赖许可清单': 'Dependency license list',
    '宿主没有报告依赖许可清单': 'The host did not report a dependency license list',
    '当前只确认本应用源码以 MIT 许可分发；不伪造第三方清单。':
      'Only this app\'s source is confirmed as MIT-licensed; no third-party list is fabricated.',
    '完整许可文本随仓库分发；这里不复制未经宿主报告的内容。':
      'Full license texts ship with the repository; content not reported by the host is not copied here.',
    '正在读取许可文本…': 'Loading license texts…',
    '许可文本读取失败': 'License text read failed',
    '文本读取失败': 'Text unavailable',
    '第三方依赖': 'Third-party dependencies',
    '宿主没有报告许可文本，无法判断有没有第三方依赖。':
      'The host did not report license texts, so whether third-party dependencies exist is unknown.',
    '没有可显示的许可文本': 'No license text to show',
    '宿主报告了空清单；这里不会编造第三方依赖。':
      'The host reported an empty list; third-party dependencies are not invented here.',
    '完整许可文本随 HAP 以 rawfile 资源分发；点击条目展开，长按复制。':
      'Full license texts ship with the HAP as rawfile resources; tap a row to expand and long-press to copy.',
    '许可文本读取失败：{0}；这不代表没有第三方依赖。':
      'Failed to read license text: {0}; this does not mean there are no third-party dependencies.',
    '请求': 'Request',
    '权限状态': 'Permission status',
    '正在读取设备授权状态…': 'Loading device permission status…',
    '读取手机权限状态失败': 'Failed to read phone permission status',
    '宿主没有报告手机权限状态': 'The host did not report phone permission status',
    '本页没有读取到任何授权状态，因此不把未读显示成“已允许”或“已拒绝”。':
      'This page read no grant state, so unread items are not shown as Allowed or Denied.',
    '状态来自本机 bundleManager / abilityAccessCtrl / notificationManager 的实际读取；未在 module.json5 声明的权限只显示“未知”和原因。本页不请求权限、不显示能力开关，也不把 PhotoPicker 的按 URI 授权当成整库照片授权。撤销或修改系统授权请前往系统设置。':
      'Status comes from real reads of bundleManager, abilityAccessCtrl, and notificationManager. Permissions not declared in module.json5 show only Unknown and the reason. This page never requests permissions, shows no capability toggles, and does not treat PhotoPicker URI grants as full photo-library access. Change or revoke grants in system settings.',
    '最近使用审计': 'Recent-use audit',
    '宿主没有报告使用审计': 'The host did not report a use audit',
    '本宿主没有能力使用审计，不能判断有没有记录；不把未报告显示成“暂无记录”。':
      'This host has no capability-use audit, so it cannot tell whether records exist; unreported is not shown as No records.',
    '正在读取预设…': 'Loading presets…',
    '预设读取失败': 'Failed to load presets',
    '宿主还没有返回预设清单，暂不判断有没有预设。':
      'The host has not returned a preset list, so whether presets exist is not judged yet.',
    '当前引擎没有预设': 'The current engine has no presets',
    '预设由引擎提供；本页不会编造预设或默认项。':
      'Presets come from the engine; this page does not invent presets or defaults.',
    '预设清单由宿主报告；启用状态和配置只展示已收到的字段。使用预设创建会话需要宿主提供入口。':
      'The preset list is reported by the host; enabled state and configuration show only received fields. Creating a session from a preset needs a host entry point.',
    '查看配置': 'View configuration',
    '搜索插件': 'Search plugins',
    '宿主还没有返回插件清单，暂不判断有没有插件。':
      'The host has not returned a plugin list, so whether plugins exist is not judged yet.',
    '没有匹配的插件。': 'No matching plugins.',
    '没有已加载插件': 'No plugins loaded',
    '引擎还没给出插件列表。': 'The engine has not provided a plugin list yet.',
    '这台手机没有 pnpm、execa 或子进程安装环境。插件和 bundle 可以在这里查看；安装、启用和停用请在桌面 DSH 完成。':
      'This phone has no pnpm, execa, or subprocess install environment. Plugins and bundles can be viewed here; install, enable, and disable them in desktop DSH.',

    // Math formula chrome.
    '重试渲染': 'Retry rendering',
    '公式渲染失败：{0}': 'Formula rendering failed: {0}',
    '公式渲染失败，已保留 TeX 源':
      'Formula rendering failed; the TeX source was kept',
    '数学公式为空': 'The math formula is empty',
    '原生公式渲染失败': 'Native formula rendering failed',
    'SVG 编码失败': 'SVG encoding failed',
    '原生公式图片解码失败': 'Failed to decode the native formula image',
    '原生公式渲染排队过多，请重试': 'Too many native formula jobs queued; try again',
    '原生公式结果不是有效 JSON': 'The native formula result is not valid JSON',
    '原生公式结果缺少 SVG 或尺寸': 'The native formula result is missing SVG or dimensions',
    '原生公式结果无效': 'The native formula result is invalid',
    '原生公式结果超出尺寸上限': 'The native formula result exceeds the size limit',

    // Model service and permission continuation copy.
    '保存或选择后会写入本机配置；模型服务地址与模型从下一次启动本地引擎起装配。密钥按该服务的 AssetStore 别名在每次请求时读取：给同一别名保存新密钥后，后续请求会使用新密钥。':
      'Saving or selecting writes this device. The service address and model are applied the next time the local engine starts. The key is read from that service\'s AssetStore alias on each request: after saving a new key for the same alias, later requests use it.',
    '保存或选择后会写入本机配置；模型服务地址与模型会在下次启动主机时生效。密钥按各服务的 AssetStore 别名在每次请求时读取。':
      'Saving or selecting writes this device. The service address and model take effect the next time the host starts. Keys are read from each service\'s AssetStore alias on every request.',
    '填写这几项后保存。保存会创建新的模型服务并选中它；地址与模型从下次启动本地引擎起装配；保存的密钥在该服务的后续请求中使用。':
      'Fill in these fields and save. Saving creates and selects a new model service; its address and model are applied the next time the local engine starts; the saved key is used on that service\'s later requests.',
    '保存会更新这个模型服务；运行中的引擎仍使用启动时冻结的地址与模型。密钥按该服务别名在每次请求时读取，保存新密钥后后续请求会使用它。':
      'Saving updates this model service. The running engine keeps the address and model frozen at startup. The key is read from this service\'s alias on every request, so later requests use a newly saved key.',
    '此设备已保存密钥': 'A key is saved on this device',
    '尚未保存密钥': 'No key saved yet',
    'API 密钥': 'API key',
    '密钥已保存在这台设备上；界面只显示状态，不显示明文。留空保存不会改动原密钥。':
      'The key is saved on this device; the UI shows only its state, never plaintext. Saving with this blank does not change the existing key.',
    '还没有保存密钥；填入密钥后才能使用这个服务。':
      'No key is saved yet; enter one before using this service.',
    '保存后会写入本机配置；服务地址与模型从下一次启动本地引擎起装配。密钥按这个服务的 AssetStore 别名在每次请求时读取：保存新密钥后，同一服务的后续请求会使用新密钥。':
      'Saving writes this device. The service address and model are applied the next time the local engine starts. The key is read from this service\'s AssetStore alias on each request: after saving a new key, later requests to the same service use it.',
    '保存后会写入本机配置；服务地址与模型会在下次启动主机时生效。密钥按这个服务的 AssetStore 别名在每次请求时读取。':
      'Saving writes this device. The service address and model take effect the next time the host starts. The key is read from this service\'s AssetStore alias on every request.',
    '选择官方 DeepSeek 模型服务并保存密钥后，网页搜索和抓取会自动启用。':
      'Web search and fetch turn on automatically when you select the official DeepSeek model service and save its key.',
    '只读：MCP 注册表在 Worker 的 /dsh/home/mcp.json，改写要走宿主的 phone/mcpUpsert 工具；':
      'Read-only: the MCP registry lives in the Worker\'s /dsh/home/mcp.json; changes go through the host\'s phone/mcpUpsert tool;',
    '本宿主没有注册该工具，所以不会在这里保存或删除服务器。':
      'this host does not register that tool, so servers are never saved or deleted here.',
    '保存不会落盘：本宿主没有 phone/mcpUpsert 这个 host tool。':
      'Saving writes nothing: this host has no phone/mcpUpsert host tool.',
    'MCP 注册表在 Worker 的 /dsh/home/mcp.json；本页只读展示，不提供保存或删除。':
      'The MCP registry lives in the Worker\'s /dsh/home/mcp.json; this page is read-only and offers no save or delete.',
    '匹配后缀主机本身和所有子域': 'Matches the suffix host itself and all subdomains',

    // File dialogs, automation kinds, validation, and export labels.
    '路径分隔': 'Path separator',
    '里面的会话会留着，只是不再放在这个文件夹里':
      'Sessions inside are kept; they just leave this folder',
    '会在工作区里新建同名文件夹，之后的会话和文件都可以放进去。':
      'Creates a folder with this name in the workspace; later sessions and files can go inside.',
    '名称不能为空': 'Name cannot be empty',
    '提醒内容不能为空': 'Reminder content cannot be empty',
    '请填写完整有效的重复规则': 'Enter a complete, valid repeat rule',
    '延时': 'Delay',
    '间隔': 'Interval',
    '每天': 'Daily',
    '每周': 'Weekly',
    '请输入有效数字': 'Enter a valid number',
    '模型选择不合法，请重新选择': 'Invalid model selection; choose again',
    '宿主已报告内容': 'Host reported content',
    '还没写': 'Not written yet',
    '宿主已提供报告内容': 'Host provided report content',
    '图片未加载：{0}': 'Image not loaded: {0}',
    '链接打开失败': 'Failed to open link',

    // Phone-permission templates; fixed text only, values stay verbatim.
    '只读设备信息：{0} · {1} · API {2}':
      'Read-only device info: {0} · {1} · API {2}',
    '读取应用通知开关失败：{0}': 'Failed to read the app notification switch: {0}',
    '未在 module.json5 声明 {0}；平台不报告未声明权限的授权状态。{1}':
      'Not declared in module.json5: {0}; the platform reports no grant state for undeclared permissions. {1}',
    ' PhotoPicker 按 URI 授权，不等同整库照片权限，不能当作已允许。':
      ' PhotoPicker grants by URI, which is not full photo-library access and is not treated as Allowed.',
    '读取授权状态失败：{0}': 'Failed to read grant state: {0}',
    '未知错误': 'Unknown error',
    '本地页面已加载，正在等待 Worker 就绪':
      'Local page loaded; waiting for the Worker to be ready',
    '本地运行时页面失败':
      'Local runtime page failed',
    '本地运行时已就绪':
      'Local runtime ready',
    '本地运行时启动失败':
      'Local runtime failed to start',
    '本地运行时还没就绪；草稿已保留。':
      'Local runtime is not ready yet; the draft was kept.',
    'Worker 会话尚未建立；草稿已保留。':
      'The Worker session is not established yet; the draft was kept.',
    '当前没有运行中的轮次':
      'There is no running turn',
    '本轮仍在运行；请先停止或等待结束后再新建会话。':
      'This turn is still running; stop it or wait for it to end before creating a session.',
    '本轮仍在运行；停止后才能切换会话。':
      'This turn is still running; stop it before switching sessions.',
    '找不到这个会话':
      'Session not found',
    '会话标题不能为空':
      'Session title cannot be empty',
    '本轮仍在运行；停止后才能归档当前会话。':
      'This turn is still running; stop it before archiving the current session.',
    '本轮仍在运行；请先停止再删除会话。':
      'This turn is still running; stop it before deleting the session.',
    '文件夹名不能为空':
      'Folder name cannot be empty',
    '默认文件夹不能删除':
      'The default folder cannot be deleted',
    '这个模型服务标识已存在；本次未覆盖现有服务':
      'This model service id already exists; the existing service was not overwritten',
    '这个模型服务已不存在；请重新载入后再保存':
      'This model service no longer exists; reload and save again',
    '这个模型服务已经不存在':
      'This model service no longer exists',
    '已选择模型服务；将在下次启动本地引擎时生效。':
      'Model service selected; it takes effect the next time the local engine starts.',
    '只能删除本机保存的模型服务；启动配置的服务不能删除':
      'Only model services saved on this device can be deleted; a launch-configured service cannot.',
    '这是当前运行中的模型服务；请先停止本地引擎再删除，本次未删除':
      'This is the running model service; stop the local engine before deleting it. Nothing was deleted.',
    '无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试':
      'Cannot read this device\'s key, so the service or key was not deleted. Unlock the device, reload the page, and try again.',
    '密钥删除没有确认；模型服务未删除，请重试':
      'Key deletion was not confirmed; the model service was not deleted. Try again.',
    '已删除本机保存的模型服务与密钥':
      'Deleted the model service and key saved on this device',
    '请先保存这个模型服务，再测试连接':
      'Save this model service before testing the connection',
    '没有可删除密钥的模型服务':
      'No model service has a key to delete',
    '这是当前运行中的模型服务；请先停止本地引擎再删除密钥，本次未删除':
      'This is the running model service; stop the local engine before deleting its key. Nothing was deleted.',
    '无法读取此设备的密钥，不能删除密钥。请解锁设备后重新载入页面再试':
      'Cannot read this device\'s key, so the key was not deleted. Unlock the device, reload the page, and try again.',
    '已删除此模型服务保存在 AssetStore 的密钥。':
      'Deleted this model service\'s key from AssetStore.',
    '当前会话还没有 Worker 会话，无法切换模型。':
      'This session has no Worker session yet, so the model cannot be switched.',
    '模型目录里没有这个模型或推理强度，请刷新后重试。':
      'The model or reasoning effort is not in the catalog; refresh and retry.',
    '模型切换已提交，但会话状态没有刷新确认。':
      'The model switch was submitted, but the session state did not confirm a refresh.',
    '模型切换没有被会话确认。':
      'The session did not confirm the model switch.',
    '当前会话还没有 Worker 会话，无法切换权限。':
      'This session has no Worker session yet, so the permission cannot be switched.',
    '权限目录里没有这个权限模式，请刷新后重试。':
      'The permission mode is not in the catalog; refresh and retry.',
    '权限命令已提交，但会话状态没有刷新确认。':
      'The permission command was submitted, but the session state did not confirm a refresh.',
    '权限命令没有被会话确认。':
      'The session did not confirm the permission command.',
    '正在重新加载本地运行时':
      'Reloading the local runtime',
    '停止本地运行时失败':
      'Failed to stop the local runtime',
    '本地运行时已停止':
      'Local runtime stopped',
    '本地运行时尚未就绪，无法读取文件':
      'Local runtime is not ready; cannot read files',
    '宿主上下文尚未初始化':
      'Host context is not initialized yet',
    '没有选择附件。':
      'No attachment selected.',
    '本地运行时尚未就绪；附件没有写入 Worker 文件系统':
      'Local runtime is not ready; the attachment was not written to the Worker filesystem',
    '当前会话没有可导出的内容':
      'This session has nothing to export',
    '没有选择导出位置':
      'No export location selected',
    '会话已导出到所选位置。':
      'Session exported to the selected location.',
    '正在运行…':
      'Running…',
    '命令未运行：本地运行时尚未就绪':
      'Command did not run: local runtime is not ready',
    '这个待处理请求已经不存在':
      'This pending request no longer exists',
    '已提交回答。':
      'Answer submitted.',
    '这个条目没有可用的启用/停用宿主实现。':
      'This item has no host implementation for enabling or disabling.',
    '新会话权限默认值已同步给 Worker。':
      'The new-session permission default was synced to the Worker.',
    '字号已保存':
      'Text size saved',
    '定时任务已删除。':
      'Scheduled task deleted.',
    '已安装插件由 DSH 安装层管理；本宿主不提供卸载写入。':
      'Installed plugins are managed by the DSH install layer; this host provides no uninstall write.',
    'Agent 预设由 Worker 管理；当前 RPC 只提供读取。':
      'Agent presets are managed by the Worker; the current RPC is read-only.',
    '会话事件流中断':
      'Session event stream interrupted',
    '上次运行中断的轮次已标记为已取消。':
      'The turn interrupted by the last run was marked cancelled.',
    '正在安装本地运行时':
      'Installing the local runtime',
    '无法创建私有运行时目录':
      'Cannot create the private runtime directory',
    '安装资源 runtime.zip 读取失败':
      'Failed to read the runtime.zip install resource',
    '原生事件回调安装失败':
      'Failed to install the native event callback',
    '本地运行时没有返回可用的端口或启动令牌':
      'The local runtime returned no usable port or launch token',
    '本地运行时鉴权 cookie 配置失败':
      'Failed to configure the local runtime auth cookie',
    '本地运行时已启动，正在等待 Worker 就绪':
      'Local runtime started; waiting for the Worker to be ready',
    '密钥存储无法读取；模型请求会被宿主拒绝。':
      'The key store cannot be read; the host will reject model requests.',
    '发送失败':
      'Send failed',
    '会话错误':
      'Session error',
    'Worker 错误':
      'Worker error',
    '取消请求已发送，但运行时未在 10 秒内确认本轮结束。':
      'The cancel request was sent, but the runtime did not confirm the turn ended within 10 seconds.',
    '取消未确认':
      'Cancel not confirmed',
    '本地运行时尚未就绪，无法读取配置':
      'Local runtime is not ready; cannot read configuration',
    '本地运行时尚未就绪，无法读取 MCP 注册表':
      'Local runtime is not ready; cannot read the MCP registry',
    'phone/mcpList 没有返回注册表快照':
      'phone/mcpList returned no registry snapshot',
    '本地运行时尚未就绪，无法读取 shell 能力':
      'Local runtime is not ready; cannot read shell capabilities',
    'phone/shellCaps 没有返回能力快照':
      'phone/shellCaps returned no capability snapshot',
    '本地运行时尚未就绪，无法读取定时任务':
      'Local runtime is not ready; cannot read scheduled tasks',
    '本地运行时尚未就绪，无法预览文件':
      'Local runtime is not ready; cannot preview files',
    '本地运行时状态读取失败':
      'Failed to read local runtime status',
    '本地运行时尚未就绪，无法运行诊断':
      'Local runtime is not ready; cannot run diagnostics',
    '开关值必须是 true 或 false':
      'The switch value must be true or false',
    '请选择当前模型目录中的模型':
      'Choose a model from the current model catalog',
    '这个配置项没有可用的写入类型':
      'This configuration item has no usable write type',
    '设置已保存':
      'Settings saved',
    '设置文档必须是 JSON 对象':
      'The settings document must be a JSON object',
    '设置文档已保存':
      'Settings document saved',
    '定时任务内容必须是 JSON 对象':
      'Scheduled task content must be a JSON object',
    '任务名称不能为空且最多 120 个字符':
      'Task name cannot be empty and can have at most 120 characters',
    '定时任务已不存在，请刷新后重试':
      'The scheduled task no longer exists; refresh and retry',
    '定时任务原始记录不可用，请刷新后重试':
      'The scheduled task record is unavailable; refresh and retry',
    '保存请求已返回，但目录没有显示更新后的内容；请刷新确认。':
      'The save request returned, but the catalog does not show the updated content; refresh to confirm.',
    '定时任务已更新。':
      'Scheduled task updated.',
    '当前会话尚未启动 Worker，无法创建定时任务':
      'This session has not started a Worker, so a scheduled task cannot be created.',
    '创建请求没有返回定时任务 id':
      'The create request returned no scheduled-task id',
    '创建请求已返回，但目录没有显示新任务；请刷新确认。':
      'The create request returned, but the catalog does not show the new task; refresh to confirm.',
    '定时任务已创建。':
      'Scheduled task created.',
    '本轮仍在运行；停止后才能使用预设开新会话。':
      'This turn is still running; stop it before starting a new session from a preset.',
    '已读取预设文档。':
      'Preset document loaded.',
    '拒绝删除 Worker 命名空间之外的文件':
      'Refused to delete a file outside the Worker namespace',
    '本地运行时尚未就绪，未删除文件':
      'Local runtime is not ready; the file was not deleted',
    '文件已删除。':
      'File deleted.',
    '实时审批事件流不可用：{0}':
      'Live approval event stream unavailable: {0}',
    '取消请求未送达：{0}':
      'Cancel request was not delivered: {0}',
    '已保存到本机：模型服务{0}（下次启动本地引擎时生效）':
      'Saved on this device: model service{0} (takes effect the next time the local engine starts)',
    '已切换模型：{0} · {1}':
      'Model switched: {0} · {1}',
    '本会话权限已切换为：{0}':
      'Session permission switched to: {0}',
    '无法读取文件：{0}':
      'Cannot read file: {0}',
    '{0} 个附件已写入 Worker 工作区；发送时才会引用。':
      '{0} attachments written to the Worker workspace; they are referenced only when you send.',
    '部分附件未导入：{0}':
      'Some attachments were not imported: {0}',
    '导出失败：{0}':
      'Export failed: {0}',
    '命令未运行：{0}':
      'Command did not run: {0}',
    '回答未送达：{0}':
      'Answer was not delivered: {0}',
    '插件已是{0}状态，未改动。':
      'The plugin is already {0}; nothing changed.',
    '插件已{0}；重启 Worker 后生效。':
      'Plugin {0}; takes effect after the Worker restarts.',
    '插件已{0}。':
      'Plugin {0}.',
    '插件状态未修改：{0}':
      'Plugin state was not changed: {0}',
    '权限设置未保存：{0}':
      'Permission setting was not saved: {0}',
    '删除失败：{0}':
      'Delete failed: {0}',
    '实时审批事件流已断开：{0}':
      'Live approval event stream disconnected: {0}',
    '会话事件流中断：{0}':
      'Session event stream interrupted: {0}',
    '模型目录读取失败：{0}':
      'Failed to load the model catalog: {0}',
    '权限目录读取失败：{0}':
      'Failed to load the permission catalog: {0}',
    '发送失败：{0}':
      'Send failed: {0}',
    '无法建立 Worker 会话：{0}':
      'Cannot create a Worker session: {0}',
    'MCP 注册表读取失败：{0}':
      'Failed to read the MCP registry: {0}',
    'shell 能力读取失败：{0}':
      'Failed to read shell capabilities: {0}',
    '定时任务读取失败：{0}':
      'Failed to load scheduled tasks: {0}',
    '文件列表读取失败：{0}':
      'Failed to load the file list: {0}',
    '预览读取失败：{0}':
      'Failed to load preview: {0}',
    '诊断失败：{0}':
      'Diagnostics failed: {0}',
    '设置文档未保存：{0}':
      'Settings document was not saved: {0}',
    '已用预设 {0} 创建新会话。':
      'Created a new session with preset {0}.',
    '预设会话未创建：{0}':
      'Preset session was not created: {0}',
    '预设文档读取失败：{0}':
      'Failed to read the preset document: {0}',
    '模型没有切换成功：{0}':
      'Model switch failed: {0}',
    '权限没有切换成功：{0}':
      'Permission switch failed: {0}',
    '运行时资源安装失败：{0}':
      'Runtime resource installation failed: {0}',
    '本地运行时启动失败：{0}':
      'Local runtime failed to start: {0}',
    '设置未保存：{0}':
      'Settings were not saved: {0}',
    '定时任务未保存：{0}':
      'Scheduled task was not saved: {0}',
    '本轮结束：{0} · {1}':
      'Turn ended: {0} · {1}',
    '本轮结束：{0}':
      'Turn ended: {0}',
    '任务已被其他窗口修改':
      'The task was changed by another window',
    '任务已结束':
      'The task has ended',
    '任务已不存在':
      'The task no longer exists',
    '{0}，请刷新后重试':
      '{0}. Refresh and retry.',
    '启用':
      'Enabled',
    '停用':
      'Disabled'
  };

  /** Normalizes a BCP-47-ish tag or settings id to `zh` / `en`. */
  static normalize(tag: string): string {
    if (tag === undefined || tag === null) {
      return LocaleText.ZH;
    }
    if (tag.toLowerCase().indexOf('en') === 0) {
      return LocaleText.EN;
    }
    return LocaleText.ZH;
  }

  /**
   * Resolves the effective UI language. `system` delegates to the caller's
   * actual system language tag; an explicit `en` / `zh` choice always wins.
   */
  static resolve(settingsLanguage: string, systemLanguageTag: string): string {
    if (settingsLanguage === 'en' || settingsLanguage === 'zh') {
      return settingsLanguage;
    }
    return LocaleText.normalize(systemLanguageTag.length > 0 ? systemLanguageTag : 'zh');
  }

  /**
   * Exact-match static copy lookup. Unknown keys and non-English languages
   * fall back to the Chinese source string, so partial dictionaries stay safe.
   */
  static tr(language: string, chinese: string, english?: string): string {
    if (LocaleText.normalize(language) !== LocaleText.EN) {
      return chinese;
    }
    if (english !== undefined && english !== null && english.length > 0) {
      return english;
    }
    const mapped: string | undefined = LocaleText.EN_BY_ZH[chinese];
    return mapped !== undefined ? mapped : chinese;
  }

  /**
   * Translates a static template and fills `{0}`, `{1}`, … with caller-supplied
   * values. Only the template is looked up; values are never translated.
   */
  static fill(language: string, chineseTemplate: string, values: string[]): string {
    let text: string = LocaleText.tr(language, chineseTemplate);
    for (let index: number = 0; index < values.length; index++) {
      text = text.split('{' + index.toString() + '}').join(values[index]);
    }
    return text;
  }

  /** Whether the dictionary has an English pair for this literal. */
  static hasEnglish(chinese: string): boolean {
    return LocaleText.EN_BY_ZH[chinese] !== undefined;
  }
}
