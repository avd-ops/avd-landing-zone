import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const portal = require('../../../site/portal/portal-core.js');

test('portal-core omits hostPlacement flags by default and emits -HostPlacement azure-local when selected', () => {
  const defaultCmd = portal.commands.predeploy(portal.DEFAULTS, false);
  assert.doesNotMatch(defaultCmd, /-HostPlacement/);
  assert.doesNotMatch(defaultCmd, /-LocalSmbProfilePath/);

  const azLocalCmd = portal.commands.predeploy({
    ...portal.DEFAULTS,
    hostPlacement: 'azure-local',
    localSmbProfilePath: '\\\\files.contoso.com\\profiles'
  }, false);
  assert.match(azLocalCmd, /-HostPlacement azure-local/);
  assert.match(azLocalCmd, /-LocalSmbProfilePath '\\\\files\.contoso\.com\\profiles'/);
});
