import XCTest
#if !LOCAL_WINDOWS_STANDALONE
@testable import LessMeet
#endif

final class LocalAudioWindowsTests: XCTestCase {
    func testWindowGeometryAndExactOverlap() throws {
        for seconds in [1, 295, 300, 301, 590, 595, 650] {
            let total = seconds * 16_000
            var cursor = 0
            let windows = LocalAudioWindows { requested in
                let end = min(total, cursor + requested)
                defer { cursor = end }
                return (cursor..<end).map { Float($0 % 1024) }
            }
            var previous: LocalAudioWindow?
            var count = 0
            while let window = try windows.next() {
                XCTAssertEqual(window.startMs, Int64(count * 295_000))
                XCTAssertEqual(window.endMs, min(window.startMs + 300_000, Int64(seconds * 1000)))
                XCTAssertLessThanOrEqual(window.samples.count, 4_800_000)
                if let previous {
                    XCTAssertEqual(Array(previous.samples.suffix(80_000)), Array(window.samples.prefix(80_000)))
                }
                let offset = count * 295 * 16_000
                for position in stride(from: 0, to: window.samples.count, by: 7_919) {
                    XCTAssertEqual(window.samples[position], Float((offset + position) % 1024))
                }
                previous = window
                count += 1
            }
            XCTAssertEqual(count, seconds <= 300 ? 1 : 1 + (seconds - 300 + 294) / 295)
            XCTAssertEqual(cursor, total)
            XCTAssertNil(try windows.next())
        }
    }

    func testEmptyAndFractionalTail() throws {
        XCTAssertNil(try LocalAudioWindows(read: { _ in [] }).next())
        var delivered = false
        let windows = LocalAudioWindows { _ in
            defer { delivered = true }
            return delivered ? [] : [Float](repeating: 0.1, count: 17)
        }
        XCTAssertEqual(try windows.next()?.endMs, 2)
        XCTAssertNil(try windows.next())
    }

    func testInvalidReaderAndFailurePropagate() {
        XCTAssertThrowsError(try LocalAudioWindows(read: { _ in [.nan] }).next())
        XCTAssertThrowsError(try LocalAudioWindows(read: { count in Array(repeating: 0, count: count + 1) }).next())
        XCTAssertThrowsError(try LocalAudioWindows(read: { _ in throw CancellationError() }).next()) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}

#if LOCAL_WINDOWS_STANDALONE
@main enum LocalAudioWindowsTestRunner {
    static func main() {
        let suite = LocalAudioWindowsTests.defaultTestSuite
        suite.run()
        exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
    }
}
#endif
