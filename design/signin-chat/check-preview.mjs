// Check the design's state rendering without running a browser or app.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync(new URL('./preview.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
assert(html.includes("connect-src 'none'"));
assert(html.includes("form-action 'none'"));
assert(!/\b(fetch|XMLHttpRequest|WebSocket|sendBeacon)\s*\(/.test(script));
assert(!/https?:\/\//.test(script));

const elements = new Map();
const listeners = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    innerHTML: '', textContent: '', value: '', disabled: true,
    classList: { toggle() {} }, addEventListener() {}, focus() {},
  });
  return elements.get(id);
}
const document = {
  body: { classList: { toggle() {} } },
  getElementById: element,
  querySelector: element,
  querySelectorAll: () => [],
  addEventListener: (type, listener) => listeners.set(type, listener),
};
const context = vm.createContext({ document, location: { search: '' }, URLSearchParams });
vm.runInContext(script, context);
let count = 0;
for (const [screen, states] of Object.entries(vm.runInContext('states', context))) {
  for (const [state] of states) {
    vm.runInContext(`show('${screen}','${state}')`, context);
    const output = element('app').innerHTML;
    assert(output.includes('Audio stays local.'), `${screen}/${state}: disclosure`);
    assert(output.includes('Product weekly'), `${screen}/${state}: recording context`);
    assert(!output.includes('undefined'), `${screen}/${state}: undefined output`);
    if (screen === 'signin') assert(output.includes('role="dialog"'));
    if (state === 'welcome') assert(!output.includes('data-action="close"'));
    if (state === 'streaming') assert(output.includes('Incomplete answer · not saved'));
    if (state === 'history') assert(output.includes('saved history has not been changed'));
    count++;
  }
}
vm.runInContext("show('chat','conversation')", context);
listeners.get('input')({ target: { id: 'draft', value: 'A local sample question' } });
assert.equal(element('[data-action="send"]').disabled, false);
listeners.get('change')({ target: { id: 'model-picker', value: '' } });
assert.equal(vm.runInContext('state', context), 'choose');
listeners.get('input')({ target: { id: 'draft', value: 'A local sample question' } });
assert.equal(element('[data-action="send"]').disabled, true);
vm.runInContext("show('chat','streaming')", context);
listeners.get('input')({ target: { id: 'draft', value: 'Changed while answering' } });
assert.equal(vm.runInContext('draft', context), 'Changed while answering');
assert.equal(element('[data-action="send"]').disabled, true);
assert(vm.runInContext("escapeHTML('<script>')", context) === '&lt;script&gt;');
console.log(`PASS ${count} static states, disclosure, modal welcome, send gating, editable busy draft, escaping and no network entry points.`);
console.log('This check does not prove browser layout, native behavior, authentication, chat or persistence.');
