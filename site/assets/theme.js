/* avd-ops theme and drawer v2.7.0 (https://avd-ops.dev/, avd-ops/avd-ops site/assets/theme.js). MIT.
   Personal project, not for production, as is; not affiliated with the author's employer or Microsoft.
   Load it in <head> without defer: it applies a saved theme before the page paints, then wires the shell's theme
   button (.theme) and menu button (.menu, the drawer for the side list below 64rem). No libraries, no requests.
   The theme choice is the only thing stored, in this browser only; if storage is blocked the page follows the system. */
(function () {
  var root = document.documentElement;
  var KEY = 'avd-ops-theme';
  var DEV_KEY = 'avd-ops-devmode';
  root.classList.add('js');
  try { var saved = localStorage.getItem(KEY); if (saved === 'light' || saved === 'dark') root.setAttribute('data-theme', saved); } catch (e) { /* storage blocked */ }
  try { var savedDev = localStorage.getItem(DEV_KEY); if (savedDev === 'on' || savedDev === 'off') root.setAttribute('data-dev', savedDev); } catch (e) { /* storage blocked */ }

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
      });
      try { window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', label); } catch (e) { /* old browser */ }
    }

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
