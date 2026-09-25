// Read-only smoke against the local Wrangler preview; never uses production.
// Start: npx --no-install wrangler@4.136.3 dev --config website/wrangler.jsonc --local --ip 127.0.0.1 --port 8793
// Then: node website/verify-local.mjs
import assert from 'node:assert/strict';

for (const [route, expected] of [
  ['/', 200], ['/style.css', 200], ['/privacy', 404], ['/terms', 404],
  ['/docs/legal/PRIVACY_DRAFT.md', 404], ['/_headers', 404],
]) {
  const response = await fetch(`http://127.0.0.1:8793${route}`, {
    redirect: 'error', signal: AbortSignal.timeout(5000),
  });
  const body = await response.text();
  assert.equal(response.status, expected, route);
  assert.equal(response.headers.get('x-robots-tag'), 'noindex, nofollow', route);
  assert.match(response.headers.get('content-security-policy') ?? '', /default-src 'none'/);
  if (route === '/') {
    assert.match(body, /Operator: Hoang Bang/);
    assert.match(body, /mailto:hoang@2m0r\.com/);
  }
  if (expected === 404) assert.match(body, /This page is not published yet/);
  console.log(`PASS ${route}: ${response.status}; noindex + CSP`);
}
console.log('NOT TESTED: rendered layout, public HTTPS, OAuth, email delivery, legal approval.');
