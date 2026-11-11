// SPDX-License-Identifier: MIT
// Each demo surface owns its state, including pending work and selected case.
export function createDemoState() {
  return {
    tab: 'bot', case: 'memory', memorySaved: false, approval: 'pending',
    progress: 'ready', workspaceOpen: false, details: null, model: 'DeepSeek',
    prompt: '', timer: null
  };
}

const escapeHTML = value => value.replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[character]);

function icon(name) {
  if (name === 'dsh') return '<span class="native-dsh-icon" aria-hidden="true"></span>';
  const paths = {
    bot: '<path d="M1.9 8C3.3 5.9 5.3 4.6 7.6 4.6S12 5.9 13.5 8C12 10.1 10 11.4 7.6 11.4S3.3 10.1 1.9 8Z"/><path d="m13.2 8 1.8-2.4M13.2 8l1.8 2.4"/><circle cx="5.8" cy="7.3" r=".65"/>',
    discover: '<circle cx="8" cy="8" r="6"/><path d="m10.8 5.2-1.7 3.9-3.9 1.7 1.7-3.9Z"/>',
    me: '<circle cx="8" cy="4.6" r="2.5"/><path d="M2.7 14v-1.4c0-2.1 2.4-3.4 5.3-3.4s5.3 1.3 5.3 3.4V14Z"/>'
  };
  return `<svg class="native-tab-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name]}</svg>`;
}

function navigation(state, t) {
  const tabs = [['bot', 'Bot'], ['dsh', 'DSH'], ['discover', t('发现', 'Discover')], ['me', t('我的', 'Me')]];
  return `<nav class="native-tabs" role="tablist" aria-label="${t('iOS 底部导航', 'iOS tab navigation')}">
    ${tabs.map(([id, title]) => `<button role="tab" aria-selected="${state.tab === id}" data-demo-action="tab" data-value="${id}">${icon(id)}<span>${title}</span></button>`).join('')}
  </nav>`;
}

function artifact(kind, t) {
  const data = kind === 'data';
  return `<button class="native-artifact" data-preview="${kind}">
    <span class="file-icon ${data ? '' : 'coral'}">${data ? 'CSV' : 'MD'}</span>
    <span><strong>${data ? t('调研数据.csv', 'Research data.csv') : t('产品调研.md', 'Research brief.md')}</strong>
    <small>${t('工作区 · 点按预览', 'Workspace · tap to preview')}</small></span><span class="artifact-arrow">↗</span>
  </button>`;
}

function message(value, type = 'assistant') {
  return `<div class="native-message ${type}">${escapeHTML(value)}</div>`;
}

function botContent(state, t) {
  if (state.details === 'bots') {
    return `<h3 class="native-section-label">${t('我的 Bot', 'My Bots')}</h3>
      <button class="native-bot-row" data-demo-action="back"><img src="/assets/bot-avatar.png" alt=""><span><strong>${t('大肥鱼', 'Big Fish')}</strong><small>${t('返回当前对话', 'Return to the conversation')}</small></span><span>›</span></button>
      <div class="native-memory"><strong>${t('当前 Bot 的记忆', 'This Bot’s memory')}</strong><p>${state.memorySaved ? t('周报先写结论，再列出下一步待办。', 'Start weekly updates with a conclusion, then list next steps.') : t('还没有保存写作偏好。回到对话试着保存一条。', 'No writing preference saved yet. Return to the conversation to save one.')}</p></div>`;
  }
  const name = `<div class="native-author"><img src="/assets/bot-avatar.png" alt="">${t('大肥鱼', 'Big Fish')}</div>`;
  if (state.case === 'approval') {
    let outcome;
    if (state.approval === 'pending') {
      outcome = `<div class="native-approval"><strong>${t('等待你的确认', 'Waiting for your approval')}</strong>
        <p>${t('读取工作区的 notes.md，整理并保存产品调研文档。', 'Read notes.md from the workspace and save a research brief.')}</p>
        <code>read_file · notes.md</code>
        <div class="native-actions"><button class="native-primary" data-demo-action="approve">${t('允许一次', 'Allow once')}</button><button class="native-secondary" data-demo-action="deny">${t('拒绝', 'Deny')}</button></div></div>`;
    } else if (state.approval === 'allowed') {
      outcome = `<div class="native-confirmed">✓ ${t('已允许本次操作', 'Allowed for this task')}</div>
        ${message(t('资料已整理，文档已保存。点开看看。', 'The notes are organized and your brief is saved. Open it below.'))}${artifact('brief', t)}`;
    } else {
      outcome = `<div class="native-approval"><strong>${t('已拒绝本次操作', 'Action denied')}</strong>
        <p>${t('任务已停止。你可以重新查看这次请求。', 'The task has stopped. You can review the request again.')}</p>
        <button class="native-secondary" data-demo-action="retry-approval">${t('重新查看请求', 'Review request again')}</button></div>`;
    }
    return `${message(state.prompt || t('把笔记整理成一份产品调研文档。', 'Turn my notes into a product research brief.'), 'user')}${name}
      ${message(t('我会先读取笔记，再提炼要点。请确认这次工具操作。', 'I’ll read the notes and pull out the key points. Please review this tool request.'))}${outcome}`;
  }
  return `${message(state.prompt || t('以后写周报，先给结论，再列待办。记住这个偏好。', 'For weekly updates, lead with the conclusion, then list next steps. Remember that preference.'), 'user')}
    ${name}${message(t('好，我可以把它存到当前 Bot 的记忆里。你也可以随时查看和删除。', 'I can save that in this Bot’s memory. You can review or delete it at any time.'))}
    <div class="native-memory"><div class="native-card-heading"><span>✧</span><strong>${t('写作偏好', 'Writing preference')}</strong><small>${state.memorySaved ? t('已保存', 'Saved') : t('待保存', 'Ready to save')}</small></div>
    <p>${t('周报先写结论，再列出下一步待办。', 'Start weekly updates with a conclusion, then list next steps.')}</p>
    ${state.memorySaved
      ? `<div class="native-confirmed">✓ ${t('已加入大肥鱼的记忆', 'Added to Big Fish’s memory')}</div><details class="native-details"><summary>${t('查看这条记忆', 'Review this memory')}</summary><p>${t('范围：当前 Bot。后续对话可使用这个偏好。', 'Scope: this Bot. The preference is available to future conversations.')}</p><button class="native-delete" data-demo-action="forget">${t('删除记忆', 'Forget this preference')}</button></details>`
      : `<button class="native-primary" data-demo-action="remember">${t('保存这条记忆', 'Save this memory')}</button>`}
    </div>`;
}

function dshContent(state, t) {
  if (state.workspaceOpen) {
    return `<div class="native-page-title"><h3>${t('工作区文件', 'Workspace files')}</h3><button class="native-link" data-demo-action="close-files">${t('返回会话', 'Back to chat')}</button></div>
      <div class="native-path">/workspace</div>${artifact('brief', t)}${artifact('data', t)}
      <p class="native-hint">${t('点按文件打开预览，然后回到会话继续处理。', 'Preview a file, then return to the conversation.')}</p>`;
  }
  const analysis = state.case !== 'document';
  const request = analysis
    ? t('分析这份 CSV，整理重点，给我一份简报。', 'Analyze this CSV and turn the key findings into a brief.')
    : t('把 notes.md 整理成一份产品调研文档。', 'Turn notes.md into a product research brief.');
  let result = '';
  if (state.progress === 'ready') {
    result = `<div class="native-run-card"><p>${analysis ? t('读取示例表格，统计场景分布，生成结果文件。', 'Read the sample table, summarize the categories and create the output.') : t('读取笔记、整理结构，并将文档保存到工作区。', 'Read the notes, organize the structure and save a document.')}</p>
      <button class="native-primary" data-demo-action="run">${analysis ? t('运行分析', 'Run analysis') : t('开始整理', 'Create document')} <span>↗</span></button></div>`;
  } else if (state.progress === 'running') {
    result = `<div class="native-progress" role="status"><span class="spinner"></span>${t('正在处理示例资料…', 'Processing the sample material…')}</div>`;
  } else {
    result = `<details class="native-details tool-log"><summary>${t('已调用工具 · 展开过程', 'Tools used · inspect the steps')}</summary>
      <div class="native-log-row"><span>✓ read_file</span><code>${analysis ? 'research.csv' : 'notes.md'}</code></div>
      <div class="native-log-row"><span>✓ ${analysis ? 'python3' : 'write_file'}</span><code>${analysis ? 'summarize.py' : 'research.md'}</code></div>
      <div class="native-log-row"><span>✓ write_file</span><code>research.md</code></div></details>
      ${message(analysis ? t('示例数据已整理。文件处理占 78%，资料梳理占 65%，工具连接占 48%。这些数据来自独立多选项，统计结果已写入简报。', 'The sample data is ready. File handling is 78%, research is 65%, and tools are 48%. These are independent, multiple-choice categories. The summary is saved.') : t('文档已整理为关键发现和下一步行动，保存在工作区。', 'Your notes are organized into findings and next steps, and saved in the workspace.'))}
      ${artifact(analysis ? 'data' : 'brief', t)}
      <button class="native-link" data-demo-action="open-files">${t('打开工作区文件', 'Open workspace files')} →</button>`;
  }
  return `${message(state.prompt || request, 'user')}<div class="native-attachment"><span>${analysis ? 'CSV' : 'MD'}</span>${analysis ? 'research.csv' : 'notes.md'}<small>${t('示例附件', 'Sample attachment')}</small></div>
    <div class="native-author"><span class="native-dsh-icon"></span>DSH</div>${result}`;
}

function discoverContent(state, t) {
  const connectors = [
    ['gmail', 'Gmail', t('搜索和阅读邮件', 'Search and read mail'), '✉'],
    ['devices', t('设备', 'Devices'), t('通过蓝牙连接外设', 'Connect Bluetooth peripherals'), '⌁'],
    ['search', t('网页搜索', 'Web search'), t('搜索和读取网页', 'Search and read the web'), '◎'],
    ['mcp', t('自定义 MCP 服务', 'Custom MCP server'), t('添加你自己的服务地址', 'Add your own server address'), '▤']
  ];
  const selected = connectors.find(([key]) => key === state.details);
  if (selected) {
    return `<button class="native-link" data-demo-action="back">← ${t('发现', 'Discover')}</button>
      <div class="native-connector-detail"><span>${selected[3]}</span><h3>${selected[1]}</h3><p>${selected[2]}</p></div>
      <p class="native-hint">${selected[0] === 'gmail'
        ? t('Gmail 连接器提供只读搜索与正文预览。目前处于 OAuth 测试阶段。', 'The Gmail connector supports read-only search and message previews. It is currently in OAuth testing.')
        : t('在 App 中配置此服务后，可以在对应功能中使用。', 'Configure this service in the app to use it in supported workflows.')}</p>
      <div class="native-demo-note">${t('网站示意 · 使用示例内容', 'Website demo · sample content')}</div>`;
  }
  return `<h3 class="native-section-label">${t('连接器', 'Connectors')}</h3><div class="native-settings-group">
    ${connectors.map(([key, title, description, symbol]) => `<button class="native-settings-row" data-demo-action="connector" data-value="${key}"><span class="connector-symbol">${symbol}</span><span><strong>${title}</strong><small>${description}</small></span><span>›</span></button>`).join('')}
    </div><p class="native-hint">${t('点按连接器，查看它能做什么。', 'Tap a connector to see what it does.')}</p>`;
}

function meContent(state, t) {
  return `<div class="native-profile"><img src="/assets/app-icon.png" alt="Phone DSH"><strong>Phone DSH</strong><small>${t('你的口袋 AI 工作区', 'Your pocket AI workspace')}</small></div>
    <div class="native-settings-group"><div class="native-setting-title">${t('模型服务', 'Model service')}<span>${t('演示配置', 'Demo settings')}</span></div>
    <div class="native-models">${['DeepSeek', 'OpenAI', 'Anthropic'].map(model => `<button data-demo-action="model" data-value="${model}" aria-pressed="${state.model === model}">${model}<span>${state.model === model ? '✓' : ''}</span></button>`).join('')}</div></div>
    <button class="native-settings-row standalone" data-demo-action="open-files"><span>▤</span><strong>${t('工作区文件', 'Workspace files')}</strong><span>›</span></button>
    <a class="native-settings-row standalone" href="/privacy"><span>◈</span><strong>${t('隐私政策', 'Privacy policy')}</strong><span>›</span></a>`;
}

export function renderDemo(container, state, language) {
  if (!container) return;
  const t = (zh, en) => language === 'zh' ? zh : en;
  const conversational = ['bot', 'dsh'].includes(state.tab);
  const title = { bot: t('大肥鱼', 'Big Fish'), dsh: t('新会话', 'New session'), discover: t('发现', 'Discover'), me: t('我的', 'Me') }[state.tab];
  const renderers = { bot: botContent, dsh: dshContent, discover: discoverContent, me: meContent };
  container.innerHTML = `
    <header class="native-toolbar ${state.tab === 'bot' ? 'bot-toolbar' : ''}">
      <button class="native-toolbar-button" data-demo-action="menu" aria-label="${state.tab === 'bot' ? t('查看 Bot 列表', 'View Bot list') : t('查看工作区', 'View workspace')}">☰</button>
      <div class="native-title">${state.tab === 'bot' ? '<img src="/assets/bot-avatar.png" alt="">' : ''}<strong>${title}</strong></div>
      <button class="native-toolbar-button" data-demo-action="tab" data-value="me" aria-label="${t('模型与设置', 'Models and settings')}">•••</button>
    </header>
    <div class="native-content" aria-live="polite"><div class="native-demo-note">${t('交互演示 · 示例内容', 'Interactive demo · sample content')}</div>${renderers[state.tab](state, t)}</div>
    ${conversational && !state.workspaceOpen ? `<form class="native-composer" data-demo-form>
      <button type="button" data-demo-action="open-files" aria-label="${t('查看文件', 'View files')}">＋</button>
      <input autocomplete="off" maxlength="160" aria-label="${t('输入演示指令', 'Enter a demo prompt')}" placeholder="${state.tab === 'bot' ? t('向大肥鱼提问', 'Ask Big Fish') : t('描述你想完成的任务', 'Describe a task')}" ${state.progress === 'running' ? 'disabled' : ''}>
      <button type="submit" class="native-send" aria-label="${t('发送演示指令', 'Send demo prompt')}" ${state.progress === 'running' ? 'disabled' : ''}>↑</button>
    </form>` : ''}
    ${navigation(state, t)}`;
}

export function selectCase(state, selected) {
  clearTimeout(state.timer);
  state.timer = null;
  state.case = selected;
  state.tab = ['memory', 'approval'].includes(selected) ? 'bot' : 'dsh';
  state.workspaceOpen = false;
  state.details = null;
  state.prompt = '';
  state.progress = 'ready';
  state.approval = 'pending';
}

export function demoAction(state, action, value, update) {
  switch (action) {
    case 'tab':
      state.tab = value;
      state.workspaceOpen = false;
      state.details = null;
      if (value === 'bot' && !['memory', 'approval'].includes(state.case)) selectCase(state, 'memory');
      if (value === 'dsh' && !['analysis', 'document'].includes(state.case)) selectCase(state, 'analysis');
      break;
    case 'remember': state.memorySaved = true; break;
    case 'forget': state.memorySaved = false; break;
    case 'approve': state.approval = 'allowed'; break;
    case 'deny': state.approval = 'denied'; break;
    case 'retry-approval': state.approval = 'pending'; break;
    case 'run':
      if (state.progress === 'running') return;
      state.progress = 'running';
      state.timer = setTimeout(() => {
        state.progress = 'done';
        state.timer = null;
        update();
      }, 1100);
      break;
    case 'menu':
      if (state.tab === 'bot') {
        state.details = 'bots';
        break;
      }
      state.tab = 'dsh';
      state.workspaceOpen = true;
      break;
    case 'open-files':
      state.tab = 'dsh';
      state.workspaceOpen = true;
      break;
    case 'close-files': state.workspaceOpen = false; break;
    case 'connector': state.details = value; break;
    case 'back': state.details = null; break;
    case 'model': state.model = value; break;
  }
  update();
}

export function submitDemo(state, prompt, update) {
  const trimmed = prompt.trim();
  if (!trimmed || state.progress === 'running') return;
  if (state.tab === 'bot') {
    selectCase(state, /记住|偏好|remember|preference/i.test(trimmed) ? 'memory' : 'approval');
    state.prompt = trimmed;
    update();
  } else {
    selectCase(state, /文档|笔记|document|notes/i.test(trimmed) ? 'document' : 'analysis');
    state.prompt = trimmed;
    demoAction(state, 'run', '', update);
  }
}
