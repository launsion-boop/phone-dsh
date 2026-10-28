// SPDX-License-Identifier: MIT
/**
 * Locale dictionaries owned by the phone model-config settings tab.
 *
 * The Host sends structured issue codes, never user-facing prose, so these are
 * the only strings the browser renders. `zh` is the key-set source of truth and
 * `en` is checked against it at compile time.
 * @module @phone-dsh/dsh-phone-model-config/client/locales
 */

/** Simplified Chinese dictionary and key-set source of truth. */
export const zh = {
  tab: '模型服务',
  title: '当前模型服务',
  injectedByHost: '由宿主注入',
  otherProviders: '其他已保存服务',
  'labels.service': '服务',
  'labels.id': '标识',
  'labels.baseURL': '服务 URL',
  'labels.model': '模型',
  'labels.reasoningEffort': '推理强度',
  openNativeSettings: '打开系统原生模型设置',
  searchNote: '网页搜索使用同一模型服务的主机与 Keychain 密钥；没有单独的搜索密钥或假开关。',
  credentialNote: 'API 密钥保存在此设备的 Keychain，由宿主在模型请求时注入。Worker、Web 页面和此设置页都读不到密钥；此页只读显示宿主当前选择的服务。请到原生“设置 → 模型服务”中新增、编辑或切换服务。',
  'unavailable.missing': '尚未配置模型服务',
  'unavailable.invalid': '模型服务配置无效',
  loading: '正在读取宿主模型配置…',
  errorTitle: '无法读取模型配置',
  loadFailed: 'Remote 读取失败：{message}',
  'issue.envMissing': '宿主未注入 {env}。请在原生“设置 → 模型服务”中保存一个服务并重启主机。',
  'issue.jsonInvalid': '宿主注入的 {env} 不是有效 JSON。',
  'issue.documentNotObject': '宿主注入的 {env} 不是 JSON 对象。',
  'issue.versionUnsupported': '宿主注入的 {env} 版本不受支持。',
  'issue.providersEmpty': '宿主注入的 {env} 没有列出任何模型服务。',
  'issue.providerInvalid': '模型服务条目无效：{providerId}',
  'issue.providerInvalidAnonymous': '模型服务条目缺少有效的标识、地址或模型。',
  'issue.duplicateProviderId': '模型服务标识重复：{providerId}',
  'issue.selectedMissing': '宿主没有选择模型服务。',
  'issue.selectedUnknown': '选中的模型服务不存在：{providerId}',
} satisfies Record<string, string>

/** Dictionary key union for the `settings.phoneModelConfig` namespace. */
export type PhoneModelConfigLocaleKey = keyof typeof zh

/** English dictionary, checked against the Chinese key set. */
export const en = {
  tab: 'Model service',
  title: 'Current model service',
  injectedByHost: 'Injected by the host',
  otherProviders: 'Other saved services',
  'labels.service': 'Service',
  'labels.id': 'ID',
  'labels.baseURL': 'Service URL',
  'labels.model': 'Model',
  'labels.reasoningEffort': 'Reasoning effort',
  openNativeSettings: 'Open Native Model Settings',
  searchNote: 'Web search uses the same model-service host and Keychain key; there is no separate search secret or fake switch.',
  credentialNote: 'The API key is stored in this device’s Keychain and injected by the host on model requests. The Worker, the Web page and this settings tab never see the key; this tab only shows the service the host selected. Add, edit or switch services in the native Settings → Model service page.',
  'unavailable.missing': 'No model service is configured',
  'unavailable.invalid': 'The model service configuration is invalid',
  loading: 'Reading the host model configuration…',
  errorTitle: 'Could not read the model configuration',
  loadFailed: 'Remote read failed: {message}',
  'issue.envMissing': 'The host did not inject {env}. Add a service in native Settings → Model service and restart the host.',
  'issue.jsonInvalid': 'The host-provided {env} is not valid JSON.',
  'issue.documentNotObject': 'The host-provided {env} is not a JSON object.',
  'issue.versionUnsupported': 'The host-provided {env} uses an unsupported version.',
  'issue.providersEmpty': 'The host-provided {env} lists no model services.',
  'issue.providerInvalid': 'Model service entry is invalid: {providerId}',
  'issue.providerInvalidAnonymous': 'A model service entry is missing a valid ID, endpoint or model.',
  'issue.duplicateProviderId': 'Duplicate model service ID: {providerId}',
  'issue.selectedMissing': 'The host has not selected a model service.',
  'issue.selectedUnknown': 'The selected model service does not exist: {providerId}',
} satisfies Record<PhoneModelConfigLocaleKey, string>
