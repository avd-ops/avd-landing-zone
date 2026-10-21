/*
 * Deployment portal engine: reads pasted Cloud Shell output and decides the next step.
 * Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
 *
 * Runs in the browser (window.PortalCore) and in Node (module.exports) so it can be tested
 * against real outputs (build/tests/portal). Nothing here touches the network.
 *
 * Input: whatever the operator pasted. The scripts end every run with a state line:
 *   <<<AVDLZ-STATE {json} AVDLZ-STATE>>>
 * (schema in site/portal/README.md). Output from before state lines existed, and errors that
 * stop a script before it can print one, are recognized from their text.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.PortalCore = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var STEPS = [
    { id: 'region', title: 'Choose a region' },
    { id: 'size', title: 'Size the host pool' },
    { id: 'cost', title: 'Cost' },
    { id: 'predeploy', title: 'Pre-deployment preflight' },
    { id: 'deploy', title: 'Deploy the landing zone' },
    { id: 'postdeploy', title: 'Post-deployment setup' },
    { id: 'signin', title: 'Sign in' },
    { id: 'verify', title: 'Verify access' }
  ];

  var DEFAULTS = {
    repoUrl: 'https://github.com/avd-ops/avd-landing-zone',
    parameterFile: 'parameters/dev.bicepparam',
    location: 'northcentralus',
    usersGroup: 'AVD Users',
    adminsGroup: 'AVD Admins',
    namePrefix: 'avdlz',
    environment: 'dev',
    testUserUpn: '',
    // The avd-opsbot app's client ID (Initialize-AvdGraphApp.ps1, decision 0016); empty: Microsoft's default app.
    graphClientId: ''
  };

  // ---------------------------------------------------------------- helpers
  function psQuote(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }
  function merge(a, b) {
    var o = {}, k;
    for (k in a) if (Object.prototype.hasOwnProperty.call(a, k)) o[k] = a[k];
    for (k in b || {}) if (Object.prototype.hasOwnProperty.call(b, k) && b[k] !== null && b[k] !== undefined && b[k] !== '') o[k] = b[k];
    return o;
  }
  function envFromFile(file) { var m = /parameters\/([a-z]+)\.bicepparam/.exec(file || ''); return m ? m[1] : null; }
  // What a published copy's portal-config.js may set, since both go into every command (decision 0017):
  // a GitHub repo URL, and a tag or commit to check out (no quotes, spaces, options or shell characters).
  function isRepoUrl(u) { return typeof u === 'string' && /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/?$/.test(u) && !/\.\./.test(u); }
  function isRef(r) { return typeof r === 'string' && /^[A-Za-z0-9][A-Za-z0-9._\/-]{0,99}$/.test(r) && !/\.\.|\/\/|\/$|\.lock$/.test(r); }
  function isCommit(c) { return typeof c === 'string' && /^[0-9a-f]{7,40}$/i.test(c); }
  // site: window.AVDLZ_PORTAL_CONFIG. Returns { repoUrl, ref, commit, ignored[] }: what is valid, and the keys that were not.
  // commit: the commit this portal was built from (the Pages workflow or Publish-AvdPortal.ps1 writes it).
  function siteConfig(site) {
    site = site || {};
    var out = { repoUrl: null, ref: null, commit: null, ignored: [] };
    if (site.repoUrl !== undefined) { if (isRepoUrl(site.repoUrl)) out.repoUrl = site.repoUrl.replace(/\/+$/, ''); else out.ignored.push('repoUrl'); }
    if (site.ref !== undefined) { if (isRef(site.ref)) out.ref = site.ref; else out.ignored.push('ref'); }
    if (site.commit !== undefined) { if (isCommit(site.commit)) out.commit = site.commit.toLowerCase(); else out.ignored.push('commit'); }
    return out;
  }

  // Every setting that goes into a command, and what it may look like (red team PH-4). The settings panel,
  // the saved settings and a pasted state line's context all pass through here; anything else is dropped
  // and reported, so neither a crafted paste nor an old saved value can put more than a value into a command.
  // The patterns match the Bicep parameters (namePrefix 2-8 lowercase letters or digits, environmentName
  // dev/test/prod) and Azure's region names; group names and the UPN are also single-quoted in the command.
  var SETTINGS = {
    parameterFile: /^parameters\/[a-z][a-z0-9-]{0,39}\.bicepparam$/,
    location: /^[a-z][a-z0-9]{2,39}$/,
    usersGroup: /^[^\x00-\x1f\x7f]{1,256}$/,
    adminsGroup: /^[^\x00-\x1f\x7f]{1,256}$/,
    namePrefix: /^[a-z0-9]{2,8}$/,
    environment: /^(dev|test|prod)$/,
    testUserUpn: /^[^\s@'"`$;|&<>]{1,64}@[A-Za-z0-9][A-Za-z0-9.-]{0,253}$/,
    graphClientId: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  };
  var SETTING_NAMES = Object.keys(SETTINGS);
  // patch: candidate settings (other keys pass through untouched). Returns { settings, rejected[] }: the
  // settings whose values fit, trimmed, and the names of those that did not (an empty value is neither).
  function validSettings(patch) {
    var out = { settings: {}, rejected: [] }, k, v;
    for (k in patch || {}) {
      if (!Object.prototype.hasOwnProperty.call(patch, k)) continue;
      v = patch[k];
      if (SETTINGS[k]) {
        if (v === null || v === undefined || v === '') continue;
        v = String(v).trim();
        if (SETTINGS[k].test(v)) out.settings[k] = v; else out.rejected.push(k);
      }
      else out.settings[k] = v;
    }
    return out;
  }
  // A pasted state line is untrusted input (decision 0007), and its context and check data go into commands
  // that run as subscription Owner. Only these fields of a context reach the config: the settings above, and
  // sizing, power and launch, each checked field by field. Anything else a context carries (a repo URL, a ref,
  // a run to record) is dropped, so a crafted paste can't point the next block at other code.
  // The ranges are the scripts' own (Test-AvdLandingZoneReadiness.ps1 ValidateRange and ValidatePattern). A field
  // left out or null (deploy.sh writes null for a flag it wasn't given) is left out; a field that is there and
  // doesn't fit rejects the whole object.
  var VM_SIZE = /^Standard_[A-Za-z0-9_]{2,40}$/;
  var SHUTDOWN = /^(([01][0-9]|2[0-3]):[0-5][0-9]|none)$/;
  function wholeIn(v, min, max) { var n = Number(v); return typeof v !== 'boolean' && v !== '' && v !== null && isFinite(n) && Math.floor(n) === n && n >= min && n <= max ? n : null; }
  // Returns { value, bad }: the fields that are there and fit (null when none are), and whether any did not.
  function checkFields(obj, rules) {
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return { value: null, bad: true };
    var o = {}, k, v;
    for (k in rules) {
      v = obj[k];
      if (v === undefined || v === null) continue;
      v = rules[k](v);
      if (v === null) return { value: null, bad: true };
      o[k] = v;
    }
    return { value: Object.keys(o).length ? o : null, bad: false };
  }
  var SIZING_RULES = {
    hosts: function (v) { return wholeIn(v, 1, 200); },
    vmSize: function (v) { return typeof v === 'string' && VM_SIZE.test(v) ? v : null; },
    maxSessions: function (v) { return wholeIn(v, 1, 1000); },
    profileQuotaGiB: function (v) { return wholeIn(v, 1, 102400); },
    activeHoursPerWeek: function (v) { var n = Number(v); return typeof v !== 'boolean' && v !== '' && isFinite(n) && n >= 1 && n <= 168 ? n : null; }
  };
  var POWER_RULES = {
    startVmOnConnect: function (v) { return v === true || v === 'true' ? true : v === false || v === 'false' ? false : null; },
    autoShutdownTime: function (v) { return typeof v === 'string' && SHUTDOWN.test(v) ? v : null; }
  };
  function validSizing(s) { return checkFields(s, SIZING_RULES).value; }
  function validPower(p) { return checkFields(p, POWER_RULES).value; }
  // An estimate is shown and repriced, never put into a command: it only has to have the shape the page reads.
  function validEstimate(e) {
    if (!e || typeof e !== 'object' || Array.isArray(e)) return null;
    var lists = ['lines', 'unpriced', 'excluded'];
    for (var i = 0; i < lists.length; i++) if (e[lists[i]] !== undefined && e[lists[i]] !== null && !Array.isArray(e[lists[i]])) return null;
    return (e.lines || []).every(function (l) { return l && typeof l === 'object'; }) ? e : null;
  }
  function present(o, k) { return !!o && o[k] !== undefined && o[k] !== null; }
  function contextSettings(context) {
    var patch = {};
    SETTING_NAMES.forEach(function (k) { if (context && Object.prototype.hasOwnProperty.call(context, k)) patch[k] = context[k]; });
    var checked = validSettings(patch);
    [['sizing', SIZING_RULES], ['power', POWER_RULES]].forEach(function (r) {
      if (!present(context, r[0])) return;
      var c = checkFields(context[r[0]], r[1]);
      if (c.bad) checked.rejected.push(r[0]); else if (c.value) checked.settings[r[0]] = c.value;
    });
    var launch = context && launchTarget(context.launch);
    if (launch) checked.settings.launch = launch;
    return checked;
  }
  // Values from a state line's other fields that go into a command, checked where they are read.
  var PASTED = {
    location: /^[a-z][a-z0-9]{2,39}$/,
    deploymentName: /^[A-Za-z0-9._()-]{1,64}$/,
    // Get-AvdRunId's run IDs, the same pattern as RUN_ID.
    runId: /^run-\d{8}-\d{4}-[a-z0-9]{4}$/,
    quotaName: /^[A-Za-z0-9_.-]{1,80}$/,
    // Single-quoted in the command; any UPN Entra ID allows, apostrophes included, with no control character.
    user: /^[^\x00-\x20\x7f@]{1,113}@[A-Za-z0-9][A-Za-z0-9.-]{0,253}$/
  };
  function pasted(kind, v) { return typeof v === 'string' && PASTED[kind].test(v) ? v : null; }
  function pastedList(kind, list) { return (Array.isArray(list) ? list : []).filter(function (v) { return pasted(kind, v) !== null; }); }
  // Quota items from a preflight: a region, a quota name and whole numbers, or the item is left out.
  function pastedQuota(d) {
    if (!d || !pasted('location', d.location) || !pasted('quotaName', d.quotaName)) return null;
    var o = { location: d.location, quotaName: d.quotaName }, ok = true;
    ['limit', 'used', 'needed'].forEach(function (k) { var n = wholeIn(d[k] === undefined || d[k] === null ? 0 : d[k], 0, 1000000); if (n === null) ok = false; o[k] = n; });
    return ok ? o : null;
  }
  // Another landing zone the post-deployment preflight found: only its name prefix and environment.
  function pastedLandingZone(f) {
    return f && SETTINGS.namePrefix.test(String(f.namePrefix || '')) && SETTINGS.environment.test(String(f.environment || '')) ? { namePrefix: f.namePrefix, environment: f.environment } : null;
  }
  function repoDir(cfg) { return (cfg.repoUrl || DEFAULTS.repoUrl).replace(/\/+$/, '').split('/').pop(); }

  // ---------------------------------------------------------------- sizing (decision 0010)
  // Users per vCPU for Windows multi-session hosts, from Microsoft's session host sizing guidance.
  // Suggested sizes are memory-optimized E-series: with many users on one host, memory runs out
  // before CPU (8 GiB per vCPU, against 4 on D-series). Hosts use Premium SSD OS disks.
  var WORKLOADS = {
    light: { label: 'Light: a few line-of-business apps, data entry', usersPerVcpu: 6, suggestedSize: 'Standard_E4as_v5' },
    medium: { label: 'Medium: Office, web, email', usersPerVcpu: 4, suggestedSize: 'Standard_E8as_v5' },
    heavy: { label: 'Heavy: many apps at once, large files', usersPerVcpu: 2, suggestedSize: 'Standard_E8as_v5' },
    power: { label: 'Power: developers, analysts, light graphics', usersPerVcpu: 1, suggestedSize: 'Standard_E16as_v5' }
  };
  // Sizes suited to multi-session hosts (vCPUs, memory in GiB), memory-optimized first.
  var VM_SIZES = {
    Standard_E4as_v5: { vcpu: 4, ramGiB: 32, recommended: true }, Standard_E8as_v5: { vcpu: 8, ramGiB: 64, recommended: true }, Standard_E16as_v5: { vcpu: 16, ramGiB: 128, recommended: true },
    Standard_E4s_v5: { vcpu: 4, ramGiB: 32, recommended: true }, Standard_E8s_v5: { vcpu: 8, ramGiB: 64, recommended: true }, Standard_E16s_v5: { vcpu: 16, ramGiB: 128, recommended: true },
    Standard_D4as_v5: { vcpu: 4, ramGiB: 16 }, Standard_D8as_v5: { vcpu: 8, ramGiB: 32 }, Standard_D16as_v5: { vcpu: 16, ramGiB: 64 },
    Standard_D4s_v5: { vcpu: 4, ramGiB: 16 }, Standard_D8s_v5: { vcpu: 8, ramGiB: 32 }, Standard_D16s_v5: { vcpu: 16, ramGiB: 64 }
  };
  var OS_DISK = 'Premium SSD (P10, 128 GiB)';
  // hostCount: a number of hosts, or 'auto' to size from people and workload.
  // spareHost (automatic sizing only): true / false, or null for automatic (a spare in prod).
  // Defaults are the minimum viable kit, matching parameters/dev.bicepparam: one E4as_v5 host and
  // a 100 GiB profile share. One entry per host pool. The landing zone deploys one pooled host pool
  // today; the list shape leaves room for more (each would get its own sizing and, later, its own deployment).
  var HOST_POOL_DEFAULTS = { name: 'Pooled desktops', type: 'pooled', users: 10, concurrencyPercent: 80, workload: 'medium', vmSize: 'Standard_E4as_v5', hostCount: 1, spareHost: null, profileGiBPerUser: 5, activeHoursPerWeek: 50 };
  var MAX_HOSTS = 50;
  var MAX_HOST_POOLS = 1;

  function num(v, d) { var n = Number(v); return isFinite(n) && n > 0 ? n : d; }

  // Sizing for one host pool: hosts, sessions per host, vCPUs to request quota for, profile share size.
  function computePool(spec, environment) {
    var p = merge(HOST_POOL_DEFAULTS, spec || {}), notes = [];
    // '' is a choice here ('Suggested' size, 'Automatic' host count), not a missing value.
    ['vmSize', 'hostCount'].forEach(function (k) { if (spec && spec[k] === '') p[k] = ''; });
    var w = WORKLOADS[p.workload] || WORKLOADS.medium;
    var vmSize = p.vmSize || w.suggestedSize, vm = VM_SIZES[vmSize];
    if (!vm) { vmSize = w.suggestedSize; vm = VM_SIZES[vmSize]; notes.push('Unknown size; using ' + vmSize + '.'); }
    var users = Math.round(num(p.users, 1));
    var concurrent = Math.max(1, Math.ceil(users * Math.min(num(p.concurrencyPercent, 100), 100) / 100));
    var sessionsPerHost = Math.max(1, vm.vcpu * w.usersPerVcpu);
    var auto = p.hostCount === 'auto' || p.hostCount === '' || p.hostCount === null || p.hostCount === undefined;
    var hosts;
    if (auto) {
      hosts = Math.ceil(concurrent / sessionsPerHost);
      var spare = p.spareHost === true || p.spareHost === 'true' || (environment === 'prod' && p.spareHost !== false && p.spareHost !== 'false');
      if (spare) { hosts += 1; notes.push('One spare host, so a host can be drained or fail without turning users away.'); }
      if (environment === 'prod' && hosts < 2) { hosts = 2; notes.push('At least two hosts in prod (the Well-Architected review flags one).'); }
    }
    else {
      // The number chosen is kept; the notes say what it means.
      hosts = Math.min(MAX_HOSTS, Math.max(1, Math.round(num(p.hostCount, 1))));
      if (hosts * sessionsPerHost < concurrent)
        notes.push(hosts + ' host' + (hosts > 1 ? 's' : '') + ' carry ' + hosts * sessionsPerHost + ' sessions, but ' + concurrent + ' people are expected at the busiest time. Add hosts, choose a larger size, or choose Automatic.');
      if (hosts === 1) notes.push('One host: no redundancy. Users can\'t sign in while it is drained, updated or down.' + (environment === 'prod' ? ' The Well-Architected review flags one host in prod.' : ''));
    }
    // Premium file shares are provisioned (minimum 100 GiB); 20% headroom over the expected profile sizes.
    var profileQuotaGiB = Math.max(100, Math.ceil(users * num(p.profileGiBPerUser, 10) * 1.2 / 100) * 100);
    // Too little memory per session: below 1 GiB on any size, below 1.5 GiB on a D-series (the
    // preflight applies the same rule).
    var ramPerSession = vm.ramGiB / sessionsPerHost, isE = /^Standard_E/.test(vmSize);
    if (ramPerSession < 1 || (ramPerSession < 1.5 && !isE))
      notes.push('Only ' + ramPerSession.toFixed(1) + ' GiB of memory per session. ' + (isE ? 'Use a larger E-series size.' : 'The memory-optimized ' + vmSize.replace(/^Standard_D/, 'Standard_E') + ' has twice the memory for the same vCPUs.'));
    return {
      name: p.name, workload: p.workload, users: users, concurrentUsers: concurrent, vmSize: vmSize, vcpuPerHost: vm.vcpu, ramGiBPerHost: vm.ramGiB,
      memoryPerSessionGiB: Math.round(ramPerSession * 10) / 10, osDisk: OS_DISK,
      sessionsPerHost: sessionsPerHost, hosts: hosts, hostCountAuto: auto, vcpus: hosts * vm.vcpu, capacity: hosts * sessionsPerHost,
      profileQuotaGiB: profileQuotaGiB, activeHoursPerWeek: Math.min(168, Math.round(num(p.activeHoursPerWeek, 50))), notes: notes
    };
  }

  // ---------------------------------------------------------------- power and hours (the Cost step)
  // What the parameter files deploy when the portal doesn't say otherwise: Start VM on Connect on, and a
  // daily stop at 20:00 in dev and test (none in prod, which relies on the scaling plan).
  function powerDefaults(environment) { return { startVmOnConnect: true, autoShutdownTime: environment === 'prod' ? 'none' : '20:00' }; }
  function effectivePower(cfg) {
    var d = powerDefaults(envFromFile(cfg.parameterFile) || cfg.environment), p = cfg.power || {};
    return { startVmOnConnect: p.startVmOnConnect === undefined || p.startVmOnConnect === null ? d.startVmOnConnect : p.startVmOnConnect === true || p.startVmOnConnect === 'true',
      autoShutdownTime: p.autoShutdownTime || d.autoShutdownTime, fromFile: !cfg.power };
  }
  // The scaling plan's weekday ramp-up (bicep/modules/controlPlane.bicep) starts hosts at 07:00.
  var RAMP_UP_HOUR = 7;
  // Hours each host runs per week, from the hours people work and the two power settings.
  // Upper bounds where the schedule, not use, decides: the estimate should not flatter the settings.
  function hostHours(workedPerWeek, power) {
    var worked = Math.min(168, Math.max(1, Math.round(num(workedPerWeek, 50))));
    var stop = /^\d{2}:\d{2}$/.test(power.autoShutdownTime || '') ? power.autoShutdownTime : null;
    if (!stop)
      return { hoursPerWeek: 168, basis: 'No scheduled stop: nothing turns the hosts off every day. The scaling plan only stops hosts nobody is signed in to, and disconnected sessions count, so this assumes they run around the clock.' };
    if (power.startVmOnConnect)
      return { hoursPerWeek: worked, basis: 'Start VM on Connect starts a host when the first person connects, and the scheduled stop turns them off at ' + stop + ', so hosts run about as long as people work.' };
    var h = Number(stop.slice(0, 2)) + Number(stop.slice(3)) / 60, window = Math.round(5 * Math.max(0, h - RAMP_UP_HOUR));
    return { hoursPerWeek: Math.max(worked, window), basis: 'Without Start VM on Connect, hosts must already be running when people arrive: the scaling plan starts them at 07:00 on weekdays and the scheduled stop turns them off at ' + stop + ' (' + window + ' h a week), whether or not anyone uses them.' };
  }
  function powerArgs(cfg, ps) {
    if (!cfg.power) return '';
    var p = effectivePower(cfg);
    return ps ? ' -AutoShutdownTime ' + p.autoShutdownTime + ' -StartVmOnConnect ' + p.startVmOnConnect : ' --auto-shutdown ' + p.autoShutdownTime + ' --start-vm-on-connect ' + p.startVmOnConnect;
  }
  // Hours the preflight prices: from the hours people work (kept on the Cost step, apart from the priced
  // hours a pasted preflight reports, so turning a setting back on lowers them again) and the power settings.
  function pricedHours(cfg) {
    var s = sized(cfg), worked = cfg.hoursWorkedPerWeek || (s && s.activeHoursPerWeek) || 50;
    return hostHours(worked, effectivePower(cfg)).hoursPerWeek;
  }

  // Reprices a preflight estimate for the current sizing and hours: compute scales with hosts and hours,
  // OS disks with hosts, the profile share with its size; the other lines don't change. Unit prices come
  // from the preflight (Azure list prices from Cloud Shell), so a different size or region can't be repriced.
  function repriceEstimate(estimate, sizing, hoursPerWeek, location) {
    if (!estimate || !estimate.lines) return null;
    var comp = null;
    estimate.lines.forEach(function (l) { if (l.key === 'compute') comp = l; });
    var m = comp && /\((\d+) x (Standard_[A-Za-z0-9_]+)\)/.exec(comp.item || '');
    var pricedSize = m ? m[2] : null, pricedHosts = m ? Number(m[1]) : null;
    var stale = [];
    if (sizing && pricedSize && sizing.vmSize !== pricedSize) stale.push('priced for ' + pricedSize.replace('Standard_', '') + ', not ' + sizing.vmSize.replace('Standard_', ''));
    if (location && estimate.location && estimate.location !== location) stale.push('priced in ' + estimate.location + ', not ' + location);
    var hosts = sizing && !stale.length ? sizing.hosts : pricedHosts;
    var round2 = function (n) { return Math.round(n * 100) / 100; };
    var lines = estimate.lines.map(function (l) {
      var o = merge(l, {}), q = l.quantity;
      if (!stale.length && hosts && l.key === 'compute') { q = Math.round(hosts * hoursPerWeek * 52 / 12 * 10) / 10; o.item = 'Session hosts (' + hosts + ' x ' + pricedSize + ')'; o.note = hoursPerWeek + ' h/week each'; }
      if (!stale.length && hosts && l.key === 'osdisk') { q = hosts; o.item = (l.item || '').replace(/\(\d+ x/, '(' + hosts + ' x'); }
      if (!stale.length && sizing && sizing.profileQuotaGiB && l.key === 'profiles') { q = sizing.profileQuotaGiB; o.item = (l.item || '').replace(/\d+ GiB provisioned/, sizing.profileQuotaGiB + ' GiB provisioned'); }
      o.quantity = q; o.monthly = round2(q * l.unitPrice);
      return o;
    });
    var total = round2(lines.reduce(function (t, l) { return t + l.monthly; }, 0));
    var alwaysOn = comp && hosts ? round2(total - lines.filter(function (l) { return l.key === 'compute'; })[0].monthly + hosts * 168 * 52 / 12 * comp.unitPrice) : null;
    return { currency: estimate.currency, location: estimate.location, lines: lines, total: total, alwaysOnTotal: alwaysOn, hoursPerWeek: stale.length ? null : hoursPerWeek,
      unpriced: estimate.unpriced || [], excluded: estimate.excluded || [], stale: stale };
  }

  // What the commands pass: the sizing the portal computed, or the one a pasted preflight validated.
  function toSizing(r) { return { hosts: r.hosts, vmSize: r.vmSize, maxSessions: r.sessionsPerHost, profileQuotaGiB: r.profileQuotaGiB, activeHoursPerWeek: r.activeHoursPerWeek }; }
  function sized(cfg) { var s = cfg.sizing; return s && s.hosts && s.vmSize ? s : null; }

  // ---------------------------------------------------------------- commands
  // Every command is a self-contained Cloud Shell (PowerShell) block: sessions are ephemeral,
  // so each starts by cloning or updating the repo and moving into it (build/lessons/0015).
  function preamble(cfg) {
    // The page checks the repo URL it puts in the config; a URL that isn't a plain GitHub repo falls back to this repo.
    var repo = isRepoUrl(cfg.repoUrl) ? cfg.repoUrl : DEFAULTS.repoUrl;
    var dir = '~/' + repoDir({ repoUrl: repo }), url = repo.replace(/\/+$/, '') + '.git';
    var lines = ['if (-not (Test-Path ' + dir + ')) { git clone ' + url + ' ' + dir + ' }'];
    // A published copy pins its repo and ref: an existing clone is pointed at that repo and checked out at that ref.
    if (isRef(cfg.ref)) lines.push('Set-Location ' + dir + '; git remote set-url origin ' + url + '; git fetch -q --tags origin; git checkout -q ' + psQuote(cfg.ref));
    else lines.push('Set-Location ' + dir + '; git checkout -q master; git pull -q --ff-only');
    return lines.join('\n');
  }
  // Record this run (run recorder spec sections 5 and 6): the run ID, and where the run folder goes
  // ('azure': the run store and Cloud Shell; 'on': Cloud Shell only). Every block sets the journal's
  // two variables again, so a command still records after a Cloud Shell reset.
  var RUN_ID = /^run-\d{8}-\d{4}-[a-z0-9]{4}$/;
  function recording(cfg) { var r = cfg && cfg.record; return r && RUN_ID.test(r.runId || '') ? { runId: r.runId, mode: r.mode === 'on' ? 'on' : 'azure' } : null; }
  function newRunId(now, suffix) {
    var d = now || new Date(), p = function (n) { return (n < 10 ? '0' : '') + n; };
    var s = String(suffix || Math.random().toString(36).slice(2, 6)).toLowerCase().replace(/[^a-z0-9]/g, '');
    s = (s + '0000').slice(0, 4);
    return 'run-' + d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate()) + '-' + p(d.getUTCHours()) + p(d.getUTCMinutes()) + '-' + s;
  }
  // Turned off (cfg.record kept without a run ID): blocks clear the two variables, so a shell that ran a
  // recorded block stops writing to that run's journal.
  function recordEnv(cfg) {
    var r = recording(cfg);
    if (r) return ["$env:AVDLZ_RECORD = '" + r.mode + "'; $env:AVDLZ_RUN_ID = '" + r.runId + "'"];
    return cfg && cfg.record ? ['Remove-Item Env:AVDLZ_RECORD, Env:AVDLZ_RUN_ID -ErrorAction SilentlyContinue'] : [];
  }
  function block(cfg, lines) { return [preamble(cfg)].concat(recordEnv(cfg), lines).join('\n'); }
  // Steps that use Microsoft Graph sign in first, once for the session; the scripts reuse the sign-in (decision 0016).
  function signIn(cfg) {
    var id = String(cfg.graphClientId || '').trim();
    return './scripts/ops/Connect-AvdLandingZone.ps1' + (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id) ? ' -ClientId ' + psQuote(id) : '');
  }

  // Sizing flags, only once a sizing is set: the preflight validates and prices it, deploy.sh deploys it,
  // and the post-deployment preflight checks quota for it.
  var sizeArgs = {
    // Hours are priced from the working hours and the power settings (the Cost step).
    predeploy: function (cfg) {
      var s = sized(cfg);
      return (s ? ' -SessionHostCount ' + s.hosts + ' -SessionHostVmSize ' + s.vmSize + ' -MaxSessionLimit ' + s.maxSessions + ' -ProfileShareQuotaGiB ' + s.profileQuotaGiB : '') +
        powerArgs(cfg, true) + (s || cfg.power ? ' -ActiveHoursPerWeek ' + pricedHours(cfg) : '');
    },
    deploy: function (cfg) { var s = sized(cfg); return (s ? ' --hosts ' + s.hosts + ' --vm-size ' + s.vmSize + ' --max-sessions ' + s.maxSessions + ' --profile-quota ' + s.profileQuotaGiB : '') + powerArgs(cfg, false); },
    postdeploy: function (cfg) { var s = sized(cfg); return s ? ' -SessionHostVmSize ' + s.vmSize + ' -SessionHostCount ' + s.hosts : ''; }
  };

  var cmd = {
    predeploy: function (cfg, fix) {
      return block(cfg, [signIn(cfg), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile ' + cfg.parameterFile +
        ' -Location ' + cfg.location + ' -UsersGroup ' + psQuote(cfg.usersGroup) + ' -AdminsGroup ' + psQuote(cfg.adminsGroup) + sizeArgs.predeploy(cfg) + (fix ? ' -Fix' : '')]);
    },
    deploy: function (cfg) {
      return block(cfg, ['bash ./scripts/deploy/deploy.sh -p ' + cfg.parameterFile + ' -l ' + cfg.location +
        ' --users-group ' + psQuote(cfg.usersGroup) + ' --admins-group ' + psQuote(cfg.adminsGroup) + sizeArgs.deploy(cfg)]);
    },
    deployStatus: function (cfg, name) {
      var n = name ? psQuote(name) : "(az deployment sub list --query \"sort_by([?starts_with(name,'avdlz-')], &properties.timestamp)[-1].name\" -o tsv)";
      return [
        '$name = ' + n,
        'az deployment sub show -n $name --query "{name:name, state:properties.provisioningState, duration:properties.duration}" -o table',
        'az deployment operation sub list -n $name --query "[?properties.provisioningState==\'Failed\'].{resource:properties.targetResource.resourceName, error:properties.statusMessage.error.code}" -o table'
      ].join('\n');
    },
    postdeploy: function (cfg, fix) {
      return block(cfg, [signIn(cfg), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        sizeArgs.postdeploy(cfg) + (fix ? ' -Fix -AllowHostStart' : '')]);
    },
    wellArchitected: function (cfg) {
      return block(cfg, ['./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        ' -WellArchitected -SkipTenant -SkipNtfs']);
    },
    // Auto shutdown (decision 0011): Stop, Lock or Resume the session hosts by hand.
    power: function (cfg, action) {
      return block(cfg, ['./scripts/automation/Invoke-AvdPowerAction.ps1 -Action ' + action + ' -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment]);
    },
    demo: function (cfg) {
      return block(cfg, [signIn(cfg), './scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        (cfg.testUserUpn ? ' -TestUserUpn ' + psQuote(cfg.testUserUpn) : '')]);
    },
    // Verify access (decision 0014): confirm from Azure telemetry that a sign-in reached the desktop.
    // opts: user (default: the signed-in Azure user), demo, timeout (minutes).
    verify: function (cfg, opts) {
      opts = opts || {};
      return block(cfg, ['./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        (opts.user ? ' -UserPrincipalName ' + psQuote(opts.user) : '') + (opts.demo ? ' -Demo' : '') + (opts.timeout ? ' -TimeoutMinutes ' + opts.timeout : '')]);
    },
    // Where did I leave off (run recorder spec section 4): reads where the run stands from Azure.
    runStatus: function (cfg) {
      return block(cfg, ['./scripts/ops/Get-AvdRunStatus.ps1' + (cfg.namePrefix ? ' -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment : '')]);
    },
    // Open a recorded run (Start-AvdRunRecorder.ps1): run.json and the expected cost, gated at half the cap.
    // The parameter file reads the portal's sizing from the AVD_* variables, so the price matches what deploys;
    // they are cleared again so later blocks in the same shell use only their own flags.
    recordStart: function (cfg) {
      var r = recording(cfg); if (!r) return '';
      var s = sized(cfg), vars = ['AVD_SESSION_HOST_COUNT', 'AVD_SESSION_HOST_VM_SIZE', 'AVD_MAX_SESSION_LIMIT', 'AVD_PROFILE_QUOTA_GIB'];
      var lines = s ? ["$env:AVD_SESSION_HOST_COUNT = '" + s.hosts + "'; $env:AVD_SESSION_HOST_VM_SIZE = '" + s.vmSize + "'; $env:AVD_MAX_SESSION_LIMIT = '" + s.maxSessions + "'; $env:AVD_PROFILE_QUOTA_GIB = '" + s.profileQuotaGiB + "'"] : [];
      lines.push('./scripts/ops/Start-AvdRunRecorder.ps1 -RunId ' + r.runId + ' -ParameterFile ' + cfg.parameterFile + ' -Location ' + cfg.location + ' -Hours 3 -Cap 10' + (r.mode === 'on' ? ' -Local' : ''));
      if (s) lines.push('Remove-Item ' + vars.map(function (v) { return 'Env:' + v; }).join(', ') + ' -ErrorAction SilentlyContinue');
      return block(cfg, lines);
    },
    // Close a recorded run (Stop-AvdRunRecorder.ps1). mode: 'before-cleanup' (export the AVD logs while the
    // workspace still exists), 'end' (status and the first actual cost), 'copy' (the private companion repo),
    // 'cost' (read the actual cost again until it settles).
    recordStop: function (cfg, mode) {
      var r = recording(cfg); if (!r) return '';
      var flag = { 'before-cleanup': ' -BeforeCleanup', end: ' -Status torn-down', copy: ' -CopyTo github', cost: ' -UpdateCost' }[mode];
      if (!flag) return '';
      return block(cfg, ['./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId ' + r.runId + (cfg.namePrefix ? ' -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment : '') + flag + (r.mode === 'on' ? ' -Local' : '')]);
    },
    // Same-tenant recovery (build/specs/recovery-spec.md): read-only status, the configuration snapshot, and a
    // recovery test that only plans and prices until it is run again with -Go.
    recoveryStatus: function (cfg, opts) {
      opts = opts || {};
      var tier = /^R[012]$/.test(opts.tier || '') ? opts.tier : '';
      var loc = /^[a-z0-9]+$/.test(opts.recoveryLocation || '') ? opts.recoveryLocation : '';
      return block(cfg, ['./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        (tier && tier !== 'R0' ? ' -RecoveryTier ' + tier : '') + (loc ? ' -RecoveryLocation ' + loc : '')]);
    },
    exportConfig: function (cfg, identity) {
      return block(cfg, (identity ? [signIn(cfg)] : []).concat(['./scripts/ops/Export-AvdConfiguration.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment + (identity ? ' -IncludeIdentity' : '')]));
    },
    // Blue/green host rotation (build/specs/image-pipeline-spec.md section 6.5): each run continues where the last stopped.
    rotation: function (cfg, opts) {
      opts = opts || {};
      // The parameter file the rotation deploys with travels in the state line; the default one is left out.
      var pf = cfg.parameterFile && cfg.parameterFile !== 'parameters/' + cfg.environment + '.bicepparam' ? ' -ParameterFile ' + psQuote(cfg.parameterFile) : '';
      return block(cfg, ['./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment + pf +
        (opts.logOff ? ' -LogOffAtDeadline' : '') + (opts.rollback ? ' -Rollback' : '')]);
    },
    recoveryTest: function (cfg) {
      return block(cfg, ['./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment]);
    },
    removeDemo: function (cfg) {
      return block(cfg, [signIn(cfg), './scripts/ops/Remove-AvdDemo.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment]);
    },
    // Quota increase through the Microsoft.Quota API; small requests are usually approved in minutes.
    quota: function (items) {
      var lines = [
        '$sub = (Get-AzContext).Subscription.Id',
        'Register-AzResourceProvider -ProviderNamespace Microsoft.Quota | Out-Null'
      ];
      items.forEach(function (q) {
        var limit = Math.max(q.limit || 0, (q.used || 0) + (q.needed || 0));
        lines.push(
          '# ' + q.quotaName + ' in ' + q.location + ': limit ' + q.limit + ', used ' + q.used + ', needed ' + q.needed + ' -> request ' + limit,
          "$body = @{ properties = @{ limit = @{ limitObjectType = 'LimitValue'; value = " + limit + " }; name = @{ value = '" + q.quotaName + "' } } } | ConvertTo-Json -Depth 5",
          '$r = Invoke-AzRestMethod -Method PUT -Payload $body -Path "/subscriptions/$sub/providers/Microsoft.Compute/locations/' + q.location +
            '/providers/Microsoft.Quota/quotas/' + q.quotaName + '?api-version=2023-02-01"',
          '"' + q.quotaName + ': HTTP $($r.StatusCode) $((($r.Content | ConvertFrom-Json).properties).provisioningState)"'
        );
      });
      lines.push('# A few minutes later, check the new limits:');
      items.forEach(function (q) {
        lines.push("Get-AzVMUsage -Location " + q.location + " | Where-Object { $_.Name.Value -eq '" + q.quotaName + "' } | Select-Object @{n='Quota';e={$_.Name.Value}}, CurrentValue, Limit");
      });
      return lines.join('\n');
    },
    graphReset: function (cfg, rerun) {
      return ['Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null'].concat(rerun ? [rerun] : []).join('\n');
    }
  };

  // ---------------------------------------------------------------- run in (avd-ops docs/design-system.md, "Run in")
  // Where the operator runs the commands: Cloud Shell, Windows or macOS, in PowerShell or Bash. The commands
  // above are written for Cloud Shell PowerShell, the default, and stay exactly as they are there; forRunIn()
  // rewrites a block for the other places. Where each script works: scripts/platforms.json (copied here; a test
  // keeps them equal). tested: a real run proved it; untested: should work, no real run yet; no: hidden.
  var PLATFORMS = {
    "scripts/ops/Connect-AvdLandingZone.ps1": {"cloudshell-pwsh": "tested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules, the Microsoft.Graph modules", "evidence": "build/lessons/0030-graph-unlisted-delegated-scope.md"},
    "scripts/ops/Test-AvdLandingZoneReadiness.ps1": {"cloudshell-pwsh": "tested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules, the Microsoft.Graph modules", "evidence": "build/tests/portal/fixtures/real-predeploy-ready.txt, real-postdeploy-ready.txt"},
    "scripts/deploy/deploy.sh": {"cloudshell-pwsh": "tested", "cloudshell-bash": "untested", "windows": "no", "macos": "untested", "requires": "bash, the az CLI with Bicep", "evidence": "build/tests/portal/fixtures/real-deploy-dcr-tables.txt, build/lessons/0006-provider-registration.md"},
    "scripts/ops/Deploy-AvdDemo.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules, the Microsoft.Graph modules"},
    "scripts/ops/Test-AvdUserConnection.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Get-AvdRunStatus.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Start-AvdRunRecorder.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Stop-AvdRunRecorder.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Get-AvdRecoveryStatus.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Export-AvdConfiguration.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules, the Microsoft.Graph modules"},
    "scripts/ops/Invoke-AvdHostRotation.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Start-AvdRecoveryTest.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "scripts/ops/Remove-AvdDemo.ps1": {"cloudshell-pwsh": "tested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules, the Microsoft.Graph modules", "evidence": "build/lessons/0029-device-cleanup-rerun.md"},
    "scripts/automation/Invoke-AvdPowerAction.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "requires": "PowerShell 7.2 or later, the Az modules"}
  };
  var RUNIN_DEFAULT = { where: 'cloudshell', shell: 'pwsh' };
  var PLACES = { cloudshell: 'Cloud Shell', windows: 'Windows', macos: 'macOS' };
  // Windows runs PowerShell 7 only; Bash there means WSL, which is its own Linux machine.
  function validRunIn(r) {
    r = r || {};
    var where = PLACES.hasOwnProperty(r.where) ? r.where : RUNIN_DEFAULT.where;
    var shell = r.shell === 'bash' && where !== 'windows' ? 'bash' : 'pwsh';
    return { where: where, shell: shell };
  }
  function isDefaultRunIn(r) { r = validRunIn(r); return r.where === 'cloudshell' && r.shell === 'pwsh'; }
  function platformKey(r) { return r.where === 'cloudshell' ? 'cloudshell-' + r.shell : r.where; }
  function scriptsIn(command) {
    var seen = {}, out = [];
    String(command || '').replace(/\.\/(scripts\/[\w.\/-]+\.(?:ps1|sh))/g, function (m, p) { if (!seen[p]) { seen[p] = 1; out.push(p); } return m; });
    return out;
  }
  // How well a block works where the operator runs it: the weakest of its scripts. A block with no script
  // (inline az or PowerShell) is tested where it was written and untested elsewhere.
  function support(command, runIn) {
    var r = validRunIn(runIn), key = platformKey(r), rank = { tested: 0, untested: 1, no: 2 }, status = 'tested', requires = [], blockedBy = [];
    var scripts = scriptsIn(command);
    if (!scripts.length && !isDefaultRunIn(r)) status = 'untested';
    scripts.forEach(function (s) {
      var p = PLATFORMS[s], v = p ? p[key] : 'untested';
      if (!rank.hasOwnProperty(v)) v = 'untested';
      if (v === 'no') blockedBy.push(s);
      if (rank[v] > rank[status]) status = v;
      if (p && p.requires) String(p.requires).split(/,\s*/).forEach(function (q) { if (q && requires.indexOf(q) < 0) requires.push(q); });
    });
    if (r.where === 'cloudshell') requires = [];
    return { status: status, requires: requires, blockedBy: blockedBy, place: PLACES[r.where], shell: r.shell };
  }
  function bashQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
  // PowerShell's $env: assignments and Remove-Item Env: become export and unset, so pwsh and bash scripts
  // started from the same bash prompt both see them.
  function envToBash(line) {
    var sets = line.trim().split(/;\s*(?=\$env:)/), out = [];
    for (var i = 0; i < sets.length; i++) {
      var m = /^\$env:([A-Z0-9_]+) = '((?:[^']|'')*)'$/.exec(sets[i]);
      if (!m) return null;
      out.push(m[1] + '=' + bashQuote(m[2].replace(/''/g, "'")));
    }
    return 'export ' + out.join(' ');
  }
  function unsetToBash(line) {
    var m = /^Remove-Item ((?:Env:[A-Z0-9_]+(?:, )?)+) -ErrorAction SilentlyContinue$/.exec(line.trim());
    return m ? 'unset ' + m[1].split(/,\s*/).map(function (v) { return v.replace(/^Env:/, ''); }).join(' ') : null;
  }
  var AZ_SIGNIN_PS = 'if (-not (Get-AzContext)) { Connect-AzAccount -UseDeviceAuthentication | Out-Null }';
  var AZ_CLI_SIGNIN_PS = 'az account show -o none 2>$null; if ($LASTEXITCODE -ne 0) { az login --use-device-code -o none }';
  var AZ_CLI_SIGNIN_BASH = 'az account show -o none 2>/dev/null || az login --use-device-code -o none';
  // Rewrites a Cloud Shell PowerShell block for another place and shell. Cloud Shell PowerShell returns it as is.
  function forRunIn(command, runIn) {
    var r = validRunIn(runIn);
    if (!command || isDefaultRunIn(r)) return command || '';
    if (/^AVD_PS$/m.test(command)) throw new Error('The block holds a line the Bash version cannot carry.');
    var lines = String(command).split('\n'), pre = [], body = lines;
    var clone = /^if \(-not \(Test-Path (~\/\S+)\)\) \{ git clone (\S+) \S+ \}$/.exec(lines[0] || '');
    var into = clone && /^Set-Location (~\/\S+); (.*)$/.exec(lines[1] || '');
    if (into) { body = lines.slice(2); }
    var local = r.where !== 'cloudshell';
    var usesCli = body.some(function (l) { return /^bash \.\/|(^|[;(]\s*)az /.test(l); });
    // Az PowerShell: the scripts and the Az cmdlets; a block of az commands needs only the az CLI sign-in.
    var azPs = function (l) { return /\.ps1\b|-Az[A-Z]|Get-AzContext/.test(l); };
    var usesPs = body.some(azPs);
    if (r.shell === 'pwsh') {
      if (into) pre = [lines[0], lines[1]];
      if (local && usesPs) pre.push(AZ_SIGNIN_PS);
      if (local && usesCli) pre.push(AZ_CLI_SIGNIN_PS);
      return pre.concat(body).join('\n');
    }
    // Bash: the clone and checkout in bash, then each stretch of PowerShell lines in one pwsh process (a Graph
    // sign-in and the script that uses it must share it), and bash scripts as they are.
    if (into) pre = ['[ -d ' + into[1] + ' ] || git clone ' + clone[2] + ' ' + clone[1], 'cd ' + into[1] + ' && ' + into[2].split(/;\s*/).join(' && ')];
    if (local && usesCli) pre.push(AZ_CLI_SIGNIN_BASH);
    // Each stretch is written word for word to a file through a quoted heredoc (bash expands nothing in it).
    var out = [], ps = [], file = false;
    var flush = function () {
      if (!ps.length) return;
      if (local && ps.some(azPs)) ps.unshift(AZ_SIGNIN_PS);
      if (!file) { out.push('f="$(mktemp -d)/step.ps1"'); file = true; }
      out.push("cat > \"$f\" <<'AVD_PS'"); out = out.concat(ps); out.push('AVD_PS', 'pwsh -NoLogo -File "$f"'); ps = [];
    };
    body.forEach(function (l) {
      var b = envToBash(l) || unsetToBash(l);
      if (b) { flush(); out.push(b); }
      else if (/^bash \.\//.test(l)) { flush(); out.push(l.replace(/'((?:[^']|'')*)'/g, function (m, s) { return bashQuote(s.replace(/''/g, "'")); })); }
      else ps.push(l);
    });
    flush();
    return pre.concat(out).join('\n');
  }

  // ---------------------------------------------------------------- reading the paste
  function extractStates(text) {
    var states = [], re = /<<<AVDLZ-STATE([\s\S]*?)AVDLZ-STATE>>>/g, m;
    while ((m = re.exec(text))) {
      // A terminal copy can break the long line; JSON strings carry no raw newlines, so drop them.
      var raw = m[1].replace(/[\r\n]+/g, '').trim();
      try { states.push(JSON.parse(raw)); } catch (e) { states.push({ parseError: String(e && e.message || e), raw: raw.slice(0, 200) }); }
    }
    return states;
  }

  // ARM error codes that name a known cause.
  var ARM_ERRORS = [
    { code: 'LocationNotSupportAvailabilityZones', what: 'A resource was created with availability zones in a region that has none.',
      fix: 'Fixed in the template (build/lessons/0001). Update the repo and deploy again; the next block does both.', action: 'redeploy' },
    { code: 'SkuNotAvailable', what: 'The VM size is not available in this region or zone for your subscription.',
      fix: 'Pick another size or region, then run the pre-deployment preflight, which checks sizes and zones.', action: 'predeploy' },
    { code: 'QuotaExceeded', what: 'Not enough vCPU quota.', fix: 'Run the pre-deployment preflight: it shows the quota and the portal builds the increase request.', action: 'predeploy' },
    { code: 'OperationNotAllowed', what: 'Usually a quota limit.', fix: 'Run the pre-deployment preflight: it checks quota and the portal builds the increase request.', action: 'predeploy' },
    { code: 'AuthorizationFailed', what: 'Your account lacks permission for part of the deployment.', fix: 'Deploy as Owner of the subscription (or Contributor + Role Based Access Control Administrator).', action: 'predeploy' },
    { code: 'VaultAlreadyExists', what: 'The Key Vault name is taken (often by a soft-deleted vault from an earlier deployment).', fix: 'Run the pre-deployment preflight with -Fix: it recovers a soft-deleted vault into its resource group so the name prefix can stay. Or change namePrefix in the parameter file.', action: 'predeploy-fix' },
    { code: 'InvalidTemplateDeployment', what: 'Azure rejected the template or parameters before deploying.', fix: 'Run the pre-deployment preflight; it compiles the parameter file and checks the region.', action: 'predeploy' },
    { code: 'InvalidOutputTable', what: 'The AVD Insights data collection rule was created before the Log Analytics workspace had its Perf and Event tables. This happens when the workspace was only just created, or recovered from a soft delete left by an earlier cleanup.',
      fix: 'Deploy again: the deployment is idempotent and the workspace tables should now be ready. If it fails the same way, paste both outputs into Report a problem.', action: 'redeploy' },
    { code: 'ResourceGroupBeingDeleted', what: 'A landing zone resource group is still being deleted.', fix: 'Wait until the deletion finishes, then deploy again.', action: 'redeploy' },
    { code: 'RoleAssignmentExists', what: 'A role assignment already exists (usually harmless on a redeploy).', fix: 'Deploy again; the template is idempotent.', action: 'redeploy' }
  ];
  function armErrors(text) {
    var seen = {}, out = [];
    ARM_ERRORS.forEach(function (e) { if (text.indexOf(e.code) >= 0 && !seen[e.code]) { seen[e.code] = 1; out.push(e); } });
    return out;
  }
  function armCodes(text) {
    var codes = {}, re = /"code"\s*:\s*"([A-Za-z]+)"/g, m;
    while ((m = re.exec(text))) if (!/^(DeploymentFailed|ResourceDeploymentFailure|Failed)$/.test(m[1])) codes[m[1]] = 1;
    return Object.keys(codes);
  }

  // Output from before state lines existed (or cut off): infer what we can from the text.
  function inferFromText(text) {
    var failures = [], re = /\[FAIL \] (.+)\n(?:[ \t]{6,}(?!->)(.+)\n)?(?:[ \t]{6,}-> (.+))?/g, m;
    while ((m = re.exec(text + '\n'))) failures.push({ id: '', check: m[1].trim(), detail: (m[2] || '').trim(), remediation: (m[3] || '').trim() });
    var fix = /\(FIX mode\)/.test(text);
    var ready = /(^|\n)\s*Ready\.\s*(\n|$)/.test(text), notReady = /Not ready: \d+ failure/.test(text);
    if (/PRE-DEPLOYMENT preflight/.test(text) && (ready || notReady)) {
      // The clean run prints the deploy command: take the parameter file, region and groups from it.
      var ctx = {}, dm = /deploy\.sh -p (\S+) -l (\S+) --users-group '((?:[^']|'')*)' --admins-group '((?:[^']|'')*)'/.exec(text);
      var pf = /PRE-DEPLOYMENT preflight - (\S+\.bicepparam)/.exec(text);
      if (pf) ctx.parameterFile = pf[1];
      if (dm) { ctx.parameterFile = dm[1]; ctx.location = dm[2]; ctx.usersGroup = dm[3].replace(/''/g, "'"); ctx.adminsGroup = dm[4].replace(/''/g, "'"); }
      var pm = /prefix ([a-z0-9]+), env (dev|test|prod), ([a-z0-9]+),/.exec(text);
      if (pm) { ctx.namePrefix = pm[1]; ctx.environment = pm[2]; ctx.location = ctx.location || pm[3]; }
      return { v: 0, stage: 'predeploy', status: ready && !notReady ? 'ready' : 'notready', fix: fix, context: ctx, failures: failures, warnings: [] };
    }
    if (/AVD landing zone preflight - /.test(text) && (ready || notReady)) {
      var c = /preflight - ([a-z0-9]+)\/(dev|test|prod)/.exec(text);
      return { v: 0, stage: 'postdeploy', status: ready && !notReady ? 'ready' : 'notready', fix: fix, context: c ? { namePrefix: c[1], environment: c[2] } : {}, failures: failures, warnings: [] };
    }
    if (/==> Landing zone deployed\./.test(text)) {
      var s = /-NamePrefix ([a-z0-9]+) -Environment (dev|test|prod)/.exec(text);
      return { v: 0, stage: 'deploy', status: 'succeeded', context: s ? { namePrefix: s[1], environment: s[2] } : {} };
    }
    if (/"status"\s*:\s*"Failed"/.test(text) && /"code"\s*:\s*"DeploymentFailed"/.test(text)) return { v: 0, stage: 'deploy', status: 'failed', context: {} };
    var d = /==> Deploying \(([^)]+)\)/.exec(text);
    if (d) return { v: 0, stage: 'deploy', status: 'started', context: { deploymentName: d[1] } };
    return null;
  }

  // Errors that stop a command before our scripts can report anything.
  function shellProblems(text) {
    var p = [];
    if (/The term '\.\/scripts\/[^']+' is not recognized/.test(text) || /No such file or directory.*scripts\/deploy/.test(text))
      p.push({ id: 'not-in-repo', what: 'Cloud Shell was not in the repository folder (a new Cloud Shell session starts in your home folder).', fix: 'Every block below starts by moving into the repository.' });
    var pm = /A parameter cannot be found that matches parameter name '([^']+)'/.exec(text);
    if (pm) p.push({ id: 'bad-parameter', what: "The command had an unknown parameter '" + pm[1] + "' (often a stray keystroke when pasting).", fix: 'Copy the block again and paste it as-is.' });
    if (/DeviceCodeCredential authentication failed/.test(text))
      p.push({ id: 'graph-token', what: 'The Microsoft Graph sign-in could not get a token.', fix: 'Sign out of Graph and run the step again; it asks for a new device code.' });
    if (/Please run 'az login'|Run 'az login'|No subscription found|az account set/.test(text) && !/<<<AVDLZ-STATE/.test(text))
      p.push({ id: 'az-login', what: 'The Azure CLI is not signed in to the right subscription.', fix: 'Run: az account set --subscription "<your subscription>", then the step again.' });
    if (/To sign in, use a web browser to open the page https:\/\/(login\.)?microsoft\.com\/device/.test(text) && !/<<<AVDLZ-STATE/.test(text) && !/== Summary/.test(text))
      p.push({ id: 'device-code', what: 'The output stops at a device-code sign-in prompt.', fix: 'Open the link, enter the code, then wait for the script to finish before pasting the output.' });
    return p;
  }

  // Which of our commands the pasted output was running, read from the prompt line, e.g.
  // "PS /home/builder> ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ... -Fix".
  // A redacted report (site/portal/report.js) has "PS /home/<user-1>>".
  function commandInText(text) {
    var lines = text.split('\n'), i, m;
    for (i = lines.length - 1; i >= 0; i--) {
      m = /^PS (?:<[a-z]+-\d+>|[^>])*> (.*\b(Test-AvdLandingZoneReadiness|deploy\.sh|Deploy-AvdDemo|Remove-AvdDemo|Test-AvdUserConnection)\b.*)$/.exec(lines[i]);
      if (!m) continue;
      var c = m[1], fix = /\s-Fix\b/.test(c);
      if (/Test-AvdLandingZoneReadiness/.test(c)) return { step: /-PreDeployment\b/.test(c) ? 'predeploy' : 'postdeploy', fix: fix };
      if (/deploy\.sh/.test(c)) return { step: 'deploy', fix: false };
      if (/Deploy-AvdDemo/.test(c)) return { step: 'signin', fix: false };
      if (/Remove-AvdDemo/.test(c)) return { step: 'signin', removeDemo: true };
      if (/Test-AvdUserConnection/.test(c)) return { step: 'verify', fix: false };
    }
    return null;
  }

  // ---------------------------------------------------------------- deciding the next step
  function hasFixable(items) { return items.some(function (f) { return /-Fix\b/.test(f.remediation || ''); }); }
  function byId(items, id) { return items.filter(function (f) { return f.id === id; }); }

  function decide(state, cfg, ctx) {
    var a = [], failures = state.failures || [], warnings = state.warnings || [], S = state.stage;
    var note = function (title, why, command) { a.push({ title: title, why: why, command: command || '' }); };

    // Security Defaults has no per-app exclusion for the storage app: a tenant decision, never a blocker.
    var secDefaults = byId(warnings, 'security-defaults');
    var noteSecDefaults = function (when) {
      if (secDefaults.length) note('Decide about Security Defaults ' + when, [secDefaults[0].detail, secDefaults[0].remediation].filter(Boolean).join(' ') + ' Nothing here changes it; the rest of the landing zone works either way.', '');
    };

    if (S === 'predeploy') {
      if (state.status === 'ready') {
        noteSecDefaults('before the post-deployment setup');
        note('Deploy the landing zone', 'The pre-deployment preflight ' + (secDefaults.length ? 'passed' : 'is clean') + '. Deployment takes 30-45 minutes and keeps running in Azure if Cloud Shell disconnects; paste its output here when it ends (or when you reconnect).', cmd.deploy(cfg));
        return { step: 'deploy', actions: a };
      }
      var quota = byId(failures, 'quota'), kv = byId(failures, 'kv-softdeleted'), hp = byId(failures, 'hostpool-region'), lzr = byId(failures, 'lz-region');
      var others = failures.filter(function (f) { return ['quota', 'kv-softdeleted', 'hostpool-region', 'lz-region'].indexOf(f.id) < 0; });
      // -Fix recovers a soft-deleted vault into its resource group, so the name prefix can stay.
      var kvFix = kv.length > 0 && !state.fix && kv.some(function (f) { return ((f.data && f.data.vaults) || []).length === 1; });
      var fixFirst = ((others.length > 0 && hasFixable(others)) || kvFix) && !state.fix;
      var regionChange = false;
      if (fixFirst)
        note('Run the preflight again with -Fix', [others.length > 0 && hasFixable(others) ? 'It creates the missing groups and service principal and registers providers and features, waiting until they finish.' : '',
          kvFix ? 'It recovers the deleted Key Vault (' + kv[0].data.vaults[0] + ') into its resource group, so the deployment reuses it and keeps the name prefix.' : ''].filter(Boolean).join(' '), cmd.predeploy(cfg, true));
      if (hp.length) {
        var regions = pastedList('location', hp[0].data && hp[0].data.regions);
        var pick = pastedList('location', ctx.rankedRegions).filter(function (r) { return regions.indexOf(r) >= 0; })[0] || regions[0];
        if (pick) {
          regionChange = true;
          note('Choose a region that offers AVD host pools', cfg.location + ' does not offer AVD host pools. ' + (ctx.rankedRegions ? 'The closest one that does, by your latency test, is ' + pick + '.' : 'For example ' + pick + '; run the latency test in step 1 to pick the closest.'), cmd.predeploy(merge(cfg, { location: pick }), false));
        }
      }
      if (lzr.length) {
        var where = pastedList('location', lzr[0].data && lzr[0].data.deployedIn)[0];
        if (where) regionChange = true;
        note('Use the region the landing zone is already in', 'Resource groups cannot move region. Check against ' + where + ', or remove the existing landing zone first.', where ? cmd.predeploy(merge(cfg, { location: where }), false) : '');
      }
      if (quota.length)
        note('Request more vCPU quota', quota.map(function (q) { return q.check + ': ' + q.detail; }).join('; ') + '. Small increases are usually approved within minutes; if it goes to review, follow it in Portal > Quotas > My requests. Then run the preflight again.', cmd.quota(quota.map(function (q) { return pastedQuota(q.data); }).filter(Boolean)));
      if (kv.length && !kvFix)
        note('Resolve the soft-deleted Key Vault', 'A deleted, purge-protected vault (' + ((kv[0].data && kv[0].data.vaults) || []).join(', ') + ') still holds the vault name for 90 days. ' + [kv[0].detail, kv[0].remediation].filter(Boolean).join(' ') + ' (namePrefix is in ' + cfg.parameterFile + '.)', '');
      if (others.length && !fixFirst)
        others.forEach(function (f) { note('Fix: ' + f.check, [f.detail, f.remediation].filter(Boolean).join(' '), ''); });
      // Close with a rerun unless an action above already reruns it (with -Fix or in another region).
      if (!fixFirst && !regionChange)
        note(a.length ? 'Then run the preflight again' : 'Run the preflight again', 'It should come back Ready.', cmd.predeploy(cfg, false));
      return { step: 'predeploy', actions: a };
    }

    if (S === 'deploy') {
      if (state.status === 'succeeded') {
        note('Run the post-deployment setup', 'The landing zone is deployed. This grants admin consent for the storage app, checks Conditional Access and sets the profile share permissions (starting the session host if needed). It asks for a Microsoft Graph device code.', cmd.postdeploy(cfg, true));
        return { step: 'postdeploy', actions: a };
      }
      if (state.status === 'whatif') {
        note('Deploy for real', 'The what-if ran. Deployment takes 30-45 minutes.', cmd.deploy(cfg));
        return { step: 'deploy', actions: a };
      }
      if (state.status === 'started') {
        note('Check on the deployment', 'The output ends while the deployment was running. It keeps running in Azure even if Cloud Shell disconnected. Run this and paste the result; when it shows Succeeded, the post-deployment setup is next. Do not start the deployment again while it runs.', cmd.deployStatus(cfg, pasted('deploymentName', state.context && state.context.deploymentName)));
        return { step: 'deploy', actions: a };
      }
      var known = armErrors(ctx.text), codes = armCodes(ctx.text);
      if (known.length) {
        known.forEach(function (e) { note(e.code + ': ' + e.what, e.fix, e.action === 'redeploy' ? cmd.deploy(cfg) : cmd.predeploy(cfg, e.action === 'predeploy-fix')); });
      }
      else {
        note('Find out what failed', 'The deployment failed' + (codes.length ? ' (' + codes.join(', ') + ')' : '') + '. This lists the failed resources and their error codes; paste the result here.', cmd.deployStatus(cfg, pasted('deploymentName', state.context && state.context.deploymentName)));
      }
      return { step: 'deploy', actions: a };
    }

    if (S === 'postdeploy') {
      var missing = byId(failures, 'lz-missing');
      if (missing.length) {
        var found = (Array.isArray(missing[0].data && missing[0].data.found) ? missing[0].data.found : []).map(pastedLandingZone).filter(Boolean);
        if (found.length) note('Check the landing zone that exists', 'No landing zone named ' + cfg.namePrefix + '-' + cfg.environment + ' in this subscription, but there is ' + found.map(function (f) { return f.namePrefix + '-' + f.environment; }).join(', ') + '.', cmd.postdeploy(merge(cfg, found[0]), false));
        else note('Deploy the landing zone first', 'Nothing is deployed under this name in this subscription. Start with the pre-deployment preflight (or switch subscription with Set-AzContext).', cmd.predeploy(cfg, false));
        return { step: found.length ? 'postdeploy' : 'predeploy', actions: a };
      }
      var locked = byId(warnings, 'power-locked');
      if (locked.length) note('Resume the session hosts', 'Auto shutdown locked them (' + ((locked[0].data && locked[0].data.lock) || 'locked') + '): they are drained and off, and nobody can sign in until they are resumed. Resume once the cost is dealt with; hosts then start on the next connection.', cmd.power(cfg, 'Resume'));
      if (state.status === 'ready') {
        var waf = (state.warnings || []).filter(function (w) { return /^waf-/.test(w.id || ''); });
        if (state.context && state.context.wellArchitected) {
          var open = waf.filter(function (w) { return !(w.data && w.data.accepted); }), expected = waf.length - open.length;
          var pillars = {};
          open.forEach(function (w) { var p = (w.data && w.data.pillar) || 'Other'; pillars[p] = (pillars[p] || 0) + 1; });
          note(waf.length ? 'Review the Well-Architected findings' : 'Well-Architected: every check passes',
            waf.length ? (open.length ? 'To review: ' + ['Reliability', 'Security', 'Cost Optimization', 'Operational Excellence', 'Performance Efficiency', 'Other'].filter(function (p) { return pillars[p]; }).map(function (p) { return pillars[p] + ' ' + p; }).join(', ') + '.' : 'Nothing beyond the expected ones.') +
              (expected ? ' ' + expected + ' are trade-offs the ' + cfg.environment + ' parameter file makes on purpose; change them before production.' : '') + ' The findings are listed above; none of them blocks sign-in.'
              : 'Design checks, Azure Advisor, Defender for Cloud, Azure Policy and PSRule for Azure found nothing to review.', '');
        }
        noteSecDefaults('if profiles fail to load');
        note('Sign in to the desktop', (secDefaults.length ? 'The checks pass apart from Security Defaults above.' : 'Everything checks out.') + ' Open https://windows.cloud.microsoft (or the Windows App) as a member of ' + cfg.usersGroup + ' and open the desktop. New group members can take up to an hour to see it; a stopped host starts on the first connection.', '');
        note('Optional: validate sign-in end to end with a demo host pool', 'Deploys a separate demo host pool, checks the host and your test user, and tells you how to remove it.', cmd.demo(cfg));
        if (!(state.context && state.context.wellArchitected))
          note('Optional: Well-Architected review', 'Reviews the deployed landing zone by pillar (reliability, security, cost, operations, performance): design checks, Azure Advisor, Defender for Cloud, Azure Policy and PSRule for Azure. Findings are warnings; no Graph sign-in needed. A few minutes.', cmd.wellArchitected(cfg));
        return { step: 'signin', actions: a };
      }
      // Only a deployment changes the share's SMB settings; -Fix does not (build/lessons/0028).
      var smb = byId(failures, 'smb-channel');
      if (smb.length) {
        note('Deploy the landing zone again', 'The profile share allows only ' + ((smb[0].data && smb[0].data.channelEncryption) || 'AES-256-GCM') + ' channel encryption, so Azure Files denies Entra Kerberos sign-ins and FSLogix profiles fail to load. Deploying again updates the existing storage account in place to allow AES-128-GCM and AES-256-GCM.', cmd.deploy(cfg));
        failures = failures.filter(function (f) { return f.id !== 'smb-channel'; });
      }
      if (hasFixable(failures) && !state.fix) {
        note('Run the setup with -Fix', 'It applies the tenant steps (admin consent, Conditional Access exclusion, profile share permissions) and starts the session host if it is stopped.', cmd.postdeploy(cfg, true));
        return { step: 'postdeploy', actions: a };
      }
      failures.forEach(function (f) { note('Fix: ' + f.check, [f.detail, f.remediation].filter(Boolean).join(' '), ''); });
      note('Then run the check again', 'It should come back Ready.', cmd.postdeploy(cfg, false));
      return { step: 'postdeploy', actions: a };
    }

    if (S === 'demo') {
      if (state.status === 'ready') {
        note('Sign in to the demo desktop', 'Open https://windows.cloud.microsoft as ' + (cfg.testUserUpn || 'a member of ' + cfg.usersGroup) + ' and open the Desktop in the ' + ((state.context && state.context.workspace) || 'demo') + ' workspace.', '');
        note('Remove the demo when you are done', 'Removes the demo resource group and its device objects; the landing zone stays.', cmd.removeDemo(cfg));
      }
      else {
        failures.forEach(function (f) { note('Fix: ' + f.check, [f.detail, f.remediation].filter(Boolean).join(' '), ''); });
        note('Then run the demo validation again', '', cmd.demo(cfg));
      }
      return { step: 'signin', actions: a };
    }

    if (S === 'verify') {
      // Test-AvdUserConnection.ps1 (decision 0014). It fails closed: only "verified" is a pass.
      var vc = state.context || {}, conns = vc.connections || [], again = { user: pasted('user', vc.user), demo: vc.demo === true };
      var connected = conns.filter(function (c) { return c && c.connectedAt; })[0];
      var who = vc.user || 'you';
      if (state.status === 'verified') {
        var how = connected ? ['on ' + (connected.sessionHost || 'a session host'), connected.clientType ? 'with the ' + connected.clientType + ' client' + (connected.clientOS ? ' on ' + connected.clientOS : '') : '',
          connected.gatewayRegion ? 'through gateway ' + connected.gatewayRegion : ''].filter(Boolean).join(', ') : '';
        note('Access verified', 'Azure recorded a connection by ' + who + ' that reached Connected' + (how ? ' (' + how + ')' : '') + '.' +
          (connected && typeof connected.connectionSetupSeconds === 'number' ? ' Connection setup took ' + connected.connectionSetupSeconds + ' s (Started to Connected). That is connection setup, not the time to a usable desktop, and a first connection to a stopped host includes it starting.' : '') +
          ' This proves a real sign-in reached the desktop; it doesn\'t prove the desktop is usable or that other users will get in.', '');
        byId(warnings, 'connect-errors').forEach(function (w) { note('Another attempt failed', w.detail || '', ''); });
        return { step: 'verify', actions: a };
      }
      if (state.status === 'failed') {
        byId(failures, 'connect-errors').forEach(function (f) {
          var service = f.data && f.data.serviceError;
          note('The connection failed', (f.detail ? 'AVD logged: ' + f.detail + '. ' : '') + (service
            ? 'AVD marked it a service error: try again in a few minutes, and check Azure Service Health.'
            : 'Check the landing zone: the post-deployment check covers the host pool, the session hosts and the group assignments. Then open the desktop again.'), service ? '' : cmd.postdeploy(cfg, false));
        });
        note('Then check the connection again', 'After signing in again.', cmd.verify(cfg, again));
        return { step: 'verify', actions: a };
      }
      var qf = byId(failures, 'query-failed')[0], lzm = byId(failures, 'no-landing-zone')[0], inprog = byId(failures, 'in-progress')[0];
      if (qf) {
        note('The connection logs couldn\'t be read', (qf.data && qf.data.status === 403
          ? 'Your account can\'t read the Log Analytics workspace\'s data. ' + (qf.remediation || '') : (qf.detail || '') + ' ' + (qf.remediation || '')).trim(), '');
        note('Then check again', '', cmd.verify(cfg, again));
      }
      else if (lzm) {
        note('Landing zone not found', [lzm.check, lzm.remediation].filter(Boolean).join('. '), cmd.postdeploy(cfg, false));
      }
      else {
        note(inprog ? 'The connection hasn\'t reached Connected yet' : 'No connection found yet',
          (inprog ? 'A connection started and logged no errors. The host may still be starting (Start VM on Connect), or the rest of the connection hasn\'t reached Log Analytics. '
            : 'Nothing is logged for ' + who + ' in the last ' + (vc.windowMinutes || 60) + ' minutes. Open the desktop and sign in as ' + who + ' first. If you just did, the data can take several minutes to arrive. ') +
          'This is not a pass. Check again and wait longer:', cmd.verify(cfg, { user: again.user, demo: again.demo, timeout: 30 }));
      }
      return { step: 'verify', actions: a };
    }

    if (S === 'power') {
      var pw = state.power || {};
      if (state.status === 'locked') {
        note('The session hosts are locked', (pw.deallocated || []).length + ' host(s) deallocating; they stay off, drained and outside the scaling plan until resumed. Resume once the cost is dealt with.', cmd.power(cfg, 'Resume'));
        return { step: 'signin', actions: a };
      }
      if (state.status === 'resumed') {
        note('Sign in to the desktop', 'The hosts take sessions again. The first connection starts a host (Start VM on Connect), which takes a few minutes.', '');
        return { step: 'signin', actions: a };
      }
      note('Session hosts stopped', (pw.deallocated || []).length + ' deallocated' + ((pw.skipped || []).length ? ', ' + pw.skipped.length + ' left running because users are signed in' : '') + '. They start again on the next connection.', '');
      return { step: 'signin', actions: a };
    }
    if (S === 'resume') {
      // Get-AvdRunStatus.ps1 (run recorder spec section 4): Azure says where the run stands; the journal only adds detail.
      var rc = state.context || {}, basis = rc.basis ? ' ' + rc.basis : '';
      if (rc.lastStage === 'deploy' && rc.lastStatus === 'running') {
        note('Wait for the deployment', 'Azure shows the deployment still running.' + basis + ' Do not start it again. Check on it with this, and paste the result when it shows Succeeded or Failed.', cmd.deployStatus(cfg, pasted('deploymentName', rc.deploymentName)));
        return { step: 'deploy', actions: a };
      }
      if (state.status !== 'ready' || !rc.nextStage) {
        note('Couldn\'t tell where the run stands', 'The status check saw something it doesn\'t recognize.' + basis + ' Use Report a problem so it can be added, and pick the step yourself from the list.', '');
        return { step: null, actions: a };
      }
      if (rc.lastStage === 'deploy' && rc.lastStatus === 'failed') {
        note('Find out what failed', 'The last deployment failed.' + basis + ' This lists the failed resources and their error codes; paste the result here.', cmd.deployStatus(cfg, pasted('deploymentName', rc.deploymentName)));
        return { step: 'deploy', actions: a };
      }
      var NEXT = { predeploy: 'Run the pre-deployment preflight', deploy: 'Deploy the landing zone', postdeploy: 'Run the post-deployment setup', signin: 'Deploy the demo and sign in', verify: 'Check access' };
      note(NEXT[rc.nextStage] || 'Continue', 'This is where the run left off.' + basis, rerunForStep(rc.nextStage, cfg, rc.nextStage === 'postdeploy' ? true : undefined));
      return { step: rc.nextStage, actions: a };
    }
    if (S === 'rotation') {
      // Invoke-AvdHostRotation.ps1: refused before anything changed, waiting (run it again), done or failed.
      // Rotation runs on a deployed landing zone, so its actions show on the post-deployment slide.
      var ro = state.context || {}, wait = byId(warnings, 'rotation-waiting')[0];
      if (state.status === 'refused') {
        note('The rotation did not start', ((failures[0] || {}).detail || '') + ' ' + ((failures[0] || {}).remediation || '') + ' Nothing was changed.', '');
        return { step: 'postdeploy', actions: a };
      }
      if (state.status === 'failed') {
        var f0 = failures[0] || {};
        if (f0.id === 'rotation-deploy') note('The new hosts did not deploy', (f0.detail || '') + ' Fix what deploy.sh reported and run the rotation again (it continues), or roll back.', cmd.rotation(cfg));
        else note('The rotation stopped in phase ' + (ro.phase || 'Deploy'), (f0.detail || '') + ' ' + (f0.remediation || '') + ' Nothing after that was changed.', cmd.rotation(cfg));
        if (!ro.rollback && ro.phase !== 'Remove') note('Or roll back', 'The original hosts take sessions again and the new ones are removed.', cmd.rotation(cfg, { rollback: true }));
        return { step: 'postdeploy', actions: a };
      }
      if (state.status === 'waiting') {
        var afterDeadline = wait && /-LogOffAtDeadline/.test((wait.detail || '') + ' ' + (wait.remediation || ''));
        // A rollback that waited for the deployment to end is run again as a rollback.
        if (ro.rollbackPending) {
          note('Roll back once the deployment ends', ((wait || {}).detail || '') + ' Run the rollback again then.', cmd.rotation(cfg, { rollback: true }));
          return { step: 'postdeploy', actions: a };
        }
        var paused = byId(warnings, 'rotation-paused')[0];
        if (paused) {
          note('The rotation is paused before ' + (ro.stopBefore || 'the next phase'), (paused.detail || '') + ' Run it again to continue from phase ' + (ro.phase || 'Deploy') + '.', cmd.rotation(cfg));
          if (!ro.rollback) note('Or roll back', 'The original hosts take every session again and the new ones are removed.', cmd.rotation(cfg, { rollback: true }));
          return { step: 'postdeploy', actions: a };
        }
        note(ro.phase === 'Wait' ? 'Users are moving to the new hosts' : 'Run the rotation again', ((wait || {}).detail || '') + ' It continues from phase ' + (ro.phase || 'Deploy') + '.', cmd.rotation(cfg, { logOff: afterDeadline }));
        if (!ro.rollback && ro.phase !== 'Remove') note('Or roll back', 'Before the old hosts are removed, a rollback puts users back on them and removes the new ones.', cmd.rotation(cfg, { rollback: true }));
        return { step: 'postdeploy', actions: a };
      }
      var left = byId(warnings, 'devices-left');
      if (left.length) {
        var dn = [].concat.apply([], left.map(function (w) { return (w.data && w.data.devices) || []; }));
        note('Delete the old device objects', 'Entra ID and Intune still hold ' + (dn.join(', ') || 'the removed hosts') + '. Delete them there by hand once you have checked they are these hosts.', '');
      }
      note(ro.rollback ? 'The rollback is complete' : 'The rotation is complete', ro.rollback ? 'The original hosts take every session; the new ones are removed.' : 'Every session host runs ' + (ro.version || 'the new version') + '. To go back, rotate to the previous version.', ro.rollback ? '' : cmd.rotation(cfg, { rollback: true }));
      return { step: 'postdeploy', actions: a };
    }
    if (S === 'recovery') {
      // Get-AvdRecoveryStatus.ps1 and Start-AvdRecoveryTest.ps1: one action for the first thing that isn't met.
      var rv = state.context || {}, open = failures.concat(warnings), runId = pasted('runId', rv.runId);
      var has = function (id) { return byId(open, id).length > 0; };
      var opts = { tier: rv.tier, recoveryLocation: rv.recoveryLocation };
      if (rv.test) {
        if (rv.mode === 'plan' && state.status === 'ready') note('Run the recovery test when you are ready', 'The plan above restores the newest recovery point into a new storage account and prints its cost. Nothing was created. Add -Go to the same command to run it, and remove it after with -Cleanup.', cmd.recoveryTest(cfg) + ' -Go');
        else if (rv.mode === 'plan') note('Not ready for a recovery test', ((failures[0] || {}).detail || '') + ' Nothing was created.', '');
        else if (state.status === 'passed') note('Remove the test copy', 'The restore passed; the measured RPO and restore time are in the run record. Remove the test copy now so it stops billing.', cmd.recoveryTest(cfg) + ' -Cleanup -RunId ' + psQuote(runId || ''));
        else if (state.status === 'done') note('Check the recovery status again', 'The test copy is removed. The status check now counts the passed test.', cmd.recoveryStatus(cfg, opts));
        else note('Remove the test, then look at the error', ((failures[0] || {}).detail || 'The test did not pass.') + ' Remove what it created first, so nothing keeps billing.', runId ? cmd.recoveryTest(cfg) + ' -Cleanup -RunId ' + psQuote(runId) : '');
        return { step: 'recovery', actions: a };
      }
      if (state.status === 'met') {
        note('Recovery tier ' + (rv.tier || 'R0') + ' is met', rv.met + ' of ' + rv.total + ' items are met. Run the status check again monthly, after a snapshot and a copy.', '');
        return { step: 'recovery', actions: a };
      }
      if (has('dr-profile-backup') || has('dr-profile-backup-access')) note('Fix the profile backup first', [(byId(open, 'dr-profile-backup')[0] || byId(open, 'dr-profile-backup-access')[0]).detail, 'The post-deployment preflight reports the cause it knows.'].join(' '), cmd.postdeploy(cfg, false));
      if (has('dr-config') || has('dr-identity')) note('Take a configuration snapshot', 'It records what the Bicep doesn\'t hold (assignments, scaling schedules, drain state' + (has('dr-identity') ? ', and the AVD groups and their Conditional Access policies' : '') + '). Then copy it with the command it prints, so it counts.', cmd.exportConfig(cfg, has('dr-identity')));
      if (has('dr-tested')) note('Plan a recovery test', 'A tier only counts once a restore has been tested. This prints the plan and the estimate; nothing is created.', cmd.recoveryTest(cfg));
      if (has('dr-iac')) note('Deploy from a pushed commit', byId(open, 'dr-iac')[0].detail, '');
      if (!a.length) note('Recovery tier ' + (rv.tier || 'R0') + ' is not met', 'See the failures above.', '');
      return { step: 'recovery', actions: a };
    }
    if (S === 'cleanup') {
      // A Graph sign-in that timed out leaves the hosts' device objects (build/lessons/0029).
      var left = byId(warnings, 'devices-left'), lz = state.context && state.context.includeLandingZone;
      if (left.length) {
        var names = [].concat.apply([], left.map(function (w) { return (w.data && w.data.devices) || []; }));
        note('Finish the device cleanup', 'The Microsoft Graph step did not finish, so the device objects for ' + (names.join(', ') || 'the session hosts') + ' are still in Entra ID and Intune. ' +
          (lz ? 'Delete them there by hand.' : 'Run the cleanup again: it kept the demo deployment record, which names them. Open https://microsoft.com/devicelogin first, because the sign-in code lasts 120 seconds.'), lz ? '' : cmd.removeDemo(cfg));
      }
      if (state.context && state.context.includeLandingZone) note('The landing zone is removed', 'To deploy again, start with the pre-deployment preflight. The Key Vault name stays reserved for 90 days: change namePrefix to reuse the subscription sooner.', cmd.predeploy(cfg, false));
      else note('The demo is removed', 'The landing zone is untouched.', '');
      return { step: state.context && state.context.includeLandingZone ? 'predeploy' : 'signin', actions: a };
    }
    return { step: null, actions: a };
  }

  var STAGE_LABEL = { predeploy: 'Pre-deployment preflight', deploy: 'Deployment', postdeploy: 'Post-deployment setup', demo: 'Demo validation', cleanup: 'Cleanup', power: 'Auto shutdown', verify: 'Access check', resume: 'Where you left off', recovery: 'Recovery', rotation: 'Host rotation' };
  var STATUS_LABEL = { done: 'Done', ready: 'Ready', notready: 'Not ready', succeeded: 'Succeeded', failed: 'Failed', started: 'Still running (or disconnected)', whatif: 'What-if only', locked: 'Locked', resumed: 'Resumed', stopped: 'Stopped', verified: 'Verified', notverified: 'Not verified', unknown: 'Unknown', met: 'Met', notmet: 'Not met', passed: 'Passed', refused: 'Refused', waiting: 'Waiting' };

  /*
   * analyze(text, config, options) -> {
   *   recognized, stage, status, headline, source ('state' | 'text' | 'none'),
   *   problems [{what, fix}], failures [...], warnings [...],
   *   actions [{title, why, command}], step (next step id), config (updated with the run's context)
   * }
   * options.rankedRegions: regions ordered by measured latency, closest first.
   */
  function analyze(text, config, options) {
    text = String(text || '').replace(/\r\n/g, '\n');
    options = options || {};
    var cfg = merge(DEFAULTS, config);
    var states = extractStates(text).filter(function (s) { return !s.parseError; });
    var state = states.length ? states[states.length - 1] : inferFromText(text);
    var source = states.length ? 'state' : (state ? 'text' : 'none');
    var problems = shellProblems(text);

    // The context goes into the next commands, so its settings are checked like typed ones (red team PH-4);
    // the commit it carries is compared with this portal's, not merged.
    var checked = contextSettings(state && state.context);
    var stateCommit = state && state.context && isCommit(state.context.commit) ? String(state.context.commit).toLowerCase() : null;
    if (state && state.context) cfg = merge(cfg, checked.settings);
    if (state && state.context && checked.settings.parameterFile && !checked.settings.environment) cfg.environment = envFromFile(checked.settings.parameterFile) || cfg.environment;

    var result = { recognized: !!state || problems.length > 0, source: source, problems: problems, config: cfg, rejectedSettings: checked.rejected, failures: [], warnings: [], actions: [], stage: null, status: null, headline: '', step: options.currentStep || null,
      estimate: validEstimate(state && state.context && state.context.estimate), sizing: checked.settings.sizing || null,
      power: checked.settings.power || null,
      commit: { state: stateCommit, portal: isCommit(options.portalCommit) ? String(options.portalCommit).toLowerCase() : null }, versionNote: versionNote(stateCommit, options.portalCommit) };
    if (state) {
      var d = decide(state, cfg, { text: text, rankedRegions: options.rankedRegions });
      result.stage = state.stage; result.status = state.stage === 'cleanup' && state.status === 'ready' ? 'done' : state.status;
      result.failures = state.failures || []; result.warnings = state.warnings || [];
      result.actions = d.actions; result.step = d.step;
      result.headline = (STAGE_LABEL[state.stage] || state.stage) + ': ' + (STATUS_LABEL[result.status] || result.status) +
        (state.fix ? ' (fix mode)' : '') + (state.counts ? ' — ' + ['fail', 'warn', 'fixed', 'pass'].filter(function (k) { return state.counts[k]; }).map(function (k) { return state.counts[k] + ' ' + k; }).join(', ') : '');
    }
    // A shell problem means the step didn't really run: repeat the step we were on.
    if (problems.length && (!state || source === 'text' && !/Summary|deployed|Deploying/.test(text))) {
      // Repeat the command that was pasted (from its prompt line), else the step we were on.
      var ran = commandInText(text);
      var redo = ran && ran.removeDemo ? cmd.removeDemo(cfg) : rerunForStep(ran ? ran.step : (options.currentStep || 'predeploy'), cfg, ran ? ran.fix : undefined);
      if (ran && !state) result.step = ran.step;
      problems.forEach(function (p) {
        var command = p.id === 'graph-token' ? cmd.graphReset(cfg, redo) : (p.id === 'device-code' ? '' : redo);
        result.actions.unshift({ title: p.what, why: p.fix, command: command });
      });
      result.headline = result.headline || 'The step did not run to completion';
    }
    if (!result.recognized) {
      result.headline = 'No landing zone output found';
      result.actions = [{ title: 'Paste the whole output of the command', why: 'Include everything from the command to the prompt that follows it. The scripts end with a line starting <<<AVDLZ-STATE, which is what this page reads.', command: '' }];
    }
    return result;
  }

  // The scripts write their commit into the state line and the host writes the portal's into portal-config.js.
  // When both are known and differ, the portal may be behind the scripts (or a copy pinned to an older ref
  // runs newer scripts): say so, since a renamed parameter or a new state field would otherwise look like
  // a wrong command (red team PH-8). One may be the short form of the other.
  function versionNote(stateCommit, portalCommit) {
    if (!isCommit(stateCommit) || !isCommit(portalCommit)) return '';
    var a = String(stateCommit).toLowerCase(), b = String(portalCommit).toLowerCase();
    if (a.indexOf(b) === 0 || b.indexOf(a) === 0) return '';
    return 'This output came from the landing zone at commit ' + a.slice(0, 7) + ', but this portal was built from ' + b.slice(0, 7) +
      '. If the commands or the findings look wrong, reload the page (GitHub Pages) or republish the copy (Publish-AvdPortal.ps1) and paste the output again.';
  }

  function rerunForStep(step, cfg, fix) {
    switch (step) {
      case 'deploy': return cmd.deploy(cfg);
      case 'postdeploy': return cmd.postdeploy(cfg, fix === undefined ? true : fix);
      case 'signin': return cmd.demo(cfg);
      case 'verify': return cmd.verify(cfg);
      default: return cmd.predeploy(cfg, !!fix);
    }
  }

  // ---------------------------------------------------------------- verify access: reachability (decision 0014)
  // Concrete hosts from Microsoft's required endpoints for end-user devices
  // (https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint). Most of that list is
  // wildcards, which a browser can't probe; *.wvd.microsoft.com (feed, broker, gateway) is the important one.
  // Both are listed by name for end-user devices on that page (ms.date 2026-03-11, read 2026-10-06; spec §11 A1).
  var REACHABILITY_HOSTS = [
    { host: 'login.microsoftonline.com', purpose: 'Microsoft Entra ID sign-in' },
    { host: 'windows.cloud.microsoft', purpose: 'Web client and Windows App service' }
  ];
  var REACHABILITY_LIMITS = 'Reached means this browser, on this network, completed DNS, a connection and TLS to the host and got a response. ' +
    'It doesn\'t test sign-in, your access to the desktop, the feed and gateway hosts (*.wvd.microsoft.com, which can\'t be probed by name), ' +
    'UDP (RDP Shortpath), or the session host. A proxy that answers with its own block page also counts as reached. ' +
    'The time is to Microsoft\'s nearest front door, not to your session host\'s region.';

  // The latency step's rating, shared with the reachability probe.
  function rateLatency(ms) {
    if (ms === null || ms === undefined || isNaN(ms)) return { label: 'No answer', cls: 'muted' };
    if (ms < 100) return { label: 'Good', cls: 'good' };
    if (ms <= 150) return { label: 'Usable', cls: 'ok' };
    return { label: 'Sluggish', cls: 'poor' };
  }

  // results: [{ host, median }] from the page's probe; median is null when every request failed.
  // A host missing from results was not tested. Only all hosts reached is "reachable" (fail closed).
  function classifyReachability(results) {
    var list = Array.isArray(results) ? results : [];
    var hosts = REACHABILITY_HOSTS.map(function (h) {
      var r = list.filter(function (x) { return x && x.host === h.host; })[0];
      var tested = !!r, reached = tested && typeof r.median === 'number' && !isNaN(r.median);
      return { host: h.host, purpose: h.purpose, reached: tested ? reached : null, median: reached ? r.median : null, rating: rateLatency(reached ? r.median : null) };
    });
    var ok = hosts.filter(function (h) { return h.reached === true; }), tested = hosts.filter(function (h) { return h.reached !== null; });
    var failed = hosts.filter(function (h) { return h.reached !== true; }).map(function (h) { return h.host; });
    var o = { hosts: hosts, limits: REACHABILITY_LIMITS };
    if (!tested.length) {
      o.status = 'unknown'; o.headline = 'Not checked yet';
      o.guidance = 'Run the check from the device and network people will connect from.';
    } else if (ok.length === hosts.length) {
      o.status = 'reachable'; o.headline = 'This device reaches AVD\'s sign-in and client hosts';
      o.guidance = 'Next, open the desktop. A result here is a network check only; it doesn\'t show you can sign in.';
    } else if (ok.length) {
      o.status = 'partial'; o.headline = 'Some hosts didn\'t answer: ' + failed.join(', ');
      o.guidance = 'A warning, not a stop: you can still try the desktop. A firewall, proxy, DNS filter or content blocker may be stopping these hosts. If the desktop fails, your network must allow the AVD end-user endpoints: https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint';
    } else {
      o.status = 'blocked'; o.headline = 'No AVD host answered';
      o.guidance = 'A warning, not a stop: you can still try the desktop. A firewall, proxy, DNS filter, captive portal or content blocker is stopping requests to AVD from this browser. Try another network or turn off the blocker for this page. Your network must allow the AVD end-user endpoints: https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint';
    }
    return o;
  }

  // ---------------------------------------------------------------- verify access: launch link (decision 0014)
  // The web client's direct launch URL, from the workspace and desktop object IDs in the post-deployment
  // or demo state line (context.launch). The path, ?tenant= (for external identities) and #loginHint=
  // ("only work[s] if it is at the end of the URL"; without the tenant parameter for internal identities) are
  // from https://learn.microsoft.com/windows-app/direct-launch-urls (ms.date 2026-09-09, read 2026-10-06; spec §11 A2).
  // A pasted state line is untrusted input: the IDs must be GUIDs, so the link can only point at
  // windows.cloud.microsoft, and a login hint must look like a UPN with nothing that could end the URL part.
  var GUID = /^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  var WEB_CLIENT = 'https://windows.cloud.microsoft';
  function launchTarget(launch) {
    if (!launch || typeof launch !== 'object' || !GUID.test(launch.workspaceObjectId || '') || !GUID.test(launch.desktopObjectId || '')) return null;
    var t = { workspaceObjectId: launch.workspaceObjectId, desktopObjectId: launch.desktopObjectId };
    if (GUID.test(launch.tenantId || '')) t.tenantId = launch.tenantId;
    ['workspace', 'appGroup'].forEach(function (k) { if (typeof launch[k] === 'string' && /^[A-Za-z0-9._-]{1,80}$/.test(launch[k])) t[k] = launch[k]; });
    return t;
  }
  function launchUrl(launch, opts) {
    opts = opts || {};
    var t = launchTarget(launch);
    if (!t) return null;
    var url = WEB_CLIENT + '/webclient/avd/' + t.workspaceObjectId + '/' + t.desktopObjectId;
    if (opts.tenant && t.tenantId) url += '?tenant=' + t.tenantId;
    if (opts.loginHint && /^[^\s@#?&\/%'"<>]+@[^\s@#?&\/%'"<>]+\.[^\s@#?&\/%'"<>]+$/.test(opts.loginHint)) url += '#loginHint=' + opts.loginHint;
    return url;
  }

  // The first command for someone who has not run anything yet.
  function firstStep(config) {
    var cfg = merge(DEFAULTS, config);
    return { title: 'Run the pre-deployment preflight', why: 'Checks that the subscription and tenant are ready for the landing zone in ' + cfg.location + '. It asks for a Microsoft Graph device code. Paste its output here afterwards.', command: cmd.predeploy(cfg, false) };
  }

  // What to run at a given step when there is no pasted output to go on (e.g. picked in the tracker).
  function actionsForStep(step, config) {
    var cfg = merge(DEFAULTS, config);
    switch (step) {
      case 'region': return [{ title: 'Measure latency from where your users work', why: 'Run the test below from your users\' network (not over a VPN), then use the closest region. The preflight confirms the region offers AVD host pools.', command: '' }];
      case 'size': return [{ title: 'Size the host pool', why: 'Choose the number of hosts and their size, or let the portal size them from how many people use them and how they work. The commands then check quota and availability for that size.', command: '' }];
      case 'cost': return [{ title: 'Choose how the hosts are powered', why: 'Start VM on Connect and the scheduled stop decide how many hours the hosts run, which is most of the cost. The pre-deployment preflight prices the plan for ' + cfg.location + ' at Azure list prices; after that, changing a setting here reprices it.', command: '' },
        firstStep(cfg)];
      case 'predeploy': return [firstStep(cfg)];
      case 'deploy': return [{ title: 'Deploy the landing zone', why: 'Run this once the pre-deployment preflight is Ready. It takes 30-45 minutes and keeps running in Azure if Cloud Shell disconnects.', command: cmd.deploy(cfg) },
        { title: 'Already started? Check on it', why: 'Shows the latest deployment and any failed resources.', command: cmd.deployStatus(cfg) }];
      case 'postdeploy': return [{ title: 'Run the post-deployment setup', why: 'Admin consent for the storage app, the Conditional Access exclusion and the profile share permissions. It asks for a Microsoft Graph device code.', command: cmd.postdeploy(cfg, true) }];
      case 'signin': return [{ title: 'Sign in to the desktop', why: 'Open https://windows.cloud.microsoft (or the Windows App) as a member of ' + cfg.usersGroup + '. The next step, Verify access, checks this device can reach AVD.', command: '' },
        { title: 'Optional: validate sign-in with a demo host pool', why: 'Deploys a separate demo host pool and checks the host and your test user.', command: cmd.demo(cfg) },
        { title: 'Optional: Well-Architected review', why: 'Reviews the deployed landing zone by pillar. Findings are warnings; no Graph sign-in needed.', command: cmd.wellArchitected(cfg) }];
      case 'verify': return [{ title: 'Open the desktop', why: 'After the reachability check, open ' + (launchTarget(cfg.launch) ? 'the desktop with the link above' : 'https://windows.cloud.microsoft') + ' (or the Windows App) and sign in as a member of ' + cfg.usersGroup +
        '. New group members can take up to an hour to see the desktop. The notes above say what to expect on the first connection.', command: '' },
        { title: 'Then confirm it from Azure telemetry', why: 'Once you see the desktop, or the client gives up, run this. It reads the connection logs for your account, waits up to 15 minutes for them to arrive, and says Verified, Failed or Not verified. Only Verified is a pass.', command: cmd.verify(cfg) }];
      default: return [firstStep(cfg)];
    }
  }

  // The steps of a recorded run, in order, for the portal's Record this run panel.
  function recordActions(cfg) {
    var r = recording(cfg); if (!r) return [];
    var store = r.mode === 'azure';
    var a = [
      { title: 'Open the run', why: 'Before the pre-deployment preflight. Prices the run from the parameter file at list prices and refuses if the total is more than half the cap or a line has no price. Writes run.json and cost.json to the run folder' + (store ? ' in the run store (set it up once with Initialize-AvdRunStore.ps1)' : ' in Cloud Shell') + '.', command: cmd.recordStart(cfg) },
      { title: 'Before cleanup: keep the logs', why: 'Cleanup deletes the Log Analytics workspace, the only copy of the AVD logs. This exports them into the run folder and checks the row counts first.', command: cmd.recordStop(cfg, 'before-cleanup') },
      { title: 'After cleanup: close the run', why: store ? 'Records how the run ended and the first actual cost reading. Cost Management can take a day or more to settle.' : 'Records how the run ended. Cloud Shell only reads no actual cost; turn on the run store for that.', command: cmd.recordStop(cfg, 'end') },
      { title: 'Copy it to your private repo', why: 'Needs AVD_PRIVATE_REPO set to a private repository of yours and the GitHub CLI signed in (gh auth login, device code). Every file is read back and checked. It refuses a public repository.', command: cmd.recordStop(cfg, 'copy') }
    ];
    if (store) a.push({ title: 'Later: read the cost again', why: 'Appends another actual cost reading; the cost settles once it is unchanged for 72 hours. A cost on the landing zone after the day of cleanup is flagged as still billing.', command: cmd.recordStop(cfg, 'cost') });
    return a;
  }

  return { STEPS: STEPS, newRunId: newRunId, recording: recording, recordActions: recordActions, DEFAULTS: DEFAULTS, isRepoUrl: isRepoUrl, isRef: isRef, isCommit: isCommit, siteConfig: siteConfig, SETTINGS: SETTINGS, SETTING_NAMES: SETTING_NAMES, validSettings: validSettings, contextSettings: contextSettings, validSizing: validSizing, validPower: validPower, validEstimate: validEstimate, versionNote: versionNote, WORKLOADS: WORKLOADS, VM_SIZES: VM_SIZES, HOST_POOL_DEFAULTS: HOST_POOL_DEFAULTS, MAX_HOST_POOLS: MAX_HOST_POOLS, MAX_HOSTS: MAX_HOSTS, computePool: computePool, toSizing: toSizing, powerDefaults: powerDefaults, effectivePower: effectivePower, hostHours: hostHours, repriceEstimate: repriceEstimate, pricedHours: pricedHours, analyze: analyze, extractStates: extractStates, firstStep: firstStep, actionsForStep: actionsForStep, commands: cmd, psQuote: psQuote,
    PLATFORMS: PLATFORMS, RUNIN_DEFAULT: RUNIN_DEFAULT, PLACES: PLACES, validRunIn: validRunIn, isDefaultRunIn: isDefaultRunIn, scriptsIn: scriptsIn, support: support, forRunIn: forRunIn,
    REACHABILITY_HOSTS: REACHABILITY_HOSTS, rateLatency: rateLatency, classifyReachability: classifyReachability, launchTarget: launchTarget, launchUrl: launchUrl };
});
