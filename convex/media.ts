import { createFile, MP4BoxBuffer } from "mp4box";
import { fail, MAX_AUDIO } from "./limits";

const invalid = (): never => fail(415, "Billing requires a valid, non-fragmented AAC M4A recording. Export or record it again in LessMeet.");
const positive = (n: number) => Number.isSafeInteger(n) && n > 0;

// Admission checks for the native M4A box tree, before MP4Box allocates tables
// or descends into containers. This is not a complete ISO-BMFF parser firewall:
// codec descriptors and extension boxes still belong to the downstream parser.
export function preflight(bytes: ArrayBuffer, batch = false) {
  const view = new DataView(bytes);
  const containers = new Set([
    "moov", "trak", "edts", "mdia", "minf", "dinf", "stbl", "udta",
    "meco", "hnti", "hinf", "strk", "strd", "sinf", "rinf", "schi", "trgr",
    "iprp", "ipco", "grpl", "j2kH", "etyp", "povd", "vttc", "mfra",
  ]);
  const tableWidths: Record<string, number> = { stts: 8, ctts: 8, stsc: 12, stco: 4, co64: 8, stss: 4 };
  let boxes = 0;
  let entries = 0;
  let sampleEntries = 0;
  function walk(start: number, end: number, depth: number, parent = "") {
    if (depth > 16) invalid();
    for (let offset = start; offset < end;) {
      if (++boxes > 4096 || end - offset < 8) invalid();
      let size = view.getUint32(offset), header = 8;
      const type = String.fromCharCode(...new Uint8Array(bytes, offset + 4, 4));
      if (size === 1) {
        if (end - offset < 16) invalid();
        size = view.getUint32(offset + 8) * 0x100000000 + view.getUint32(offset + 12);
        header = 16;
      }
      // Native exports use explicit sizes (including 64-bit mdat); no open-ended boxes.
      if (!Number.isSafeInteger(size) || size < header || size > end - offset) invalid();
      const body = offset + header, limit = offset + size, length = limit - body;
      const need = (n: number) => { if (length < n) invalid(); };
      const table = (prefix: number, count: number, width: number) => {
        if (count > 1_000_000 || count > (length - prefix) / width || length !== prefix + count * width) invalid();
        if (batch && (entries += count) > 65_536) invalid();
      };
      if (["moof", "mvex", "traf", "stz2"].includes(type)) invalid();
      if (type === "stsz") {
        need(12);
        const count = view.getUint32(body + 8);
        // In particular, constant-size stsz expands count entries DURING parse,
        // before buildSampleLists, so the existing later guard is not sufficient.
        if (view.getUint32(body) !== 0 || view.getUint32(body + 4) !== 0 || !positive(count)) invalid();
        if (batch && (sampleEntries += count) > 16_384) invalid();
        table(12, count, 4);
      } else if (Object.hasOwn(tableWidths, type)) {
        need(8);
        if (view.getUint8(body) !== 0 && !(type === "ctts" && view.getUint8(body) === 1)) invalid();
        table(8, view.getUint32(body + 4), tableWidths[type]);
      } else if (type === "elst") {
        need(8);
        const version = view.getUint8(body), count = view.getUint32(body + 4);
        if (version > 1 || count > 1) invalid();
        table(8, count, version === 1 ? 20 : 12);
      }
      let child = -1;
      if (containers.has(type) || type === "ilst" || parent === "ilst") child = body;
      else if (type === "meta") { need(4); child = body + 4; }
      else if (type === "stsd" || type === "dref") {
        need(8);
        if (view.getUint32(body) !== 0 || view.getUint32(body + 4) !== 1) invalid();
        child = body + 8;
      } else if (type === "mp4a") { need(28); child = body + 28; }
      if (child >= 0) walk(child, limit, depth + 1, type);
      offset = limit;
    }
  }
  walk(0, bytes.byteLength, 0);
}

// This is structural validation, NOT an AAC decoder. MP4Box parses the actual
// uploaded sample tables. We verify ranges and timelines and charge the maximum
// of sample timing and AAC-LC frame count; never a caller-supplied duration.
// A maliciously forged compressed payload still requires a decoder to disprove.
export function audioSeconds(bytes: ArrayBuffer, mimeType: string): number {
  if ((mimeType !== "audio/m4a" && mimeType !== "audio/mp4") || !bytes.byteLength || bytes.byteLength > MAX_AUDIO) invalid();
  try {
    preflight(bytes);
    const file = createFile();
    const buildSamples = file.buildSampleLists.bind(file);
    file.buildSampleLists = () => {
      if (file.moov.traks.length !== 1) invalid();
      const table = file.moov.traks[0].mdia.minf.stbl;
      // Bound expansion before the parser constructs per-sample objects. Native
      // AAC samples are variable-size, with one table entry per access unit.
      if (!table.stsz || table.stsz.sample_size !== 0 || !positive(table.stsz.sample_count) ||
          table.stsz.sample_count > 1_000_000 || table.stsz.sample_count > bytes.byteLength / 4 ||
          table.stsz.sample_sizes.length !== table.stsz.sample_count) invalid();
      buildSamples();
    };
    file.onError = () => { throw new Error("Invalid MP4"); };
    file.appendBuffer(MP4BoxBuffer.fromArrayBuffer(bytes, 0), true);
    file.flush();
    const info = file.getInfo();
    if (!info.hasMoov || info.isFragmented || info.tracks.length !== 1 || info.audioTracks.length !== 1 || !file.mdats.length) invalid();
    // Reject truncated/trailing unparsed bytes, not just a readable moov header.
    let end = 0;
    for (const box of file.boxes) {
      if (box.start !== end || !positive(box.size) || box.size < (box.hdr_size ?? 8)) invalid();
      end = end + box.size;
    }
    if (end !== bytes.byteLength) invalid();
    const track = info.audioTracks[0];
    const audio = track.audio;
    if (!audio) return invalid();
    if (track.codec !== "mp4a.40.2" || !positive(track.timescale) ||
        ![8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000].includes(audio.sample_rate) ||
        ![1, 2].includes(audio.channel_count) || !positive(track.nb_samples)) invalid();
    const samples = file.getTrackSamplesInfo(track.id);
    if (samples.length !== track.nb_samples) invalid();
    let ticks = 0, lastOffset = 0;
    for (const sample of samples) {
      if (!positive(sample.size) || !positive(sample.duration) || sample.timescale !== track.timescale ||
          !Number.isSafeInteger(sample.offset) || sample.offset < lastOffset || sample.dts !== ticks || sample.cts !== sample.dts ||
          !file.mdats.some(mdat => mdat.start !== undefined && sample.offset >= mdat.start + (mdat.hdr_size ?? 8) && sample.offset + sample.size <= mdat.start + mdat.size)) invalid();
      ticks += sample.duration;
      lastOffset = sample.offset + sample.size;
    }
    const timed = ticks / track.timescale;
    const frames = samples.length * 1024 / audio.sample_rate;
    const tolerance = 2 * 1024 / audio.sample_rate;
    // Only a single rate-1 trim is supported. Reject edit lists that repeat or
    // stretch audio, and inconsistent movie/track playback headers.
    if (!positive(info.timescale) || !positive(track.movie_timescale) ||
        Math.abs(info.duration / info.timescale - timed) > tolerance ||
        Math.abs(track.movie_duration / track.movie_timescale - timed) > tolerance ||
        (track.edits && (track.edits.length > 1 || track.edits.some(edit =>
          edit.media_rate_integer !== 1 || edit.media_rate_fraction !== 0 || edit.media_time < 0 ||
          edit.media_time / track.timescale > tolerance ||
          Math.abs(edit.segment_duration / info.timescale - timed) > tolerance)))) invalid();
    // AAC-LC access units represent 1024 PCM samples (960-frame variants are
    // conservatively overcharged). Permit only the final frame's padding delta.
    if (!Number.isFinite(timed) || timed <= 0 || Math.abs(timed - frames) > tolerance ||
        Math.abs(track.duration / track.timescale - timed) > tolerance) invalid();
    const seconds = Math.ceil(Math.max(timed, frames));
    if (!positive(seconds)) invalid();
    return seconds;
  } catch { return invalid(); }
}
