import { nativeM4aFixture } from "./nativeMediaFixture";

// Table-only synthetic AAC fixtures. These establish structural bounds, not decode
// or acoustic quality. Original fixture is an actual Apple offline synthetic export.
type Box = { type: string; body: Buffer };
function boxes(data: Buffer): Box[] {
  const result: Box[] = [];
  for (let i = 0; i < data.length;) {
    let size = data.readUInt32BE(i), header = 8;
    if (size === 1) { size = Number(data.readBigUInt64BE(i + 8)); header = 16; }
    result.push({ type: data.toString("latin1", i + 4, i + 8), body: data.subarray(i + header, i + size) }); i += size;
  }
  return result;
}
function box(type: string, body: Buffer): Buffer {
  const header = Buffer.alloc(8); header.writeUInt32BE(body.length + 8); header.write(type, 4, "latin1"); return Buffer.concat([header, body]);
}
function words(...values: number[]) { const b = Buffer.alloc(values.length * 4); values.forEach((v, i) => b.writeUInt32BE(v, i * 4)); return b; }
function arrayBuffer(b: Buffer) { return Uint8Array.from(b).buffer; }

export function structuralFixture(seconds: number): ArrayBuffer {
  const samples = Math.round(seconds * 48000), priming = 2112, count = Math.ceil((samples + priming) / 1024), coded = count * 1024;
  const original = boxes(Buffer.from(nativeM4aFixture())), ftyp = original.find(b => b.type === "ftyp")!;
  const audioOffset = ftyp.body.length + 8 + 8;
  const rewrite = (data: Buffer): Buffer => Buffer.concat(boxes(data).map(b => {
    let body: Buffer = Buffer.from(b.body);
    if (["moov", "trak", "mdia", "minf", "stbl", "udta", "ilst", "----"].includes(b.type)) body = rewrite(body);
    else if (b.type === "meta") body = Buffer.concat([body.subarray(0, 4), rewrite(body.subarray(4))]);
    else if (["mvhd", "mdhd"].includes(b.type)) body.writeUInt32BE(coded, 16);
    else if (b.type === "tkhd") body.writeUInt32BE(coded, 20);
    else if (b.type === "stts") body = words(0, 1, count, 1024);
    else if (b.type === "stsc") body = words(0, 1, 1, count, 1);
    else if (b.type === "stsz") body = words(0, 0, count, ...Array<number>(count).fill(4));
    else if (b.type === "stco") body = words(0, 1, audioOffset);
    else if (b.type === "data" && body.subarray(8).toString().includes("00000840")) {
      const text = ` 00000000 00000840 ${(coded - priming - samples).toString(16).padStart(8, "0")} ${samples.toString(16).padStart(16, "0")} 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000`;
      body = Buffer.concat([body.subarray(0, 8), Buffer.from(text)]);
    }
    return box(b.type, body);
  }));
  return arrayBuffer(Buffer.concat([box("ftyp", ftyp.body), box("mdat", Buffer.alloc(count * 4)), rewrite(box("moov", original.find(b => b.type === "moov")!.body))]));
}

export function nativeWithEdit(conflict = false): ArrayBuffer {
  const rewrite = (data: Buffer): Buffer => Buffer.concat(boxes(data).map(b => {
    let body: Buffer = Buffer.from(b.body);
    if (b.type === "moov" || b.type === "trak") body = rewrite(body);
    if (b.type === "mvhd") body.writeUInt32BE(60000, 16);
    if (b.type === "tkhd") body.writeUInt32BE(60000, 20);
    if (b.type === "trak") body = Buffer.concat([body, box("edts", box("elst", words(0, 1, 60000, conflict ? 2113 : 2112, 0x10000)))]);
    return box(b.type, body);
  }));
  // Retain the original extended mdat header/offsets exactly; edit only final moov.
  const bytes = Buffer.from(nativeM4aFixture());
  const moovStart = bytes.lastIndexOf(Buffer.from("moov")) - 4;
  return arrayBuffer(Buffer.concat([bytes.subarray(0, moovStart), rewrite(bytes.subarray(moovStart))]));
}

export function nativeWithTiming(runs: [number, number][]): ArrayBuffer {
  const rewrite = (data: Buffer): Buffer => Buffer.concat(boxes(data).map(b => {
    let body: Buffer = Buffer.from(b.body);
    if (["moov", "trak", "mdia", "minf", "stbl"].includes(b.type)) body = rewrite(body);
    if (b.type === "stts") body = words(0, runs.length, ...runs.flat());
    return box(b.type, body);
  }));
  const bytes = Buffer.from(nativeM4aFixture()), start = bytes.lastIndexOf(Buffer.from("moov")) - 4;
  return arrayBuffer(Buffer.concat([bytes.subarray(0, start), rewrite(bytes.subarray(start))]));
}
