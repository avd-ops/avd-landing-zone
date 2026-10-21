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
  if (site.ignored.length) $('source-line').appendChild(document.createTextNode(' This copy\'s portal-config.js has an invalid ' + site.ignored.join(' and ') + ', so the commands use the default.'));
  // Report a problem files into the repo the commands run from, and the issue is public (red team PH-10).
  var repoSlug = repoUrl.replace(/^https:\/\/github\.com\//, '');
  $('issues-link').textContent = repoSlug;

  // Saved settings are checked like typed ones: an old or edited value that no longer fits is dropped.
  var cfg = Object.assign({}, P.DEFAULTS, P.validSettings(load('config', {})).settings, { repoUrl: repoUrl, ref: site.ref, sizing: load('sizing', null), power: load('power', null), hoursWorkedPerWeek: load('hoursWorked', 50), launch: P.launchTarget(load('launch', null)), record: load('record', null) });
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
    if (patch && patch.sizing && patch.sizing.hosts) { cfg.sizing = patch.sizing; save('sizing', cfg.sizing); }
    // ... and which power settings it priced.
    if (patch && patch.power && patch.power.autoShutdownTime) { cfg.power = { startVmOnConnect: patch.power.startVmOnConnect !== false, autoShutdownTime: patch.power.autoShutdownTime }; save('power', cfg.power); }
    // ... and, after the post-deployment setup or the demo, the desktop to launch (decision 0014).
    var launch = patch && P.launchTarget(patch.launch);
    if (launch) { cfg.launch = launch; save('launch', launch); }
    var keep = {}; FIELDS.forEach(function (k) { keep[k] = cfg[k]; }); save('config', keep);
    FIELDS.forEach(function (k) { var el = $(k); if (el && el.value !== cfg[k]) el.value = cfg[k] || ''; });
    $('region-summary').textContent = cfg.location + (ranked && ranked.length ? (ranked[0] === cfg.location ? ' (closest measured)' : '') : ' (not measured yet)');
    $('region-skip').textContent = 'Skip: use ' + cfg.location + ' (change it in Deployment settings)';
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
  function showSettings(open) {
    $('settings-panel').classList.toggle('hidden', !open);
    $('settings-link').setAttribute('aria-expanded', String(open));
    if (open) { $('settings-panel').scrollIntoView({ behavior: 'smooth', block: 'nearest' }); $('parameterFile').focus({ preventScroll: true }); }
    else $('settings-link').focus({ preventScroll: true });
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
  // Short labels and phases for the progress rail; the full step titles stay everywhere else.
  var RAIL = { region: ['Region', 'Plan'], size: ['Size'], cost: ['Cost'], predeploy: ['Preflight', 'Deploy'], deploy: ['Deploy'], postdeploy: ['Setup'], signin: ['Sign in', 'Use'], verify: ['Verify'] };
  function renderSteps() {
    var cur = curIndex(), ol = $('steps');
    ol.textContent = '';
    P.STEPS.forEach(function (s, i) {
      var li = document.createElement('li');
      li.className = i > reached ? 'locked' : i === cur ? 'current' : i < reached || i < cur ? 'done' : '';
      var b = document.createElement('button');
      b.type = 'button';
      b.disabled = i > reached;
      if (i > reached) b.title = 'Reached after the steps before it';
      b.setAttribute('aria-current', i === cur ? 'step' : 'false');
      b.innerHTML = '<span class="n">' + (li.className === 'done' ? '✓' : (i + 1)) + '</span>';
      var rail = RAIL[s.id] || [s.title];
      if (rail[1]) li.setAttribute('data-phase-start', rail[1]);
      b.setAttribute('aria-label', (i + 1) + '. ' + s.title);
      b.appendChild(el('span', 'lbl', rail[0]));
      b.addEventListener('click', function () { goTo(s.id); });
      li.appendChild(b); ol.appendChild(li);
    });
    // Keep the current step in view when the tracker scrolls sideways (phones).
    var li = ol.children[cur]; if (li) ol.scrollLeft = Math.max(0, li.offsetLeft - ol.offsetLeft - 16);
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
    $('next-step').innerHTML = (cur < reached ? 'Next' : 'Skip to next step') + ' &rarr;';
    $('next-step').classList.toggle('primary', cur < reached);
    $('step-pos').textContent = 'Step ' + (cur + 1) + ' of ' + P.STEPS.length + ': ' + P.STEPS[cur].title;
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
    if (page !== 'instant' && track.getBoundingClientRect().top < (bar ? bar.getBoundingClientRect().bottom : 0)) $('steps').scrollIntoView({ behavior: 'smooth', block: 'start' });
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
  function syncRunIn() {
    var bash = document.querySelector('input[name="runin-shell"][value="bash"]');
    bash.disabled = runIn.where === 'windows';
    bash.parentNode.title = bash.disabled ? 'On Windows the commands run in PowerShell 7' : '';
    document.querySelectorAll('input[name="runin-where"], input[name="runin-shell"]').forEach(function (i) { i.checked = i.value === runIn.where || i.value === runIn.shell; });
    $('runin-note').textContent = [runIn.where === 'windows' ? 'Windows runs the commands in PowerShell 7.' : '',
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
      var hint = el('p', 'muted resume-hint', 'If Cloud Shell resets, the deployment keeps running. Use ');
      var link = el('a', '', 'Where did I leave off?'); link.href = '#resume';
      link.addEventListener('click', function (e) { e.preventDefault(); showResume(true); });
      hint.appendChild(link); hint.appendChild(document.createTextNode(' at the top to pick up from there.'));
      box.appendChild(hint);
    }
  }

  // ---------------------------------------------------------------- where did I leave off (run recorder spec section 4)
  function renderResume() {
    if (!$('resume-panel').classList.contains('hidden')) renderActions([{ title: 'Read where the run stands', why: '', command: P.commands.runStatus(config()) }], $('resume-actions'));
  }
  function showResume(open) {
    $('resume-panel').classList.toggle('hidden', !open);
    $('resume-link').setAttribute('aria-expanded', String(open));
    if (open) {
      renderResume();
      $('resume-panel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
    else $('resume-link').focus({ preventScroll: true });
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
    $('record-note').textContent = 'Every command below sets this run ID, so it keeps recording after a Cloud Shell reset. Open the run before the pre-deployment preflight; the run folder is kept ' +
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
    if (cfg.record) $('record-steps').open = true;
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
      $('next-title').textContent = 'Run in ' + P.PLACES[runIn.where];
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
    cfg = Object.assign({}, P.DEFAULTS, { repoUrl: repoUrl, ref: site.ref, sizing: null, power: null, hoursWorkedPerWeek: 50, launch: null, record: wasRecording ? { mode: wasRecording.mode } : null });
    if (wasRecording) save('record', cfg.record); step = null; reached = 0; ranked = null; lastAnalysis = null; latency = [];
    pools = [Object.assign({}, P.HOST_POOL_DEFAULTS)]; estimate = null; renderPools(); renderCost();
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

  // ---------------------------------------------------------------- sizing and cost (decision 0010)
  // Sizings saved before the host count could be chosen start again from the minimum viable kit.
  var pools = (load('hostPools', null) || []).filter(function (p) { return p && p.hostCount !== undefined; });
  if (!pools.length) pools = [Object.assign({}, P.HOST_POOL_DEFAULTS)];
  var estimate = load('estimate', null);
  var POOL_FIELDS = [
    ['name', 'Name', 'text'], ['users', 'People who will use it', 'number'], ['concurrencyPercent', 'Signed in at the busiest time (%)', 'number'],
    ['workload', 'How they work', 'workload'], ['vmSize', 'VM size', 'vmsize'], ['hostCount', 'Session hosts', 'hostcount'], ['spareHost', 'Spare host (Automatic only)', 'spare'],
    ['profileGiBPerUser', 'Profile size per person (GiB)', 'number']
  ];
  function money(n, cur) { return (n === null || n === undefined) ? '–' : Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' ' + (cur || ''); }
  function poolResult(i) { return P.computePool(pools[i], cfg.environment); }
  function renderPools() {
    var box = $('pools'); box.textContent = '';
    pools.forEach(function (pool, i) {
      var card = el('div', 'pool'); card.appendChild(el('h3', '', 'Host pool ' + (i + 1) + ' (pooled)'));
      var row = el('div', 'row');
      POOL_FIELDS.forEach(function (f) {
        var lab = el('label', 'field'); lab.appendChild(el('span', '', f[1]));
        var input;
        if (f[2] === 'workload' || f[2] === 'vmsize' || f[2] === 'spare' || f[2] === 'hostcount') {
          input = document.createElement('select');
          var opts = f[2] === 'workload' ? Object.keys(P.WORKLOADS).map(function (k) { return [k, P.WORKLOADS[k].label + ' (' + P.WORKLOADS[k].usersPerVcpu + '/vCPU)']; })
            : f[2] === 'vmsize' ? [['', 'Suggested: memory-optimized E-series']].concat(Object.keys(P.VM_SIZES).map(function (k) { return [k, k.replace('Standard_', '') + ' (' + P.VM_SIZES[k].vcpu + ' vCPU, ' + P.VM_SIZES[k].ramGiB + ' GiB' + (P.VM_SIZES[k].recommended ? ', recommended' : '') + ')']; }))
              : f[2] === 'hostcount' ? [['auto', 'Automatic: enough for the busiest time']].concat(Array.from({ length: P.MAX_HOSTS }, function (_, n) { return [String(n + 1), (n + 1) + (n ? ' hosts' : ' host (minimum)')]; }))
                : [['', 'Automatic (one in prod)'], ['true', 'Yes'], ['false', 'No']];
          opts.forEach(function (o) { var op = document.createElement('option'); op.value = o[0]; op.textContent = o[1]; input.appendChild(op); });
          input.value = pool[f[0]] === null || pool[f[0]] === undefined ? '' : String(pool[f[0]]);
          if (f[2] === 'spare') input.disabled = pool.hostCount !== 'auto';
        }
        else { input = document.createElement('input'); input.type = f[2]; if (f[2] === 'number') input.min = '1'; input.value = pool[f[0]]; input.autocomplete = 'off'; }
        input.addEventListener('input', function () {
          var v = input.value;
          pools[i][f[0]] = f[2] === 'number' ? Number(v) : f[2] === 'spare' ? (v === '' ? null : v === 'true') : f[2] === 'hostcount' ? (v === 'auto' ? 'auto' : Number(v)) : v;
          save('hostPools', pools);
          if (f[2] === 'hostcount') renderPools(); else renderSizeResult();
        });
        lab.appendChild(input); row.appendChild(lab);
      });
      card.appendChild(row); box.appendChild(card);
    });
    $('add-pool').disabled = pools.length >= P.MAX_HOST_POOLS;
    renderSizeResult();
  }
  function renderSizeResult() {
    var r = poolResult(0), tb = $('size-result'); tb.textContent = '';
    [['Concurrent sessions', r.concurrentUsers + ' of ' + r.users + ' people'],
      ['Session hosts', (r.hostCountAuto ? '' : 'Chosen: ') + r.hosts + ' × ' + r.vmSize.replace('Standard_', '') + ' (' + r.vcpuPerHost + ' vCPU, ' + r.ramGiBPerHost + ' GiB each; ' + r.memoryPerSessionGiB + ' GiB per session)'],
      ['OS disk', r.osDisk + ' on every host'],
      ['Sessions per host (max session limit)', String(r.sessionsPerHost)],
      ['Capacity', r.capacity + ' sessions'],
      ['vCPU quota needed', r.vcpus + ' vCPUs'],
      ['Profile share', r.profileQuotaGiB + ' GiB provisioned (storage SKU from ' + cfg.parameterFile.replace(/^parameters\//, '') + ')']
    ].forEach(function (kv) { var tr = el('tr'); tr.appendChild(el('td', '', kv[0])); tr.appendChild(el('td', '', kv[1])); tb.appendChild(tr); });
    var ul = $('size-notes'); ul.textContent = ''; r.notes.forEach(function (n) { ul.appendChild(el('li', '', n)); });
    var s = cfg.sizing, mine = P.toSizing(r);
    if (s && (s.hosts !== mine.hosts || s.vmSize !== mine.vmSize || s.maxSessions !== mine.maxSessions || s.profileQuotaGiB !== mine.profileQuotaGiB))
      ul.appendChild(el('li', '', 'The commands use ' + s.hosts + ' × ' + s.vmSize.replace('Standard_', '') + ' with ' + s.maxSessions + ' sessions each (the last sizing applied or checked by a pasted preflight). Select Use this sizing to switch to the one above.'));
    renderSizeSummary();
  }
  function renderSizeSummary() {
    var s = cfg.sizing;
    $('size-summary').textContent = s ? s.hosts + ' × ' + s.vmSize.replace('Standard_', '') + ', ' + (s.hosts * s.maxSessions) + ' sessions' : 'not set (the parameter file\'s values)';
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
      var r = poolResult(0), s = cfg.sizing || P.toSizing(r), q = Math.round(s.hosts * hh.hoursPerWeek * 52 / 12 * 10) / 10;
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

  function applySizing(s) {
    cfg.sizing = s; save('sizing', s);
    renderSizeResult(); renderCost(); lastAnalysis = null; render();
  }
  $('size-apply').addEventListener('click', function () {
    var r = poolResult(0);
    applySizing(P.toSizing(r));
    $('size-status').textContent = 'Applied: the commands now check and price ' + r.hosts + ' × ' + r.vmSize.replace('Standard_', '') + '.';
    if (curIndex() <= stepIndex('size')) goTo('cost');
  });
  $('size-clear').addEventListener('click', function () {
    applySizing(null); $('size-status').textContent = 'The commands use the parameter file\'s sizing.';
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
  renderPools(); renderCost(); renderReachability();
  render(); showStep('instant');
})();
