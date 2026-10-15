import Foundation

struct LocalAudioWindow {
    let index: Int
    let samples: [Float]
    var startMs: Int64 { Int64(index) * 295_000 }
    var endMs: Int64 { min(7_200_000, startMs + Int64((samples.count + 15) / 16)) }
}

/// One reader preserves resampler state. Only the last five seconds are reused.
final class LocalAudioWindows {
    private let read: (Int) throws -> [Float]
    private var overlap: [Float] = []
    private var index = 0
    private var finished = false
    private static let capacity = 300 * 16_000
    private static let overlapCount = 5 * 16_000

    convenience init(reader: LocalPCMReader) {
        self.init(read: { try reader.read(maxSamples: $0) })
    }

    init(read: @escaping (Int) throws -> [Float]) { self.read = read }

    func next() throws -> LocalAudioWindow? {
        try Task.checkCancellation()
        guard !finished else { return nil }
        var samples = overlap
        let reused = samples.count
        samples.reserveCapacity(Self.capacity)
        while samples.count < Self.capacity {
            try Task.checkCancellation()
            let requested = min(16_384, Self.capacity - samples.count)
            let block = try read(requested)
            guard block.count <= requested, block.allSatisfy(\.isFinite) else {
                finished = true
                throw LocalPCMReader.Failure.decoding("Invalid PCM reader block.")
            }
            if block.isEmpty {
                finished = true
                break
            }
            samples.append(contentsOf: block)
        }
        // EOF immediately after a full window must not emit overlap alone.
        guard samples.count > reused else { return nil }
        guard index <= 24 else {
            finished = true
            throw LocalPCMReader.Failure.invalidSource("Audio exceeds two hours.")
        }
        let window = LocalAudioWindow(index: index, samples: samples)
        index += 1
        overlap = finished ? [] : Array(samples.suffix(Self.overlapCount))
        return window
    }
}
