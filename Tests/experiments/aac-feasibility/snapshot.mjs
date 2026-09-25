import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const paths = ['package.json', 'package-lock.json', 'Package.swift',
  'convex/media.ts', 'convex/http.ts', 'convex/jobs.ts', 'convex/gemini.ts',
  'convex/limits.ts', 'convex/billing.ts', 'convex/billingPolicy.ts', 'convex/recordings.ts',
  'Sources/LessMeet/Cloud/CloudClient.swift', 'Sources/LessMeet/Capture/CaptureAudioRecorder.swift',
  'Sources/LessMeet/Capture/CaptureService.swift', 'Tests/backend/mediaFixture.ts'];
const hashes = Object.fromEntries(paths.map(p => [p, createHash('sha256').update(readFileSync(p)).digest('hex')]));
if (process.argv[2]) writeFileSync(process.argv[2], JSON.stringify(hashes, null, 2) + '\n');
else console.log(JSON.stringify(hashes, null, 2));
