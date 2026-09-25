// Synthetic fixture only. Each process tests exactly one tiny mutation.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
const [dir, kind] = process.argv.slice(2);
if (!dir?.startsWith('/tmp/lessmeet-aac-feasibility.')) throw Error('isolated dependency directory required');
const sha = b => createHash('sha256').update(b).digest('hex');
const wasm = [];
const nativeCompile = WebAssembly.compile.bind(WebAssembly);
// Inspect the actual published WASM bytes without saving/distributing them.
function inspect(bytes) {
  const b = new Uint8Array(bytes);
  let pos = 8;
  function leb() { let n=0, shift=0, x; do { x=b[pos++]; n+=(x&127)*2**shift; shift+=7; if(shift>35) throw Error('LEB overflow'); } while(x&128); return n; }
  const memory = [];
  while (pos < b.length) {
    const id = b[pos++], size = leb(), end = pos + size;
    if (end > b.length) throw Error('invalid WASM section');
    if (id === 5) {
      const count = leb();
      for(let i=0;i<count;i++) { const flags=leb(), initial=leb(); memory.push({flags,initialPages:initial,maximumPages:flags&1?leb():null}); }
    }
    pos = end;
  }
  return {sha256:sha(b), bytes:b.length, memory};
}
WebAssembly.compile = async bytes => {
  const info = inspect(bytes);
  const module = await nativeCompile(bytes);
  info.imports = WebAssembly.Module.imports(module);
  info.exports = WebAssembly.Module.exports(module);
  wasm.push(info);
  return module;
};
const start = performance.now();
const { AACDecoder } = await import(pathToFileURL(`${dir}/node_modules/@wasm-audio-decoders/aac/index.js`));
const encoded = readFileSync('Tests/backend/mediaFixture.ts','utf8').match(/const encoded = "([A-Za-z0-9+/=]+)"/)[1];
const fixture = Buffer.from(encoded,'base64');
// Known fixture's stsz: [21,4,4,4,4,4], first payload offset 44.
// This is a fixed short-fixture extraction, NOT a native/general MP4 demuxer.
const first = fixture.subarray(44,65), unit = fixture.subarray(65,69);
const mutations = {
  valid: unit,
  'trailing-zero': Buffer.concat([unit,Buffer.from([0])]),
  'trailing-end': Buffer.concat([unit,Buffer.from([0xe0])]),
  'trailing-ff': Buffer.concat([unit,Buffer.from([255])]),
  'two-units': Buffer.concat([unit,unit]),
  erased: Buffer.alloc(unit.length),
  empty: Buffer.alloc(0),
  truncated: unit.subarray(0,unit.length-1),
};
if (!(kind in mutations)) throw Error('unknown probe');
const decoder = new AACDecoder({audioSpecificConfig:Uint8Array.from([0x11,0x88,0x56,0xe5,0])});
await decoder.ready;
function summary(out) {
  return {keys:Object.keys(out),samplesDecoded:out.samplesDecoded,sampleRate:out.sampleRate,
    errors:out.errors,channels:out.channelData.length,
    pcm:out.channelData.map(x=>({length:x.length,sha256:sha(new Uint8Array(x.buffer,x.byteOffset,x.byteLength))}))};
}
let result;
try {
  const priming = summary(await decoder.decodeFrames([first]));
  const probe = summary(await decoder.decodeFrames([mutations[kind]]));
  result = {kind,inputHex:mutations[kind].toString('hex'),inputBytes:mutations[kind].length,priming,probe};
} catch(error) { result={kind,exception:String(error)}; }
finally { decoder.free(); }
console.log(JSON.stringify({fixtureSha256:sha(fixture),result,wasm,
  elapsedMs:performance.now()-start,memory:process.memoryUsage()},null,2));
