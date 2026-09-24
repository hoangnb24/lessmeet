// Offline checks only. Run from the repository root with node website/verify-drafts.mjs.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const site = path.join(root, 'website');
const config = JSON.parse(fs.readFileSync(path.join(site, 'wrangler.jsonc'), 'utf8'));
assert.equal(config.assets.directory, './public');
assert.equal(config.assets.not_found_handling, '404-page');
assert.equal(config.workers_dev, false);
assert.equal(config.preview_urls, false);
assert.deepEqual(config.routes, [{pattern: 'www.lessmeet.2m0r.com', custom_domain: true}]);
const publicRoot = path.join(site, 'public');
assert.equal(fs.lstatSync(publicRoot).isSymbolicLink(), false);
const assets = fs.readdirSync(publicRoot).sort();
assert.deepEqual(assets, ['404.html', '_headers', 'index.html', 'style.css']);
for (const name of assets) {
  assert.equal(fs.lstatSync(path.join(publicRoot, name)).isFile(), true);
  assert.equal(fs.lstatSync(path.join(publicRoot, name)).isSymbolicLink(), false);
}
let htmlLinks = 0;
for (const name of ['index.html', '404.html']) {
  const html = fs.readFileSync(path.join(publicRoot, name), 'utf8');
  assert.doesNotMatch(html, /<script\b|<form\b/i);
  for (const match of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    if (match[1].startsWith('mailto:')) continue;
    assert.ok(match[1].startsWith('/'));
    const target = path.resolve(publicRoot, `.${match[1] === '/' ? '/index.html' : match[1]}`);
    assert.ok(target.startsWith(`${publicRoot}/`));
    assert.ok(fs.existsSync(target), target);
    htmlLinks++;
  }
}
const docs = [path.join(site, 'README.md'), ...fs.readdirSync(path.join(root, 'docs/legal'))
  .filter(name => name.endsWith('.md')).map(name => path.join(root, 'docs/legal', name))];
let markdownLinks = 0;
for (const file of docs) {
  const content = fs.readFileSync(file, 'utf8');
  for (const match of content.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    if (/^(?:https?:|mailto:|#)/.test(match[1])) continue;
    const target = path.resolve(path.dirname(file), match[1].split('#')[0]);
    assert.ok(target.startsWith(`${root}/`));
    assert.ok(fs.existsSync(target), `${file}: ${match[1]}`);
    markdownLinks++;
  }
}
const readme = fs.readFileSync(path.join(site, 'README.md'), 'utf8');
for (const [field, limit] of [['Name', 30], ['Subtitle', 30], ['Promotional text', 170], ['Keywords', 100]]) {
  const row = readme.split('\n').find(line => line.startsWith(`| ${field} |`));
  assert.ok(row, field);
  const value = row.split('|')[2].trim();
  assert.ok(value.length <= limit, `${field}: ${value.length}/${limit}`);
  console.log(`${field}: ${value.length}/${limit}`);
}
console.log(`PASS: ${assets.length} allowed public assets; ${htmlLinks} HTML and ${markdownLinks} local Markdown links; no draft exposure by asset inventory.`);
console.log('NOT TESTED: HTTP routing, DNS/TLS, provider settings, app runtime, deletion, publication.');
