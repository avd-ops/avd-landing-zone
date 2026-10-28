// Browser and DOM integration tests for the deployment portal Control Planes selector
// (avd-ops decision 0009 Phase 5).
// Run: node --test "build/tests/portal/portal-browser.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const read = (f) => readFileSync(join(root, f), 'utf8');

function fullText(el) {
  if (!el) return '';
  let out = el.textContent || '';
  if (Array.isArray(el.children)) {
    for (const c of el.children) out += fullText(c);
  }
  return out;
}

function createPortalDomHarness(initialStorage = {}) {
  const html = read('site/portal/index.html');
  const reportSrc = read('site/portal/report.js');
  const coreSrc = read('site/portal/portal-core.js');
  const pageSrc = read('site/portal/portal-page.js');

  const elements = new Map();
  const storage = new Map(Object.entries(initialStorage));

  function makeElement(id, tag = 'div') {
    const listeners = {};
    const attrs = new Map();
    const classSet = new Set();
    let textVal = '';
    const el = {
      id,
      tagName: tag.toUpperCase(),
      value: '',
      checked: false,
      disabled: false,
      hidden: false,
      open: false,
      innerHTML: '',
      dataset: {},
      style: {},
      options: [],
      children: [],
      parentNode: { title: '', classList: { add() {}, remove() {}, toggle() {} } },
      get textContent() { return textVal; },
      set textContent(v) {
        textVal = String(v ?? '');
        if (textVal === '') el.children = [];
      },
      classList: {
        add: (...names) => names.forEach((n) => classSet.add(n)),
        remove: (...names) => names.forEach((n) => classSet.delete(n)),
        toggle: (n, force) => {
          const on = force === undefined ? !classSet.has(n) : Boolean(force);
          if (on) classSet.add(n); else classSet.delete(n);
          return on;
        },
        contains: (n) => classSet.has(n)
      },
      setAttribute(k, v) {
        attrs.set(k, String(v));
        if (k === 'class') {
          classSet.clear();
          String(v).split(/\s+/).filter(Boolean).forEach((c) => classSet.add(c));
        }
      },
      getAttribute(k) { return attrs.has(k) ? attrs.get(k) : null; },
      removeAttribute(k) { attrs.delete(k); },
      addEventListener(type, fn) {
        (listeners[type] ||= []).push(fn);
      },
      dispatchEvent(evt) {
        const list = listeners[evt.type] || [];
        for (const fn of list) fn.call(el, evt);
      },
      click() {
        if (el.type === 'checkbox') {
          el.checked = !el.checked;
          el.dispatchEvent({ type: 'change', target: el, preventDefault() {} });
        }
        el.dispatchEvent({ type: 'click', target: el, preventDefault() {} });
      },
      focus() {},
      scrollIntoView() {},
      scrollTo() {},
      getBoundingClientRect() { return { top: 100, bottom: 200, left: 0, right: 800, width: 800, height: 100 }; },
      offsetLeft: 0,
      offsetHeight: 600,
      offsetWidth: 800,
      scrollLeft: 0,
      appendChild(child) {
        if (child && typeof child === 'object') child.parentNode = el;
        el.children.push(child);
        if (el.tagName === 'SELECT' && child?.tagName === 'OPTION') el.options.push(child);
        return child;
      },
      querySelector(sel) {
        if (sel.startsWith('#')) return getEl(sel.slice(1));
        return makeElement(sel);
      },
      querySelectorAll(sel) {
        if (sel === 'button[data-step]') return el.children;
        return [];
      }
    };
    return el;
  }

  function getEl(id) {
    if (!elements.has(id)) {
      const tagMatch = html.match(new RegExp(`<([a-z0-9-]+)[^>]*\\bid="${id}"[^>]*>`, 'i'));
      const tag = tagMatch ? tagMatch[1] : 'div';
      const el = makeElement(id, tag);
      if (tagMatch) {
        const openTag = tagMatch[0];
        if (/\btype="checkbox"/i.test(openTag)) el.type = 'checkbox';
        if (/\bchecked\b/i.test(openTag)) el.checked = true;
        if (/\bhidden\b/i.test(openTag)) el.hidden = true;
        const valMatch = openTag.match(/\bvalue="([^"]*)"/i);
        if (valMatch) el.value = valMatch[1];
        const stepMatch = openTag.match(/\bdata-step="([^"]*)"/i);
        if (stepMatch) el.setAttribute('data-step', stepMatch[1]);
      }
      elements.set(id, el);
    }
    return elements.get(id);
  }

  for (const [, id] of html.matchAll(/\bid="([^"]+)"/g)) getEl(id);

  const slideEls = [];
  for (const [openTag, stepId] of html.matchAll(/<section[^>]*\bclass="[^"]*\bslide\b[^"]*"[^>]*\bdata-step="([^"]+)"[^>]*>/gi)) {
    const idMatch = openTag.match(/\bid="([^"]+)"/i);
    const sl = idMatch ? getEl(idMatch[1]) : makeElement(`slide-${stepId}`, 'section');
    sl.setAttribute('data-step', stepId);
    const slotEl = makeElement(`slot-${stepId}`, 'div');
    const h2NumEl = makeElement(`n-${stepId}`, 'span');
    sl.querySelector = (sel) => {
      if (sel === '.slot') return slotEl;
      if (sel === 'h2 .n') return h2NumEl;
      return makeElement(sel);
    };
    slideEls.push(sl);
  }

  const docListeners = {};
  const document = {
    documentElement: makeElement('html', 'html'),
    activeElement: null,
    getElementById: (id) => getEl(id),
    querySelector: (sel) => (sel.startsWith('#') ? getEl(sel.slice(1)) : makeElement(sel)),
    querySelectorAll: (sel) => (sel === '#track > .slide' ? slideEls : []),
    createElement: (tag) => makeElement('', tag),
    createTextNode: (t) => ({ textContent: String(t ?? ''), children: [] }),
    addEventListener(type, fn) { (docListeners[type] ||= []).push(fn); }
  };

  const localStorage = {
    getItem: (k) => (storage.has(k) ? storage.get(k) : null),
    setItem: (k, v) => storage.set(k, String(v)),
    removeItem: (k) => storage.delete(k)
  };

  const windowObj = {
    document,
    localStorage,
    navigator: { clipboard: { writeText: async () => {} } },
    location: { href: 'http://127.0.0.1/portal/index.html', hostname: '127.0.0.1', pathname: '/portal/index.html', hash: '' },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    addEventListener() {},
    scrollTo() {},
    setTimeout: (fn) => { fn(); return 1; },
    clearTimeout() {}
  };
  windowObj.window = windowObj;
  windowObj.globalThis = windowObj;

  const context = vm.createContext(windowObj);
  vm.runInContext(reportSrc, context, { filename: 'report.js' });
  vm.runInContext(coreSrc, context, { filename: 'portal-core.js' });
  vm.runInContext(pageSrc, context, { filename: 'portal-page.js' });

  return { html, elements, getEl, localStorage, AvdPortal: windowObj.AvdPortal };
}

test('portal HTML declares the Control Planes panel, presets, and all 5 control-plane checkboxes', () => {
  const html = read('site/portal/index.html');
  assert.match(html, /id="control-planes-panel"/);
  assert.match(html, /id="cp-preset-greenfield"[^>]*>Greenfield (?:&mdash;|—) all 5 control planes<\/button>/);
  assert.match(html, /id="cp-preset-brownfield"[^>]*>Brownfield (?:&mdash;|—) Entra \+ Intune \+ Azure<\/button>/);
  assert.match(html, /id="cp-preset-azure"[^>]*>Azure only<\/button>/);
  for (const id of ['cp-entra', 'cp-intune', 'cp-m365', 'cp-azure', 'cp-powerPlatform']) {
    assert.match(html, new RegExp(`id="${id}"`), `checkbox ${id} exists in index.html`);
  }
  for (const sha of ['3a6132c', 'f64c56a', 'f18b14f', 'ac01bc4', '4543356']) {
    assert.match(html, new RegExp(`@${sha}<\\/code>`), `pinned commit ${sha} shown in index.html`);
  }
});

test('portal UI: Greenfield and Brownfield presets update checkboxes, summary, and standalone Cloud Shell commands', () => {
  const { getEl, localStorage } = createPortalDomHarness({
    'avdlz.portal.step': JSON.stringify('deploy'),
    'avdlz.portal.reachedStep': JSON.stringify('deploy')
  });

  // Click "Greenfield — all 5 control planes"
  getEl('cp-preset-greenfield').click();
  assert.equal(getEl('cp-entra').checked, true);
  assert.equal(getEl('cp-intune').checked, true);
  assert.equal(getEl('cp-m365').checked, true);
  assert.equal(getEl('cp-azure').checked, true);
  assert.equal(getEl('cp-powerPlatform').checked, true);
  assert.equal(getEl('cp-summary').textContent, 'Greenfield — all 5 control planes');
  const greenfieldActions = fullText(getEl('actions'));
  assert.match(greenfieldActions, /Invoke-AvdControlPlanes\.ps1 -Planes 'entra,intune,m365,azure,power-platform'/);
  assert.match(greenfieldActions, /Deploy-AvdEntra\.ps1/);
  assert.match(greenfieldActions, /Deploy-AvdPowerPlatform\.ps1/);

  // Click "Brownfield — Entra + Intune + Azure"
  getEl('cp-preset-brownfield').click();
  assert.equal(getEl('cp-entra').checked, true);
  assert.equal(getEl('cp-intune').checked, true);
  assert.equal(getEl('cp-m365').checked, false);
  assert.equal(getEl('cp-azure').checked, true);
  assert.equal(getEl('cp-powerPlatform').checked, false);
  assert.equal(getEl('cp-summary').textContent, 'Brownfield — Entra + Intune + Azure');
  const brownfieldActions = fullText(getEl('actions'));
  assert.match(brownfieldActions, /Invoke-AvdControlPlanes\.ps1 -Planes 'entra,intune,azure'/);
  assert.doesNotMatch(brownfieldActions, /Deploy-AvdPowerPlatform\.ps1/);

  const savedCp = JSON.parse(localStorage.getItem('avdlz.portal.controlPlanes'));
  assert.deepEqual(savedCp, {
    entra: true,
    intune: true,
    m365: false,
    azure: true,
    powerPlatform: false
  });

  // Click "Azure only"
  getEl('cp-preset-azure').click();
  assert.equal(getEl('cp-entra').checked, false);
  assert.equal(getEl('cp-azure').checked, true);
  assert.equal(getEl('cp-summary').textContent, 'Azure only');
});

test('portal UI: pasting <<<AVDLZ-STATE ... AVDLZ-STATE>>> from Invoke-AvdControlPlanes.ps1 updates the step and actions', () => {
  const { getEl } = createPortalDomHarness({
    'avdlz.portal.step': JSON.stringify('deploy'),
    'avdlz.portal.reachedStep': JSON.stringify('deploy')
  });

  const stateLine = '<<<AVDLZ-STATE {"v":1,"stage":"controlplanes","teardown":false,"planes":["entra","intune","azure"],"completedPlanes":["entra","intune","azure"],"nextPlane":null,"failedPlane":null,"status":"succeeded"} AVDLZ-STATE>>>';
  getEl('paste').value = stateLine;
  getEl('analyze').click();

  assert.equal(getEl('next-headline').textContent, 'Control planes: Succeeded');
  assert.match(fullText(getEl('actions')), /Test-AvdLandingZoneReadiness\.ps1/);
});

test('portal UI: Region and Verify steps link to AVD Line Check with the active deployment region', () => {
  const { html, getEl } = createPortalDomHarness();
  assert.match(html, /id="region-linecheck"[^>]*href="https:\/\/linecheck\.avd-ops\.dev\/\?pack=avd&amp;region=northcentralus"/);
  assert.match(html, /id="verify-linecheck"[^>]*href="https:\/\/linecheck\.avd-ops\.dev\/\?pack=avd&amp;region=northcentralus"/);
  assert.equal(getEl('region-linecheck').href, 'https://linecheck.avd-ops.dev/?pack=avd&region=northcentralus');
  assert.equal(getEl('verify-linecheck').href, 'https://linecheck.avd-ops.dev/?pack=avd&region=northcentralus');

  getEl('location').value = 'westeurope';
  getEl('location').dispatchEvent({ type: 'change', target: getEl('location'), preventDefault() {} });
  assert.equal(getEl('region-linecheck').href, 'https://linecheck.avd-ops.dev/?pack=avd&region=westeurope');
  assert.equal(getEl('verify-linecheck').href, 'https://linecheck.avd-ops.dev/?pack=avd&region=westeurope');
});

