#!/usr/bin/env node
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// Redacts run output in Cloud Shell with the deployment portal's own redaction (site/portal/report.js),
// so the run recorder and the portal never disagree (build/specs/run-recorder-spec.md section 5).
//
//   node scripts/ops/redact.mjs --level private|public [--name <value>]... [--storage <value>]... [--term <value>]... [--in <file>] [--out <file>]
//
// --level private removes secrets only (what is kept in the operator's own tenant); --level public also
// removes tenant names, IDs, emails, domains and names (what may leave the tenant). Reads stdin
// without --in and writes stdout without --out. Prints the counts to stderr. Exits 2 on bad arguments
// and 1 on any other error, so callers fail closed: nothing is kept or uploaded unless this exits 0.
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { redact, describe } = require('../../site/portal/report.js');

export function parseArgs(argv) {
  const o = { level: null, known: [], extraTerms: [], input: null, output: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = argv[i + 1];
    const need = () => { if (v === undefined || v.startsWith('--')) throw new Error(`${a} needs a value`); i++; return v; };
    switch (a) {
      case '--level': o.level = need(); break;
      case '--name': o.known.push({ kind: 'name', value: need() }); break;
      case '--storage': o.known.push({ kind: 'storage', value: need() }); break;
      case '--term': o.extraTerms.push(need()); break;
      case '--in': o.input = need(); break;
      case '--out': o.output = need(); break;
      default: throw new Error(`unknown argument ${a}`);
    }
  }
  if (o.level !== 'private' && o.level !== 'public') throw new Error('--level must be private or public');
  return o;
}

function main() {
  let args;
  try { args = parseArgs(process.argv.slice(2)); }
  catch (e) { process.stderr.write(`redact.mjs: ${e.message}\n`); process.exit(2); }
  try {
    const text = readFileSync(args.input ?? 0, 'utf8');
    const r = redact(text, { level: args.level, known: args.known, extraTerms: args.extraTerms });
    if (args.output) writeFileSync(args.output, r.text); else process.stdout.write(r.text);
    process.stderr.write(`${describe(r.counts)}\n`);
  }
  catch (e) { process.stderr.write(`redact.mjs: ${e.message}\n`); process.exit(1); }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
