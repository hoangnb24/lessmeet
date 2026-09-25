// Metadata/tarball verification only. Never imports or executes downloaded code.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
const [dir, output] = process.argv.slice(2);
if (!dir?.startsWith('/tmp/lessmeet-aac-feasibility.')) throw Error('Use the isolated mktemp directory');
if (process.argv.includes('--prepare')) {
  const pinned = readFileSync(new URL('./dependency-lock.json',import.meta.url));
  writeFileSync(join(dir,'package-lock.json'),pinned);
  writeFileSync(join(dir,'package.json'),JSON.stringify({name:'lessmeet-aac-first-gate',private:true,type:'module',dependencies:{'@wasm-audio-decoders/aac':'0.0.1'}})+'\n');
  writeFileSync(join(dir,'npmrc'),'ignore-scripts=true\naudit=false\nfund=false\n');
  writeFileSync(join(dir,'global-npmrc'),'ignore-scripts=true\n');
  console.log('Prepared isolated dependency manifest/configuration; use npm ci --ignore-scripts.');
  process.exit(0);
}
const lockBytes = readFileSync(join(dir, 'package-lock.json'));
const lock = JSON.parse(lockBytes);
const sha = (bytes, algorithm='sha256', encoding='hex') => createHash(algorithm).update(bytes).digest(encoding);
if (process.argv.includes('--snapshot-only')) {
  function walk(path) {
    return readdirSync(join(dir,path),{withFileTypes:true}).flatMap(entry => {
      const next = `${path}/${entry.name}`;
      return entry.isDirectory() ? walk(next) : [{path:next,sha256:sha(readFileSync(join(dir,next)))}];
    });
  }
  writeFileSync(output, JSON.stringify(walk('node_modules'),null,2)+'\n');
  writeFileSync(new URL('./dependency-lock.json', import.meta.url), lockBytes);
  console.log('Saved installed-file hashes and exact dependency lock; no network.');
  process.exit(0);
}
const results = [];
for (const [path, item] of Object.entries(lock.packages)) {
  if (!path) continue;
  const pkg = JSON.parse(readFileSync(join(dir, path, 'package.json')));
  const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(pkg.name)}/${pkg.version}`, {signal: AbortSignal.timeout(15000)});
  if (!response.ok) throw Error(`Registry metadata ${response.status}`);
  const registry = await response.json();
  if (item.integrity !== registry.dist.integrity || item.resolved !== registry.dist.tarball) throw Error('Registry/lock mismatch');
  if (new URL(item.resolved).origin !== 'https://registry.npmjs.org') throw Error('Unexpected origin');
  const download = await fetch(item.resolved, {signal: AbortSignal.timeout(15000)});
  if (!download.ok) throw Error(`Tarball ${download.status}`);
  const bytes = Buffer.from(await download.arrayBuffer());
  const [algorithm, expected] = item.integrity.split('-');
  if (sha(bytes, algorithm, 'base64') !== expected) throw Error('Integrity mismatch');
  const licenses = readdirSync(join(dir, path)).filter(x => /^(license|copying|notice)/i.test(x)).map(x => ({path:x, sha256:sha(readFileSync(join(dir,path,x))), text:readFileSync(join(dir,path,x),'utf8')}));
  results.push({name:pkg.name,version:pkg.version,license:pkg.license,dependencies:pkg.dependencies,
    resolved:item.resolved,integrity:item.integrity,tarballSha256:sha(bytes),bytes:bytes.length,
    packageJsonSha256:sha(readFileSync(join(dir,path,'package.json'))),scripts:pkg.scripts,licenses});
}
const report = {node:process.version,lockSha256:sha(lockBytes),packages:results};
writeFileSync(output, JSON.stringify(report,null,2)+'\n');
writeFileSync(new URL('./dependency-lock.json', import.meta.url), lockBytes);
console.log(JSON.stringify({...report, packages:results.map(({licenses,...x})=>({...x,licenses:licenses.map(({text,...l})=>l)}))},null,2));
