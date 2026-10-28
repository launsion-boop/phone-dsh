// SPDX-License-Identifier: MIT
/** Browser dictionaries for the phone MCP Settings tab. */

/** Every localized string key contributed under `settings.phoneMcp`. */
export type PhoneMcpLocaleKey =
  | 'tab'
  | 'title'
  | 'description'
  | 'addServer'
  | 'editServer'
  | 'serverName'
  | 'serverNameHint'
  | 'url'
  | 'urlHint'
  | 'headersFromEnv'
  | 'headersFromEnvHint'
  | 'enabled'
  | 'toolCallTimeoutMs'
  | 'save'
  | 'saving'
  | 'cancel'
  | 'remove'
  | 'removing'
  | 'reconnect'
  | 'reconnecting'
  | 'refresh'
  | 'nativeSettings'
  | 'loading'
  | 'empty'
  | 'statusDisabled'
  | 'statusConnecting'
  | 'statusConnected'
  | 'statusError'
  | 'authenticationNone'
  | 'authenticationHeaders'
  | 'authenticationHostManaged'
  | 'tools'
  | 'noTools'
  | 'edit'
  | 'configFile'
  | 'loadFailed'
  | 'actionFailed'
  | 'formInvalid'
  | 'headerLineInvalid'
  | 'timeoutInvalid'
  | 'nativeKeyRequired'
  | 'upsertCommitted'
  | 'upsertCommitPending'
  | 'upsertUnknown'

/** Chinese copy. */
export const zh: Record<PhoneMcpLocaleKey, string> = {
  tab: 'MCP',
  title: 'HTTP MCP 服务器',
  description: '管理 Streamable HTTP MCP。手机 App 的认证值存放在独立 Keychain 并由主机按精确 URL 注入；令牌值不会写入配置或日志。',
  addServer: '添加服务器',
  editServer: '编辑服务器',
  serverName: '服务器名称',
  serverNameHint: '模型中的工具名会使用 mcp__<serverName>__<tool>；仅允许 A-Z a-z 0-9 _ -，最长 32 个字符。',
  url: 'MCP 地址',
  urlHint: '仅支持 http:// 或 https:// 的 Streamable HTTP 端点，不支持 stdio。',
  headersFromEnv: '认证头（Header=环境变量名）',
  headersFromEnvHint: '每行一个，例如 Authorization=MCP_TOKEN。这里只保存环境变量名；手机 App 中真实值在“设备网络与密钥”里写入独立 Keychain，由主机按精确 URL 注入。留空表示不发送认证头。',
  enabled: '启用',
  toolCallTimeoutMs: '工具调用超时（毫秒）',
  save: '保存并连接',
  saving: '正在连接…',
  cancel: '取消编辑',
  remove: '删除',
  removing: '正在删除…',
  reconnect: '重新连接',
  reconnecting: '正在重连…',
  refresh: '刷新',
  nativeSettings: '设备网络与密钥',
  loading: '正在读取配置…',
  empty: '尚未配置 HTTP MCP 服务器。',
  statusDisabled: '已停用',
  statusConnecting: '等待挂载',
  statusConnected: '已连接',
  statusError: '连接失败',
  authenticationNone: '未配置认证头；连接请求不会携带认证信息。',
  authenticationHeaders: '认证头在连接时从环境变量解析。',
  authenticationHostManaged: '认证值由本机注入：只作用于这个精确 URL，不写入 Worker 配置。',
  tools: '当前真实工具',
  noTools: '当前没有发现工具。',
  edit: '编辑',
  configFile: '配置文件',
  loadFailed: '读取配置失败',
  actionFailed: '操作失败',
  formInvalid: '请填写服务器名称和 MCP 地址。',
  headerLineInvalid: '认证头格式错误，请使用 Header=环境变量名。',
  timeoutInvalid: '超时必须是正整数毫秒。',
  nativeKeyRequired: '该服务器需要认证值：已打开“设备网络与密钥”，填写并保存后会同时授权精确 URL 并连接。',
  upsertCommitted: 'Worker 已保存该 MCP 行；精确授权与设备密钥已提交。',
  upsertCommitPending: 'Worker 已保存该 MCP 行；旧密钥清理暂未完成，已保留可恢复记录并会在下次读取时重试。',
  upsertUnknown: '保存结果暂时无法确认；已保留可恢复的事务，刷新后会自动核对。',
}

/** English copy. */
export const en: Record<PhoneMcpLocaleKey, string> = {
  tab: 'MCP',
  title: 'HTTP MCP servers',
  description: 'Manage Streamable HTTP MCP servers. On the phone, authentication values live in the dedicated Keychain and are injected by the host for the exact URL; values are never written to the file or logs.',
  addServer: 'Add server',
  editServer: 'Edit server',
  serverName: 'Server name',
  serverNameHint: 'Model-facing tools become mcp__<serverName>__<tool>; only A-Z a-z 0-9 _ - are allowed, up to 32 characters.',
  url: 'MCP URL',
  urlHint: 'Only http:// or https:// Streamable HTTP endpoints; stdio is not supported.',
  headersFromEnv: 'Auth headers (Header=ENV_VAR)',
  headersFromEnvHint: 'One per line, for example Authorization=MCP_TOKEN. Only the variable name is stored; on the phone the value is entered under Device network & keys in the dedicated Keychain and injected by the host for the exact URL. Leave empty to send no authentication header.',
  enabled: 'Enabled',
  toolCallTimeoutMs: 'Tool call timeout (ms)',
  save: 'Save and connect',
  saving: 'Connecting…',
  cancel: 'Cancel edit',
  remove: 'Remove',
  removing: 'Removing…',
  reconnect: 'Reconnect',
  reconnecting: 'Reconnecting…',
  refresh: 'Refresh',
  nativeSettings: 'Device network & keys',
  loading: 'Reading configuration…',
  empty: 'No HTTP MCP server is configured yet.',
  statusDisabled: 'Disabled',
  statusConnecting: 'Not mounted',
  statusConnected: 'Connected',
  statusError: 'Connection failed',
  authenticationNone: 'No authentication header is configured; connection requests carry no credentials.',
  authenticationHeaders: 'Auth headers are resolved from the environment when connecting.',
  authenticationHostManaged: 'Authentication values are injected by this device for the exact URL and never enter the Worker configuration.',
  tools: 'Current real tools',
  noTools: 'No tools are currently discovered.',
  edit: 'Edit',
  configFile: 'Configuration file',
  loadFailed: 'Could not read the configuration',
  actionFailed: 'Action failed',
  formInvalid: 'Enter a server name and an MCP URL.',
  headerLineInvalid: 'Invalid header line; use Header=ENV_VAR.',
  timeoutInvalid: 'The timeout must be a positive integer in milliseconds.',
  nativeKeyRequired: 'This server needs an authentication value. Device network & keys is open; save there to grant the exact URL and connect.',
  upsertCommitted: 'The Worker already saved this MCP row; the exact grant and device key were committed.',
  upsertCommitPending: 'The Worker saved this MCP row; old-key cleanup is still pending and will retry on the next registry read.',
  upsertUnknown: 'The save result is not confirmed yet; the recoverable transaction was kept and will be reconciled on refresh.',
}
