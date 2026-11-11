// SPDX-License-Identifier: MIT
import { createDemoState, renderDemo, selectCase, demoAction, submitDemo } from './demos.js';

const root = document.documentElement;
let language = root.lang === 'en' ? 'en' : 'zh';
const demoStates = { phone: createDemoState(), feature: createDemoState() };
const systemTheme = matchMedia('(prefers-color-scheme: dark)');
const text = (zh, en) => language === 'zh' ? zh : en;

function remember(key, value) {
  try { localStorage.setItem(`phonedsh.${key}`, value); } catch {}
}

function applyTheme(preference) {
  root.dataset.themePreference = preference;
  root.dataset.theme = preference === 'system' ? (systemTheme.matches ? 'dark' : 'light') : preference;
  document.querySelectorAll('[data-theme-choice]').forEach(button => {
    button.setAttribute('aria-pressed', String(button.dataset.themeChoice === preference));
  });
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', root.dataset.theme === 'dark' ? '#171a18' : '#ffffff');
}

function closeThemeMenu() {
  document.querySelector('[data-theme-menu]').hidden = true;
  document.querySelector('[data-theme-toggle]').setAttribute('aria-expanded', 'false');
}

function applyLanguage() {
  root.lang = language === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-zh][data-en]').forEach(element => {
    element.textContent = element.dataset[language].replaceAll('\\n', '\n');
  });
  document.querySelectorAll('button[data-language]').forEach(button => {
    button.textContent = language === 'zh' ? 'EN' : '中文';
    button.setAttribute('aria-label', text('Switch to English', '切换到中文'));
  });
  document.querySelector('[data-theme-toggle]')?.setAttribute('aria-label', text('选择主题', 'Choose theme'));
  document.querySelectorAll('.policy-article').forEach(article => {
    article.hidden = article.dataset.language !== language;
  });
  const policy = document.querySelector('.policy-article:not([hidden])');
  if (policy) {
    document.title = text('隐私政策 · Phone DSH', 'Privacy policy · Phone DSH');
    const toc = document.querySelector('.privacy-nav');
    toc.replaceChildren();
    policy.querySelectorAll('h3').forEach((heading, index) => {
      heading.id = `${language}-section-${index}`;
      const link = document.createElement('a');
      link.href = `#${heading.id}`;
      link.textContent = heading.textContent;
      toc.append(link);
    });
  } else {
    document.title = text('Phone DSH · 把想法，做成结果。', 'Phone DSH · Your pocket AI workspace');
  }
  renderPhone();
  renderWorkspace();
}

function renderSurface(name) {
  const state = demoStates[name];
  renderDemo(document.querySelector(`#${name}-demo`), state, language);
  if (name === 'feature') {
    document.querySelectorAll('[data-scenario]').forEach(button => {
      const caseSelected = ['bot', 'dsh'].includes(state.tab) && button.dataset.scenario === state.case;
      button.setAttribute('aria-selected', String(caseSelected));
    });
  }
}

function renderPhone() { renderSurface('phone'); }
function renderWorkspace() { renderSurface('feature'); }

function showPreview(kind) {
  const dialog = document.querySelector('#preview-dialog');
  const isData = kind === 'data';
  document.querySelector('#preview-filename').textContent = isData ? text('调研数据.csv', 'Research data.csv') : text('产品调研.md', 'Research brief.md');
  const sample = `<div class="eyebrow">${text('示例内容 · 交互原型', 'SAMPLE CONTENT · INTERACTIVE PROTOTYPE')}</div>`;
  const bars = `<div class="preview-bars">${[[text('文件整理','Files'),78],[text('资料梳理','Research'),65],[text('连接工具','Tools'),48]].map(([label,value]) => `<div class="preview-bar"><span>${label}</span><div><i style="width:${value}%"></i></div><span>${value}%</span></div>`).join('')}</div>`;
  document.querySelector('#preview-body').innerHTML = isData
    ? `${sample}<h2>${text('工作场景分布', 'A look at the workflow')}</h2><p>${text('以下为演示图表使用的虚构数据。', 'Illustrative data created for this demo.')}</p>${bars}<p>${text('在实际 App 中，文件保存在工作区，可以继续交给 Agent 处理。', 'In the app, workspace files are available for the agent to keep working on.')}</p>`
    : `${sample}<h2>${text('让灵感在手机上落地', 'Bring an idea to life on your phone')}</h2><p>${text('一份演示简报，探索如何把零散资料变成可继续使用的成果。', 'A sample brief about turning scattered material into something useful.')}</p><h3>${text('我们发现了什么', 'What we found')}</h3><ul><li>${text('手机上的工作经常从一句话或一个文件开始。', 'Work on a phone often starts with a message or a file.')}</li><li>${text('看得见的任务过程，有助于及时调整方向。', 'Visible task progress makes it easier to adjust the direction.')}</li><li>${text('把成果保留为文件，才能顺手继续下一步。', 'Saving the output as a file makes the next step easier.')}</li></ul><h3>${text('接下来怎么做', 'Where to go next')}</h3><p>${text('先明确目标，再提供相关资料。查看 Agent 的处理过程，打开工作区文件，然后继续对话完善结果。', 'Set a goal and add the relevant material. Follow the agent’s progress, open the workspace file, and refine the result together.')}</p>`;
  if (!dialog.open) dialog.showModal();
}

document.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!event.target.closest('.theme-control')) closeThemeMenu();
  if (!button) return;
  if (button.hasAttribute('data-language')) {
    language = language === 'zh' ? 'en' : 'zh';
    remember('language', language);
    applyLanguage();
  }
  if (button.hasAttribute('data-theme-toggle')) {
    const menu = document.querySelector('[data-theme-menu]');
    menu.hidden = !menu.hidden;
    button.setAttribute('aria-expanded', String(!menu.hidden));
  }
  if (button.dataset.themeChoice) {
    applyTheme(button.dataset.themeChoice);
    remember('theme', button.dataset.themeChoice);
    closeThemeMenu();
  }
  if (button.dataset.scenario) {
    selectCase(demoStates.feature, button.dataset.scenario);
    renderWorkspace();
  }
  if (button.hasAttribute('data-reset-feature')) {
    const selected = demoStates.feature.case;
    clearTimeout(demoStates.feature.timer);
    demoStates.feature = createDemoState();
    selectCase(demoStates.feature, selected);
    renderWorkspace();
  }
  if (button.dataset.demoAction) {
    const surface = button.closest('[data-demo-surface]').dataset.demoSurface;
    demoAction(demoStates[surface], button.dataset.demoAction, button.dataset.value, () => renderSurface(surface));
  }
  if (button.dataset.preview) showPreview(button.dataset.preview);
  if (button.hasAttribute('data-close-preview')) document.querySelector('#preview-dialog').close();
  if (button.hasAttribute('data-open-contact')) {
    const dialog = document.querySelector('#contact-dialog');
    if (!dialog.open) dialog.showModal();
  }
  if (button.hasAttribute('data-close-contact')) document.querySelector('#contact-dialog').close();
});

document.addEventListener('submit', event => {
  if (!event.target.matches('[data-demo-form]')) return;
  event.preventDefault();
  const input = event.target.querySelector('input');
  if (!input.value.trim()) {
    input.focus();
    return;
  }
  const surface = event.target.closest('[data-demo-surface]').dataset.demoSurface;
  submitDemo(demoStates[surface], input.value, () => renderSurface(surface));
});

document.querySelectorAll('dialog').forEach(dialog => {
  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const rect = dialog.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
  });
});
document.addEventListener('keydown', event => { if (event.key === 'Escape') closeThemeMenu(); });
document.addEventListener('keydown', event => {
  if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
  const list = event.target.closest('[role="tablist"]');
  if (!list) return;
  const tabs = [...list.querySelectorAll('[role="tab"]')];
  const index = tabs.indexOf(document.activeElement);
  if (index === -1) return;
  event.preventDefault();
  const direction = ['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : -1;
  let next = (index + direction + tabs.length) % tabs.length;
  if (event.key === 'Home') next = 0;
  if (event.key === 'End') next = tabs.length - 1;
  const nextTab = tabs[next];
  const value = nextTab.dataset.value;
  const surface = list.closest('[data-demo-surface]');
  nextTab.click();
  const focusTarget = value ? surface.querySelector(`[role="tab"][data-value="${value}"]`) : nextTab;
  focusTarget.focus();
});
systemTheme.addEventListener('change', () => applyTheme(root.dataset.themePreference));
applyTheme(root.dataset.themePreference);
applyLanguage();
