import { describe, it, expect } from "vitest";
import { batchMedia } from "../../convex/batchMedia";
import { geometry, manifest, digestInput, digest, sha256, controlJSON, validateResult } from "../../convex/batchContract";
import { nativeM4aFixture } from "./nativeMediaFixture";
import { m4aFixture } from "./mediaFixture";
import { audioSeconds } from "../../convex/media";
import { nativeWithEdit, nativeWithTiming, structuralFixture } from "./batchMediaFixture";
import { readFileSync } from "node:fs";

describe("batch exact admission", () => {
  it.each([60, 62])("rejects original stts count %s when stsz declares 61", count => {
    const bytes = nativeM4aFixture(), offset = Buffer.from(bytes).indexOf("stts");
    expect(offset).toBeGreaterThan(0); new DataView(bytes).setUint32(offset + 12, count);
    expect(() => batchMedia(bytes, { value: 5, timescale: 4 })).toThrow();
    // Batch-only correction must not reinterpret existing legacy acceptance/billing.
    expect(audioSeconds(bytes, "audio/m4a")).toBe(2);
  });
  it("admits frozen native fractional export bytes and matches its digest", async () => {
    const root = new URL("../fixtures/batch-native/", import.meta.url);
    const m = manifest(JSON.parse(readFileSync(new URL("wire-manifest.json", root), "utf8")));
    const evidence = JSON.parse(readFileSync(new URL("evidence.json", root), "utf8"));
    const bytes = Uint8Array.from(readFileSync(new URL("chunks/chunk-00.m4a", root))).buffer;
    expect(bytes.byteLength).toBe(m.chunks[0].bytes); expect(await sha256(bytes)).toBe(m.chunks[0].sha256);
    expect(batchMedia(bytes, m.source.duration)).toMatchObject({ sampleRate: 44100, presentationSampleCount: 132301 });
    expect(await digest(m)).toBe(evidence.manifestDigest);
  });
  it("accepts exact multi-run timing coverage", () => {
    expect(batchMedia(nativeWithTiming([[30, 1024], [30, 1024], [1, 1024]]), { value: 5, timescale: 4 }).accessUnitCount).toBe(61);
  });
  it.each([
    [[30, 1024], [30, 1024]],
    [[30, 1024], [32, 1024]],
    [[60, 1024], [1, 2048]],
    [[61, 1024], [0, 1024]],
    [[0xffffffff, 1024], [1, 1024]],
  ] as [number, number][][])("rejects contradictory/empty/unbounded timing runs %j", (...runs) => {
    expect(() => batchMedia(nativeWithTiming(runs), { value: 5, timescale: 4 })).toThrow();
  });
  it("admits actual native gapless metadata without legacy billing changes", () => {
    const bytes = nativeM4aFixture();
    expect(batchMedia(bytes, { value: 5, timescale: 4 })).toMatchObject({ codedSampleCount: 62464, primingSampleCount: 2112, presentationSampleCount: 60000, trailingPaddingSampleCount: 352 });
    expect(audioSeconds(bytes, "audio/m4a")).toBe(2);
    expect(() => batchMedia(bytes, { value: 1301, timescale: 1000 })).toThrow();
  });
  it("admits exact edit-list presentation", () => {
    expect(batchMedia(m4aFixture(), { value: 1, timescale: 10 })).toMatchObject({ presentationSampleCount: 4800, primingSampleCount: 1024 });
  });
  it("accepts agreeing native SMPB/edit declarations and rejects conflicting ones", () => {
    expect(batchMedia(nativeWithEdit(), { value: 5, timescale: 4 }).presentationSampleCount).toBe(60000);
    expect(() => batchMedia(nativeWithEdit(true), { value: 5, timescale: 4 })).toThrow();
  });
  it("bounds a full 300 second sample table before expansion", () => {
    const bytes = structuralFixture(300);
    expect(batchMedia(bytes, { value: 300, timescale: 1 })).toMatchObject({ presentationSampleCount: 14400000, accessUnitCount: 14065 });
    expect(() => batchMedia(structuralFixture(301), { value: 300, timescale: 1 })).toThrow();
    expect(() => batchMedia(structuralFixture(400), { value: 300, timescale: 1 })).toThrow();
  });
  it("computes 120 minute geometry and quota exactly", () => {
    const g = geometry({ value: 7200, timescale: 1 });
    expect(g).toHaveLength(25); expect(g.reduce((n, c) => n + c.value / c.timescale, 0)).toBe(7320);
    expect(g.reduce((n, c) => n + c.quota, 0)).toBe(7200);
  });
  it("rejects duplicate keys and fractional timestamp overreach", () => {
    expect(() => controlJSON('{"a":1,"\\u0061":2}')).toThrow();
    expect(() => validateResult('{"version":1,"segments":[{"startMs":0,"endMs":1,"speaker":null,"text":"x"}]}', { value: 1, timescale: 48000 })).toThrow();
    expect(validateResult('{"version":1,"segments":[]}', { value: 1, timescale: 48000 }).rawText).toContain("segments");
  });
  it("uses fixed digest serialization and reduced source fractions", async () => {
    const m = { version: 1, source: { sha256: "a".repeat(64), bytes: 1, duration: { value: 5, timescale: 4 } }, chunks: [{ sha256: "b".repeat(64), bytes: 1 }] };
    expect(digestInput(manifest(m))).toBe(JSON.stringify(["lessmeet.batch.geometry.v1", "a".repeat(64), 1, 5, 4, [[0, "b".repeat(64), 1]]]));
    expect(await digest(manifest(m))).toBe("cf7f70ecfb89df934aaf59fdccd3814a325763ee598461595df1113b58977f8f");
    expect(() => manifest({ ...m, source: { ...m.source, duration: { value: 10, timescale: 8 } } })).toThrow();
  });
});
