'use strict';

let md = null;

window.addEventListener('DOMContentLoaded', () => {
  md = window.markdownit({
    html: false,          // never execute HTML from the notes file
    linkify: true,
    highlight: (str, lang) => {
      if (lang && window.hljs && hljs.getLanguage(lang)) {
        try { return hljs.highlight(str, { language: lang }).value; } catch (_) { /* fall through */ }
      }
      return '';
    },
  });
});

// Called from Swift via callAsyncJavaScript. Preserves relative scroll
// position across live reloads.
function renderMarkdown(text) {
  if (!md) return false;
  const se = document.scrollingElement || document.documentElement;
  const maxScroll = Math.max(1, se.scrollHeight - se.clientHeight);
  const ratio = se.scrollTop / maxScroll;

  document.getElementById('content').innerHTML = md.render(text || '');
  decorateCodeBlocks();

  const newMax = Math.max(0, se.scrollHeight - se.clientHeight);
  se.scrollTop = ratio * newMax;
  return true;
}

// One-click copy button on every fenced code block. The text goes through the
// native pasteboard (script message handler) — reliable on file:// pages.
function decorateCodeBlocks() {
  document.querySelectorAll('#content pre').forEach((pre) => {
    const btn = document.createElement('button');
    btn.className = 'copy-btn';
    btn.type = 'button';
    btn.textContent = 'Copy';
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const code = pre.querySelector('code');
      const text = (code ? code.innerText : pre.innerText).replace(/\n$/, '');
      window.webkit?.messageHandlers?.copy?.postMessage(text);
      btn.textContent = 'Copied ✓';
      btn.classList.add('copied');
      setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1200);
    });
    pre.appendChild(btn);
  });
}

// Hook for switching the opacity slider from whole-window alpha to
// CSS-background-only alpha, if that ever reads better.
function setBackgroundAlpha(alpha) {
  document.documentElement.style.setProperty('--bg-alpha', String(alpha));
}

// Shown while macOS display mirroring is active: the OS mirror clones the
// framebuffer below the capture pipeline, so the notes ARE on the beamer.
function setMirrorWarning(visible) {
  let banner = document.getElementById('mirror-warning');
  if (visible && !banner) {
    banner = document.createElement('div');
    banner.id = 'mirror-warning';
    banner.textContent = '⚠️ macOS mirroring is ON — these notes are VISIBLE on the external display. Use Start Mirror in GhostScreen to hide them.';
    document.body.prepend(banner);
  } else if (!visible && banner) {
    banner.remove();
  }
  return true;
}
