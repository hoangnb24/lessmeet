# AAC first gate — REOPEN_REQUEST (2026-09-24)

## Outcome and decision

**Stop before adoption/rebuild/demux.** Published `@wasm-audio-decoders/aac@0.0.1`
can stream-decode the tiny synthetic raw unit in Node, and distinguishes all three
tested trailing-byte variants and erased/truncated data by errors. It does NOT
expose decoder-consumed bytes, residual bits/bytes, or a progress/priming status.
Its `inputBytes` field is a submitted-byte counter on error records, not a consumed
byte count: installed `src/AACDecoder.js` increments it by the entire supplied
chunk at line 150 regardless of how much C decoding consumed. `_decode` at lines
83–120 returns only error, output channels and sample count.

This is a **missing strict-consumption proof**, not a demonstrated accepted
trailing-garbage exploit. No tested nonempty malformed input silently passed.
The empty call and valid first/priming unit both return zero samples/no errors;
zero-output handling therefore requires state, not `errors.length === 0` alone.
No actual hung/non-progressing C decoder case was generated. Hidden consumption
cannot be established by this public API. Lead must authorize a separate pinned
wrapper/source-rebuild investigation or choose another candidate before relying
on full consumption. Do not infer that an external service is essential.

No model/config changes, demux, upload envelope, full recording, codec rebuild,
provider calls, deployment, credentials, personal audio, commits or pushes.
One model request remains the design; bearer-ingress risk remains deferred.
License disposition is not granted. Write ownership of this experiment is
relinquished to Lead; no dependent implementation is underway.

## Identity, scope and environment

- Original base: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus accepted dirty files.
- All repository writes are under `Tests/experiments/aac-feasibility/`.
- Dependency directory: `/tmp/lessmeet-aac-feasibility.s4EAQZ` (retained for Lead).
  It contains installation, lock, npm cache/config/logs only. No global install.
- macOS 26.4 (25E246), arm64. Probes use Node 22.22.3 at
  `/Users/tubakhuym/.hermes/node/bin/node`; Python 3.9 from installed Xcode.
- Isolated npm installation used Homebrew Node 26.0.0/npm 11.12.1 via an explicit
  clean environment. This differs from the interactive Node 22.22.3/npm 10.9.8.
  No install scripts executed; npm update notices were ignored.
- `before.json`/`after.json` record SHA-256 for 15 frozen root/backend/native/fixture
  inputs. `summary.json` records comparison. They do not claim other active Peer
  paths were frozen. The initial worktree was already dirty with other lanes.
- `SHA256.json` enumerates every experiment file except itself; its own SHA-256
  is supplied in the response. No decoder binaries or third-party JS source are
  copied into the repository. Reports contain hashes, metadata and license text.

## Dependency/artifact verification

`artifacts.json` records each registry URL, full SRI, recomputed tarball SHA-256,
declared licenses and packaged license-file text/hashes. Every downloaded tarball
matched BOTH its exact installed lock SRI and registry version metadata. Downloads
for verification were held in memory only. `installed-files.json` hashes all
installed package files; `dependency-lock.json` is the complete transitive lock.

| Package | Version | Declared license |
| --- | --- | --- |
| @wasm-audio-decoders/aac | 0.0.1 | MIT wrapper; no packaged license file |
| @wasm-audio-decoders/common | 9.0.7 | MIT; no packaged license file |
| codec-parser | 2.5.0 | LGPL-3.0-or-later |
| @eshaz/web-worker | 1.2.2 | Apache-2.0 |
| simple-yenc | 1.0.4 | MIT |

AAC tarball SHA-256:
`5d22878d9ff14e516ffce336a581dbccb4ff8bca18b02b009b32edb81b7954f3`.
AAC SRI:
`sha512-tSIdJiLQqKJpd4PecDpreFT4WwmfZoJERHutLUH20GH56XRq0nFdggS3uJZ0aTAwcZDA0M66JAYZy52oPMT4aw==`.
Dependency lock SHA-256:
`606059fb74a8491563efe8d7410b24c6289353079c88cb5e5ee1907d92cce8dd`.

Upstream source previously inspected at
`eshaz/wasm-audio-decoders@6301f74004288e0eacf187d6a69424e9629019c4`
references FAAD2 `673a22a3c7c33e96e2ff7aae7c4d2bc190dfbf92`, whose
[COPYING](https://github.com/knik0/faad2/blob/673a22a3c7c33e96e2ff7aae7c4d2bc190dfbf92/COPYING)
contains GPLv2 terms and a commercial-license notice. The installed artifact is
not asserted reproducibly built from that source commit (the wrapper differs
from the inspected source). Registry integrity is not build provenance or a
license clearance. Do not call the combined decoder MIT-only.

## Actual WASM and startup graph

The probe intercepts `WebAssembly.compile` to inspect actual published module
bytes before compiling, without writing those bytes anywhere in the repository.
Detailed imports/exports and module hashes are in every probe JSON.

| Module | Bytes | Initial memory | Declared maximum |
| --- | ---: | ---: | ---: |
| startup Puff decompressor | 2,665 | 96 pages = 6 MiB | none |
| AAC decoder | 217,531 | 260 pages = 16.25 MiB | 260 pages = 16.25 MiB |

Puff SHA-256: `e55e803264dc0f2eb2823141893387f14097dc1f11dc771066aa57abc1271d1f`.
AAC WASM SHA-256: `2003ae9119da0da0277f7089070bc44dfbc0a63158f2146c4f9098ee83903968`.
Puff imports nothing. AAC imports nine functions (`a.a` through `a.i`), no memory,
network or filesystem capability. Packaged glue binds assertions/abort/exit,
timer/keepalive, refused heap resize and fd stubs/logging. WASM confinement does
not establish decoder correctness or CPU termination. Puff's absence of a
declared maximum is a separate artifact-hardening question; local Node imposes
a 512-page limit per memory. This flag is NOT a Convex configuration.

Node startup and decoder instantiation passed. Static package graph:
AAC index -> AACDecoder + AACDecoderWebWorker -> common index ->
WASMAudioDecoderWorker -> @eshaz/web-worker. The worker class extends
`globalThis.Worker || NodeWorker` at module evaluation; browser entry exports the
ambient Worker, whereas Node entry uses worker_threads. A non-worker named import
does not prove this graph is eliminated. No Convex/browser bundle, edge-runtime
execution, deployed memory accounting or platform timeout was tested: stopped
at consumption gate. A Node pass is not a Convex compatibility pass.

## Probe results (eight fresh subprocesses)

Input is ONLY the repository's existing 872-byte synthetic 0.1-second silence
fixture. No ffmpeg invocation or media device was needed. Fixture SHA-256:
`e5a63bddc64bf91f985c36f135b8b6ffdf6733cdabadec4b9d3e769a7c00312e`.
The script extracts fixed known offsets, not a general parser: first 21-byte unit
at offset 44 primes state; target unit is `01182007`, four bytes at offset 65.
ASC is `118856e500`. The first unit returns zero samples, no errors.

| Target | Decoded samples/channel | Errors | Result |
| --- | ---: | --- | --- |
| valid 4-byte unit | 1024 | none | baseline decoded |
| same unit + 00 | 1024 | bitstream-element error | distinguishable; reject |
| same unit + E0 | 1024 | channel error | distinguishable; reject |
| same unit + FF | 1024 | channel error | distinguishable; reject |
| erased 00000000 | 0 | bitstream-element error | distinguishable; reject |
| empty input | 0 | none | caller must reject; not proof of decoder stall |
| two concatenated valid units | 2048 | none | caller can detect extra output |
| truncated 011820 | 0 | bitstream-element error | distinguishable; reject |

All eight probe processes exited 0 with no supervisor kill; this means the
harness completed, NOT eight admission-safety passes. Trailing cases still
return baseline PCM alongside errors; ignoring errors would be unsafe. Reported
output is 48 kHz, TWO channels despite the mono fixture description/ASC. This
compatibility discrepancy remains unexplained; no channel-correctness claim.
Silence PCM hashes match across valid/trailing variants. No audible-quality,
full-duration, decoder-stall, reset-after-corruption or long-memory test occurred.

## Resource controls, true failures and limits

Every decoder process had an independent Python supervisor: 10-second wall kill,
256 MiB sampled RSS kill, 128 KiB captured-output ceiling, CPU rlimits 5 seconds
soft/6 hard, no core dumps. Node used `--max-old-space-size=64`,
`--max-semi-space-size=4`, `--wasm-max-mem-pages=512`. These bound JS heap policy
and WASM memories, not total process RSS. The supervisor sends SIGKILL to the
process group, so a blocked child event loop cannot suppress the wall kill.

**No instantaneous kernel total-RSS ceiling was available.** Darwin's RLIMIT_AS
aliases RLIMIT_RSS; setting RLIMIT_DATA to 256 MiB failed. The first supervisor
self-test failed in preexec before any decoder ran; the corrected supervisor
removed that unsupported limit. RSS sampling can overshoot and excludes child
process RSS; decoder probes use no spawned workers. This is not equivalent to a
cgroup or resource-isolated deployed service.

Supervisor controls were exercised using our own non-decoder code:
- idle-loop wall test: SIGKILL, ~0.224 s for 0.2 s budget;
- synchronously blocked `while(true)` test: SIGKILL, ~0.225 s;
- incremental Buffer allocation test: SIGKILL at sampled 57,409,536 bytes for a
  48 MiB threshold, demonstrating overshoot rather than hiding it.
These commands intentionally exited 1 at the supervisor level; reports show -9
for the killed child. They are successful supervisor checks, not decoder failures.

The initial npm attempt failed because user/global configs used the same file;
no install occurred. Separate isolated config files fixed it; install completed
with five packages and scripts disabled. No automatic npm update was performed.

## Reproduction

Run from `/Users/tubakhuym/projects/lessmeet`. Never install into project root.
Existing isolated directory can be reused for probes. To recreate dependencies
in a NEW authorized temporary directory, use the pinned metadata (no binaries):

```sh
aac_tmp=$(mktemp -d /tmp/lessmeet-aac-feasibility.XXXXXX)
node Tests/experiments/aac-feasibility/artifacts.mjs "$aac_tmp" --prepare
```

Run npm with working directory explicitly set to that new directory:

```sh
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin npm ci --ignore-scripts --no-audit --no-fund --cache "$aac_tmp/npm-cache" --userconfig "$aac_tmp/npmrc" --globalconfig "$aac_tmp/global-npmrc" --registry https://registry.npmjs.org
```

The actual first installation used `npm install` with those flags in the printed
isolated directory; the lock now permits `npm ci`. Reproduction prepare/ci path
was supplied but not run again. Registry verification actually run:

```sh
node Tests/experiments/aac-feasibility/artifacts.mjs /tmp/lessmeet-aac-feasibility.s4EAQZ Tests/experiments/aac-feasibility/artifacts.json
```

Actual probe command below was run once for each of `valid`, `trailing-end`,
`trailing-zero`, `trailing-ff`, `erased`, `empty`, `two-units`, `truncated`, changing
both the final argument and report filename to match:

```sh
python3 Tests/experiments/aac-feasibility/supervise.py --report Tests/experiments/aac-feasibility/valid.json -- /Users/tubakhuym/.hermes/node/bin/node --max-old-space-size=64 --max-semi-space-size=4 --wasm-max-mem-pages=512 Tests/experiments/aac-feasibility/probe.mjs /tmp/lessmeet-aac-feasibility.s4EAQZ valid
```

Supervisor self-test exact command arrays are recorded in `supervisor-*.json`.
Artifact snapshots/frozen-input comparison/report generation:

```sh
node Tests/experiments/aac-feasibility/artifacts.mjs /tmp/lessmeet-aac-feasibility.s4EAQZ Tests/experiments/aac-feasibility/installed-files.json --snapshot-only
node Tests/experiments/aac-feasibility/snapshot.mjs Tests/experiments/aac-feasibility/after.json
node Tests/experiments/aac-feasibility/summarize.mjs
git diff --check
shasum -a 256 Tests/experiments/aac-feasibility/SHA256.json
```

No full project regression was needed or run: production inputs are unchanged.
Usable downstream input is this exact first-gate evidence and pinned dependency
lock, NOT a decoder approval, consumption guarantee, deployment proof or beta
readiness claim. Lead decides the next source/ABI investigation and acceptance.
