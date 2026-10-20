/*
 * Deployment portal issue reports: redaction and the prefilled GitHub issue.
 * Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
 *
 * Runs in the browser (window.PortalReport) and in Node (module.exports) so the redaction is
 * tested against real Cloud Shell output (build/tests/portal/report.test.mjs). Nothing here touches
 * the network: the page opens github.com/<repo>/issues/new with the redacted report filled in,
 * and the operator reviews it and submits it themselves (build/decisions/0008).
 *
 * Redaction replaces each distinct value with a numbered placeholder (<email-1>, <id-2>, ...)
 * so a report still shows which values match, without showing them.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.PortalReport = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // IDs that are the same in every tenant (built-in roles, first-party apps) and help diagnosis.
  // build/tests/portal/report.test.mjs checks that every GUID in bicep/ and scripts/ is listed here.
  var PUBLIC_IDS = [
    '00000000-0000-0000-0000-000000000000',
    '00000003-0000-0000-c000-000000000000', // Microsoft Graph
    '0000000a-0000-0000-c000-000000000000', // Intune
    '9cdead84-a844-4324-93f2-b2e6bb768d07', // Azure Virtual Desktop
    '14d82eec-204b-4c2f-b7e8-296a70dab67e', // Microsoft Graph Command Line Tools (the Graph SDK's default app)
    '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb',
    '1c0163c0-47e6-4577-8991-ea5c82e286e4',
    '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63',
    '40c5ff49-9181-41f8-ae61-143b0e78555e',
    '4633458b-17de-408a-b874-0445c86b69e6',
    '4a9ae827-6dc8-4573-8ac7-8239d42aa03f',
    'a7264617-510b-434b-a828-9731dc254ea7',
    'e56962a6-4747-49cd-b67b-bf8b01975c4c',
    'e765b5de-1225-4ba3-bd56-1ac6695af988',
    'ea3f2387-9b95-492a-a190-fcdc54f7b070',
    'fb879df8-f326-4884-b1cf-06f3ad86be52',
    '082f0a83-3be5-4ba1-904c-961cca79b387', // Desktop Virtualization Contributor
    'd3881f73-407a-4167-8283-e981cbba0404', // Automation Operator
    'b24988ac-6180-42a0-ab88-20f7382dd24c', // Contributor
    'acdd72a7-3385-48ef-bd42-f606fba81ae7', // Reader
    '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1', // Storage Blob Data Reader
    // Entra directory role templates (group owner check in the preflight and deploy.sh)
    '62e90394-69f5-4237-9190-012177145e10', // Global Administrator
    'e8611ab8-c189-46e8-94e1-60213ab1f814', // Privileged Role Administrator
    'fdd7a751-b60b-444a-984c-02652fe8fa1c', // Groups Administrator
    'fe930be7-5e62-47db-91af-98c3a49a38b1', // User Administrator
    // Windows policy registry keys in WDOT's profile (scripts/image/wdot/profile/PolicyRegSettings.json)
    '309dce9b-bef4-4119-9921-a851fb12f0f4',
    '67144949-5132-4859-8036-a737b43825d8',
    'eb73b633-3f4e-4ba0-8f60-8f3c6f53168f',
    '9c5a40da-b965-4fc3-8781-88dd50a6299d',
    '3af8b24a-c441-4fa4-8c5c-bed591bfa867',
    '2698178d-fdad-40ae-9d3c-1371703adc5b',
    'ffc42108-4920-4acf-a4fc-8abdcc68ada4',
    'a7a5847a-7511-4e4e-90b1-45ad2a002f51'
  ];
  // Values the repo ships with: not private, and keeping them keeps reports readable.
  var DEFAULT_VALUES = ['avdlz', 'avd users', 'avd admins', 'dev', 'test', 'prod', 'northcentralus'];
  // Domains that are not the operator's.
  var PUBLIC_DOMAINS = ['microsoft.com', 'windows.net', 'azure.com', 'azure.net', 'contoso.com', 'example.com', 'github.com', 'github.io', 'cloud.microsoft', 'microsoftonline.com'];

  var LABELS = {
    secret: 'secret or token', email: 'email address / UPN', domain: 'domain', tenant: 'tenant name', id: 'ID',
    subscription: 'subscription name', storage: 'storage account', vault: 'key vault', ip: 'public IP address',
    user: 'user name in a path', name: 'name from your settings', custom: 'term you added'
  };

  function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  /*
   * redact(text, options) -> { text, counts {kind: n}, total }
   * options.known: [{ kind, value }] values from the operator's settings (name prefix, groups, ...)
   * options.extraTerms: [string] anything else the operator wants removed
   * options.level: 'public' (default, everything above) or 'private' (secrets only: what the run
   *   journal keeps in the operator's own tenant, build/specs/run-recorder-spec.md section 5)
   */
  function redact(text, options) {
    options = options || {};
    text = String(text || '');
    var counts = {}, maps = {}, offset = {}, pm, placeholderRe = /<([a-z]+)-(\d+)>/g;
    // Text that was redacted before (an edited report): number new values after the old ones.
    while ((pm = placeholderRe.exec(text)) !== null) offset[pm[1]] = Math.max(offset[pm[1]] || 0, Number(pm[2]));
    function count(kind) { counts[kind] = (counts[kind] || 0) + 1; }
    function token(kind, value) {
      var m = maps[kind] = maps[kind] || {}, key = String(value).toLowerCase();
      if (!m[key]) m[key] = '<' + kind + '-' + ((offset[kind] || 0) + Object.keys(m).length + 1) + '>';
      count(kind);
      return m[key];
    }
    function fixed(kind, placeholder) { return function () { count(kind); return placeholder; }; }
    function replaceTerms(kind, values) {
      values.filter(function (v, i, a) { return v && v.length >= 3 && a.indexOf(v) === i && DEFAULT_VALUES.indexOf(v.toLowerCase()) < 0 && !/^<[a-z]+-\d+>$/.test(v); })
        .sort(function (a, b) { return b.length - a.length; })
        .forEach(function (v) {
          // Short values only as whole words, so a 3-letter prefix does not eat ordinary words.
          var re = v.length < 5 ? new RegExp('(^|[^A-Za-z0-9])(' + escapeRe(v) + ')(?![A-Za-z0-9])', 'gi') : new RegExp('()(' + escapeRe(v) + ')', 'gi');
          text = text.replace(re, function (all, pre, hit) { return pre + token(kind, hit); });
        });
    }

    // 1. Secrets: gone entirely, never numbered.
    text = text
      .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g, fixed('secret', '<token>'))
      .replace(/\b(Bearer\s+)[A-Za-z0-9._~+\/=-]{16,}/gi, function (a, p) { count('secret'); return p + '<token>'; })
      .replace(/([?&]sig=)(?!<)[^&\s"']+/gi, function (a, p) { count('secret'); return p + '<secret>'; })
      .replace(/(AccountKey=)(?!<)[^;\s"']+/gi, function (a, p) { count('secret'); return p + '<secret>'; })
      .replace(/((?:password|passwd|pwd|secret|client_secret|apikey|api_key)["']?\s*[=:]\s*["']?)(?!<)[^\s"',;]+/gi, function (a, p) { count('secret'); return p + '<secret>'; })
      .replace(/(enter the code\s+)[A-Z0-9]{6,12}\b/gi, function (a, p) { count('secret'); return p + '<device-code>'; })
      .replace(/[A-Za-z0-9+\/]{40,}={0,2}/g, function (s) {
        // Keys and tokens: long, mixed-case, with digits. Paths (with / between words) are not.
        var keyLike = /[0-9]/.test(s) && /[a-z]/.test(s) && /[A-Z]/.test(s) && (/=$/.test(s) || !/\//.test(s));
        if (!keyLike) return s;
        count('secret'); return '<secret>';
      });

    // Private level (run recorder spec section 5): secrets only, for what stays in the operator's own tenant.
    if (options.level === 'private') return finish();

    // 2. The operator's own terms and settings.
    replaceTerms('custom', (options.extraTerms || []).map(function (t) { return String(t).trim(); }));
    var known = (options.known || []).slice();
    // The state line carries the run's settings: redact them wherever else they appear.
    var stateRe = /<<<AVDLZ-STATE\s*([\s\S]*?)\s*AVDLZ-STATE>>>/g, sm;
    while ((sm = stateRe.exec(text)) !== null) {
      try {
        var c = JSON.parse(sm[1].replace(/\n/g, '')).context || {};
        ['namePrefix', 'usersGroup', 'adminsGroup', 'testUserUpn', 'storageAccount'].forEach(function (k) {
          if (typeof c[k] === 'string') known.push({ kind: k === 'storageAccount' ? 'storage' : 'name', value: c[k] });
        });
      }
      catch (e) { /* a broken state line: the patterns below still apply */ }
    }
    // Emails are handled below; a UPN in the settings is still an email.
    replaceTerms('storage', known.filter(function (k) { return k.kind === 'storage'; }).map(function (k) { return k.value; }));
    replaceTerms('name', known.filter(function (k) { return k.kind !== 'storage' && !/@/.test(k.value || ''); }).map(function (k) { return String(k.value || '').trim(); }));

    // 3. Emails and UPNs (guest UPNs contain #EXT#), then their domains wherever else they appear.
    var domains = [];
    text = text.replace(/[A-Za-z0-9._%+#-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})\b/g, function (all, domain) {
      var d = domain.toLowerCase();
      if (!/onmicrosoft\.com$/.test(d) && PUBLIC_DOMAINS.indexOf(d) < 0 && domains.indexOf(d) < 0) domains.push(d);
      return token('email', all);
    });
    text = text.replace(/\b([A-Za-z0-9-]+)(\.onmicrosoft\.com)\b/gi, function (all, t, rest) { return token('tenant', t) + rest; });
    replaceTerms('domain', domains);

    // 4. Subscription names (printed in quotes by the scripts, and in the state line's data).
    var subs = [];
    [/^AVD [^\n]* - [^\n]* in '([^'\n]+)'/gm, /subscription '([^'\n]+)'/gi, /"subscription"\s*:\s*"([^"\n]+)"/g, /Subscription:\s+(.+)$/gm].forEach(function (re) {
      var m; while ((m = re.exec(text)) !== null) if (!/^</.test(m[1].trim())) subs.push(m[1].trim());
    });
    // A subscription name can be anything, so only replace it in the places it was found.
    subs.filter(function (v, i, a) { return a.indexOf(v) === i; }).forEach(function (v) {
      var t = token('subscription', v); counts.subscription--;
      [new RegExp("^(AVD [^\\n]* - [^\\n]* in ')" + escapeRe(v) + "(')", 'gm'), new RegExp("(subscription ')" + escapeRe(v) + "(')", 'gi'), new RegExp('("subscription"\\s*:\\s*")' + escapeRe(v) + '(")', 'g'), new RegExp('(Subscription:\\s+)' + escapeRe(v) + '()', 'g')]
        .forEach(function (re) { text = text.replace(re, function (a, p, s) { count('subscription'); return p + t + s; }); });
    });

    // 5. Globally unique resource names: storage accounts and key vaults (st/kv + prefix + env + suffix),
    //    and their host names. Private endpoint zones (privatelink.*) are the same everywhere.
    text = text
      .replace(/\b(?!privatelink\b)([a-z0-9]{3,24})(\.(?:file|blob|queue|table|dfs|web)\.core\.windows\.net)\b/g, function (a, n, rest) { return token('storage', n) + rest; })
      .replace(/\b(?!privatelink\b)([a-z0-9-]{3,24})(\.vault\.azure\.net)\b/g, function (a, n, rest) { return token('vault', n) + rest; })
      .replace(/\bst[a-z0-9]{0,15}?(?:dev|test|prod)[a-z0-9]{4,}\b/g, function (n) { return token('storage', n); })
      .replace(/\bkv[a-z0-9]{0,15}?(?:dev|test|prod)[a-z0-9]{4,}\b/g, function (n) { return token('vault', n); });

    // 6. IDs (subscription, tenant, object): all GUIDs except the public ones.
    text = text.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, function (g) {
      return PUBLIC_IDS.indexOf(g.toLowerCase()) >= 0 ? g : token('id', g);
    });

    // 7. Public IPv4 addresses. Private ranges and Azure's platform addresses help diagnosis.
    text = text.replace(/\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g, function (ip, a, b, c, d) {
      var o = [a, b, c, d].map(Number);
      if (o.some(function (x) { return x > 255; })) return ip;
      var priv = o[0] === 10 || o[0] === 127 || o[0] === 0 || (o[0] === 172 && o[1] >= 16 && o[1] <= 31) || (o[0] === 192 && o[1] === 168) ||
        (o[0] === 169 && o[1] === 254) || (o[0] === 100 && o[1] >= 64 && o[1] <= 127) || ip === '168.63.129.16';
      return priv ? ip : token('ip', ip);
    });

    // 8. User names in home paths.
    text = text
      .replace(/(\/home\/)(?!<)([A-Za-z0-9._-]+)/g, function (a, p, u) { return p + token('user', u); })
      .replace(/([A-Za-z]:\\Users\\)(?!<)([^\\\s"']+)/g, function (a, p, u) { return p + token('user', u); });

    return finish();

    function finish() {
      var total = 0; Object.keys(counts).forEach(function (k) { if (counts[k] > 0) total += counts[k]; else delete counts[k]; });
      return { text: text, counts: counts, total: total };
    }
  }

  function describe(counts) {
    var keys = Object.keys(counts || {});
    if (!keys.length) return 'Nothing found to redact.';
    return 'Redacted ' + keys.map(function (k) { return counts[k] + ' × ' + (LABELS[k] || k); }).join(', ') + '.';
  }

  // A code fence longer than any backtick run in the text, so pasted output can't close it.
  function fence(text) {
    var longest = 2; (String(text).match(/`+/g) || []).forEach(function (r) { longest = Math.max(longest, r.length); });
    return new Array(longest + 2).join('`');
  }

  /*
   * buildReport({ output, description, analysis, step, config, extraTerms }) -> { title, body, redaction }
   * Everything that goes into the report passes through redact().
   */
  function buildReport(input) {
    input = input || {};
    var cfg = input.config || {}, a = input.analysis || null;
    var known = ['namePrefix', 'usersGroup', 'adminsGroup', 'testUserUpn'].map(function (k) { return { kind: 'name', value: cfg[k] }; })
      .concat([{ kind: 'storage', value: cfg.storageAccount }]);
    var opts = { known: known, extraTerms: input.extraTerms || [] };

    var lines = [];
    lines.push('### What happened', '', String(input.description || '').trim() || '_No description given._', '');
    lines.push('### Portal', '');
    lines.push('- Step: ' + (input.step || 'none'));
    if (cfg.location || cfg.parameterFile) lines.push('- Settings: ' + [cfg.parameterFile, cfg.location, cfg.environment].filter(Boolean).join(', '));
    if (a) {
      lines.push('- Read the output from: ' + ({ state: 'state line', text: 'text (no state line)', none: 'nothing recognized' }[a.source] || a.source));
      if (a.headline) lines.push('- Analysis: ' + a.headline);
      var ids = (a.failures || []).concat(a.warnings || []).map(function (f) { return f.id || f.check; }).filter(Boolean);
      if (ids.length) lines.push('- Findings: ' + ids.join('; '));
      if (a.problems && a.problems.length) lines.push('- Problems: ' + a.problems.map(function (p) { return p.id; }).join(', '));
      if (a.actions && a.actions.length) lines.push('- Suggested next: ' + a.actions.map(function (x) { return x.title; }).join('; '));
    }
    lines.push('');
    var output = String(input.output || '').replace(/\r\n/g, '\n').replace(/\s+$/, '');
    if (output) {
      var f = fence(output);
      lines.push('### Cloud Shell output', '', f + 'text', output, f, '');
    }
    lines.push('<!-- avdlz-portal-report v1 -->', '_Sent from the deployment portal. Redacted in the reporter\'s browser before submitting; check before copying anything from it into the repo._');

    var r = redact(lines.join('\n'), opts);
    var title = redact('Portal: ' + (a && a.headline ? a.headline : 'problem at step ' + (input.step || 'unknown')), opts).text;
    return { title: title.slice(0, 120), body: r.text, redaction: r };
  }

  /*
   * issueUrl(repoUrl, title, body, maxLength) -> { url, trimmed }
   * GitHub rejects very long URLs, so the middle of a long body is cut, keeping the start (the
   * description and analysis) and the end (the output's last lines and state line).
   */
  function issueUrl(repoUrl, title, body, maxLength) {
    maxLength = maxLength || 7500;
    var base = String(repoUrl).replace(/\/+$/, '') + '/issues/new?labels=portal-report&title=' + encodeURIComponent(title) + '&body=';
    if ((base + encodeURIComponent(body)).length <= maxLength) return { url: base + encodeURIComponent(body), trimmed: 0 };
    var all = body.split('\n'), head = Math.min(all.length, 30);
    var fits = function (tail) {
      var cut = all.length - head - tail;
      var b = all.slice(0, head).concat(['[... ' + cut + ' lines cut to fit a GitHub link. Paste the copied full report here if they matter ...]'], all.slice(all.length - tail)).join('\n');
      return (base + encodeURIComponent(b)).length <= maxLength ? b : null;
    };
    // Keep as much of the end as fits.
    var lo = 0, hi = all.length - head, best = fits(0);
    if (best === null) { head = 8; best = fits(0); }
    while (lo < hi) {
      var mid = Math.ceil((lo + hi) / 2), b = fits(mid);
      if (b !== null) { best = b; lo = mid; } else hi = mid - 1;
    }
    return { url: base + encodeURIComponent(best || ''), trimmed: all.length - head - lo };
  }

  return { redact: redact, describe: describe, buildReport: buildReport, issueUrl: issueUrl, PUBLIC_IDS: PUBLIC_IDS };
});
