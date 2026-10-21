/* avd-ops theme and drawer v2.4.1 (https://avd-ops.dev/, avd-ops/avd-ops site/assets/theme.js). MIT.
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

    // The notice in the bar opens over the page, so a click outside it or Escape closes it again.
    var notice = document.querySelector('.shell header.bar .notice');
    if (notice) {
      // pointerdown, not click: iOS Safari sends no click for a tap on text or empty space.
      document.addEventListener('pointerdown', function (e) { if (notice.open && !notice.contains(e.target)) notice.open = false; });
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && notice.open) { notice.open = false; notice.querySelector('summary').focus(); }
      });
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
