/* avd-ops theme and drawer v2.0.1 (https://avd-ops.dev/, nickprignano/avd-ops site/assets/theme.js). MIT.
   Personal project, not for production, as is; not affiliated with the author's employer or Microsoft.
   Load it in <head> without defer: it applies a saved theme before the page paints, then wires the shell's theme
   button (.theme) and menu button (.menu, the drawer for the side list below 64rem). No libraries, no requests.
   The theme choice is the only thing stored, in this browser only; if storage is blocked the page follows the system. */
(function () {
  var root = document.documentElement;
  var KEY = 'avd-ops-theme';
  root.classList.add('js');
  try { var saved = localStorage.getItem(KEY); if (saved === 'light' || saved === 'dark') root.setAttribute('data-theme', saved); } catch (e) { /* storage blocked */ }

  function isDark() {
    var t = root.getAttribute('data-theme');
    if (t) return t === 'dark';
    try { return window.matchMedia('(prefers-color-scheme: dark)').matches; } catch (e) { return false; }
  }

  function wire() {
    var body = document.body;
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

    var menu = document.querySelector('.shell .menu');
    var side = document.querySelector('.shell .side');
    var backdrop = document.querySelector('.shell .backdrop');
    if (!menu || !side) return;
    // While the drawer is open the page behind it is inert, so Tab stays in the side list.
    var behind = document.querySelectorAll('.shell header.bar, .shell .notice, .shell main, .shell footer.foot');
    function setOpen(open) {
      body.classList.toggle('drawer-open', open);
      for (var i = 0; i < behind.length; i++) { if (open) behind[i].setAttribute('inert', ''); else behind[i].removeAttribute('inert'); }
      menu.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) {
        var first = side.querySelector('[aria-current]') || side.querySelector('a');
        if (first) first.focus();
      } else {
        menu.focus();
      }
    }
    menu.addEventListener('click', function () { setOpen(!body.classList.contains('drawer-open')); });
    if (backdrop) backdrop.addEventListener('click', function () { setOpen(false); });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && body.classList.contains('drawer-open')) setOpen(false);
    });
    // Closing on a wide screen keeps the side list in place if the window grows while the drawer is open.
    try {
      window.matchMedia('(min-width: 64.0625rem)').addEventListener('change', function (m) {
        if (m.matches && body.classList.contains('drawer-open')) setOpen(false);
      });
    } catch (e) { /* old browser */ }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire);
  else wire();
}());
