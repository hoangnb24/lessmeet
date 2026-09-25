import SwiftUI

/// Derived view and verbatim alternatives stay distinct; speaker labels are chunk-local.
struct BatchTranscriptView: View {
    let batch: LocalBatch
    @ObservedObject var cloud: RecordingCloudModel
    let enabled: Bool
    @State private var retryIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Batch transcription").font(.title2)
            Text("\(batch.status?.chunks.filter { $0.state == "succeeded" }.count ?? 0) of \(batch.manifest.chunks.count) chunks completed · \(batch.status?.state ?? "prepared locally")")
                .font(.callout).foregroundStyle(.secondary)
            if let pending = batch.pending {
                Text("Unresolved \(pending.kind) operation. Refresh to reconcile. Stopping this app does not stop remote generation.").foregroundStyle(.orange)
            }
            if let notice = batch.notice { Text(notice).foregroundStyle(.orange) }
            if batch.status?.cleanupPending == true { Text("Provider cleanup is still pending; completed text is not proof of deletion.").foregroundStyle(.orange) }
            HStack {
                Button("Refresh saved batch") { cloud.refresh() }.disabled(!enabled)
                if batch.status == nil || batch.status?.state == "uploading" {
                    Button("Continue saved upload") { cloud.continueBatch() }.disabled(!enabled)
                }
            }
            ForEach(batch.status?.chunks ?? [], id: \.index) { slot in
                HStack {
                    Text("Chunk \(slot.index + 1) · \(rangeLabel(slot.index)) · \(slot.state) · attempt \(slot.attempt)")
                    if slot.retryAllowed {
                        Button("Retry failed chunk") { retryIndex = slot.index }.disabled(!enabled)
                    }
                }.font(.caption)
            }
            if let response = batch.aggregate {
                Text("Saved view: \(response.status) · revision \(response.revision)").font(.caption)
                if !response.missingChunks.isEmpty {
                    Text("Missing chunks: \(response.missingChunks.map { String($0 + 1) }.joined(separator: ", ")). This is not a complete transcript.").foregroundStyle(.orange)
                }
                if response.status == "too_large" { Text("Combined view is too large. Original chunk results remain available below; nothing was truncated.") }
                if response.aggregate == nil, let previous = batch.lastReadableAggregate {
                    Text("Earlier saved view below · revision \(previous.revision). The latest combined view is unavailable.").foregroundStyle(.orange)
                }
                if let aggregate = response.aggregate ?? batch.lastReadableAggregate?.aggregate {
                    Text("Times use an enclosing millisecond display; the final boundary may be approximate. Speaker labels are local to each chunk.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(aggregate.timed.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(segment.startMs)–\(segment.endMs) ms\(segment.overlaps ? " · overlapping alternatives" : "")").font(.caption).foregroundStyle(.secondary)
                            Text(segment.text).textSelection(.enabled)
                            Text(segment.sources.map { source in
                                "chunk \(source.chunkIndex + 1), segment \(source.segmentIndex + 1)" + (source.speaker.map { ", local speaker \($0.localLabel)" } ?? "")
                            }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(aggregate.untimed.enumerated()), id: \.offset) { _, section in
                        Text("Untimed · chunk \(section.chunkIndex + 1)").font(.caption)
                        ForEach(Array(section.segments.enumerated()), id: \.offset) { _, segment in
                            Text(segment.text).textSelection(.enabled)
                            Text("Original segment \(segment.source.segmentIndex + 1)" + (segment.source.speaker.map { " · local speaker \($0.localLabel)" } ?? "")).font(.caption2)
                        }
                    }
                }
            } else { Text("No combined view saved yet. Refresh to check progress.").foregroundStyle(.secondary) }
            ForEach(batch.results.keys.sorted(), id: \.self) { key in
                if let raw = batch.results[key] {
                    DisclosureGroup("Original JSON · chunk \(raw.index + 1), attempt \(raw.attempt)") {
                        Text(raw.rawText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .confirmationDialog("Retry only this failed chunk?", isPresented: Binding(get: { retryIndex != nil }, set: { if !$0 { retryIndex = nil } })) {
            Button("Retry failed chunk (may incur a charge)") { if let index = retryIndex { cloud.retryBatch(index: index) }; retryIndex = nil }
            Button("Cancel", role: .cancel) { retryIndex = nil }
        } message: { Text("Only one explicit retry is allowed. Successful siblings and unknown work will not be rerun.") }
    }
    private func rangeLabel(_ index: Int) -> String {
        guard batch.manifest.chunks.indices.contains(index), let end = try? batch.manifest.source.duration.enclosingMilliseconds else { return "range unavailable" }
        let start = Int64(index) * 295_000
        return "\(start)–\(min(start + 300_000, end)) ms (enclosing)"
    }
}
