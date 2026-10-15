// Export only the offline design. This does not open or test LessMeet.app.
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const folder = dirname(fileURLToPath(import.meta.url));
const profile = mkdtempSync(join(tmpdir(), 'lessmeet-preview-export-'));
const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const shots = [
  ['signin', 'signin', 'signedout'],
  ['chat', 'chat', 'conversation'],
  ['signin-waiting', 'signin', 'waiting'],
  ['signin-consent', 'signin', 'consent'],
  ['chat-empty', 'chat', 'empty'],
  ['chat-streaming', 'chat', 'streaming'],
  ['chat-error', 'chat', 'requesterror'],
  ['chat-dark', 'chat', 'conversation', 'dark'],
  ['chat-compact', 'chat', 'conversation', 'light', '1064,840'],
];
for (const [name, screen, state, theme = 'light', size = '1360,960'] of shots) {
  const url = pathToFileURL(join(folder, 'preview.html'));
  url.search = new URLSearchParams({ screen, state, theme }).toString();
  if (name === 'chat-compact') url.searchParams.set('compact', '1');
  const result = spawnSync(chrome, [
    '--headless', '--disable-gpu', '--disable-background-networking',
    '--disable-component-update', '--disable-sync', '--disable-extensions',
    '--no-first-run', '--no-default-browser-check', '--hide-scrollbars',
    '--host-resolver-rules=MAP * ~NOTFOUND',
    `--user-data-dir=${profile}`, `--window-size=${size}`,
    `--screenshot=${join(folder, name + '.png')}`, url.href,
  ], { encoding: 'utf8', timeout: 30000 });
  if (result.status !== 0 || !result.stderr.includes('bytes written to file')) {
    throw new Error(`${name}: export failed\n${result.stderr}`);
  }
  console.log(`PASS ${name}.png (${size})`);
}
console.log('Temporary isolated browser profile:', profile);
