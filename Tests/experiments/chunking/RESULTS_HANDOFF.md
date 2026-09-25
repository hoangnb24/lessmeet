# Disconnected chunk-result v1 candidate — 300/295/5 migration

## Outcome and ownership

Migrated the accepted pure result validator/derived merge to 300-second windows,
5-second overlap, 295-second stride, at most 25 slots and 7200-second total duration.
Production-source delta is only the geometry constants, five-second overlap check
and resource-envelope comment. Validation/dedup semantics and exported API types
are unchanged. Version remains 1: the earlier geometry was accepted offline but
never deployed as a network contract. Lead requested this migration because actual
dense 48 kHz stereo 600-second native output was 18,950,335 bytes, above 18 MiB.
The shorter native export's size/safety must still be measured separately by H.

No Convex integration, schema, Gemini, HTTP, billing, deletion, native, STATUS or
dependency edits. The only importer remains the fixture test. Lead decides acceptance.
Write ownership of the three paths below is relinquished at this handoff.

Original base: `b42a7a00a9e0f60a72eaeeadaa17b0c9c190f605` plus the accepted dirty
checkout and unrelated concurrent native work. Migration starts from the three
previously accepted file hashes below, matched before edits. The original creation
assignment started with these paths absent; this migration does not. No commit/push.

| Changed path | Before SHA-256 (accepted candidate) | After SHA-256 |
| --- | --- | --- |
| `convex/chunkResults.ts` | `5772db38db627416ea0b3e6ae373d5e0f358eac7b3759ffee65417e9de0d5c43` | `2ed80c8e98374d09ab7e70fc2a44b9d365701ab2215942e3532657bdf7232d27` |
| `Tests/backend/chunkResults.test.ts` | `a11659ec664676cb9e4520e56189d72ead11cdee0f4b467e090b871e8b12f92a` | `6d6557b6c9e566f1313ab9e8d122b00e41a5786e8623bc87c54d384ed4357333` |
| `Tests/experiments/chunking/RESULTS_HANDOFF.md` | `c5d64a3260e3b936e3bf1026ac516e04c3790739e1b2fb647a958180bc55d41c` | Supplied in final handoff response, outside this self-referential file. |

## Exact exported API

Runtime exports:

```ts
CHUNK_RESULT_LIMITS // frozen object described below
class ChunkResultError extends Error {
  readonly code: "invalid_result" | "invalid_manifest" | "raw_too_large";
  constructor(code: "invalid_result" | "invalid_manifest" | "raw_too_large");
}
validateChunkResult(rawText: string, admittedDurationMs: number): ValidatedChunkResult;
mergeChunkResults(input: ChunkMergeInput): ChunkMergeResult;
```

Exported types (all property names are literal contract names):

```ts
type ChunkSegment = {
  startMs: number | null; endMs: number | null;
  speaker: string | null; text: string;
};
type ValidatedChunkResult = {
  rawText: string; result: { version: 1; segments: ChunkSegment[] };
};
type ChunkResultInput = {
  index: number; startMs: number; endMs: number; rawText: string | null;
};
type ChunkMergeInput = { durationMs: number; chunks: ChunkResultInput[] };
type SegmentSource = {
  chunkIndex: number; segmentIndex: number;
  speaker: { chunkIndex: number; localLabel: string } | null;
};
type TimedSegment = {
  startMs: number; endMs: number; text: string;
  sources: SegmentSource[]; overlaps: boolean;
};
type UntimedSection = {
  chunkIndex: number; segments: { text: string; source: SegmentSource }[];
};
type ChunkAggregate = {
  version: 1; durationMs: number; missingChunks: number[];
  timed: TimedSegment[]; untimed: UntimedSection[];
};
type ChunkMergeResult = {
  version: 1; originals: ChunkResultInput[]; missingChunks: number[];
} & (
  { status: "complete" | "partial"; aggregate: ChunkAggregate; aggregateBytes: number } |
  { status: "too_large"; aggregate: null; aggregateBytes: null }
);
```

`CHUNK_RESULT_LIMITS` keys/values:

```text
segments=2048, textBytes=8192, speakerBytes=128,
rawBytes=393216, aggregateBytes=393216,
chunks=25, chunkMs=300000, strideMs=295000, durationMs=7200000
```

## Validation and caller obligations

The validator accepts a raw JSON string, not an arbitrary JS/provider object.
It checks raw UTF-8 size before parsing and requires exact root `version/segments`
and segment `startMs/endMs/speaker/text` keys. Duplicate keys, including Unicode-
escaped aliases, are rejected rather than silently taking the last value. A bounded
nonrecursive string/key scan follows JSON parsing/shape validation; there is no
additional parser dependency. Malformed shape, unknown version, extra provenance,
non-string text and out-of-range timestamps fail closed.

Timestamp pairs are both null or safe integers with
`0 <= startMs < endMs <= admittedDurationMs`. Duration is integer milliseconds,
positive and at most 300000. Segment order need not be chronological; raw ordinal
is preserved and the timed aggregate is sorted independently.

Text and non-null speaker labels must contain non-whitespace/non-format content.
Ordinary Unicode, tabs, CR and LF are allowed and retained. C0 except tab/CR/LF,
C1, directional formatting controls and unpaired surrogates are rejected. Zero-
width joiners inside legitimate text/emoji are retained. This is conservative
control rejection, not a Unicode security sanitizer. Labels remain untrimmed and
local. Zero segments is allowed for caller-confirmed silence; an empty text segment
is not. Provider completion/empty-audio policy remains a separate caller gate.

Merge requires the entire canonical manifest, including missing slots with null
rawText. It rejects extra/missing/duplicate indices, extra keys and noncanonical
offsets. Input order is irrelevant; originals are returned in index order.

```text
0 < T <= 7200000, integer milliseconds
N = 1 + ceil(max(0, T - 300000) / 295000)
start(i) = 295000*i
end(i) = min(start(i)+300000, T)
```

At T=7200000, indices 0..23 have 300000 ms each and index 24 is
[7080000,7200000), lasting 120000 ms. Total initial input is 7320000 ms:
the same approved 120000 ms fixed overhead, now 24 overlaps of 5000 ms each.
Old 600/590/10 manifests are rejected when they differ from this geometry; there
is no dual-geometry fallback under version 1. Short single-slot inputs <=300000 ms
are naturally unchanged.

Every non-null raw result is revalidated against its slot duration during merge.
Invalid results throw; the caller may separately retain a bounded invalid provider
response and supply null for its unavailable usable result. This module does not
silently convert invalid data into a successful chunk.

Caller must establish authentic media admission, exact decoded/presentation bounds,
provider finish state, ownership, selected attempt, and the immutable linkage from
each raw string to that attempt. The module cannot certify those facts from a string
or manifest. Source indices address the originals in this returned snapshot; they
are not authenticated provider/attempt IDs. Persist the selected-attempt linkage
outside this contract. `complete` means all slots have supplied valid result JSON,
not evidence of complete/accurate speech recognition or remote execution success.

## Deterministic lossless representation

- Exact original JSON strings remain in `originals`; no whitespace, text, label or
  response reserialization replaces them. All provenance is generated internally.
- Timed segments receive canonical offsets, then sort by global start, chunk index,
  raw segment ordinal. Untimed segments remain in ordered chunk sections with no
  fabricated timestamps. Both collections are necessary for a complete view.
- Only adjacent chunks' wholly overlapping segments with identical global intervals
  and exact NFC/whitespace-normalized text deduplicate. No case folding, punctuation
  removal, fuzzy match or sentence splitting. Earlier chunk text represents the
  derived segment, while both source ordinals and local speaker labels survive.
- Dedup is one-to-one: repeated segments in one chunk are not collapsed together or
  all consumed by one adjacent match. Repeated speech at different times is retained.
- Ambiguous timed intersections remain and both sides are flagged `overlaps=true`.
  This includes same-chunk intersections; touching endpoints are not overlaps.
  Untimed sections cannot honestly receive overlap flags without timestamps.
- Speaker identity is always `{chunkIndex,localLabel}`; equal labels across chunks
  do not establish global identity. Dedup can retain conflicting local labels in
  separate source references without inventing a mapping.
- `aggregateBytes` is exact UTF-8 byte size of JSON.stringify(aggregate), including
  provenance and missing indices. The 384 KiB cap is inclusive. On overflow, status
  is `too_large`, aggregate/aggregateBytes are null, and every original plus missing
  index remains available. There is no truncated-complete output. Callers page/store
  originals separately; the entire return object is NOT claimed to fit 384 KiB.

Known accepted ambiguity is unchanged: chunk 0 `[296000,297000,"yes","Alice"]`
and chunk 1 `[1000,2000,"yes","Bob"]` become one derived segment with two source
references, despite possibly representing simultaneous different speakers. Both
exact raw alternatives and namespaced labels remain. `overlaps:false` in this case
means no intersection with another retained timed entry, NOT acoustic certainty,
proven unique utterance or correct global speaker mapping. The named regression
`retains the known identical-text/time speaker ambiguity as a multi-source derived
equivalence` reproduces this explicitly. Downstream MUST expose multi-source
equivalence/provenance and raw alternatives, never irreversibly replace originals
with the derived view or claim globally correct speakers.

## Resource bounds and limits

At most 25 * 384 KiB = 9,830,400 bytes (9.375 MiB) raw JSON and
25 * 2048 = 51,200 segments are admitted per call, replacing the prior 13-slot
envelope. The 384 KiB aggregate limit and per-result limits remain unchanged.
Only one preceding chunk's overlap index is retained; cursor-based one-to-one
matching avoids quadratic queue shifts. Sorting is O(S log S), overlap marking
is linear, and size accounting serializes individual items/sections rather than
one oversized aggregate string. Raw code-unit checks precede UTF-8 allocation.
Object-key scan stack is capped at two object levels, even for values hidden by
duplicate keys. No recursive application-level walk, network, imports, dependency,
provider job, retry or persistent allocation is introduced.

These are algorithm/input bounds, NOT measured peak-RSS, deployed CPU limits or
codec-safety proof. JS parsing/normalization/runtime allocation overhead still exists.
The API receives an already-created string and cannot bound upstream HTTP reception.
Large returned originals require paged persistence/read APIs outside this module.
No rendering, audio playback or native save/reopen behavior was implemented/tested.

## Verification actually run

Environment: `/Users/tubakhuym/projects/lessmeet`, macOS 26.4 arm64, Node v22.22.3,
existing local TypeScript 5.9.3/Vitest 5.0.1, Vitest edge-runtime configuration.
No install, credential access, external calls, paid tests, native compilation,
deployment or commit/push. Existing backend suites use their offline fixtures/mocks.

Final source/test snapshot commands and observed outcomes:

```sh
npm run typecheck:backend
# PASS: tsc -p convex/tsconfig.json AND tsc -p Tests/backend/tsconfig.json
npm run test:backend -- Tests/backend/chunkResults.test.ts
# PASS: 116 tests, 1 file, runner duration 350 ms
npm run test:backend
# PASS: 583 tests, 16 files, runner duration 675 ms
git diff --check
# PASS, no output (tracked checkout check)
shasum -a 256 convex/chunkResults.ts Tests/backend/chunkResults.test.ts
# Matched the two hashes above
rg -n 'chunkResults' convex Tests/backend --glob '*.ts'
# Only Tests/backend/chunkResults.test.ts imports the module
```

No failed typecheck/test run was observed during this migration. Prior accepted
geometry had 107 scoped/574 full tests; those historical results do not establish
the migrated contract. The fresh 116/583 runs above exercise these new source/test
hashes. No native compilation or H-owned work was run.

Fixtures cover null/malformed/duplicate/extra-key JSON; byte, segment, speaker and
duration boundaries; valid Unicode/whitespace; control/surrogate rejection; canonical
300/295/5 geometry through 25 slots; out-of-range/duplicate manifests; spoofed
provenance; repeat/near-match/overlap cases; namespaced speakers; stable sorting and
input immutability; missing slots; exact aggregate-size boundary; timed/untimed
overflow; and the full 51,200-segment workload. Migration cases explicitly assert
old geometry rejection, 26th-slot rejection, five-second overlap endpoints and a
crossing alternative, 7320-second maximum initial input, unchanged version/caps,
full 25 * 384 KiB raw input and the accepted identical-text/time speaker ambiguity.
Tests and this handoff are the durable
reproduction evidence. No claim is made that fixture correctness proves timestamp
accuracy or real-world speaker/overlap equivalence.

## Accepted context and remaining gates

Human approved the fixed protocol-overhead allowance for internal beta: canonical
120-minute user quota versus at most 122 minutes initial provider input. It does not
prove content equality in overlap slots. This module performs no accounting and
does not grant quota, alter policy or authorize paid activation/public rollout.

Lead's two-job cap applies to new batch transcription jobs only, not a new global
chat refactor or all-Gemini cap. Initial plus one explicit attempt is the accepted
technical bound; unknown execution never auto-retries and timeout never proves
remote termination. Those lifecycle policies are not implemented in this pure
result module. Backend/schema/HTTP ownership and implementation remain separate.

Decoder consumption/safety remains unresolved; E's AAC probe is not adopted. Native
chunks remain untrusted at the server boundary. Neither the accounting approval nor
these passing tests remove that gate. No model prompt/schema wiring is made here.
