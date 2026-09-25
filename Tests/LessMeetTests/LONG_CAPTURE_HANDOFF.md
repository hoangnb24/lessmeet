# Lane B: synthetic long capture evidence

Original accepted base: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605`.
Owned additions only: `Tests/LessMeetTests/LongCaptureTests.swift` and this handoff.
No production edits, commits, external actions, credentials, personal recordings,
app launch, signing, TCC or live capture. Lead's independent Package.swift/STATUS
edits and other lanes are not part of this snapshot. Lead should exclude this
handoff from the Swift test target before the final integration suite.

Test snapshot SHA-256:
`6fb76577092c5bc9616dd5b352a4af8ddbb6148e84c8d3d291b2d382d9f69d84`.
The final response supplies this document's hash (avoiding a self-referential hash).

## Outcome and reproduction

All four opted-in synthetic cases passed, including 30/60/120 minutes. The three
long exports all exceed the unchanged 18 MiB (18,874,368-byte) admission limit.
Local capture/export success therefore does **not** establish long-meeting upload
readiness. No interface or production fix is proposed by this lane.

Environment: macOS 26.4 (25E246), arm64; Apple Swift 6.3.3
(`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`), debug SwiftPM/XCTest.
Measured 2026-09-24, approximately 22:57–22:58 Asia/Ho_Chi_Minh.
Run from `/Users/tubakhuym/projects/lessmeet`; one case per process:

```sh
LESSMEET_LONG_CAPTURE_SECONDS=10 swift test --disable-automatic-resolution --filter LongCaptureTests
LESSMEET_LONG_CAPTURE_SECONDS=1800 swift test --disable-automatic-resolution --filter LongCaptureTests
LESSMEET_LONG_CAPTURE_SECONDS=3600 swift test --disable-automatic-resolution --filter LongCaptureTests
LESSMEET_LONG_CAPTURE_SECONDS=7200 swift test --disable-automatic-resolution --filter LongCaptureTests
swift test --disable-automatic-resolution
git diff --check
shasum -a 256 Tests/LessMeetTests/LongCaptureTests.swift Tests/LessMeetTests/LONG_CAPTURE_HANDOFF.md
```

Each opted-in command exited 0 with 1 test, 0 failures. The environment variable
accepts only these four values. With it unset the long test throws XCTSkip.
The final 10-second rerun used the same test bytes as all final long-case results.
The full `swift test --disable-automatic-resolution` exited 0: 74 tests, 1 skipped,
0 failures (73 executed normally). This ran before this handoff was created;
Lead's final integration still needs its Package.swift exclusion. `git diff
--check` exited 0. `sw_vers`, `swift --version` and `uname -m` supplied the
environment above. No backend or packaging suite was run by lane B.
Read-only `test -e` checks against all eight printed UUID directories confirmed
that normal deferred cleanup removed every synthetic directory, including both
failed sanity iterations. Generated audio was not retained; this handoff preserves
the measurement evidence and the test deterministically regenerates the inputs.

## Recorded measurements

These are actual printed `LONG_CAPTURE` results, not real-time recording estimates.
Seconds describe each source; the combined expected timeline adds 0.5 seconds.
Capture includes generation/append/close; export measures `exportCombined()` only;
total also includes streaming hashes and decoding all three audio files.

| Source seconds | Capture s | Export s | Total s | M4A bytes | Temporary bytes | Decoded frames at 48 kHz | Process peak RSS bytes |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 0.0196354582 | 0.0707466665 | 0.1830587916 | 173,613 | 1,621,946 | 503,968 | 78,790,656 |
| 1800 | 0.1989008333 | 4.4038428750 | 5.2750592083 | 30,992,655 | 290,200,992 | 86,423,968 | 127,467,520 |
| 3600 | 0.3773829166 | 8.0063710001 | 9.5994269585 | 61,983,734 | 580,392,071 | 172,823,968 | 123,846,656 |
| 7200 | 0.6205919583 | 15.8870995000 | 18.8964773752 | 123,962,236 | 1,160,770,573 | 345,623,968 | 130,580,480 |

M4A sizes are respectively 0.166, 29.56, 59.11 and 118.22 MiB. Only the short
case fits 18 MiB. Decoded combined seconds: 10.4993333333, 1800.4993333333,
3600.4993333333 and 7200.4993333333. Each is 32 frames short of the expected
timeline, inside the explicitly allowed 1024-frame AAC packet tolerance.
Each run reports `originalsSHA256Preserved=true`, combined tone RMS
`0.29999892365226466` and silence RMS `0.0` in the inspected first-cycle windows.
Initial process lifetime peak RSS: 57,556,992; 57,556,992; 57,573,376;
57,556,992 bytes respectively. These initial/final high-water marks are **not**
an isolated recorder allocation measurement or a current-RSS delta.

## What is verified

- Both sources use existing `CaptureAudioRecorder.append/close` and
  `CapturedAudio.exportCombined`, without production changes.
- Synthetic mono system audio is 48 kHz/880 Hz; microphone is 24 kHz/440 Hz,
  starts 0.5 seconds later and arrives first. Both alternate 5 seconds of tone
  with 5 seconds of explicit PCM silence, delivered in one-second chunks without
  real-time waits. Timeline offsets 0 and 0.5 are asserted.
- Both original CAF files and timeline are SHA-256 hashed in 1 MiB chunks before
  and after export and must match byte-for-byte. Both original CAFs are decoded
  in 8192-frame buffers; exact frame counts and source rates are asserted.
- Combined audio is decoded in 8192-frame buffers through its complete declared
  decoded length. The number of frames actually read must equal that length and
  agree with the expected timeline within one AAC packet. First-cycle tone and
  silence windows are checked numerically. This is not full-length perceptual,
  frequency-separation or acoustic-quality verification.
- Every normal case uses a newly created UUID temporary directory with deferred
  cleanup. Test-owned buffers are four reusable one-second mono Float32 buffers
  (576,000 bytes total), bounded CMSampleBuffer/recorder copies, an 8192-frame
  decode buffer and a 1 MiB hashing buffer. No entire long PCM file is loaded.
- The longest originals total 1,036,800,000 PCM payload bytes. Free space must
  cover expected PCM plus 1 GiB. Checks run throughout capture/decoding; export
  disk checks run every 100 ms with a 2.5-billion-byte guard (headroom below
  3 GiB). All measured totals were below 3 GiB. This is a sampled logical-file
  guard, not an OS-enforced quota or a measurement of filesystem cache/APFS
  physical allocation. The exporter writes a partial file and then renames it;
  there is no test-created duplicate export.
- A monotonic 290-second cooperative check and independent 295-second process
  watchdog bound each opted-in case, including an unresponsive exporter. The
  disk guard exits 125 and watchdog exits 124; forced exit deliberately leaves
  the printed, synthetic-only directory for explicit cleanup. Neither fired.
  The 5-minute case bound does not include Swift compilation.

## Failed iterations and limits

The initial 10-second sanity command failed twice with `nilError` at the decoder
read (0.308 s and 0.280 s). Explicit Float32 decoding alone did not fix it.
Limiting reads to remaining declared frames fixed the harness's read-past-end
behavior; the first subsequent sanity run passed in 0.184 s. No production
capture/export defect was demonstrated by these failures.

The initial 30-minute run passed but reported peak RSS 615,809,024 bytes.
Streaming FileHandle reads needed a per-chunk autorelease pool: without it,
released hash buffers accumulated until the outer pool drained. That test-only
fix reduced the repeated case to 127,467,520 bytes; the table contains only the
corrected harness's measurements. Never use the initial run as bounded-memory
evidence for the final harness.

Memory uses Darwin `getrusage(RUSAGE_SELF).ru_maxrss` (bytes), encompassing the
entire XCTest process, linked frameworks and any in-process codec work. It does
not measure XPC/export helper processes, GPU memory, filesystem cache or whole
system pressure; no claim is made about those scopes. Warm filesystem caches,
simple repeated tones, mono inputs and faster-than-real-time delivery make these
numbers unsuitable as real-device performance guarantees. No stereo/high-channel,
route-change, sleep, multi-hour wall-clock, microphone/system permissions, acoustic,
UI/playback, save/reopen, upload or provider behavior was tested by this lane.
Existing short tests cover timestamp gaps; this long test uses explicit silence,
not missing-callback gaps. Backend admission was not invoked; size is compared
locally with the accepted cap.

Native build and both owned files are relinquished at handoff; Lead retains
technical acceptance and the Package.swift exclusion/integration decision.
