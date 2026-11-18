/* avd-ops theme and drawer v3.0.0 (https://avd-ops.dev/, avd-ops/avd-ops site/assets/theme.js). MIT.
   Personal project, not for production, as is; not affiliated with the author's employer or Microsoft.
   Load it in <head> without defer: it applies a saved theme and adopter palette before the page paints, then wires
   the shell's theme button (.theme), gear customizer (.customize), first-time setup popover, and menu button (.menu).
   No libraries, no requests. Choices are stored in this browser only; if storage is blocked the page uses defaults. */
(function () {
  var root = document.documentElement;
  var KEY = 'avd-ops-theme';
  var DEV_KEY = 'avd-ops-devmode';
  var ADOPTER_KEY = 'avd-ops-adopter-theme';
  var SETUP_KEY = 'avd-ops-adopter-setup';
  root.classList.add('js');

  var PALETTES = {
    teal: {
      name: 'Teal',
      light: '--accent:#0b7a6e;--accent-hover:#075f56;--on-accent:#ffffff;--accent-soft:#e1f2ef;--accent-line:#a9dbd3;--focus:#0b7a6e;--brand:#1ca998;--shell:#0d1015;--shell-fg:#e8f1f0;--shell-muted:#a3b3b8;--shell-line:#222b31;--shell-hover:#1a2329;',
      dark: '--accent:#3cc8b4;--accent-hover:#7fe0d2;--on-accent:#06110f;--accent-soft:#0f2e2b;--accent-line:#1f5a52;--focus:#7fe0d2;--brand:#1ca998;--shell:#070a0c;--shell-fg:#e8f1f0;--shell-muted:#93a6ad;--shell-line:#1a2328;--shell-hover:#12191d;'
    },
    cobalt: {
      name: 'Cobalt',
      light: '--accent:#1d4ed8;--accent-hover:#163ca8;--on-accent:#ffffff;--accent-soft:#e4eafb;--accent-line:#b0c2f2;--focus:#1d4ed8;--brand:#2563eb;--shell:#0c1322;--shell-fg:#e8f1f0;--shell-muted:#a1aab4;--shell-line:#2a313e;--shell-hover:#1e2634;',
      dark: '--accent:#60a5fa;--accent-hover:#98c4fc;--on-accent:#06110f;--accent-soft:#192a3d;--accent-line:#2b486a;--focus:#98c4fc;--brand:#3b82f6;--shell:#070b14;--shell-fg:#e8f1f0;--shell-muted:#9da6b0;--shell-line:#262b33;--shell-hover:#1a2029;'
    },
    slate: {
      name: 'Slate',
      light: '--accent:#334155;--accent-hover:#273242;--on-accent:#ffffff;--accent-soft:#e7e9eb;--accent-line:#b8bdc4;--focus:#334155;--brand:#475569;--shell:#0f172a;--shell-fg:#e8f1f0;--shell-muted:#a2acb4;--shell-line:#2c3444;--shell-hover:#20293a;',
      dark: '--accent:#cbd5e1;--accent-hover:#dde4ec;--on-accent:#06110f;--accent-soft:#2c333b;--accent-line:#535c66;--focus:#dde4ec;--brand:#94a3b8;--shell:#090d16;--shell-fg:#e8f1f0;--shell-muted:#9ea6ad;--shell-line:#282c34;--shell-hover:#1c2028;'
    },
    forest: {
      name: 'Forest',
      light: '--accent:#166534;--accent-hover:#114e28;--on-accent:#ffffff;--accent-soft:#e3ede7;--accent-line:#adc9b8;--focus:#166534;--brand:#16a34a;--shell:#0b140e;--shell-fg:#e8f1f0;--shell-muted:#a0aba6;--shell-line:#2a322e;--shell-hover:#1d2621;',
      dark: '--accent:#4ade80;--accent-hover:#89e9ac;--on-accent:#06110f;--accent-soft:#153425;--accent-line:#225d3f;--focus:#89e9ac;--brand:#22c55e;--shell:#060c08;--shell-fg:#e8f1f0;--shell-muted:#9ca6a1;--shell-line:#252b28;--shell-hover:#191f1c;'
    },
    amber: {
      name: 'Amber',
      light: '--accent:#9a5b12;--accent-hover:#78470e;--on-accent:#ffffff;--accent-soft:#f3ebe2;--accent-line:#dcc6ac;--focus:#9a5b12;--brand:#d97706;--shell:#14100a;--shell-fg:#e8f1f0;--shell-muted:#a7a6a1;--shell-line:#312f2a;--shell-hover:#25221d;',
      dark: '--accent:#f59e0b;--accent-hover:#f9c060;--on-accent:#06110f;--accent-soft:#342910;--accent-line:#634510;--focus:#f9c060;--brand:#f59e0b;--shell:#0b0905;--shell-fg:#e8f1f0;--shell-muted:#a1a09b;--shell-line:#2b2a26;--shell-hover:#1e1d19;'
    }
  };

  var FONTS = {
    'grotesk-plex': {
      name: 'Grotesk + Mono',
      css: '--display:"Schibsted Grotesk","Segoe UI",system-ui,sans-serif;--body:"IBM Plex Mono",ui-monospace,"Cascadia Mono",SFMono-Regular,Menlo,Consolas,monospace;--mono:"IBM Plex Mono",ui-monospace,"Cascadia Mono",SFMono-Regular,Menlo,Consolas,monospace;--wordmark:"Schibsted Grotesk","Segoe UI",system-ui,sans-serif;'
    },
    'system-sans': {
      name: 'System Sans',
      css: '--display:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;--body:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;--mono:ui-monospace,"Cascadia Mono",SFMono-Regular,Menlo,Consolas,monospace;--wordmark:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;'
    },
    'editorial-serif': {
      name: 'Editorial Serif',
      css: '--display:"Source Serif 4",Georgia,"Times New Roman",serif;--body:"Source Serif 4",Georgia,"Times New Roman",serif;--mono:"IBM Plex Mono",ui-monospace,"Cascadia Mono",SFMono-Regular,Menlo,Consolas,monospace;--wordmark:"Source Serif 4",Georgia,"Times New Roman",serif;'
    },
    'grotesk-sans': {
      name: 'Grotesk + Sans',
      css: '--display:"Schibsted Grotesk","Segoe UI",system-ui,sans-serif;--body:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;--mono:"IBM Plex Mono",ui-monospace,"Cascadia Mono",SFMono-Regular,Menlo,Consolas,monospace;--wordmark:"Schibsted Grotesk","Segoe UI",system-ui,sans-serif;'
    }
  };

  function readAdopter() {
    try {
      var raw = localStorage.getItem(ADOPTER_KEY);
      if (!raw) return null;
      var obj = JSON.parse(raw);
      return obj && typeof obj === 'object' ? obj : null;
    } catch (e) { return null; }
  }

  function applyAdopter(cfg) {
    var el = document.getElementById('avd-ops-adopter-live');
    if (!cfg || (cfg.presetId === 'teal' && cfg.fontId === 'grotesk-plex' && !cfg.customCss)) {
      if (el) el.textContent = '';
      return;
    }
    if (!el) {
      el = document.createElement('style');
      el.id = 'avd-ops-adopter-live';
      (document.head || root).appendChild(el);
    }
    if (cfg.customCss) {
      el.textContent = cfg.customCss;
      return;
    }
    var p = PALETTES[cfg.presetId] || PALETTES.teal;
    var f = FONTS[cfg.fontId] || FONTS['grotesk-plex'];
    el.textContent = ':root{' + p.light + f.css + '}@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){' + p.dark + '}}:root[data-theme="dark"]{' + p.dark + '}';
  }

  try { var saved = localStorage.getItem(KEY); if (saved === 'light' || saved === 'dark') root.setAttribute('data-theme', saved); } catch (e) { /* storage blocked */ }
  try { var savedDev = localStorage.getItem(DEV_KEY); if (savedDev === 'on' || savedDev === 'off') root.setAttribute('data-dev', savedDev); } catch (e) { /* storage blocked */ }
  if (typeof location !== 'undefined' && location.hostname === 'avd-ops.app') applyAdopter(readAdopter());

  function isDark() {
    var t = root.getAttribute('data-theme');
    if (t) return t === 'dark';
    try { return window.matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return false; }
  }

  function isDev() {
    return root.getAttribute('data-dev') === 'on';
  }

  function applyDev(on) {
    root.setAttribute('data-dev', on ? 'on' : 'off');
    var shells = document.querySelectorAll('.shell');
    for (var i = 0; i < shells.length; i++) shells[i].classList.toggle('dev-on', on);
    var devs = document.querySelectorAll('.shell .dev');
    var msg = on ? 'Hide contract and decision IDs (dev mode on)' : 'Show contract and decision IDs (dev mode)';
    for (var j = 0; j < devs.length; j++) {
      devs[j].setAttribute('aria-pressed', on ? 'true' : 'false');
      devs[j].setAttribute('aria-label', msg);
      devs[j].setAttribute('title', msg);
    }
    var nodes = document.querySelectorAll('[data-dev-text][data-pub-text]');
    for (var k = 0; k < nodes.length; k++) {
      nodes[k].textContent = on ? nodes[k].getAttribute('data-dev-text') : nodes[k].getAttribute('data-pub-text');
    }
    try { window.dispatchEvent(new CustomEvent('avd-ops-devmode', { detail: { dev: on } })); } catch (e) { /* old browser */ }
  }

  window.AvdOpsDev = {
    isOn: isDev,
    set: function (on) {
      var next = Boolean(on);
      try { localStorage.setItem(DEV_KEY, next ? 'on' : 'off'); } catch (e) { /* storage blocked */ }
      applyDev(next);
    }
  };

  window.AvdOpsTheme = {
    get: function () { return readAdopter() || { presetId: 'teal', fontId: 'grotesk-plex' }; },
    set: function (cfg) {
      var next = {
        presetId: (cfg && PALETTES[cfg.presetId]) ? cfg.presetId : 'teal',
        fontId: (cfg && FONTS[cfg.fontId]) ? cfg.fontId : 'grotesk-plex'
      };
      if (cfg && cfg.customCss) next.customCss = cfg.customCss;
      try { localStorage.setItem(ADOPTER_KEY, JSON.stringify(next)); localStorage.setItem(SETUP_KEY, '1'); } catch (e) { /* storage blocked */ }
      applyAdopter(next);
      try { document.dispatchEvent(new CustomEvent('avd-ops-adopter-theme', { detail: next })); } catch (e) { /* old browser */ }
      return next;
    },
    reset: function () {
      try { localStorage.removeItem(ADOPTER_KEY); localStorage.setItem(SETUP_KEY, '1'); } catch (e) { /* storage blocked */ }
      applyAdopter(null);
      try { document.dispatchEvent(new CustomEvent('avd-ops-adopter-theme', { detail: { presetId: 'teal', fontId: 'grotesk-plex' } })); } catch (e) { /* old browser */ }
    }
  };

  function wireCustomizer(shell) {
    var gear = document.querySelector('.shell .customize');
    if (!gear || !shell) return;
    applyAdopter(readAdopter());
    var pop = document.createElement('div');
    pop.className = 'cust-pop';
    pop.setAttribute('role', 'dialog');
    pop.setAttribute('aria-label', 'Theme and palette customizer');
    pop.hidden = true;

    var cur = window.AvdOpsTheme.get();
    var mode = (function () { try { return localStorage.getItem(KEY) || 'system'; } catch (e) { return 'system'; } }());

    function btnRow(items, activeKey, attr) {
      return items.map(function (item) {
        return '<button class="cust-pop-opt" type="button" data-' + attr + '="' + item[0] + '" aria-pressed="' + (item[0] === activeKey ? 'true' : 'false') + '">' + item[1] + '</button>';
      }).join('');
    }

    var paletteItems = Object.keys(PALETTES).map(function (id) { return [id, PALETTES[id].name]; });
    var fontItems = Object.keys(FONTS).map(function (id) { return [id, FONTS[id].name]; });
    var modeItems = [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']];

    pop.innerHTML = '<div class="cust-pop-head"><strong id="cust-pop-title">Customize theme &amp; palette</strong><button class="cust-pop-close" type="button" aria-label="Close theme customizer">&times;</button></div>'
      + '<p class="cust-pop-sub">Pick a theme and palette combo for this browser, or open the full customizer to export <code>adopter-theme.css</code>.</p>'
      + '<div class="cust-pop-group"><span class="cust-pop-lbl">Appearance</span><div class="cust-pop-row">' + btnRow(modeItems, mode, 'mode') + '</div></div>'
      + '<div class="cust-pop-group"><span class="cust-pop-lbl">Color palette</span><div class="cust-pop-row">' + btnRow(paletteItems, cur.presetId, 'preset') + '</div></div>'
      + '<div class="cust-pop-group"><span class="cust-pop-lbl">Typography</span><div class="cust-pop-row">' + btnRow(fontItems, cur.fontId, 'font') + '</div></div>'
      + '<div class="cust-pop-foot"><button class="cust-pop-save" type="button">Done</button><button class="cust-pop-opt" type="button" data-reset="1">Reset</button><a class="cust-pop-link">Full customizer &rarr;</a></div>';

    var rawHref = gear.getAttribute('data-design-href') || '';
    var depth = Math.min(4, (rawHref.match(/\.\.\//g) || []).length);
    var safeHref = (typeof location !== 'undefined' && location.hostname === 'avd-ops.app')
      ? '/customizer/#customize'
      : new Array(depth + 1).join('../') + 'design/index.html#customize';
    var link = pop.querySelector('.cust-pop-link');
    if (link) link.setAttribute('href', safeHref);
    shell.appendChild(pop);

    function syncPressed() {
      var active = window.AvdOpsTheme.get();
      var m = (function () { try { return localStorage.getItem(KEY) || 'system'; } catch (e) { return 'system'; } }());
      pop.querySelectorAll('[data-mode]').forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-mode') === m ? 'true' : 'false'); });
      pop.querySelectorAll('[data-preset]').forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-preset') === active.presetId ? 'true' : 'false'); });
      pop.querySelectorAll('[data-font]').forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-font') === active.fontId ? 'true' : 'false'); });
    }

    function setOpen(open, firstTime) {
      var title = pop.querySelector('#cust-pop-title');
      if (title) title.textContent = firstTime ? 'First-time setup: choose your theme' : 'Customize theme & palette';
      pop.hidden = !open;
      gear.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) syncPressed();
      else {
        try { localStorage.setItem(SETUP_KEY, '1'); } catch (e) { /* storage blocked */ }
      }
    }

    gear.addEventListener('click', function () { setOpen(pop.hidden, false); });
    pop.querySelector('.cust-pop-close').addEventListener('click', function () { setOpen(false); gear.focus(); });
    pop.querySelector('.cust-pop-save').addEventListener('click', function () { setOpen(false); gear.focus(); });
    pop.querySelector('[data-reset]').addEventListener('click', function () {
      root.removeAttribute('data-theme');
      try { localStorage.removeItem(KEY); } catch (e) { /* storage blocked */ }
      window.AvdOpsTheme.reset();
      syncPressed();
    });

    pop.addEventListener('click', function (e) {
      var mBtn = e.target.closest && e.target.closest('[data-mode]');
      if (mBtn) {
        var nextMode = mBtn.getAttribute('data-mode');
        if (nextMode === 'system') {
          root.removeAttribute('data-theme');
          try { localStorage.removeItem(KEY); } catch (err) { /* storage blocked */ }
        } else {
          root.setAttribute('data-theme', nextMode);
          try { localStorage.setItem(KEY, nextMode); } catch (err) { /* storage blocked */ }
        }
        syncPressed();
        return;
      }
      var pBtn = e.target.closest && e.target.closest('[data-preset]');
      if (pBtn) {
        var now = window.AvdOpsTheme.get();
        window.AvdOpsTheme.set({ presetId: pBtn.getAttribute('data-preset'), fontId: now.fontId });
        syncPressed();
        return;
      }
      var fBtn = e.target.closest && e.target.closest('[data-font]');
      if (fBtn) {
        var curCfg = window.AvdOpsTheme.get();
        window.AvdOpsTheme.set({ presetId: curCfg.presetId, fontId: fBtn.getAttribute('data-font') });
        syncPressed();
      }
    });

    document.addEventListener('pointerdown', function (e) {
      if (!pop.hidden && !pop.contains(e.target) && !gear.contains(e.target)) setOpen(false);
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !pop.hidden) { setOpen(false); gear.focus(); }
    });
    document.addEventListener('avd-ops-adopter-theme', syncPressed);

    try {
      if (!localStorage.getItem(ADOPTER_KEY) && !localStorage.getItem(SETUP_KEY)) {
        setOpen(true, true);
      }
    } catch (e) { /* storage blocked */ }
  }

  function wire() {
    applyDev(isDev());
    var devs = document.querySelectorAll('.shell .dev');
    for (var d = 0; d < devs.length; d++) {
      devs[d].addEventListener('click', function () {
        window.AvdOpsDev.set(!isDev());
      });
    }

    var theme = document.querySelector('.shell .theme');
    if (theme) {
      var label = function () { theme.setAttribute('aria-label', isDark() ? 'Switch to light theme' : 'Switch to dark theme'); };
      label();
      theme.addEventListener('click', function () {
        var next = isDark() ? 'light' : 'dark';
        root.setAttribute('data-theme', next);
        try { localStorage.setItem(KEY, next); } catch (e) { /* storage blocked */ }
        label();
        try { document.dispatchEvent(new CustomEvent('avd-ops-adopter-theme')); } catch (e) { /* old browser */ }
      });
      try { window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', label); } catch (e) { /* old browser */ }
    }

    wireCustomizer(document.querySelector('.shell'));

    // The notice in the bar opens over the page, so a click outside it, Escape or moving focus out of it closes it again.
    var notice = document.querySelector('.shell header.bar .notice');
    if (notice) {
      // pointerdown, not click: iOS Safari sends no click for a tap on text or empty space.
      document.addEventListener('pointerdown', function (e) { if (notice.open && !notice.contains(e.target)) notice.open = false; });
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && notice.open) { notice.open = false; notice.querySelector('summary').focus(); }
      });
      notice.addEventListener('focusout', function (e) { if (notice.open && e.relatedTarget && !notice.contains(e.relatedTarget)) notice.open = false; });
    }

    var menu = document.querySelector('.shell .menu');
    var side = document.querySelector('.shell .side');
    var backdrop = document.querySelector('.shell .backdrop');
    if (side) {
      var active = side.querySelector('a[aria-current]');
      var el = active && active.parentElement;
      while (el && el !== side) {
        if (el.matches && el.matches('details.side-group')) el.open = true;
        el = el.parentElement;
      }
    }
    if (!menu || !side) return;
    // The drawer class goes on the .shell element: the body on a page, a wrapper div in an artifact.
    var shell = menu.closest('.shell');
    // While the drawer is open the page behind it is inert, so Tab stays in the side list.
    var behind = document.querySelectorAll('.shell header.bar, .shell main, .shell footer.foot');
    function setOpen(open, quiet) {
      shell.classList.toggle('drawer-open', open);
      for (var i = 0; i < behind.length; i++) { if (open) behind[i].setAttribute('inert', ''); else behind[i].removeAttribute('inert'); }
      menu.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) {
        var first = side.querySelector('[aria-current]') || side.querySelector('a');
        if (first) first.focus();
      } else if (!quiet) {
        menu.focus();
      }
    }
    menu.addEventListener('click', function () { setOpen(!shell.classList.contains('drawer-open')); });
    if (backdrop) backdrop.addEventListener('click', function () { setOpen(false); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && shell.classList.contains('drawer-open')) setOpen(false);
    });
    // Closing on a wide screen keeps the side list in place if the window grows while the drawer is open; focus
    // stays where it was, since the menu button is hidden there.
    try {
      window.matchMedia('(min-width: 64.0625rem)').addEventListener('change', function (m) {
        if (m.matches && shell.classList.contains('drawer-open')) setOpen(false, true);
      });
    } catch (e) { /* old browser */ }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire);
  else wire();
}());