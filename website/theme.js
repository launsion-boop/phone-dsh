// SPDX-License-Identifier: MIT
(() => {
  let preference = 'system';
  let language = 'zh';
  try {
    preference = localStorage.getItem('phonedsh.theme') || 'system';
    language = localStorage.getItem('phonedsh.language') || 'zh';
  } catch {}
  if (!['system', 'light', 'dark'].includes(preference)) preference = 'system';
  document.documentElement.dataset.theme = preference === 'system'
    ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
    : preference;
  document.documentElement.dataset.themePreference = preference;
  document.documentElement.lang = language === 'en' ? 'en' : 'zh-CN';
})();
