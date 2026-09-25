import { beforeEach, describe, expect, it, vi } from "vitest";
import { createFile } from "mp4box";
import { ConvexError } from "convex/values";
import { audioSeconds } from "../../convex/media";
import { MAX_AUDIO } from "../../convex/limits";
import { m4aFixture } from "./mediaFixture";
import { nativeM4aFixture } from "./nativeMediaFixture";

vi.mock("mp4box", async importOriginal => {
  const actual = await importOriginal<typeof import("mp4box")>();
  return { ...actual, createFile: vi.fn(actual.createFile) };
});
const parser = vi.mocked(createFile);
const join = (...parts: Uint8Array[]) => {
  const bytes = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
  let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return bytes;
};
const box = (type: string, body = new Uint8Array()) => {
  const bytes = new Uint8Array(8 + body.length);
  new DataView(bytes.buffer).setUint32(0, bytes.length);
  bytes.set(new TextEncoder().encode(type), 4); bytes.set(body, 8);
  return bytes;
};
// These markers are unique in the two fixed synthetic fixtures, not a general parser.
function position(bytes: Uint8Array, type: string) {
  const marker = new TextEncoder().encode(type);
  const index = bytes.findIndex((_, i) => marker.every((b, j) => bytes[i + j] === b));
  if (index < 4) throw new Error(`Missing fixture box ${type}`);
  return index - 4;
}
function changed(type: string, field: number, value: number) {
  const bytes = new Uint8Array(m4aFixture());
  new DataView(bytes.buffer).setUint32(position(bytes, type) + field, value);
  return bytes;
}
function rejects(bytes: Uint8Array) {
  try { audioSeconds(bytes.slice().buffer, "audio/mp4"); throw new Error("Accepted hostile fixture"); }
  catch (error) {
    expect(error).toBeInstanceOf(ConvexError);
    expect((error as ConvexError<{ status: number }>).data.status).toBe(415);
  }
}
function rejectsBeforeParser(bytes: Uint8Array) {
  // Even on the vulnerable baseline, never execute adversarial allocation/recursion.
  parser.mockImplementationOnce(() => { throw new Error("Guarded parser boundary"); });
  rejects(bytes);
  expect(parser).not.toHaveBeenCalled();
}
beforeEach(() => { parser.mockReset(); });

describe("bounded M4A pre-parser admission", () => {
  it.each([0, 1, 7, 0xffffffff])("rejects invalid declared box size %i before parsing", size => {
    rejectsBeforeParser(changed("moov", 0, size));
  });
  it("rejects truncated extended-size headers", () => {
    const bytes = box("mdat"); new DataView(bytes.buffer).setUint32(0, 1);
    rejectsBeforeParser(bytes);
  });
  it("rejects unsafe 64-bit sizes", () => {
    const bytes = box("mdat", new Uint8Array(8)); const view = new DataView(bytes.buffer);
    view.setUint32(0, 1); view.setUint32(8, 0x200000); view.setUint32(12, 1);
    rejectsBeforeParser(bytes);
  });
  it("rejects a child crossing its parent despite available file bytes", () => {
    rejectsBeforeParser(join(box("moov", box("free", new Uint8Array(4)).slice(0, 8)), box("free")));
  });
  it("rejects truncated trailing box headers", () => {
    rejectsBeforeParser(join(new Uint8Array(m4aFixture()), new Uint8Array(7)));
  });
  it("bounds nested containers using only 40 tiny boxes", () => {
    let bytes = box("free"); for (let i = 0; i < 40; i++) bytes = box("moov", bytes);
    expect(bytes.length).toBe(328); rejectsBeforeParser(bytes);
  });
  it("bounds wide box lists using only 4097 empty boxes", () => {
    rejectsBeforeParser(join(...Array.from({ length: 4097 }, () => box("free"))));
  });
  it("rejects constant-size sample expansion before MP4Box allocates", () => {
    const bytes = changed("stsz", 12, 1);
    new DataView(bytes.buffer).setUint32(position(bytes, "stsz") + 16, 0xffffffff);
    rejectsBeforeParser(bytes);
  });
  it.each(["stsz", "stts", "stsc", "stco"])("rejects unbacked %s entry counts", type => {
    rejectsBeforeParser(changed(type, type === "stsz" ? 16 : 12, 0xffffffff));
  });
  it("rejects a table reading entries from its next sibling", () => {
    const bytes = new Uint8Array(m4aFixture()); const view = new DataView(bytes.buffer);
    const field = position(bytes, "stts") + 12;
    view.setUint32(field, view.getUint32(field) + 1);
    rejectsBeforeParser(bytes);
  });
  it("rejects short co64 tables before reading 64-bit offsets", () => {
    const bytes = new Uint8Array(m4aFixture());
    bytes.set(new TextEncoder().encode("co64"), position(bytes, "stco") + 4);
    rejectsBeforeParser(bytes);
  });
  it("bounds nested sample-entry boxes", () => {
    let bytes = box("free");
    for (let i = 0; i < 20; i++) bytes = box("mp4a", join(new Uint8Array(28), bytes));
    rejectsBeforeParser(bytes);
  });
  it("bounds nested metadata boxes", () => {
    let bytes = box("free");
    for (let i = 0; i < 20; i++) bytes = box("meta", join(new Uint8Array(4), bytes));
    rejectsBeforeParser(bytes);
  });
  it("rejects multiple sample descriptions before parsing", () => {
    rejectsBeforeParser(changed("stsd", 12, 0xffffffff));
  });
  it("rejects compact sample sizes before expansion", () => {
    const bytes = changed("stsz", 16, 0xffffffff);
    bytes.set(new TextEncoder().encode("stz2"), position(bytes, "stsz") + 4);
    rejectsBeforeParser(bytes);
  });
  it("rejects fragmented inputs before sample expansion", () => {
    rejectsBeforeParser(join(new Uint8Array(m4aFixture()), box("moof")));
  });
  it("keeps the 18 MiB input cap", () => rejectsBeforeParser(new Uint8Array(MAX_AUDIO + 1)));
});

describe("real-parser compatibility and explicit residual risk", () => {
  it("preserves FFmpeg and native export billing under both accepted MIME types", () => {
    for (const mime of ["audio/mp4", "audio/m4a"]) {
      expect(audioSeconds(m4aFixture(), mime)).toBe(1);
      expect(audioSeconds(nativeM4aFixture(), mime)).toBe(2);
    }
    expect(parser).toHaveBeenCalledTimes(4);
  });
  it("rejects bounded actual malformed sample offsets and truncated media", () => {
    rejects(changed("stco", 16, 0xffffff00));
    rejects(new Uint8Array(nativeM4aFixture().slice(0, -1)));
  });
  it("accepts an upload exactly at the unchanged cap with opaque free padding", () => {
    const original = new Uint8Array(m4aFixture());
    const bytes = join(original, box("free", new Uint8Array(MAX_AUDIO - original.length - 8)));
    expect(bytes.length).toBe(MAX_AUDIO);
    expect(audioSeconds(bytes.buffer, "audio/mp4")).toBe(1);
  });
  it("documents that structural admission still accepts erased compressed payload", () => {
    const bytes = new Uint8Array(m4aFixture()); const start = position(bytes, "mdat");
    const size = new DataView(bytes.buffer).getUint32(start);
    bytes.fill(0, start + 8, start + size);
    expect(audioSeconds(bytes.buffer, "audio/mp4")).toBe(1);
    expect(parser).toHaveBeenCalledOnce();
  });
});
