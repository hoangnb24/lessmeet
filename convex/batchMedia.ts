import { createFile, MP4BoxBuffer } from "mp4box";
import { preflight } from "./media";
import { failBatch, type Rational } from "./batchContract";

function invalid(): never { return failBatch(415, "invalid_media", "Batch audio must have an exact supported AAC presentation timeline."); }
const integer = (n: number) => { if (!Number.isSafeInteger(n) || n < 0) invalid(); return BigInt(n); };

// Read declared timing before MP4Box can reconstruct or repair sample durations.
// preflight has already bounded box sizes/depth and table entries. This walk only
// follows the sample-table path, never searches compressed payload for fourccs.
function declaredTiming(bytes: ArrayBuffer) {
  const view = new DataView(bytes);
  let timingBody: number | undefined, sizeBody: number | undefined;
  const path = ["moov", "trak", "mdia", "minf", "stbl"];
  function walk(start: number, end: number, depth: number) {
    for (let offset = start; offset < end;) {
      let size = view.getUint32(offset), header = 8;
      if (size === 1) { size = Number(view.getBigUint64(offset + 8)); header = 16; }
      const type = String.fromCharCode(...new Uint8Array(bytes, offset + 4, 4)), body = offset + header;
      if (depth < path.length && type === path[depth]) walk(body, offset + size, depth + 1);
      else if (depth === path.length && type === "stts") { if (timingBody !== undefined) invalid(); timingBody = body; }
      else if (depth === path.length && type === "stsz") { if (sizeBody !== undefined) invalid(); sizeBody = body; }
      offset += size;
    }
  }
  walk(0, bytes.byteLength, 0);
  if (timingBody === undefined || sizeBody === undefined || view.getUint32(timingBody) !== 0) invalid();
  const count = view.getUint32(sizeBody + 8), entries = view.getUint32(timingBody + 4);
  if (!count || count > 16384 || !entries || entries > count) invalid();
  const runs: { count: number; delta: number }[] = [];
  let covered = 0, ticks = 0n;
  for (let i = 0; i < entries; i++) {
    const runCount = view.getUint32(timingBody + 8 + i * 8), delta = view.getUint32(timingBody + 12 + i * 8);
    if (!runCount || !delta || runCount > count - covered) invalid();
    covered += runCount; ticks += BigInt(runCount) * BigInt(delta);
    runs.push({ count: runCount, delta });
  }
  if (covered !== count) invalid();
  return { count, ticks, runs };
}

// Only the bounded Apple freeform metadata path, not a scan of compressed payload.
function gapless(bytes: ArrayBuffer): bigint[] | null {
  const view = new DataView(bytes), decoder = new TextDecoder("utf-8", { fatal: true });
  type Box = { type: string; body: number; end: number };
  function boxes(start: number, end: number): Box[] {
    const result: Box[] = [];
    while (start < end) {
      let size = view.getUint32(start), header = 8;
      if (size === 1) { size = Number(view.getBigUint64(start + 8)); header = 16; }
      if (!Number.isSafeInteger(size) || size < header || start + size > end) invalid();
      result.push({ type: String.fromCharCode(...new Uint8Array(bytes, start + 4, 4)), body: start + header, end: start + size });
      start += size;
    }
    return result;
  }
  let found: bigint[] | null = null;
  const walk = (start: number, end: number) => {
    for (const box of boxes(start, end)) {
      if (["moov", "udta", "ilst"].includes(box.type)) walk(box.body, box.end);
      else if (box.type === "meta") walk(box.body + 4, box.end);
      else if (box.type === "----") {
        const children = boxes(box.body, box.end);
        const names = children.filter(c => c.type === "name");
        if (!names.some(c => decoder.decode(bytes.slice(c.body + 4, c.end)) === "iTunSMPB")) continue;
        if (found || names.length !== 1 || children.length !== 3) invalid();
        const mean = children.find(c => c.type === "mean"), data = children.find(c => c.type === "data");
        if (!mean || !data || decoder.decode(bytes.slice(mean.body + 4, mean.end)) !== "com.apple.iTunes" || view.getUint32(data.body) !== 1 || view.getUint32(data.body + 4) !== 0) invalid();
        const words = decoder.decode(bytes.slice(data.body + 8, data.end)).trim().split(/\s+/);
        if (words.length !== 12 || words.some((w, i) => !new RegExp(`^[0-9a-fA-F]{${i === 3 ? 16 : 8}}$`).test(w))) invalid();
        const values = words.map(w => BigInt(`0x${w}`));
        if (values[0] !== 0n || values.slice(4).some(v => v !== 0n)) invalid();
        found = values.slice(1, 4); // priming, padding, valid presentation samples
      }
    }
  };
  walk(0, bytes.byteLength);
  return found;
}

export function batchMedia(bytes: ArrayBuffer, expected: Rational) {
  try {
    if (!bytes.byteLength || bytes.byteLength > 18874368) invalid();
    preflight(bytes, true);
    const declared = declaredTiming(bytes);
    const trim = gapless(bytes);
    const file = createFile();
    file.onError = () => invalid();
    file.appendBuffer(MP4BoxBuffer.fromArrayBuffer(bytes, 0), true); file.flush();
    const info = file.getInfo();
    if (!info.hasMoov || info.isFragmented || info.tracks.length !== 1 || info.audioTracks.length !== 1 || !file.mdats.length) invalid();
    let end = 0;
    for (const box of file.boxes) { if (box.start !== end || !Number.isSafeInteger(box.size) || box.size < (box.hdr_size ?? 8)) invalid(); end += box.size; }
    if (end !== bytes.byteLength) invalid();
    const track = info.audioTracks[0];
    if (!track.audio || track.codec !== "mp4a.40.2" || ![8000,11025,12000,16000,22050,24000,32000,44100,48000].includes(track.audio.sample_rate) || ![1,2].includes(track.audio.channel_count)) invalid();
    const rate = integer(track.audio.sample_rate);
    const coded = integer(track.nb_samples) * 1024n, scale = integer(track.timescale);
    const media = integer(track.duration);
    if (!scale || !integer(info.timescale) || !integer(track.movie_timescale) || track.nb_samples > 16384) invalid();
    const samples = file.getTrackSamplesInfo(track.id);
    if (samples.length !== track.nb_samples || samples.length !== declared.count || !samples.length || declared.ticks !== media) invalid();
    let ticks = 0n, lastOffset = 0, run = 0, remaining = declared.runs[0].count;
    for (const [i, s] of samples.entries()) {
      if (s.duration !== declared.runs[run].delta) invalid();
      if (!Number.isSafeInteger(s.size) || s.size <= 0 || !Number.isSafeInteger(s.offset) || s.offset < lastOffset ||
          s.timescale !== track.timescale || integer(s.dts) !== ticks || s.cts !== s.dts || !s.duration ||
          !file.mdats.some(m => m.start !== undefined && s.offset >= m.start + (m.hdr_size ?? 8) && s.offset + s.size <= m.start + m.size)) invalid();
      const frames = integer(s.duration) * rate;
      if (i + 1 < samples.length ? frames !== 1024n * scale : frames > 1024n * scale) invalid();
      ticks += integer(s.duration); lastOffset = s.offset + s.size;
      if (--remaining === 0 && i + 1 < samples.length) { run++; remaining = declared.runs[run].count; }
    }
    if (ticks !== media) invalid();
    let priming = 0n, presentation = media * rate / scale;
    if (media * rate % scale !== 0n || scale === 0n) invalid();
    if (trim) {
      priming = trim[0]; presentation = trim[2];
      if (priming + trim[1] + presentation !== coded || media * rate !== coded * scale) invalid();
    }
    if (track.edits?.length) {
      if (track.edits.length !== 1 || track.edits[0].media_rate_integer !== 1 || track.edits[0].media_rate_fraction !== 0) invalid();
      const edit = track.edits[0], movieScale = integer(info.timescale);
      const p = integer(edit.media_time) * rate, duration = integer(edit.segment_duration) * rate;
      if (p % scale || duration % movieScale) invalid();
      const editPriming = p / scale, editPresentation = duration / movieScale;
      if (trim && (editPriming !== priming || editPresentation !== presentation)) invalid();
      priming = editPriming; presentation = editPresentation;
      if (integer(info.duration) * rate !== presentation * movieScale || integer(track.movie_duration) * rate !== presentation * integer(track.movie_timescale)) invalid();
    } else {
      // Native SMPB exports describe coded duration in movie/media headers.
      if (integer(info.duration) * scale !== media * integer(info.timescale) || integer(track.movie_duration) * scale !== media * integer(track.movie_timescale)) invalid();
    }
    if (presentation <= 0n || priming + presentation > coded || priming + presentation > media * rate / scale ||
        presentation * BigInt(expected.timescale) !== BigInt(expected.value) * rate || presentation > 300n * rate) invalid();
    return { validation: "structural_aac_v1" as const, byteLength: bytes.byteLength,
      sampleRate: Number(rate), channels: track.audio!.channel_count, accessUnitCount: track.nb_samples,
      codedSampleCount: Number(coded), mediaTimescale: track.timescale, mediaDurationTicks: track.duration,
      primingSampleCount: Number(priming), presentationSampleCount: Number(presentation), trailingPaddingSampleCount: Number(coded - priming - presentation) };
  } catch { return invalid(); }
}
