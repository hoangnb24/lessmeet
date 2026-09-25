// Regenerate compact evidence and candidate hashes; no third-party code execution.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
const root = new URL('./', import.meta.url);
const kinds = ['valid','trailing-end','trailing-zero','trailing-ff','erased','empty','two-units','truncated'];
const results = kinds.map(kind => {
  const report = JSON.parse(readFileSync(new URL(`${kind}.json`,root)));
  const decoded = JSON.parse(report.stdout);
  return {kind,exit:report.exit,supervisorReason:report.reason,
    elapsedSeconds:report.elapsedSeconds,sampledPeakRssBytes:report.sampledPeakRssBytes,
    ...decoded};
});
const before = JSON.parse(readFileSync(new URL('before.json',root)));
const after = JSON.parse(readFileSync(new URL('after.json',root)));
const changedInputs = Object.keys(before).filter(p=>before[p]!==after[p]);
writeFileSync(new URL('summary.json',root),JSON.stringify({changedInputs,results},null,2)+'\n');
const hashes = Object.fromEntries(readdirSync(root).filter(p=>p!=='SHA256.json').sort().map(p=>[
  p,createHash('sha256').update(readFileSync(new URL(p,root))).digest('hex')]));
writeFileSync(new URL('SHA256.json',root),JSON.stringify(hashes,null,2)+'\n');
console.log(JSON.stringify({changedInputs,results:results.map(r=>({kind:r.kind,exit:r.exit,...r.result.probe})),hashes},null,2));
if(changedInputs.length) process.exitCode=1;
