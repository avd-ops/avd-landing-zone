/*
 * Deployment portal page: wires the engine (portal-core.js) and the report (report.js) to the page.
 * Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
 *
 * Kept out of index.html so the page can carry a Content-Security-Policy that allows no inline script
 * (red team PH-9). Browser only; the engine is what the Node tests exercise.
 */
(function () {
  'use strict';
  var P = window.PortalCore;
  var $ = function (id) { return document.getElementById(id); };
  // The settings the commands use; the engine says what each may look like (P.SETTINGS, red team PH-4).
  var FIELDS = P.SETTING_NAMES;

  // ---------------------------------------------------------------- persistence (this browser only)
  function load(k, fallback) { try { var v = localStorage.getItem('avdlz.portal.' + k); return v === null ? fallback : JSON.parse(v); } catch (e) { return fallback; } }
  function save(k, v) { try { localStorage.setItem('avdlz.portal.' + k, JSON.stringify(v)); } catch (e) { /* storage unavailable */ } }

  // Clone URL: the one portal-config.js names (a copy published by Publish-AvdPortal.ps1), else the
  // fork serving the page from <owner>.github.io/<repo>, else this repo. It goes into every command,
  // so only a plain https URL is taken.
  var site = P.siteConfig(window.AVDLZ_PORTAL_CONFIG);
  var repoUrl = P.DEFAULTS.repoUrl;
  var host = location.hostname, seg = location.pathname.split('/').filter(Boolean)[0];
  if (site.repoUrl) repoUrl = site.repoUrl;
  else if (/\.github\.io$/.test(host) && seg) repoUrl = 'https://github.com/' + host.split('.')[0] + '/' + seg;
  $('repo-link').href = repoUrl;
  $('issues-link').href = repoUrl + '/issues';
  // Which code the commands run: the repo and, for a published copy, the pinned ref (decision 0017).
  $('source-repo').href = repoUrl; $('source-repo').textContent = repoUrl.replace(/^https:\/\/github\.com\//, '');
  $('source-ref').textContent = site.ref || 'master';
  if (site.commit) $('source-line').appendChild(document.createTextNode(' This portal was built from commit ' + site.commit.slice(0, 7) + '.'));
  if (site.ignored.length) { $('source-line').appendChild(document.createTextNode(' This copy\'s portal-config.js has an invalid ' + site.ignored.join(' and ') + ', so the commands use the default.')); $('source-more').open = true; }
  // Report a problem files into the repo the commands run from, and the issue is public (red team PH-10).
  var repoSlug = repoUrl.replace(/^https:\/\/github\.com\//, '');
  $('issues-link').textContent = repoSlug;

  // Saved settings are checked like typed ones: an old or edited value that no longer fits is dropped.
  var cfg = Object.assign({}, P.DEFAULTS, P.validSettings(load('config', {})).settings, { repoUrl: repoUrl, ref: site.ref, sizing: P.validSizing(load('sizing', null)), topology: P.validTopology(load('topology', null)), power: P.validPower(load('power', null)), hoursWorkedPerWeek: load('hoursWorked', 50), launch: P.launchTarget(load('launch', null)), record: load('record', null) });
  var step = load('step', null);
  // Furthest step reached, by id: later steps stay hidden until the deployment gets there. (Saved as an
  // index before the Cost step existed; those indexes are read against the old step list.)
  var OLD_STEPS = ['region', 'size', 'predeploy', 'deploy', 'postdeploy', 'signin'];
  var reached = Math.max(stepIndex(load('reachedStep', null) || (load('reached', null) !== null ? OLD_STEPS[Math.min(5, load('reached', 0))] : 'region')), stepIndex(step || 'region'));
  var ranked = load('ranked', null);
  var lastAnalysis = null;

  function config() { return cfg; }
  function setConfig(patch) {
    // The parameter file decides the environment (parameters/test.bicepparam deploys avdlz-test).
    var fe = patch && patch.parameterFile && !patch.environment && /parameters\/(dev|test|prod)\.bicepparam$/.exec(patch.parameterFile);
    if (fe) patch = Object.assign({}, patch, { environment: fe[1] });
    // Only values that fit their setting reach the commands; the rest are named in the settings panel (red team PH-4).
    var checked = P.validSettings(patch);
    FIELDS.forEach(function (k) { if (checked.settings[k]) cfg[k] = checked.settings[k]; });
    showRejected(checked.rejected);
    // A pasted preflight says which sizing it validated; the next commands keep it.
    var sizing = patch && P.validSizing(patch.sizing);
    if (sizing) { cfg.sizing = sizing; save('sizing', cfg.sizing); }
    var topology = patch && P.validTopology(patch.topology);
    if (topology) { cfg.topology = topology; save('topology', cfg.topology); }
    // ... and which power settings it priced.
    var power = patch && P.validPower(patch.power);
    if (power) { cfg.power = power; save('power', cfg.power); }
    // ... and, after the post-deployment setup or the demo, the desktop to launch (decision 0014).
    var launch = patch && P.launchTarget(patch.launch);
    if (launch) { cfg.launch = launch; save('launch', launch); }
    var keep = {}; FIELDS.forEach(function (k) { keep[k] = cfg[k]; }); save('config', keep);
    FIELDS.forEach(function (k) { var el = $(k); if (el && el.value !== cfg[k]) el.value = cfg[k] || ''; });
    $('region-summary').textContent = cfg.location + (ranked && ranked.length ? (ranked[0] === cfg.location ? ' (closest measured)' : '') : ' (not measured yet)');
    $('region-skip').textContent = 'I already know: use ' + cfg.location;
  }
  function showRejected(names) {
    var w = $('settings-warning');
    if (!names || !names.length) { w.classList.add('hidden'); w.textContent = ''; return; }
    var LABEL = { parameterFile: 'Parameter file (parameters/<name>.bicepparam)', location: 'Region (a lowercase Azure region name)', usersGroup: 'AVD users group', adminsGroup: 'AVD admins group', namePrefix: 'Name prefix (2 to 8 lowercase letters or digits)', environment: 'Environment (dev, test or prod)', testUserUpn: 'Test user (user@domain)', graphClientId: 'Graph sign-in app client ID (a GUID)' };
    w.textContent = 'Not used, because the value does not fit: ' + names.map(function (n) { return LABEL[n] || n; }).join('; ') + '. The commands keep the previous value.';
    w.classList.remove('hidden');
    showSettings(true);
  }
  FIELDS.forEach(function (k) {
    $(k).addEventListener('change', function () { var p = {}; p[k] = $(k).value.trim(); setConfig(p); lastAnalysis = null; render(); renderSizeResult(); renderCost(); });
  });

  // ---------------------------------------------------------------- deployment settings (header link)
  // Settings and "Where did I leave off?" open as sheets over the step; one at a time, Escape or the backdrop closes.
  // While a sheet is open the page behind it is inert, and closing it returns focus to what opened it.
  function sheetOpen() { return !$('settings-panel').classList.contains('hidden') ? 'settings' : !$('resume-panel').classList.contains('hidden') ? 'resume' : null; }
  var sheetOpener = null;
  function syncBackdrop() {
    var open = !!sheetOpen();
    if (open && !sheetOpener) sheetOpener = document.activeElement;
    $('sheet-backdrop').classList.toggle('hidden', !open);
    document.querySelectorAll('main, .wz-nav, .after').forEach(function (n) { if (open) n.setAttribute('inert', ''); else n.removeAttribute('inert'); });
  }
  function sheetClosed(fallback) {
    var to = sheetOpener && document.contains(sheetOpener) && sheetOpener !== document.body ? sheetOpener : fallback;
    sheetOpener = null;
    if (!sheetOpen()) to.focus({ preventScroll: true });
  }
  $('sheet-backdrop').addEventListener('click', function () { if (sheetOpen() === 'settings') showSettings(false); else if (sheetOpen() === 'resume') showResume(false); });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && sheetOpen()) $('sheet-backdrop').click(); });
  function showSettings(open) {
    if (open && sheetOpen() === 'resume') showResume(false);
    $('settings-panel').classList.toggle('hidden', !open);
    $('settings-link').setAttribute('aria-expanded', String(open));
    syncBackdrop();
    if (open) $('parameterFile').focus({ preventScroll: true });
    else sheetClosed($('settings-link'));
  }
  $('settings-link').addEventListener('click', function (e) { e.preventDefault(); showSettings($('settings-panel').classList.contains('hidden')); });
  $('settings-close').addEventListener('click', function () { showSettings(false); });
  if (location.hash === '#settings') showSettings(true);

  // ---------------------------------------------------------------- progress tracker and steps
  function stepIndex(id) { for (var i = 0; i < P.STEPS.length; i++) if (P.STEPS[i].id === id) return i; return 0; }
  function curIndex() { return stepIndex(step || 'region'); }
  // Moves to a step (revealing it if it is the next one); scroll: false when the user scrolled there.
  function goTo(id, opts) {
    opts = opts || {};
    var i = stepIndex(id);
    if (i > reached) { reached = i; save('reachedStep', P.STEPS[i].id); }
    if (id !== (step || 'region')) lastAnalysis = null;
    step = id; save('step', step);
    render();
    if (opts.scroll !== false) showStep(opts.page);
  }
  // The steps, grouped by phase (Plan, Deploy, Use), twice: as the list down the left on a wide screen (#steps) and
  // as the progress bar over the step on a narrow one (#steps-bar), where each phase is as wide as its steps.
  // A step not reached yet stays locked.
  var LIST = { predeploy: 'Preflight', deploy: 'Deploy', postdeploy: 'Setup' };
  var RAIL = { region: ['Region', 'Plan'], size: ['Size'], cost: ['Cost'], predeploy: ['Preflight', 'Deploy'], deploy: ['Deploy'], postdeploy: ['Setup'], signin: ['Sign in', 'Use'], verify: ['Verify'] };
  function renderSteps() {
    var cur = curIndex(), list = $('steps'), bar = $('steps-bar'), phase = null, segs = null;
    list.textContent = ''; bar.textContent = '';
    P.STEPS.forEach(function (s, i) {
      var rail = RAIL[s.id] || [s.title];
      var state = i > reached ? 'locked' : i === cur ? 'current' : i < reached || i < cur ? 'done' : '';
      if (rail[1] || !phase) {
        // The phase name is a visible heading only; each step's own label carries its number.
        if (rail[1]) { var g = el('li', 'group', rail[1]); g.setAttribute('aria-hidden', 'true'); list.appendChild(g); }
        phase = el('li', 'phase'); phase.setAttribute('data-steps', '0');
        phase.appendChild(el('span', 'phase-name', rail[1] || ''));
        segs = el('div', 'segs'); phase.appendChild(segs); bar.appendChild(phase);
      }
      phase.setAttribute('data-steps', String(Number(phase.getAttribute('data-steps')) + 1));
      if (i === cur) phase.classList.add('now');
      var label = (i + 1) + '. ' + s.title + (state === 'done' ? ', done' : '');
      [['step ' + state, list], ['seg ' + state, segs]].forEach(function (k, n) {
        var b = el('button', k[0]);
        b.type = 'button';
        b.disabled = i > reached;
        b.setAttribute('aria-current', i === cur ? 'step' : 'false');
        if (n === 0) {
          b.appendChild(el('span', 'n', state === 'done' ? '\u2713' : String(i + 1)));
          b.appendChild(el('span', 'lbl', LIST[s.id] || s.title));
          if (i > reached) b.title = 'Reached after the steps before it';
          b.setAttribute('aria-label', label);
          var li = el('li'); li.appendChild(b); list.appendChild(li);
        } else {
          b.title = (i + 1) + '. ' + s.title;
          b.setAttribute('aria-label', label);
          k[1].appendChild(b);
        }
        b.addEventListener('click', function () { goTo(s.id); });
      });
    });
  }
  function slides() { return Array.prototype.slice.call(document.querySelectorAll('#track > .slide')); }
  function currentSlide() { return slides()[curIndex()]; }
  // Only the steps reached so far are in the track; the command steps share one "next step" and paste box.
  function renderSlides() {
    var cur = curIndex();
    slides().forEach(function (sl, i) {
      sl.classList.toggle('hidden', i > reached);
      sl.querySelector('h2 .n').textContent = (i + 1) + '.';
      if (i === cur) sl.removeAttribute('inert'); else sl.setAttribute('inert', '');
    });
    var slot = currentSlide().querySelector('.slot'), shared = $('shared');
    var home = slot || shared;
    ['next', 'paste-box'].forEach(function (id) { if ($(id).parentNode !== home) home.appendChild($(id)); });
    $('prev-step').disabled = cur === 0;
    $('next-step').disabled = cur >= P.STEPS.length - 1;
    $('next-step').innerHTML = (cur < reached ? 'Next' : 'Skip ahead') + ' &rarr;';
    $('next-step').classList.toggle('primary', cur < reached);
    $('step-pos').textContent = 'Step ' + (cur + 1) + ' of ' + P.STEPS.length + ', ' + P.STEPS[cur].title;
    fitTrack();
  }
  var track = $('track'), programmatic = 0;
  // The track is as tall as the step in view, so a short step doesn't leave a gap under it.
  function fitTrack() { var sl = currentSlide(); if (sl) track.style.height = sl.offsetHeight + 'px'; }
  if (window.ResizeObserver) { var ro = new ResizeObserver(fitTrack); slides().forEach(function (sl) { ro.observe(sl); }); }
  window.addEventListener('resize', function () { fitTrack(); showStep('instant'); });
  var bar = document.querySelector('header.bar');
  function showStep(page) {
    var sl = currentSlide(); if (!sl) return;
    programmatic = Date.now();
    track.scrollTo({ left: sl.offsetLeft - track.offsetLeft, behavior: page === 'instant' ? 'auto' : 'smooth' });
    if (page !== 'instant' && track.getBoundingClientRect().top < (bar ? bar.getBoundingClientRect().bottom : 0)) window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  // Scrolling the track sideways (swipe, trackpad, keyboard) changes the step in view.
  var scrollTimer = null;
  track.addEventListener('scroll', function () {
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () {
      if (Date.now() - programmatic < 800) return;
      var visible = slides().filter(function (sl) { return !sl.classList.contains('hidden'); });
      var best = visible.reduce(function (a, sl) { return Math.abs(sl.offsetLeft - track.offsetLeft - track.scrollLeft) < Math.abs(a.offsetLeft - track.offsetLeft - track.scrollLeft) ? sl : a; }, visible[0]);
      if (best && best.getAttribute('data-step') !== (step || 'region')) goTo(best.getAttribute('data-step'), { scroll: false });
    }, 120);
  });
  $('prev-step').addEventListener('click', function () { goTo(P.STEPS[Math.max(0, curIndex() - 1)].id); });
  $('next-step').addEventListener('click', function () { goTo(P.STEPS[Math.min(P.STEPS.length - 1, curIndex() + 1)].id); });
  $('region-skip').addEventListener('click', function () { goTo('size'); });

  // ---------------------------------------------------------------- next step
  function copy(text, btn) {
    var done = function () { var t = btn.textContent; btn.textContent = 'Copied'; setTimeout(function () { btn.textContent = t; }, 1500); };
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, function () { fallback(text); done(); });
    else { fallback(text); done(); }
  }
  function fallback(text) {
    var ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select(); try { document.execCommand('copy'); } catch (e) { /* nothing else to try */ } document.body.removeChild(ta);
  }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }

  // ---------------------------------------------------------------- run in (avd-ops docs/design-system.md, "Run in")
  // Kept under one key for every avd-ops portal, in this browser only; blocked storage means the default.
  var runIn = (function () { try { return P.validRunIn(JSON.parse(localStorage.getItem('avd-ops-runin') || 'null')); } catch (e) { return P.validRunIn(null); } })();
  $('runline-change').addEventListener('click', function () { showSettings(true); var r = document.querySelector('input[name="runin-where"]:checked'); if (r) r.focus({ preventScroll: true }); });
  function syncRunIn() {
    $('runline-where').textContent = P.PLACES[runIn.where] + ', ' + (runIn.shell === 'bash' ? 'Bash' : 'PowerShell');
    var bash = document.querySelector('input[name="runin-shell"][value="bash"]');
    bash.disabled = runIn.where === 'windows';
    bash.parentNode.title = bash.disabled ? 'On Windows the commands run in PowerShell 7' : '';
    document.querySelectorAll('input[name="runin-where"], input[name="runin-shell"]').forEach(function (i) { i.checked = i.value === runIn.where || i.value === runIn.shell; });
    $('runin-note').textContent = [runIn.where === 'cloudshell' ? (runIn.shell === 'bash' ? 'These blocks need Cloud Shell\'s Bash prompt (you@Azure:~$). If it shows PS /home/you>, type bash first.' : 'These blocks need Cloud Shell\'s PowerShell prompt (PS /home/you>). If it shows you@Azure:~$, type pwsh first.') : '',
      runIn.where === 'windows' ? 'Windows runs the commands in PowerShell 7.' : '',
      runIn.where === 'cloudshell' ? '' : 'Each block signs in to Azure first, with a device code, if this machine is not signed in yet.',
      runIn.shell === 'bash' ? 'In Bash each block runs its PowerShell in a new pwsh, so a step that uses Microsoft Graph asks for its device code again.' : ''].filter(Boolean).join(' ');
  }
  document.querySelectorAll('input[name="runin-where"], input[name="runin-shell"]').forEach(function (i) {
    i.addEventListener('change', function () {
      var next = { where: runIn.where, shell: runIn.shell }; next[i.name === 'runin-where' ? 'where' : 'shell'] = i.value;
      runIn = P.validRunIn(next);
      try { localStorage.setItem('avd-ops-runin', JSON.stringify(runIn)); } catch (e) { /* storage unavailable */ }
      syncRunIn(); render();
    });
  });
  syncRunIn();

  function renderActions(actions, box) {
    box = box || $('actions'); box.textContent = '';
    actions.forEach(function (a, i) {
      var d = el('div', 'action');
      d.appendChild(el('h3', '', (actions.length > 1 ? (i + 1) + '. ' : '') + a.title));
      if (a.why) d.appendChild(el('p', 'why', a.why));
      if (a.command) {
        // The block for the place and shell chosen in Run in; a script that doesn't run there hides the block.
        var sup = P.support(a.command, runIn);
        if (sup.status === 'no') {
          d.appendChild(el('p', 'status unsupported', 'This step runs ' + sup.blockedBy.join(', ') + ', which does not run on ' + sup.place +
            (sup.shell === 'bash' ? ' in Bash' : ' in PowerShell') + '. Run this step in Cloud Shell' + (sup.place === 'Windows' ? ' or on macOS' : '') + '.'));
        } else {
          var text = P.forRunIn(a.command, runIn);
          var term = el('div', 'term'), head = el('div', 'term-head'), b = el('button', 'secondary', 'Copy');
          term.setAttribute('data-shell', sup.shell);
          b.type = 'button'; b.addEventListener('click', function () { copy(text, b); });
          head.appendChild(el('span', 'term-label', sup.place));
          if (sup.status === 'untested') head.appendChild(el('span', 'untested', 'Not tested yet'));
          head.appendChild(b); term.appendChild(head);
          term.appendChild(el('pre', '', text)); d.appendChild(term);
          if (sup.requires.length) d.appendChild(el('p', 'requires', sup.requires.join(', ')));
        }
      }
      box.appendChild(d);
    });
    // Spec section 4.3: a reset loses the shell, not the deployment.
    if (box === $('actions') && actions.some(function (a) { return /scripts\//.test(a.command || ''); })) {
      var hint = el('p', 'muted resume-hint', 'If Cloud Shell resets, the deployment keeps running: ');
      var link = el('a', '', 'Resume'); link.href = '#resume';
      link.addEventListener('click', function (e) { e.preventDefault(); showResume(true); });
      hint.appendChild(link); hint.appendChild(document.createTextNode(' picks up from there.'));
      box.appendChild(hint);
    }
  }

  // ---------------------------------------------------------------- where did I leave off (run recorder spec section 4)
  function renderResume() {
    if (!$('resume-panel').classList.contains('hidden')) renderActions([{ title: 'Read where the run stands', why: '', command: P.commands.runStatus(config()) }], $('resume-actions'));
  }
  function showResume(open) {
    if (open && sheetOpen() === 'settings') showSettings(false);
    $('resume-panel').classList.toggle('hidden', !open);
    syncBackdrop();
    $('resume-link').setAttribute('aria-expanded', String(open));
    if (open) {
      renderResume();
      $('resume-close').focus({ preventScroll: true });
    }
    else sheetClosed($('resume-link'));
  }
  $('resume-link').addEventListener('click', function (e) { e.preventDefault(); showResume($('resume-panel').classList.contains('hidden')); });
  $('resume-close').addEventListener('click', function () { showResume(false); });
  if (location.hash === '#resume') showResume(true);

  // ---------------------------------------------------------------- record this run (run recorder spec sections 5 and 6)
  function renderRecord() {
    var r = P.recording(cfg);
    $('record-on').checked = !!r;
    $('record-mode').value = r ? r.mode : (cfg.record && cfg.record.mode === 'on' ? 'on' : 'azure');
    $('record-mode').disabled = !r;
    $('record-panel').classList.toggle('hidden', !r);
    if (!r) return;
    $('record-id').textContent = r.runId;
    $('record-note').textContent = 'Open the run before the pre-deployment preflight. Every command carries this run ID; the run folder is kept ' +
      (r.mode === 'azure' ? 'in the run store (outside the landing zone, so cleanup never removes it) and in Cloud Shell.' : 'in Cloud Shell only (~/clouddrive/avdlz-runs when clouddrive is mounted).');
    renderActions(P.recordActions(config()), $('record-actions'));
  }
  function setRecord(rec) {
    cfg.record = rec; save('record', rec);
    render();
  }
  $('record-on').addEventListener('change', function () {
    var mode = $('record-mode').value === 'on' ? 'on' : 'azure';
    setRecord($('record-on').checked ? { runId: P.newRunId(), mode: mode } : { mode: mode });
  });
  $('record-mode').addEventListener('change', function () { if (P.recording(cfg)) setRecord({ runId: cfg.record.runId, mode: $('record-mode').value === 'on' ? 'on' : 'azure' }); });
  $('record-new').addEventListener('click', function () { if (P.recording(cfg)) setRecord({ runId: P.newRunId(), mode: P.recording(cfg).mode }); });

  function renderFindings(r) {
    var box = $('findings'); box.textContent = '';
    var items = [];
    (r.failures || []).forEach(function (f) { items.push({ cls: 'poor', label: 'Fail', f: f }); });
    (r.warnings || []).forEach(function (f) { items.push({ cls: 'ok', label: 'Warn', f: f }); });
    if (!items.length) { box.classList.add('hidden'); return; }
    var det = el('details'); det.open = items.length <= 6;
    det.appendChild(el('summary', '', items.length + ' finding' + (items.length > 1 ? 's' : '') + ' in this run'));
    var ul = el('ul', 'findings');
    items.forEach(function (it) {
      var li = el('li'); var tag = el('span', it.cls, it.label + ': '); li.appendChild(tag);
      li.appendChild(document.createTextNode(it.f.check || ''));
      var extra = [it.f.detail, it.f.remediation ? '→ ' + it.f.remediation : ''].filter(Boolean).join(' ');
      if (extra) { li.appendChild(el('br')); li.appendChild(el('span', 'muted', extra)); }
      ul.appendChild(li);
    });
    det.appendChild(ul); box.appendChild(det); box.classList.remove('hidden');
  }

  function render() {
    renderSteps(); renderSlides(); renderLaunch(); renderRecord(); renderResume();
    var chip = $('next-chip'), head = $('next-headline');
    $('next').classList.toggle('answered', !!lastAnalysis);
    if (lastAnalysis) {
      var r = lastAnalysis;
      $('next-title').textContent = r.recognized ? 'What to do next' : 'Not recognized';
      var good = /^(ready|succeeded|done|resumed|stopped|verified)$/.test(r.status || '');
      chip.textContent = r.status ? (good ? 'Done' : r.status === 'started' ? 'Running' : 'Action needed') : 'Action needed';
      chip.className = 'chip ' + (good ? 'good' : r.status === 'started' ? 'ok' : 'poor');
      head.textContent = r.headline; head.classList.remove('hidden');
      var eline = $('estimate-line');
      if (r.estimate) { eline.textContent = 'Estimated cost: ' + money(r.estimate.total, r.estimate.currency) + ' per month at list prices (details on the Cost step).'; eline.classList.remove('hidden'); }
      else eline.classList.add('hidden');
      // The scripts and this portal come from different commits (red team PH-8).
      var vline = $('version-line');
      if (r.versionNote) { vline.textContent = r.versionNote; vline.classList.remove('hidden'); } else vline.classList.add('hidden');
      renderFindings(r);
      renderActions(r.actions);
    }
    else {
      $('next-title').textContent = 'Run it';
      chip.className = 'chip hidden'; head.classList.add('hidden'); $('findings').classList.add('hidden'); $('estimate-line').classList.add('hidden'); $('version-line').classList.add('hidden');
      renderActions(P.actionsForStep(step || 'region', config()));
    }
  }

  // Secrets in a paste are replaced before the text shows or is read (report.js maskSecrets), so a
  // token, key or password is never on screen and never reaches the analysis, the report or storage.
  var maskedCount = 0;
  function showMasked() {
    var n = $('paste-masked');
    n.classList.toggle('hidden', !maskedCount);
    if (maskedCount) n.innerHTML = 'Hid ' + maskedCount + ' secret' + (maskedCount === 1 ? '' : 's') + ' (shown as <code>&lt;secret&gt;</code>). The analysis doesn\'t need ' + (maskedCount === 1 ? 'it' : 'them') + ', and nothing you paste is stored or sent.';
  }
  function maskPaste() {
    var m = window.PortalReport.maskSecrets($('paste').value);
    if (m.count) { $('paste').value = m.text; maskedCount += m.count; }
    showMasked();
  }
  function analyzePaste() {
    maskPaste();
    var text = $('paste').value;
    if (!text.trim()) { $('paste-status').textContent = 'Paste some output first.'; return; }
    var r = P.analyze(text, config(), { rankedRegions: ranked, currentStep: step || 'predeploy', portalCommit: site.commit });
    setConfig(r.config);
    if (r.rejectedSettings && r.rejectedSettings.length) showRejected(r.rejectedSettings);
    if (r.estimate) { estimate = r.estimate; save('estimate', estimate); }
    renderCost();
    renderSizeResult();
    if (r.step && r.step !== (step || 'region')) goTo(r.step);
    lastAnalysis = r;
    $('paste-status').textContent = r.recognized ? 'Analyzed: ' + r.headline : 'Nothing recognizable in the pasted text.';
    render(); refreshReport(true);
    // Show the result: it replaces the box above the paste box, which may be out of view.
    $('next').scrollIntoView({ behavior: 'smooth', block: 'start' });
    $('next').classList.remove('flash'); void $('next').offsetWidth; $('next').classList.add('flash');
  }
  $('analyze').addEventListener('click', analyzePaste);
  $('paste').addEventListener('paste', function (e) {
    // Mask the clipboard text on its way in, so a secret is never drawn, not even for a frame.
    var data = e.clipboardData && e.clipboardData.getData('text');
    if (typeof data === 'string' && data) {
      e.preventDefault();
      var m = window.PortalReport.maskSecrets(data), ta = $('paste');
      ta.setRangeText(m.text, ta.selectionStart, ta.selectionEnd, 'end');
      maskedCount += m.count;
    }
    setTimeout(analyzePaste, 0);
  });
  // Typed, dropped or autofilled text too.
  $('paste').addEventListener('input', maskPaste);
  $('clear-paste').addEventListener('click', function () { $('paste').value = ''; $('paste-status').textContent = ''; maskedCount = 0; showMasked(); lastAnalysis = null; render(); refreshReport(true); });
  $('reset').addEventListener('click', function () {
    try { Object.keys(localStorage).filter(function (k) { return k.indexOf('avdlz.portal.') === 0; }).forEach(function (k) { localStorage.removeItem(k); }); } catch (e) { /* storage unavailable */ }
    // A shell that ran a recorded block still has the run ID: the next blocks clear it.
    var wasRecording = P.recording(cfg);
    cfg = Object.assign({}, P.DEFAULTS, { repoUrl: repoUrl, ref: site.ref, sizing: null, topology: null, power: null, hoursWorkedPerWeek: 50, launch: null, record: wasRecording ? { mode: wasRecording.mode } : null });
    if (wasRecording) save('record', cfg.record); step = null; reached = 0; ranked = null; lastAnalysis = null; latency = [];
    pools = [Object.assign({}, P.HOST_POOL_DEFAULTS)];
    workspaces = [Object.assign({}, P.WORKSPACE_DEFAULTS)];
    appGroups = [Object.assign({}, P.APP_GROUP_DEFAULTS)];
    privateLink = JSON.parse(JSON.stringify(P.PRIVATE_LINK_DEFAULTS));
    selectedPools = { 0: true };
    estimate = null;
    renderTemplatesBar(); renderPools(); renderWorkspacesAndAppGroups(); renderPrivateLinkPanel(); renderCost();
    reach = null; $('reach-results').classList.add('hidden'); renderReachability();
    $('results').classList.add('hidden'); $('paste').value = ''; maskedCount = 0; showMasked(); setConfig({}); render(); showStep();
  });

  // ---------------------------------------------------------------- issue report (redacted in this browser)
  var R = window.PortalReport, reportEdited = false;
  function terms() { return $('report-terms').value.split(',').map(function (t) { return t.trim(); }).filter(Boolean); }
  function buildReport() {
    var text = $('paste').value, a = text.trim() ? P.analyze(text, config(), { rankedRegions: ranked, currentStep: step || 'predeploy' }) : null;
    return R.buildReport({ output: text, description: $('report-desc').value, analysis: a, step: step, config: config(), extraTerms: terms() });
  }
  function refreshReport(force) {
    if (!$('report-panel').open) return;
    if (reportEdited && !force) return;
    var rep = buildReport();
    $('report-body').value = rep.body; reportEdited = false;
    $('report-summary').textContent = R.describe(rep.redaction.counts) + ' Check what is left, especially names in free text.';
    $('report-ok').checked = false; $('report-submit').disabled = true; $('report-status').textContent = '';
  }
  // The final text: whatever is in the box (edits included), redacted once more.
  function finalReport() {
    var rep = buildReport();
    var body = R.redact($('report-body').value, { known: [{ kind: 'name', value: cfg.namePrefix }, { kind: 'name', value: cfg.usersGroup }, { kind: 'name', value: cfg.adminsGroup }], extraTerms: terms() }).text;
    return { title: rep.title, body: body };
  }
  $('report-panel').addEventListener('toggle', function () { refreshReport(true); });
  $('report-open').addEventListener('click', function () { $('report-panel').open = true; refreshReport(true); $('report-panel').scrollIntoView({ behavior: 'smooth', block: 'start' }); $('report-desc').focus({ preventScroll: true }); });
  ['report-desc', 'report-terms'].forEach(function (id) { $(id).addEventListener('input', function () { refreshReport(false); }); });
  $('report-body').addEventListener('input', function () { reportEdited = true; $('report-ok').checked = false; $('report-submit').disabled = true; $('report-summary').textContent = 'Edited by you. Changing the description or the terms above no longer rebuilds it (added terms are still removed when you send it); close and reopen this panel to start again.'; });
  $('report-ok').addEventListener('change', function () { $('report-submit').disabled = !$('report-ok').checked; });
  $('report-copy').addEventListener('click', function () { var f = finalReport(); copy('# ' + f.title + '\n\n' + f.body, $('report-copy')); });
  $('report-submit').addEventListener('click', function () {
    var f = finalReport(), link = R.issueUrl(repoUrl, f.title, f.body);
    if (link.trimmed) { copy(f.body, $('report-copy')); $('report-status').textContent = link.trimmed + ' lines were cut to fit the link. The full report is on your clipboard: paste it over the issue body if they matter.'; }
    else $('report-status').textContent = 'Opened a new public issue on ' + repoSlug + ' in a new tab. Review it there and select Create.';
    window.open(link.url, '_blank', 'noopener');
  });

  // ---------------------------------------------------------------- topology, setting templates, sizing and cost (decision 0010)
  // Sizings saved before the host count could be chosen start again from the minimum viable kit.
  var pools = (load('hostPools', null) || []).filter(function (p) { return p && p.hostCount !== undefined; });
  if (!pools.length) pools = [Object.assign({}, P.HOST_POOL_DEFAULTS)];
  var workspaces = (load('workspaces', null) || []).filter(function (w) { return w && typeof w === 'object'; });
  if (!workspaces.length) workspaces = [Object.assign({}, P.WORKSPACE_DEFAULTS)];
  var appGroups = (load('appGroups', null) || []).filter(function (g) { return g && typeof g === 'object'; });
  if (!appGroups.length) appGroups = [Object.assign({}, P.APP_GROUP_DEFAULTS)];
  var privateLink = load('privateLink', null);
  if (!privateLink || typeof privateLink !== 'object') privateLink = JSON.parse(JSON.stringify(P.PRIVATE_LINK_DEFAULTS));
  if (!privateLink.dnsZones || typeof privateLink.dnsZones !== 'object') privateLink.dnsZones = JSON.parse(JSON.stringify(P.PRIVATE_LINK_DEFAULTS.dnsZones));
  var customTemplates = load('customTemplates', {}) || {};
  var selectedPools = { 0: true };
  var estimate = load('estimate', null);

  function money(n, cur) { return (n === null || n === undefined) ? '–' : Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' ' + (cur || ''); }
  function poolResult(i) { return P.computePool(pools[i], cfg.environment); }
  function currentTopologyComputed() {
    return P.computeTopology({ hostPools: pools, workspaces: workspaces, appGroups: appGroups, privateLink: privateLink }, cfg.environment);
  }
  function currentManifestFromComputed(comp) {
    comp = comp || currentTopologyComputed();
    return P.validTopology({
      workspaces: comp.workspaces.map(function (ws) {
        return {
          name: ws.name,
          friendlyName: ws.friendlyName,
          description: ws.description,
          publicNetworkAccess: ws.publicNetworkAccess,
          enableFeedPrivateEndpoint: ws.enableFeedPrivateEndpoint,
          enableGlobalPrivateEndpoint: ws.enableGlobalPrivateEndpoint
        };
      }),
      hostPools: comp.pools.map(function (hp) {
        return {
          name: hp.poolKey,
          friendlyName: hp.name,
          hostPoolType: hp.hostPoolType,
          personalDesktopAssignmentType: hp.personalDesktopAssignmentType,
          loadBalancerType: hp.loadBalancerType,
          preferredAppGroupType: hp.preferredAppGroupType,
          maxSessionLimit: hp.sessionsPerHost,
          rdpProperties: hp.rdpProperties,
          validationEnvironment: hp.validationEnvironment,
          startVmOnConnect: hp.startVmOnConnect,
          deployScalingPlan: hp.deployScalingPlan,
          scalingTimeZone: hp.scalingTimeZone,
          enablePrivateEndpoint: hp.enablePrivateEndpoint,
          publicNetworkAccess: hp.publicNetworkAccess,
          sessionHostCount: hp.hosts,
          sessionHostVmSize: hp.vmSize,
          availabilityZones: hp.availabilityZones,
          encryptionAtHost: hp.encryptionAtHost,
          enrollInIntune: hp.enrollInIntune,
          fslogixProfileSizeMiB: hp.fslogixProfileSizeMiB
        };
      }),
      appGroups: comp.appGroups.map(function (ag) {
        var o = {
          name: ag.name,
          friendlyName: ag.friendlyName,
          applicationGroupType: ag.applicationGroupType,
          hostPoolName: ag.hostPool,
          workspaceName: ag.workspace
        };
        if (ag.usersGroupObjectId) o.usersGroupObjectId = ag.usersGroupObjectId;
        return o;
      }),
      privateLink: {
        enableConnectionPrivateEndpoint: comp.privateLink.enableAvdConnectionPrivateLink,
        enableFeedPrivateEndpoint: comp.privateLink.enableAvdFeedPrivateLink,
        enableGlobalPrivateEndpoint: comp.privateLink.enableAvdGlobalPrivateLink,
        hostPoolPublicNetworkAccess: comp.privateLink.hostPoolPublicNetworkAccess,
        workspacePublicNetworkAccess: comp.privateLink.workspacePublicNetworkAccess,
        dnsZones: {
          file: { mode: comp.privateLink.dnsZones.file.mode === 'existing' ? 'existing' : 'new', resourceId: comp.privateLink.dnsZones.file.existingResourceId || '' },
          keyVault: { mode: comp.privateLink.dnsZones.keyVault.mode === 'existing' ? 'existing' : 'new', resourceId: comp.privateLink.dnsZones.keyVault.existingResourceId || '' },
          avd: { mode: comp.privateLink.dnsZones.avd.mode === 'existing' ? 'existing' : 'new', resourceId: comp.privateLink.dnsZones.avd.existingResourceId || '' },
          avdGlobal: { mode: comp.privateLink.dnsZones.avdGlobal.mode === 'existing' ? 'existing' : 'new', resourceId: comp.privateLink.dnsZones.avdGlobal.existingResourceId || '' }
        }
      }
    });
  }

  // Setting templates bar
  function getSelectedTemplateObj() {
    var sel = $('template-select');
    if (!sel) return P.POOL_TEMPLATES.general;
    var v = sel.value;
    if (v && v.indexOf('custom:') === 0) {
      var ck = v.slice(7);
      return customTemplates[ck] || P.POOL_TEMPLATES.general;
    }
    return P.POOL_TEMPLATES[v] || P.POOL_TEMPLATES.general;
  }
  function renderTemplatesBar() {
    var sel = $('template-select'), srcSel = $('template-source-pool');
    if (!sel || !srcSel) return;
    var prev = sel.value || 'general';
    sel.textContent = '';
    Object.keys(P.POOL_TEMPLATES).forEach(function (k) {
      var op = document.createElement('option');
      op.value = k;
      op.textContent = P.POOL_TEMPLATES[k].label;
      sel.appendChild(op);
    });
    Object.keys(customTemplates).forEach(function (k) {
      var op = document.createElement('option');
      op.value = 'custom:' + k;
      op.textContent = 'Custom: ' + (customTemplates[k].label || k);
      sel.appendChild(op);
    });
    if (Array.prototype.some.call(sel.options, function (o) { return o.value === prev; })) sel.value = prev;
    var tpl = getSelectedTemplateObj();
    $('template-desc').textContent = tpl.description || 'Custom template saved in this browser.';
    $('template-delete-custom').classList.toggle('hidden', sel.value.indexOf('custom:') !== 0);

    var prevSrc = srcSel.value || '0';
    srcSel.textContent = '';
    pools.forEach(function (p, idx) {
      var op = document.createElement('option');
      op.value = String(idx);
      op.textContent = 'Host pool ' + (idx + 1) + ' (' + (p.poolKey || ('pool-' + (idx + 1))) + ')';
      srcSel.appendChild(op);
    });
    if (Number(prevSrc) < pools.length) srcSel.value = prevSrc;
  }
  if ($('template-select')) {
    $('template-select').addEventListener('change', function () {
      var tpl = getSelectedTemplateObj();
      $('template-desc').textContent = tpl.description || 'Custom template saved in this browser.';
      $('template-delete-custom').classList.toggle('hidden', $('template-select').value.indexOf('custom:') !== 0);
    });
    $('template-apply-all').addEventListener('click', function () {
      var tpl = getSelectedTemplateObj();
      pools = P.applyPoolTemplate(pools, tpl, 'all');
      save('hostPools', pools);
      $('template-status').textContent = 'Applied "' + (tpl.label || 'template') + '" to all ' + pools.length + ' host pool(s).';
      renderPools();
    });
    $('template-apply-selected').addEventListener('click', function () {
      var indices = Object.keys(selectedPools).filter(function (k) { return selectedPools[k] && Number(k) < pools.length; }).map(Number);
      if (!indices.length) { $('template-status').textContent = 'Check at least one host pool below first.'; return; }
      var tpl = getSelectedTemplateObj();
      pools = P.applyPoolTemplate(pools, tpl, indices);
      save('hostPools', pools);
      $('template-status').textContent = 'Applied "' + (tpl.label || 'template') + '" to ' + indices.length + ' selected host pool(s).';
      renderPools();
    });
    $('template-save-custom').addEventListener('click', function () {
      var name = ($('template-custom-name').value || '').trim();
      if (!name) { $('template-status').textContent = 'Enter a name for the custom template first.'; return; }
      var key = name.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32) || 'custom';
      var srcIdx = Number($('template-source-pool').value) || 0;
      var src = pools[srcIdx] || pools[0];
      var settings = {};
      ['hostPoolType', 'personalDesktopAssignmentType', 'loadBalancerType', 'preferredAppGroupType', 'workload', 'concurrencyPercent', 'vmSize', 'maxSessionLimitOverride', 'profileGiBPerUser', 'fslogixProfileSizeMiB', 'rdpProperties', 'validationEnvironment', 'startVmOnConnect', 'deployScalingPlan', 'scalingTimeZone', 'encryptionAtHost', 'enrollInIntune', 'availabilityZones', 'enablePrivateEndpoint', 'publicNetworkAccess'].forEach(function (k) {
        if (src[k] !== undefined) settings[k] = src[k];
      });
      customTemplates[key] = { id: key, label: name, description: 'Saved from Host pool ' + (srcIdx + 1) + ' (' + (src.poolKey || 'general') + ').', settings: settings };
      save('customTemplates', customTemplates);
      $('template-custom-name').value = '';
      renderTemplatesBar();
      $('template-select').value = 'custom:' + key;
      $('template-delete-custom').classList.remove('hidden');
      $('template-status').textContent = 'Saved custom template "' + name + '".';
    });
    $('template-delete-custom').addEventListener('click', function () {
      var v = $('template-select').value;
      if (v.indexOf('custom:') !== 0) return;
      var k = v.slice(7);
      delete customTemplates[k];
      save('customTemplates', customTemplates);
      renderTemplatesBar();
      $('template-status').textContent = 'Deleted custom template.';
    });
  }

  var POOL_FIELDS = [
    ['poolKey', 'Pool slug (ID)', 'slug'],
    ['name', 'Display name', 'text'],
    ['hostPoolType', 'Pool type', 'pooltype'],
    ['users', 'People who will use it', 'number'],
    ['concurrencyPercent', 'Signed in at busiest time (%)', 'number'],
    ['workload', 'How they work', 'workload'],
    ['vmSize', 'VM size', 'vmsize'],
    ['hostCount', 'Session hosts', 'hostcount'],
    ['spareHost', 'Spare host (Automatic only)', 'spare'],
    ['profileGiBPerUser', 'Profile size per person (GiB)', 'number']
  ];

  function makeSelect(opts, currentVal) {
    var s = document.createElement('select');
    opts.forEach(function (o) {
      var op = document.createElement('option');
      op.value = o[0];
      op.textContent = o[1];
      s.appendChild(op);
    });
    s.value = currentVal === null || currentVal === undefined ? '' : String(currentVal);
    return s;
  }

  function renderPools() {
    var box = $('pools'); box.textContent = '';
    pools.forEach(function (pool, i) {
      if (!pool.poolKey) pool.poolKey = i === 0 ? 'general' : ('pool-' + (i + 1));
      var comp = P.computePool(pool, cfg.environment);
      var card = el('div', 'pool');

      var head = el('div', 'headline');
      var selLab = el('label');
      var selChk = document.createElement('input');
      selChk.type = 'checkbox';
      selChk.checked = !!selectedPools[i];
      selChk.title = 'Select this host pool for template application';
      selChk.addEventListener('change', function () { selectedPools[i] = selChk.checked; });
      selLab.appendChild(selChk);
      selLab.appendChild(el('strong', '', 'Host pool ' + (i + 1) + ': ' + comp.poolKey + ' (' + comp.hostPoolType.toLowerCase() + ')'));
      head.appendChild(selLab);

      var btnWrap = el('div'); btnWrap.style.marginLeft = 'auto'; btnWrap.style.display = 'flex'; btnWrap.style.gap = '8px';
      var dupBtn = el('button', 'linkbtn', 'Duplicate');
      dupBtn.type = 'button';
      dupBtn.disabled = pools.length >= P.MAX_HOST_POOLS;
      dupBtn.addEventListener('click', function () {
        if (pools.length >= P.MAX_HOST_POOLS) return;
        var copyPool = JSON.parse(JSON.stringify(pool));
        copyPool.poolKey = (pool.poolKey || 'pool') + '-' + (pools.length + 1);
        copyPool.name = (pool.name || 'Host pool') + ' ' + (pools.length + 1);
        pools.push(copyPool);
        selectedPools[pools.length - 1] = true;
        save('hostPools', pools);
        renderTemplatesBar(); renderPools(); renderWorkspacesAndAppGroups();
      });
      btnWrap.appendChild(dupBtn);
      if (pools.length > 1) {
        var rmBtn = el('button', 'linkbtn', 'Remove');
        rmBtn.type = 'button';
        rmBtn.addEventListener('click', function () {
          pools.splice(i, 1);
          save('hostPools', pools);
          renderTemplatesBar(); renderPools(); renderWorkspacesAndAppGroups();
        });
        btnWrap.appendChild(rmBtn);
      }
      head.appendChild(btnWrap);
      card.appendChild(head);

      var row = el('div', 'row');
      POOL_FIELDS.forEach(function (f) {
        var lab = el('label', 'field'); lab.appendChild(el('span', '', f[1]));
        var input;
        if (f[2] === 'pooltype' || f[2] === 'workload' || f[2] === 'vmsize' || f[2] === 'spare' || f[2] === 'hostcount') {
          var opts = f[2] === 'pooltype' ? [['Pooled', 'Pooled (multi-session shared hosts)'], ['Personal', 'Personal (1:1 dedicated desktop per user)']]
            : f[2] === 'workload' ? Object.keys(P.WORKLOADS).map(function (k) { return [k, P.WORKLOADS[k].label + ' (' + P.WORKLOADS[k].usersPerVcpu + '/vCPU)']; })
            : f[2] === 'vmsize' ? [['', 'Suggested: memory-optimized E-series']].concat(Object.keys(P.VM_SIZES).map(function (k) { return [k, k.replace('Standard_', '') + ' (' + P.VM_SIZES[k].vcpu + ' vCPU, ' + P.VM_SIZES[k].ramGiB + ' GiB' + (P.VM_SIZES[k].recommended ? ', recommended' : '') + ')']; }))
            : f[2] === 'hostcount' ? [['auto', 'Automatic: enough for the busiest time']].concat(Array.from({ length: P.MAX_HOSTS }, function (_, n) { return [String(n + 1), (n + 1) + (n ? ' hosts' : ' host (minimum)')]; }))
            : [['', 'Automatic (one in prod)'], ['true', 'Yes'], ['false', 'No']];
          var curVal = f[0] === 'hostPoolType' ? comp.hostPoolType : pool[f[0]];
          input = makeSelect(opts, curVal);
          if (f[2] === 'spare') input.disabled = pool.hostCount !== 'auto' || comp.hostPoolType === 'Personal';
          if (f[2] === 'workload') input.disabled = comp.hostPoolType === 'Personal';
        }
        else {
          input = document.createElement('input');
          input.type = f[2] === 'slug' ? 'text' : f[2];
          if (f[2] === 'number') input.min = '1';
          input.value = pool[f[0]] === undefined || pool[f[0]] === null ? '' : pool[f[0]];
          input.autocomplete = 'off';
          if (f[0] === 'concurrencyPercent') input.disabled = comp.hostPoolType === 'Personal';
        }
        input.addEventListener('input', function () {
          var v = input.value;
          if (f[0] === 'poolKey') {
            pools[i].poolKey = v.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || ('pool-' + (i + 1));
          } else if (f[0] === 'hostPoolType') {
            pools[i].hostPoolType = v === 'Personal' ? 'Personal' : 'Pooled';
            pools[i].type = pools[i].hostPoolType === 'Personal' ? 'personal' : 'pooled';
            if (pools[i].hostPoolType === 'Personal') pools[i].loadBalancerType = 'Persistent';
            else if (pools[i].loadBalancerType === 'Persistent') pools[i].loadBalancerType = 'BreadthFirst';
          } else {
            pools[i][f[0]] = f[2] === 'number' ? Number(v) : f[2] === 'spare' ? (v === '' ? null : v === 'true') : f[2] === 'hostcount' ? (v === 'auto' ? 'auto' : Number(v)) : v;
          }
          save('hostPools', pools);
          if (f[2] === 'hostcount' || f[2] === 'pooltype') renderPools();
          else { renderSizeResult(); if (f[0] === 'poolKey') { renderTemplatesBar(); renderWorkspacesAndAppGroups(); } }
        });
        lab.appendChild(input); row.appendChild(lab);
      });
      card.appendChild(row);

      // Expandable per-pool settings
      var adv = el('details', 'more'); adv.style.marginTop = '10px';
      adv.appendChild(el('summary', '', 'All pool settings (load balancing, RDP, autoscale, Intune, Private Link)'));
      var advRow1 = el('div', 'row'); advRow1.style.marginTop = '8px';

      // Load balancer
      var lbLab = el('label', 'field'); lbLab.appendChild(el('span', '', 'Load balancing algorithm'));
      var lbSel = makeSelect(comp.hostPoolType === 'Personal' ? [['Persistent', 'Persistent (1:1 personal desktop)']] : [['BreadthFirst', 'BreadthFirst (spread sessions across hosts)'], ['DepthFirst', 'DepthFirst (fill one host before the next)']], comp.loadBalancerType);
      lbSel.disabled = comp.hostPoolType === 'Personal';
      lbSel.addEventListener('change', function () { pools[i].loadBalancerType = lbSel.value; save('hostPools', pools); renderSizeResult(); });
      lbLab.appendChild(lbSel); advRow1.appendChild(lbLab);

      // Personal assignment type
      var paLab = el('label', 'field'); paLab.appendChild(el('span', '', 'Personal desktop assignment'));
      var paSel = makeSelect([['Automatic', 'Automatic (assign first available host)'], ['Direct', 'Direct (admin assigns specific host)']], comp.personalDesktopAssignmentType);
      paSel.disabled = comp.hostPoolType !== 'Personal';
      paSel.addEventListener('change', function () { pools[i].personalDesktopAssignmentType = paSel.value; save('hostPools', pools); renderSizeResult(); });
      paLab.appendChild(paSel); advRow1.appendChild(paLab);

      // Preferred app group type
      var agtLab = el('label', 'field'); agtLab.appendChild(el('span', '', 'Preferred app group type'));
      var agtSel = makeSelect([['Desktop', 'Desktop (full desktop sessions)'], ['RailApplications', 'RailApplications (RemoteApp programs)']], comp.preferredAppGroupType);
      agtSel.addEventListener('change', function () { pools[i].preferredAppGroupType = agtSel.value; save('hostPools', pools); renderSizeResult(); });
      agtLab.appendChild(agtSel); advRow1.appendChild(agtLab);

      // Max session limit override
      var msLab = el('label', 'field'); msLab.appendChild(el('span', '', 'Max sessions per host override'));
      var msIn = document.createElement('input'); msIn.type = 'number'; msIn.min = '1'; msIn.max = '999999'; msIn.placeholder = 'Auto (' + comp.sessionsPerHost + ')';
      msIn.value = pool.maxSessionLimitOverride ? String(pool.maxSessionLimitOverride) : '';
      msIn.disabled = comp.hostPoolType === 'Personal';
      msIn.addEventListener('input', function () { pools[i].maxSessionLimitOverride = msIn.value ? Number(msIn.value) : null; save('hostPools', pools); renderSizeResult(); });
      msLab.appendChild(msIn); advRow1.appendChild(msLab);

      // FSLogix VHDX max size MiB
      var fslLab = el('label', 'field'); fslLab.appendChild(el('span', '', 'FSLogix max VHDX size (MiB)'));
      var fslIn = document.createElement('input'); fslIn.type = 'number'; fslIn.min = '500'; fslIn.max = '1048576';
      fslIn.value = String(comp.fslogixProfileSizeMiB || 30000);
      fslIn.addEventListener('input', function () { pools[i].fslogixProfileSizeMiB = Number(fslIn.value) || 30000; save('hostPools', pools); renderSizeResult(); });
      fslLab.appendChild(fslIn); advRow1.appendChild(fslLab);

      adv.appendChild(advRow1);

      var advRow2 = el('div', 'row'); advRow2.style.marginTop = '8px';

      // Scaling plan
      var spLab = el('label', 'field'); spLab.appendChild(el('span', '', 'Autoscale scaling plan'));
      var spVal = pool.deployScalingPlan === null || pool.deployScalingPlan === undefined ? '' : String(pool.deployScalingPlan);
      var spSel = makeSelect([['', 'Default (enabled in prod)'], ['true', 'Enabled'], ['false', 'Disabled']], spVal);
      spSel.disabled = comp.hostPoolType === 'Personal';
      spSel.addEventListener('change', function () { pools[i].deployScalingPlan = spSel.value === '' ? null : spSel.value === 'true'; save('hostPools', pools); renderSizeResult(); });
      spLab.appendChild(spSel); advRow2.appendChild(spLab);

      // Scaling time zone
      var tzLab = el('label', 'field'); tzLab.appendChild(el('span', '', 'Autoscale time zone'));
      var tzSel = makeSelect([
        ['Central Standard Time', 'Central Standard Time'],
        ['Eastern Standard Time', 'Eastern Standard Time'],
        ['Mountain Standard Time', 'Mountain Standard Time'],
        ['Pacific Standard Time', 'Pacific Standard Time'],
        ['GMT Standard Time', 'GMT Standard Time'],
        ['W. Europe Standard Time', 'W. Europe Standard Time'],
        ['UTC', 'UTC']
      ], comp.scalingTimeZone || 'Central Standard Time');
      tzSel.addEventListener('change', function () { pools[i].scalingTimeZone = tzSel.value; save('hostPools', pools); renderSizeResult(); });
      tzLab.appendChild(tzSel); advRow2.appendChild(tzLab);

      // Encryption at host
      var encLab = el('label', 'field'); encLab.appendChild(el('span', '', 'Encryption at Host'));
      var encVal = pool.encryptionAtHost === null || pool.encryptionAtHost === undefined ? '' : String(pool.encryptionAtHost);
      var encSel = makeSelect([['', 'Default (enabled in prod)'], ['true', 'Enabled'], ['false', 'Disabled']], encVal);
      encSel.addEventListener('change', function () { pools[i].encryptionAtHost = encSel.value === '' ? null : encSel.value === 'true'; save('hostPools', pools); renderSizeResult(); });
      encLab.appendChild(encSel); advRow2.appendChild(encLab);

      // Intune enrollment
      var intLab = el('label', 'field'); intLab.appendChild(el('span', '', 'Enroll hosts in Intune'));
      var intVal = pool.enrollInIntune === null || pool.enrollInIntune === undefined ? '' : String(pool.enrollInIntune);
      var intSel = makeSelect([['', 'Default (off unless set)'], ['true', 'Enabled'], ['false', 'Disabled']], intVal);
      intSel.addEventListener('change', function () { pools[i].enrollInIntune = intSel.value === '' ? null : intSel.value === 'true'; save('hostPools', pools); renderSizeResult(); });
      intLab.appendChild(intSel); advRow2.appendChild(intLab);

      // Availability zones
      var azLab = el('label', 'field'); azLab.appendChild(el('span', '', 'Availability zones'));
      var azVal = Array.isArray(pool.availabilityZones) ? pool.availabilityZones.join(',') : '';
      var azSel = makeSelect([['', 'Default (zones 1,2,3 in prod)'], ['none', 'None (regional)'], ['1,2,3', 'Zones 1, 2, 3'], ['1,2', 'Zones 1, 2'], ['1', 'Zone 1 only']], pool.availabilityZones === null || pool.availabilityZones === undefined ? '' : (azVal || 'none'));
      azSel.addEventListener('change', function () {
        var v = azSel.value;
        pools[i].availabilityZones = v === '' ? null : v === 'none' ? [] : v.split(',').map(Number);
        save('hostPools', pools); renderSizeResult();
      });
      azLab.appendChild(azSel); advRow2.appendChild(azLab);

      adv.appendChild(advRow2);

      var advRow3 = el('div', 'row'); advRow3.style.marginTop = '8px';

      // Public network access (per pool)
      var pnaLab = el('label', 'field'); pnaLab.appendChild(el('span', '', 'Host pool public network access'));
      var pnaSel = makeSelect([
        ['EnabledForClientsOnly', 'EnabledForClientsOnly (clients public, hosts private)'],
        ['Enabled', 'Enabled (public clients and session hosts)'],
        ['EnabledForSessionHostsOnly', 'EnabledForSessionHostsOnly (private clients, public hosts)'],
        ['Disabled', 'Disabled (Private Link only)']
      ], comp.publicNetworkAccess || 'EnabledForClientsOnly');
      pnaSel.addEventListener('change', function () { pools[i].publicNetworkAccess = pnaSel.value; save('hostPools', pools); renderSizeResult(); });
      pnaLab.appendChild(pnaSel); advRow3.appendChild(pnaLab);

      // Private endpoint (per pool)
      var peLab = el('label', 'field'); peLab.appendChild(el('span', '', 'Host pool connection Private Endpoint'));
      var peVal = pool.enablePrivateEndpoint === null || pool.enablePrivateEndpoint === undefined ? '' : String(pool.enablePrivateEndpoint);
      var peSel = makeSelect([['', 'Follow landing zone default'], ['true', 'Enabled (deploy connection PE)'], ['false', 'Disabled (no connection PE)']], peVal);
      peSel.addEventListener('change', function () { pools[i].enablePrivateEndpoint = peSel.value === '' ? null : peSel.value === 'true'; save('hostPools', pools); renderSizeResult(); });
      peLab.appendChild(peSel); advRow3.appendChild(peLab);

      // Start VM on Connect & Validation environment
      var svmLab = el('label', 'field'); svmLab.appendChild(el('span', '', 'Start VM on Connect'));
      var svmSel = makeSelect([['true', 'Enabled'], ['false', 'Disabled']], String(comp.startVmOnConnect !== false));
      svmSel.addEventListener('change', function () { pools[i].startVmOnConnect = svmSel.value === 'true'; save('hostPools', pools); renderSizeResult(); });
      svmLab.appendChild(svmSel); advRow3.appendChild(svmLab);

      var valLab = el('label', 'field'); valLab.appendChild(el('span', '', 'Validation environment'));
      var valSel = makeSelect([['false', 'Standard (production flights)'], ['true', 'Validation (early AVD updates)']], String(!!comp.validationEnvironment));
      valSel.addEventListener('change', function () { pools[i].validationEnvironment = valSel.value === 'true'; save('hostPools', pools); renderSizeResult(); });
      valLab.appendChild(valSel); advRow3.appendChild(valLab);

      adv.appendChild(advRow3);

      // RDP properties
      var rdpWrap = el('div'); rdpWrap.style.marginTop = '8px';
      var rdpLab = el('label', 'field'); rdpLab.appendChild(el('span', '', 'Custom RDP properties'));
      var rdpIn = document.createElement('input'); rdpIn.type = 'text'; rdpIn.autocomplete = 'off';
      rdpIn.value = comp.rdpProperties || P.DEFAULT_RDP_PROPERTIES;
      rdpIn.addEventListener('input', function () { pools[i].rdpProperties = rdpIn.value; save('hostPools', pools); renderSizeResult(); });
      rdpLab.appendChild(rdpIn); rdpWrap.appendChild(rdpLab);
      var rdpBtns = el('div', 'row'); rdpBtns.style.marginTop = '4px';
      var rdpDefBtn = el('button', 'linkbtn', 'Use standard RDP preset'); rdpDefBtn.type = 'button';
      rdpDefBtn.addEventListener('click', function () { pools[i].rdpProperties = P.DEFAULT_RDP_PROPERTIES; rdpIn.value = P.DEFAULT_RDP_PROPERTIES; save('hostPools', pools); renderSizeResult(); });
      var rdpLockBtn = el('button', 'linkbtn', 'Use locked-down RDP preset (no clipboard/printer/USB/camera)'); rdpLockBtn.type = 'button';
      rdpLockBtn.addEventListener('click', function () { pools[i].rdpProperties = P.LOCKED_DOWN_RDP_PROPERTIES; rdpIn.value = P.LOCKED_DOWN_RDP_PROPERTIES; save('hostPools', pools); renderSizeResult(); });
      rdpBtns.appendChild(rdpDefBtn); rdpBtns.appendChild(rdpLockBtn);
      rdpWrap.appendChild(rdpBtns);
      adv.appendChild(rdpWrap);

      card.appendChild(adv);
      box.appendChild(card);
    });
    $('add-pool').disabled = pools.length >= P.MAX_HOST_POOLS;
    if ($('pools-count-status')) $('pools-count-status').textContent = pools.length + ' of ' + P.MAX_HOST_POOLS + ' host pool(s) configured.';
    renderSizeResult();
  }

  if ($('add-pool')) {
    $('add-pool').addEventListener('click', function () {
      if (pools.length >= P.MAX_HOST_POOLS) return;
      var nextNum = pools.length + 1;
      var newKey = 'pool-' + nextNum;
      pools.push(Object.assign({}, P.HOST_POOL_DEFAULTS, { poolKey: newKey, name: 'Host pool ' + nextNum }));
      selectedPools[pools.length - 1] = true;
      // Also create a default Desktop app group wired to this new pool and the first workspace
      if (appGroups.length < P.MAX_APP_GROUPS) {
        var wsKey = (workspaces[0] && workspaces[0].name) || 'default';
        appGroups.push(Object.assign({}, P.APP_GROUP_DEFAULTS, {
          name: newKey + '-desktop',
          friendlyName: 'Host pool ' + nextNum + ' Desktop',
          applicationGroupType: 'Desktop',
          hostPool: newKey,
          workspace: wsKey
        }));
        save('appGroups', appGroups);
      }
      save('hostPools', pools);
      renderTemplatesBar(); renderPools(); renderWorkspacesAndAppGroups();
    });
  }

  // Workspaces and Application Groups UI
  function renderWorkspacesAndAppGroups() {
    var wsBox = $('workspaces'), agBox = $('app-groups');
    if (!wsBox || !agBox) return;
    wsBox.textContent = ''; agBox.textContent = '';

    workspaces.forEach(function (ws, i) {
      var card = el('div', 'pool');
      var head = el('div', 'headline');
      head.appendChild(el('strong', '', 'Workspace ' + (i + 1) + ': ' + (ws.name || ('ws-' + (i + 1)))));
      if (workspaces.length > 1) {
        var rm = el('button', 'linkbtn', 'Remove'); rm.type = 'button'; rm.style.marginLeft = 'auto';
        rm.addEventListener('click', function () {
          workspaces.splice(i, 1); save('workspaces', workspaces); renderWorkspacesAndAppGroups(); renderSizeResult();
        });
        head.appendChild(rm);
      }
      card.appendChild(head);
      var row = el('div', 'row');

      var slugLab = el('label', 'field'); slugLab.appendChild(el('span', '', 'Workspace slug'));
      var slugIn = document.createElement('input'); slugIn.type = 'text'; slugIn.value = ws.name || 'default'; slugIn.autocomplete = 'off';
      slugIn.addEventListener('input', function () {
        ws.name = slugIn.value.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || ('ws-' + (i + 1));
        save('workspaces', workspaces); renderWorkspacesAndAppGroups(); renderSizeResult();
      });
      slugLab.appendChild(slugIn); row.appendChild(slugLab);

      var fnLab = el('label', 'field'); fnLab.appendChild(el('span', '', 'Display name'));
      var fnIn = document.createElement('input'); fnIn.type = 'text'; fnIn.value = ws.friendlyName || ''; fnIn.autocomplete = 'off';
      fnIn.addEventListener('input', function () { ws.friendlyName = fnIn.value; save('workspaces', workspaces); renderSizeResult(); });
      fnLab.appendChild(fnIn); row.appendChild(fnLab);

      var pubLab = el('label', 'field'); pubLab.appendChild(el('span', '', 'Public network access'));
      var pubSel = makeSelect([
        ['Enabled', 'Enabled (public feed)'],
        ['EnabledForClientsOnly', 'EnabledForClientsOnly'],
        ['EnabledForSessionHostsOnly', 'EnabledForSessionHostsOnly'],
        ['Disabled', 'Disabled (Private Link feed only)']
      ], ws.publicNetworkAccess || 'Enabled');
      pubSel.addEventListener('change', function () { ws.publicNetworkAccess = pubSel.value; save('workspaces', workspaces); renderSizeResult(); });
      pubLab.appendChild(pubSel); row.appendChild(pubLab);

      var feedLab = el('label', 'field'); feedLab.appendChild(el('span', '', 'Feed Private Endpoint'));
      var feedVal = ws.enableFeedPrivateEndpoint === null || ws.enableFeedPrivateEndpoint === undefined ? '' : String(ws.enableFeedPrivateEndpoint);
      var feedSel = makeSelect([['', 'Follow landing zone default'], ['true', 'Enabled (deploy feed PE)'], ['false', 'Disabled']], feedVal);
      feedSel.addEventListener('change', function () { ws.enableFeedPrivateEndpoint = feedSel.value === '' ? null : feedSel.value === 'true'; save('workspaces', workspaces); renderSizeResult(); });
      feedLab.appendChild(feedSel); row.appendChild(feedLab);

      card.appendChild(row);
      wsBox.appendChild(card);
    });
    if ($('add-workspace')) $('add-workspace').disabled = workspaces.length >= P.MAX_WORKSPACES;

    var poolSlugs = pools.map(function (p, idx) { var k = p.poolKey || (idx === 0 ? 'general' : ('pool-' + (idx + 1))); return [k, k + ' (' + (p.name || ('Pool ' + (idx + 1))) + ')']; });
    var wsSlugs = workspaces.map(function (w, idx) { var k = w.name || (idx === 0 ? 'default' : ('ws-' + (idx + 1))); return [k, k + ' (' + (w.friendlyName || ('Workspace ' + (idx + 1))) + ')']; });

    appGroups.forEach(function (ag, i) {
      var card = el('div', 'pool');
      var head = el('div', 'headline');
      head.appendChild(el('strong', '', 'Application group ' + (i + 1) + ': ' + (ag.name || ('ag-' + (i + 1)))));
      if (appGroups.length > 1) {
        var rm = el('button', 'linkbtn', 'Remove'); rm.type = 'button'; rm.style.marginLeft = 'auto';
        rm.addEventListener('click', function () {
          appGroups.splice(i, 1); save('appGroups', appGroups); renderWorkspacesAndAppGroups(); renderSizeResult();
        });
        head.appendChild(rm);
      }
      card.appendChild(head);
      var row = el('div', 'row');

      var slugLab = el('label', 'field'); slugLab.appendChild(el('span', '', 'App group slug'));
      var slugIn = document.createElement('input'); slugIn.type = 'text'; slugIn.value = ag.name || 'desktop'; slugIn.autocomplete = 'off';
      slugIn.addEventListener('input', function () {
        ag.name = slugIn.value.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || ('ag-' + (i + 1));
        save('appGroups', appGroups); renderSizeResult();
      });
      slugLab.appendChild(slugIn); row.appendChild(slugLab);

      var fnLab = el('label', 'field'); fnLab.appendChild(el('span', '', 'Display name'));
      var fnIn = document.createElement('input'); fnIn.type = 'text'; fnIn.value = ag.friendlyName || ''; fnIn.autocomplete = 'off';
      fnIn.addEventListener('input', function () { ag.friendlyName = fnIn.value; save('appGroups', appGroups); renderSizeResult(); });
      fnLab.appendChild(fnIn); row.appendChild(fnLab);

      var typeLab = el('label', 'field'); typeLab.appendChild(el('span', '', 'Type'));
      var typeSel = makeSelect([['Desktop', 'Desktop'], ['RemoteApp', 'RemoteApp']], ag.applicationGroupType || 'Desktop');
      typeSel.addEventListener('change', function () { ag.applicationGroupType = typeSel.value; save('appGroups', appGroups); renderSizeResult(); });
      typeLab.appendChild(typeSel); row.appendChild(typeLab);

      var hpLab = el('label', 'field'); hpLab.appendChild(el('span', '', 'Host pool'));
      var curHp = ag.hostPool || ag.hostPoolName || (poolSlugs[0] && poolSlugs[0][0]) || 'general';
      var hpSel = makeSelect(poolSlugs, curHp);
      hpSel.addEventListener('change', function () { ag.hostPool = hpSel.value; ag.hostPoolName = hpSel.value; save('appGroups', appGroups); renderSizeResult(); });
      hpLab.appendChild(hpSel); row.appendChild(hpLab);

      var wsLab = el('label', 'field'); wsLab.appendChild(el('span', '', 'Workspace'));
      var curWs = ag.workspace || ag.workspaceName || (wsSlugs[0] && wsSlugs[0][0]) || 'default';
      var wsSel = makeSelect(wsSlugs, curWs);
      wsSel.addEventListener('change', function () { ag.workspace = wsSel.value; ag.workspaceName = wsSel.value; save('appGroups', appGroups); renderSizeResult(); });
      wsLab.appendChild(wsSel); row.appendChild(wsLab);

      var ugLab = el('label', 'field'); ugLab.appendChild(el('span', '', 'Entra group Object ID (optional)'));
      var ugIn = document.createElement('input'); ugIn.type = 'text'; ugIn.placeholder = 'Default: AVD users group'; ugIn.value = ag.usersGroupObjectId || ''; ugIn.autocomplete = 'off';
      ugIn.addEventListener('input', function () { ag.usersGroupObjectId = ugIn.value.trim(); save('appGroups', appGroups); renderSizeResult(); });
      ugLab.appendChild(ugIn); row.appendChild(ugLab);

      card.appendChild(row);
      agBox.appendChild(card);
    });
    if ($('add-app-group')) $('add-app-group').disabled = appGroups.length >= P.MAX_APP_GROUPS;
    if ($('ws-ag-summary')) $('ws-ag-summary').textContent = workspaces.length + ' workspace' + (workspaces.length === 1 ? '' : 's') + ', ' + appGroups.length + ' application group' + (appGroups.length === 1 ? '' : 's');
  }

  if ($('add-workspace')) {
    $('add-workspace').addEventListener('click', function () {
      if (workspaces.length >= P.MAX_WORKSPACES) return;
      var n = workspaces.length + 1;
      workspaces.push(Object.assign({}, P.WORKSPACE_DEFAULTS, { name: 'ws-' + n, friendlyName: 'AVD Workspace ' + n }));
      save('workspaces', workspaces); renderWorkspacesAndAppGroups(); renderSizeResult();
    });
  }
  if ($('add-app-group')) {
    $('add-app-group').addEventListener('click', function () {
      if (appGroups.length >= P.MAX_APP_GROUPS) return;
      var n = appGroups.length + 1;
      var hpSlug = (pools[0] && pools[0].poolKey) || 'general';
      var wsSlug = (workspaces[0] && workspaces[0].name) || 'default';
      appGroups.push(Object.assign({}, P.APP_GROUP_DEFAULTS, { name: 'remoteapp-' + n, friendlyName: 'RemoteApp Group ' + n, applicationGroupType: 'RemoteApp', hostPool: hpSlug, workspace: wsSlug }));
      save('appGroups', appGroups); renderWorkspacesAndAppGroups(); renderSizeResult();
    });
  }

  // Private Link & Private DNS zones UI
  function renderPrivateLinkPanel() {
    if (!$('dns-zones')) return;
    $('pl-hp-public').value = privateLink.hostPoolPublicNetworkAccess || 'EnabledForClientsOnly';
    $('pl-ws-public').value = privateLink.workspacePublicNetworkAccess || 'Enabled';
    $('pl-conn').checked = privateLink.enableAvdConnectionPrivateLink !== false;
    $('pl-feed').checked = !!privateLink.enableAvdFeedPrivateLink;
    $('pl-global').checked = !!privateLink.enableAvdGlobalPrivateLink;

    var dnsBox = $('dns-zones'); dnsBox.textContent = '';
    Object.keys(P.DNS_ZONE_DEFINITIONS).forEach(function (k) {
      var def = P.DNS_ZONE_DEFINITIONS[k];
      var z = (privateLink.dnsZones && privateLink.dnsZones[k]) || { mode: k === 'avdGlobal' ? 'disabled' : 'new', existingResourceId: '' };
      var row = el('div', 'row'); row.style.marginTop = '8px';

      var modeLab = el('label', 'field'); modeLab.style.flex = '1 1 240px';
      modeLab.appendChild(el('span', '', def.label + ' (' + def.zoneName + ')'));
      var modeOpts = [['new', 'Create new Private DNS zone'], ['existing', 'Use existing Private DNS zone (Resource ID)']];
      if (k === 'avdGlobal') modeOpts.push(['disabled', 'Not deployed (unless Global Private Link is on)']);
      var modeSel = makeSelect(modeOpts, z.mode || (k === 'avdGlobal' ? 'disabled' : 'new'));

      var idLab = el('label', 'field'); idLab.style.flex = '2 1 320px';
      idLab.appendChild(el('span', '', 'Existing DNS zone Resource ID'));
      var idIn = document.createElement('input'); idIn.type = 'text'; idIn.autocomplete = 'off';
      idIn.placeholder = '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/' + def.zoneName;
      idIn.value = z.existingResourceId || '';
      idIn.disabled = modeSel.value !== 'existing';

      modeSel.addEventListener('change', function () {
        privateLink.dnsZones[k] = { mode: modeSel.value, existingResourceId: idIn.value.trim() };
        idIn.disabled = modeSel.value !== 'existing';
        save('privateLink', privateLink); renderSizeResult();
      });
      idIn.addEventListener('input', function () {
        privateLink.dnsZones[k] = { mode: modeSel.value, existingResourceId: idIn.value.trim() };
        save('privateLink', privateLink); renderSizeResult();
      });

      modeLab.appendChild(modeSel); row.appendChild(modeLab);
      idLab.appendChild(idIn); row.appendChild(idLab);
      dnsBox.appendChild(row);
    });
  }

  if ($('pl-hp-public')) {
    $('pl-hp-public').addEventListener('change', function () { privateLink.hostPoolPublicNetworkAccess = $('pl-hp-public').value; save('privateLink', privateLink); renderSizeResult(); });
    $('pl-ws-public').addEventListener('change', function () { privateLink.workspacePublicNetworkAccess = $('pl-ws-public').value; save('privateLink', privateLink); renderSizeResult(); });
    $('pl-conn').addEventListener('change', function () { privateLink.enableAvdConnectionPrivateLink = $('pl-conn').checked; save('privateLink', privateLink); renderSizeResult(); });
    $('pl-feed').addEventListener('change', function () { privateLink.enableAvdFeedPrivateLink = $('pl-feed').checked; save('privateLink', privateLink); renderSizeResult(); });
    $('pl-global').addEventListener('change', function () {
      privateLink.enableAvdGlobalPrivateLink = $('pl-global').checked;
      if ($('pl-global').checked && privateLink.dnsZones.avdGlobal && privateLink.dnsZones.avdGlobal.mode === 'disabled') {
        privateLink.dnsZones.avdGlobal.mode = 'new';
      }
      save('privateLink', privateLink); renderPrivateLinkPanel(); renderSizeResult();
    });
  }

  function renderSizeResult() {
    var comp = currentTopologyComputed(), r = comp.pools[0], tb = $('size-result'); tb.textContent = '';
    var hostSummary = comp.pools.length === 1
      ? ((r.hostCountAuto ? '' : 'Chosen: ') + r.hosts + ' × ' + r.vmSize.replace('Standard_', '') + ' (' + r.vcpuPerHost + ' vCPU, ' + r.ramGiBPerHost + ' GiB each; ' + r.memoryPerSessionGiB + ' GiB per session)')
      : comp.pools.map(function (p) { return p.poolKey + ': ' + p.hosts + ' × ' + p.vmSize.replace('Standard_', '') + ' (' + p.hostPoolType + ')'; }).join('; ');
    var dnsModes = ['file', 'keyVault', 'avd', 'avdGlobal'].map(function (k) {
      var z = comp.privateLink.dnsZones[k];
      return z.mode === 'existing' ? (k + ': existing') : z.deployNew ? (k + ': new') : null;
    }).filter(Boolean).join(', ');
    var rows = [
      ['Concurrent sessions', comp.totals.concurrentUsers + ' of ' + comp.totals.users + ' people' + (comp.pools.length > 1 ? ' across ' + comp.pools.length + ' host pools' : '')],
      ['Session hosts', hostSummary],
      ['OS disk', r.osDisk + ' on every host'],
      ['Sessions per host (max session limit)', comp.pools.length === 1 ? String(r.sessionsPerHost) : comp.pools.map(function (p) { return p.poolKey + ': ' + p.sessionsPerHost; }).join(', ')],
      ['Capacity', comp.totals.capacity + ' sessions (' + comp.totals.hosts + ' total host' + (comp.totals.hosts === 1 ? '' : 's') + ')'],
      ['vCPU quota needed', comp.totals.vcpus + ' vCPUs'],
      ['Profile share', comp.totals.profileQuotaGiB + ' GiB provisioned (storage SKU from ' + cfg.parameterFile.replace(/^parameters\//, '') + ')'],
      ['Workspaces & app groups', comp.workspaces.length + ' workspace(s), ' + comp.appGroups.length + ' app group(s)'],
      ['Private Link & DNS zones', 'AVD connection PE: ' + (comp.privateLink.enableAvdConnectionPrivateLink ? 'on' : 'off') + ', feed PE: ' + (comp.privateLink.enableAvdFeedPrivateLink ? 'on' : 'off') + ', global PE: ' + (comp.privateLink.enableAvdGlobalPrivateLink ? 'on' : 'off') + ' (' + (dnsModes || 'no DNS zones') + ')']
    ];
    rows.forEach(function (kv) { var tr = el('tr'); tr.appendChild(el('td', '', kv[0])); tr.appendChild(el('td', '', kv[1])); tb.appendChild(tr); });

    if ($('ws-ag-summary')) $('ws-ag-summary').textContent = comp.workspaces.length + ' workspace' + (comp.workspaces.length === 1 ? '' : 's') + ', ' + comp.appGroups.length + ' application group' + (comp.appGroups.length === 1 ? '' : 's');
    if ($('pl-dns-summary')) $('pl-dns-summary').textContent = 'AVD connection PE ' + (comp.privateLink.enableAvdConnectionPrivateLink ? 'on' : 'off') + ', feed PE ' + (comp.privateLink.enableAvdFeedPrivateLink ? 'on' : 'off') + ', ' + (dnsModes || 'default DNS');

    var manifest = currentManifestFromComputed(comp);
    if ($('manifest-json') && document.activeElement !== $('manifest-json')) {
      $('manifest-json').value = manifest ? JSON.stringify(manifest, null, 2) : '{}';
    }

    var ul = $('size-notes'); ul.textContent = ''; comp.notes.forEach(function (n) { ul.appendChild(el('li', '', n)); });
    var s = cfg.sizing, mine = P.toSizing(comp);
    if (s && (s.hosts !== mine.hosts || s.vmSize !== mine.vmSize || s.maxSessions !== mine.maxSessions || s.profileQuotaGiB !== mine.profileQuotaGiB))
      ul.appendChild(el('li', '', 'The commands use ' + s.hosts + ' × ' + s.vmSize.replace('Standard_', '') + ' with ' + s.maxSessions + ' sessions each (the last sizing applied or checked by a pasted preflight). Select Use this sizing & topology to switch to the one above.'));
    renderSizeSummary();
  }
  function renderSizeSummary() {
    var s = cfg.sizing, t = cfg.topology;
    var poolCount = (t && t.hostPools && t.hostPools.length) || 1;
    var wsCount = (t && t.workspaces && t.workspaces.length) || 1;
    $('size-summary').textContent = s
      ? (poolCount > 1 || wsCount > 1
        ? poolCount + ' pools (' + s.hosts + ' hosts), ' + wsCount + ' workspace(s)'
        : s.hosts + ' × ' + s.vmSize.replace('Standard_', '') + ', ' + (s.hosts * s.maxSessions) + ' sessions')
      : 'not set (the parameter file\'s values)';
  }

  if ($('manifest-copy')) {
    $('manifest-copy').addEventListener('click', function () {
      copy($('manifest-json').value || '{}', $('manifest-copy'));
    });
    $('manifest-import').addEventListener('click', function () {
      try {
        var raw = JSON.parse($('manifest-json').value || '{}');
        var valid = P.validTopology(raw);
        if (!valid) { $('manifest-status').textContent = 'Invalid topology manifest JSON (check slugs, sizes, or DNS zone resource IDs).'; return; }
        if (valid.hostPools && valid.hostPools.length) {
          pools = valid.hostPools.map(function (hp) {
            return Object.assign({}, P.HOST_POOL_DEFAULTS, hp, {
              poolKey: hp.name,
              name: hp.friendlyName || hp.name,
              hostCount: hp.sessionHostCount,
              vmSize: hp.sessionHostVmSize,
              maxSessionLimitOverride: hp.maxSessionLimit
            });
          });
          save('hostPools', pools);
        }
        if (valid.workspaces && valid.workspaces.length) {
          workspaces = valid.workspaces.map(function (ws) { return Object.assign({}, P.WORKSPACE_DEFAULTS, ws); });
          save('workspaces', workspaces);
        }
        if (valid.appGroups && valid.appGroups.length) {
          appGroups = valid.appGroups.map(function (ag) { return Object.assign({}, P.APP_GROUP_DEFAULTS, ag, { hostPool: ag.hostPoolName, workspace: ag.workspaceName }); });
          save('appGroups', appGroups);
        }
        if (valid.privateLink) {
          var vpl = valid.privateLink;
          privateLink.enableAvdConnectionPrivateLink = vpl.enableConnectionPrivateEndpoint !== false;
          privateLink.enableAvdFeedPrivateLink = !!vpl.enableFeedPrivateEndpoint;
          privateLink.enableAvdGlobalPrivateLink = !!vpl.enableGlobalPrivateEndpoint;
          privateLink.hostPoolPublicNetworkAccess = vpl.hostPoolPublicNetworkAccess || 'EnabledForClientsOnly';
          privateLink.workspacePublicNetworkAccess = vpl.workspacePublicNetworkAccess || 'Enabled';
          if (vpl.dnsZones) {
            ['file', 'keyVault', 'avd', 'avdGlobal'].forEach(function (k) {
              if (vpl.dnsZones[k]) privateLink.dnsZones[k] = { mode: vpl.dnsZones[k].mode, existingResourceId: vpl.dnsZones[k].resourceId || '' };
            });
          }
          save('privateLink', privateLink);
        }
        renderTemplatesBar(); renderPools(); renderWorkspacesAndAppGroups(); renderPrivateLinkPanel();
        $('manifest-status').textContent = 'Imported topology manifest (' + pools.length + ' pool(s), ' + workspaces.length + ' workspace(s), ' + appGroups.length + ' app group(s)).';
      } catch (e) {
        $('manifest-status').textContent = 'Could not parse JSON: ' + e.message;
      }
    });
  }

  // ---------------------------------------------------------------- cost (power settings reprice the estimate)
  function renderCost() {
    var p = P.effectivePower(cfg), hh = P.hostHours(cfg.hoursWorkedPerWeek, p);
    $('power-svmoc').checked = p.startVmOnConnect;
    var on = p.autoShutdownTime !== 'none';
    $('power-shutdown').checked = on; $('power-time').disabled = !on;
    if (on) $('power-time').value = p.autoShutdownTime; else if (!$('power-time').value) $('power-time').value = '20:00';
    $('hours-worked').value = cfg.hoursWorkedPerWeek;
    $('hours-basis').textContent = 'Each host runs about ' + hh.hoursPerWeek + ' hours a week. ' + hh.basis;
    $('power-source').textContent = p.fromFile ? 'These are what ' + cfg.parameterFile + ' deploys. Change them and the commands carry your choice.' : 'The commands deploy these settings (deploy.sh --auto-shutdown ' + p.autoShutdownTime + ' --start-vm-on-connect ' + p.startVmOnConnect + ').';
    $('power-reset').classList.toggle('hidden', p.fromFile);

    var box = $('estimate'); box.textContent = '';
    var e = P.repriceEstimate(estimate, cfg.sizing, hh.hoursPerWeek, cfg.location);
    $('cost-summary').textContent = e && !e.stale.length ? 'about ' + money(e.total, e.currency) + '/month' : hh.hoursPerWeek + ' h/week per host';
    if (!e) {
      var comp = currentTopologyComputed(), s = cfg.sizing || P.toSizing(comp), q = Math.round(s.hosts * hh.hoursPerWeek * 52 / 12 * 10) / 10;
      box.appendChild(el('h3', '', 'What gets priced'));
      var t0 = el('table', 'kv'), tb0 = el('tbody');
      [['Session hosts', s.hosts + ' × ' + s.vmSize.replace('Standard_', '') + ' × ' + hh.hoursPerWeek + ' h/week = ' + q + ' host-hours a month'],
        ['OS disks', s.hosts + ' × Premium SSD P10'], ['Profile share', s.profileQuotaGiB + ' GiB provisioned'], ['Also', 'private endpoints, NAT Gateway and its public IP']
      ].forEach(function (kv) { var tr = el('tr'); tr.appendChild(el('td', '', kv[0])); tr.appendChild(el('td', '', kv[1])); tb0.appendChild(tr); });
      t0.appendChild(tb0); var w0 = el('div', 'table-wrap'); w0.appendChild(t0); box.appendChild(w0);
      box.appendChild(el('p', 'status', 'The pre-deployment preflight prices these in ' + cfg.location + ' at Azure list prices (the public Retail Prices API, from Cloud Shell). Paste its output and the estimate appears here; then these settings reprice it as you change them.'));
      return;
    }
    box.appendChild(el('h3', '', 'Estimated monthly cost'));
    if (e.stale.length) box.appendChild(el('p', 'status', 'This estimate was ' + e.stale.join(' and ') + ', so the settings above can\'t reprice it. Run the pre-deployment preflight again.'));
    var t = el('table'), tb = el('tbody');
    var head = el('tr'); head.appendChild(el('th', '', 'Item')); head.appendChild(el('th', 'money', 'Per month')); t.appendChild(head);
    e.lines.forEach(function (l) {
      var tr = el('tr'), td = el('td', 'region'); td.appendChild(document.createTextNode(l.item));
      td.appendChild(el('span', 'muted', l.quantity + ' ' + l.unit + ' × ' + l.unitPrice + ' per ' + l.unitOfMeasure + (l.note ? ' · ' + l.note : '')));
      tr.appendChild(td); tr.appendChild(el('td', 'money', money(l.monthly, e.currency))); tb.appendChild(tr);
    });
    var tot = el('tr'); tot.appendChild(el('td', '', 'Total (list prices, ' + e.location + ')')); var tt = el('td', 'money'); tt.appendChild(el('strong', '', money(e.total, e.currency))); tot.appendChild(tt); tb.appendChild(tot);
    t.appendChild(tb); var wrap = el('div', 'table-wrap'); wrap.appendChild(t); box.appendChild(wrap);
    var notes = el('ul', 'notes');
    if (e.alwaysOnTotal !== null && e.alwaysOnTotal > e.total) notes.appendChild(el('li', '', 'Around the clock it would be ' + money(e.alwaysOnTotal, e.currency) + ' a month; these settings save ' + money(e.alwaysOnTotal - e.total, e.currency) + '.'));
    e.unpriced.forEach(function (u) { notes.appendChild(el('li', '', 'Not priced: ' + u.item + ' (no matching meter; not in the total).')); });
    notes.appendChild(el('li', '', 'Not included (usage-based): ' + e.excluded.join('; ') + '.'));
    notes.appendChild(el('li', '', 'Pay-as-you-go list prices; reservations, savings plans and agreements lower them.'));
    box.appendChild(notes);
  }
  function setPower(patch) {
    var p = P.effectivePower(cfg);
    cfg.power = { startVmOnConnect: p.startVmOnConnect, autoShutdownTime: p.autoShutdownTime };
    Object.keys(patch).forEach(function (k) { cfg.power[k] = patch[k]; });
    save('power', cfg.power); lastAnalysis = null; renderCost(); render();
  }
  $('power-svmoc').addEventListener('change', function () { setPower({ startVmOnConnect: $('power-svmoc').checked }); });
  $('power-shutdown').addEventListener('change', function () { setPower({ autoShutdownTime: $('power-shutdown').checked ? ($('power-time').value || '20:00') : 'none' }); });
  $('power-time').addEventListener('change', function () { if (/^\d{2}:\d{2}$/.test($('power-time').value)) setPower({ autoShutdownTime: $('power-time').value }); });
  $('hours-worked').addEventListener('input', function () {
    var v = Math.round(Number($('hours-worked').value));
    if (v >= 1 && v <= 168) { cfg.hoursWorkedPerWeek = v; save('hoursWorked', v); lastAnalysis = null; renderCost(); render(); }
  });
  $('power-reset').addEventListener('click', function () { cfg.power = null; save('power', null); lastAnalysis = null; renderCost(); render(); });
  $('cost-continue').addEventListener('click', function () { goTo('predeploy'); });

  function applySizingAndTopology(s, topo) {
    cfg.sizing = s; save('sizing', s);
    cfg.topology = topo; save('topology', topo);
    renderSizeResult(); renderCost(); lastAnalysis = null; render();
  }
  $('size-apply').addEventListener('click', function () {
    var comp = currentTopologyComputed();
    var s = P.toSizing(comp);
    var manifest = currentManifestFromComputed(comp);
    var customTopo = manifest && P.hasCustomTopology({ topology: manifest }) ? manifest : null;
    applySizingAndTopology(s, customTopo);
    $('size-status').textContent = 'Applied: ' + comp.pools.length + ' pool(s) (' + comp.totals.hosts + ' host(s)), ' + comp.workspaces.length + ' workspace(s), ' + comp.appGroups.length + ' app group(s).';
    if (curIndex() <= stepIndex('size')) goTo('cost');
  });
  $('size-clear').addEventListener('click', function () {
    applySizingAndTopology(null, null); $('size-status').textContent = 'The commands use the parameter file\'s sizing and default topology.';
    if (curIndex() <= stepIndex('size')) goTo('cost');
  });

  // ---------------------------------------------------------------- region latency
  // Regions with a regional endpoint that resolves in-region (checked in DNS), grouped for the filters.
  var REGIONS = [
    ['eastus', 'East US', 'Americas'], ['eastus2', 'East US 2', 'Americas'], ['centralus', 'Central US', 'Americas'],
    ['northcentralus', 'North Central US', 'Americas'], ['southcentralus', 'South Central US', 'Americas'],
    ['westcentralus', 'West Central US', 'Americas'], ['westus', 'West US', 'Americas'], ['westus2', 'West US 2', 'Americas'],
    ['westus3', 'West US 3', 'Americas'], ['canadacentral', 'Canada Central', 'Americas'], ['canadaeast', 'Canada East', 'Americas'],
    ['brazilsouth', 'Brazil South', 'Americas'],
    ['northeurope', 'North Europe', 'Europe'], ['westeurope', 'West Europe', 'Europe'], ['uksouth', 'UK South', 'Europe'],
    ['ukwest', 'UK West', 'Europe'], ['francecentral', 'France Central', 'Europe'], ['germanywestcentral', 'Germany West Central', 'Europe'],
    ['switzerlandnorth', 'Switzerland North', 'Europe'], ['norwayeast', 'Norway East', 'Europe'], ['swedencentral', 'Sweden Central', 'Europe'],
    ['polandcentral', 'Poland Central', 'Europe'], ['italynorth', 'Italy North', 'Europe'], ['spaincentral', 'Spain Central', 'Europe'],
    ['eastasia', 'East Asia', 'Asia Pacific'], ['southeastasia', 'Southeast Asia', 'Asia Pacific'], ['japaneast', 'Japan East', 'Asia Pacific'],
    ['japanwest', 'Japan West', 'Asia Pacific'], ['koreacentral', 'Korea Central', 'Asia Pacific'], ['centralindia', 'Central India', 'Asia Pacific'],
    ['southindia', 'South India', 'Asia Pacific'], ['australiaeast', 'Australia East', 'Asia Pacific'],
    ['newzealandnorth', 'New Zealand North', 'Asia Pacific'], ['indonesiacentral', 'Indonesia Central', 'Asia Pacific'],
    ['malaysiawest', 'Malaysia West', 'Asia Pacific'],
    ['uaenorth', 'UAE North', 'Middle East & Africa'], ['qatarcentral', 'Qatar Central', 'Middle East & Africa'],
    ['southafricanorth', 'South Africa North', 'Middle East & Africa']
  ];
  var SAMPLES = 5, TIMEOUT_MS = 4000, CONCURRENCY = 3, TOP = 5;
  var latency = [], expanded = false;

  // https://<host>/ with a cache-busting query; the latency test times each region's endpoint, the
  // reachability probe the AVD client hosts.
  function timeOnce(host) {
    var ctrl = new AbortController(), timer = setTimeout(function () { ctrl.abort(); }, TIMEOUT_MS);
    var url = 'https://' + host + '/?avdlz=' + Date.now() + Math.random().toString(36).slice(2);
    var t0 = performance.now();
    // no-cors: the response is opaque, but only the elapsed time is needed. A rejection means DNS,
    // TLS, a block or the timeout.
    return fetch(url, { mode: 'no-cors', cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', signal: ctrl.signal })
      .then(function () { return performance.now() - t0; }).finally(function () { clearTimeout(timer); });
  }
  function measure(host) {
    // The warm-up pays for DNS, TCP and TLS; the timed requests reuse the connection.
    return timeOnce(host).then(function () {
      var times = [], chain = Promise.resolve();
      for (var i = 0; i < SAMPLES; i++) chain = chain.then(function () { return timeOnce(host).then(function (t) { times.push(t); }); });
      return chain.then(function () { times.sort(function (a, b) { return a - b; }); return times[Math.floor(times.length / 2)]; });
    });
  }
  function rating(ms) { var r = P.rateLatency(ms); return [r.label, r.cls]; }
  function runLatency() {
    var geos = Array.prototype.map.call(document.querySelectorAll('#geos input:checked'), function (c) { return c.value; });
    var todo = REGIONS.filter(function (r) { return geos.indexOf(r[2]) >= 0; });
    if (!todo.length) { $('lat-status').textContent = 'Pick at least one geography.'; return; }
    $('run').disabled = true; latency = [];
    var bar = $('progress'); bar.classList.remove('hidden'); bar.max = todo.length; bar.value = 0;
    $('lat-status').textContent = 'Measuring ' + todo.length + ' regions...';
    var next = 0, done = 0;
    function worker() {
      if (next >= todo.length) return Promise.resolve();
      var r = todo[next++];
      return measure(r[0] + '.api.cognitive.microsoft.com').then(
        function (m) { latency.push({ name: r[0], display: r[1], geo: r[2], median: m }); },
        function () { latency.push({ name: r[0], display: r[1], geo: r[2], median: null }); }
      ).then(function () { bar.value = ++done; }).then(worker);
    }
    var pool = []; for (var i = 0; i < CONCURRENCY; i++) pool.push(worker());
    Promise.all(pool).then(function () {
      latency.sort(function (a, b) { return (a.median === null) - (b.median === null) || a.median - b.median; });
      var ok = latency.filter(function (r) { return r.median !== null; });
      ranked = ok.map(function (r) { return r.name; }); save('ranked', ranked);
      expanded = false;
      bar.classList.add('hidden'); $('run').disabled = false; $('run').textContent = 'Measure again';
      if (ok.length) {
        $('lat-status').textContent = 'Closest: ' + ok[0].display + ' (' + Math.round(ok[0].median) + ' ms). Selected for the deployment; click another row to change it, then select Next.';
        setConfig({ location: ok[0].name });
        if (!step || step === 'region') { reached = Math.max(reached, stepIndex('size')); save('reachedStep', P.STEPS[reached].id); }
      }
      else $('lat-status').textContent = 'No region answered. A firewall or content blocker may be stopping the requests.';
      lastAnalysis = null;
      renderLatency(); render();
    });
  }
  function renderLatency() {
    if (!latency.length) return;
    $('results').classList.remove('hidden');
    var max = Math.max.apply(null, latency.map(function (r) { return r.median || 0; })) || 1, tbody = $('rows');
    tbody.textContent = '';
    latency.forEach(function (r, i) {
      if (!expanded && i >= TOP && r.name !== cfg.location) return;
      var tr = document.createElement('tr'); if (r.name === cfg.location) tr.className = 'sel';
      var rt = rating(r.median);
      var cells = [
        '<input type="radio" name="region" aria-label="' + r.display + '"' + (r.name === cfg.location ? ' checked' : '') + (r.median === null ? ' disabled' : '') + '>',
        String(i + 1), r.display + ' <span class="muted">' + r.name + '</span>', r.geo,
        r.median === null ? '–' : Math.round(r.median) + ' ms',
        r.median === null ? '' : '<div class="bar" style="width:' + (100 * r.median / max).toFixed(1) + '%"></div>',
        '<span class="' + rt[1] + '">' + rt[0] + '</span>'
      ];
      cells.forEach(function (html, c) {
        var td = document.createElement('td');
        if (c === 2) td.className = 'region'; if (c === 4) td.className = 'num'; if (c === 5) td.className = 'barcell';
        td.innerHTML = html; tr.appendChild(td);
      });
      if (r.median !== null) tr.addEventListener('click', function () { setConfig({ location: r.name }); lastAnalysis = null; renderLatency(); render(); });
      tbody.appendChild(tr);
    });
    var more = $('more');
    more.classList.toggle('hidden', latency.length <= TOP);
    more.textContent = expanded ? 'Show top ' + TOP + ' only' : 'Show all ' + latency.length + ' regions';
    more.setAttribute('aria-expanded', String(expanded));
  }
  $('run').addEventListener('click', runLatency);
  $('more').addEventListener('click', function () { expanded = !expanded; renderLatency(); });

  // ---------------------------------------------------------------- verify access: reachability (decision 0014)
  // Same method as the latency test; portal-core.js classifies the result. Only a summary is kept.
  var reach = null;
  function runReachability() {
    $('reach-run').disabled = true;
    $('reach-status').textContent = 'Checking ' + P.REACHABILITY_HOSTS.length + ' hosts...';
    var results = [];
    Promise.all(P.REACHABILITY_HOSTS.map(function (h) {
      return measure(h.host).then(function (m) { results.push({ host: h.host, median: m }); }, function () { results.push({ host: h.host, median: null }); });
    })).then(function () {
      reach = P.classifyReachability(results);
      save('reachability', { status: reach.status, checkedAt: new Date().toISOString() });
      $('reach-run').disabled = false; $('reach-run').textContent = 'Check again';
      $('reach-status').textContent = 'Checked just now.';
      renderReachability();
    });
  }
  function renderReachability() {
    var r = reach || P.classifyReachability([]), last = load('reachability', null);
    var label = { reachable: 'reachable', partial: 'partly reachable', blocked: 'blocked', unknown: 'not checked' };
    $('reach-summary').textContent = reach ? label[r.status] : (last && label[last.status] ? label[last.status] + ' (last check)' : 'not checked');
    $('reach-limits').textContent = r.limits;
    if (!reach) return;
    $('reach-results').classList.remove('hidden');
    var strong = $('reach-headline').querySelector('strong');
    strong.textContent = r.headline;
    strong.className = r.status === 'reachable' ? 'good' : r.status === 'partial' ? 'ok' : 'poor';
    $('reach-guidance').textContent = r.guidance;
    var tbody = $('reach-rows'); tbody.textContent = '';
    r.hosts.forEach(function (h) {
      var tr = document.createElement('tr');
      [h.host, h.purpose, h.median === null ? '–' : Math.round(h.median) + ' ms', h.reached ? 'Reached' : h.reached === false ? 'No answer' : 'Not tested'].forEach(function (t, c) {
        var td = document.createElement('td'); td.textContent = t;
        if (c === 1) td.style.whiteSpace = 'normal';
        if (c === 2) td.className = 'num';
        if (c === 3) td.className = h.reached ? 'good' : 'poor';
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
  }
  $('reach-run').addEventListener('click', runReachability);

  // ---------------------------------------------------------------- verify access: launch link (decision 0014)
  function renderLaunch() {
    var t = cfg.launch, hint = cfg.testUserUpn && $('launch-hint').checked ? cfg.testUserUpn : '';
    var url = P.launchUrl(t, { tenant: $('launch-tenant').checked, loginHint: hint });
    $('launch-link').href = url || 'https://windows.cloud.microsoft';
    $('launch-link').textContent = url ? 'Open the desktop' : 'Open the web client';
    $('launch-status').textContent = url
      ? 'Opens the Desktop' + (t.workspace ? ' in workspace ' + t.workspace : '') + ' directly in the web client, from the IDs the last post-deployment or demo run reported.'
      : 'Paste the post-deployment setup\'s output to get a direct link to this landing zone\'s desktop. Until then, this opens the web client, where you choose the desktop.';
    $('launch-tenant-label').classList.toggle('hidden', !(t && t.tenantId));
    $('launch-hint-label').classList.toggle('hidden', !cfg.testUserUpn);
    $('launch-hint-upn').textContent = cfg.testUserUpn || '';
  }
  $('launch-tenant').addEventListener('change', renderLaunch);
  $('launch-hint').addEventListener('change', renderLaunch);

  // ---------------------------------------------------------------- start
  if (/^#(region|size|cost)$/.test(location.hash) && stepIndex(location.hash.slice(1)) <= reached) step = location.hash.slice(1);
  setConfig({});
  renderTemplatesBar(); renderPools(); renderWorkspacesAndAppGroups(); renderPrivateLinkPanel(); renderCost(); renderReachability();
  render(); showStep('instant');
})();
