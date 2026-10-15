import XCTest
#if !LOCAL_MERGE_STANDALONE
@testable import LessMeet
#endif

final class LocalSegmentMergerTests: XCTestCase {
    private func segment(_ start: Int64? = 296_000, _ end: Int64? = 297_000,
                         _ text: String = "Hello", _ speaker: String? = nil) -> LocalTranscriptSegment {
        LocalTranscriptSegment(startMs: start, endMs: end, speaker: speaker, text: text)
    }
    private func window(_ index: Int, _ segments: [LocalTranscriptSegment]) -> LocalTranscriptWindow {
        let start = Int64(index) * 295_000
        return LocalTranscriptWindow(index: index, startMs: start,
                                     endMs: min(start + 300_000, 7_200_000), segments: segments)
    }
    private func anchorWords(_ start: Int64 = 297_000, count: Int = 3) -> [LocalTranscriptSegment] {
        (0..<count).map { index in
            segment(start + Int64(index) * 200, start + Int64(index + 1) * 200, " anchor\(index)")
        }
    }

    func testDriftBoundaryAndOriginalPreservation() throws {
        for drift: Int64 in [0, 1, 120, 250, 251] {
            let original = segment()
            let shifted = segment(296_000 + drift, 297_000 + drift)
            let inputs = [window(0, [original]), window(1, [shifted])]
            let result = try LocalSegmentMerger.merge(inputs)
            XCTAssertEqual(result, drift <= 250 ? [original] : [original, shifted])
            XCTAssertEqual(inputs[0].segments, [original])
            XCTAssertEqual(inputs[1].segments, [shifted])
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment()]), window(1, [segment(296_001, 297_001)])
        ], toleranceMs: 0).count, 2)
    }

    func testObserved590SecondBoundary() throws {
        // Raw windows 2/3 from the 650-second fixture, with absolute millisecond times.
        let left = [segment(591_780, 592_340, " We"), segment(592_340, 592_500, " are"),
                    segment(592_500, 592_720, " testing"), segment(592_720, 593_080, " a"),
                    segment(593_080, 593_360, " local"), segment(593_360, 593_700, " meeting"),
                    segment(593_700, 594_020, " recorder."), segment(594_380, 594_700, " The"),
                    segment(594_700, 595_000, " project")]
        let right = [segment(591_219, 591_860, " We"), segment(591_859, 592_500, " are")]
            + Array(left[2...7]) + [segment(594_699, 595_060, " project")]
        let decision = segment(595_060, 595_500, " decision")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(1, left), window(2, right + [decision])]),
                       left + [decision])
        // Include the serialized one-ms rounding variant visible in long-result-2.json.
        var roundedLeft = left
        roundedLeft[1].startMs = 592_339
        XCTAssertEqual(try LocalSegmentMerger.merge([window(1, roundedLeft), window(2, right + [decision])]),
                       roundedLeft + [decision])
    }

    func testBoundedFullSegmentEdgesAndUnmatchedPartials() throws {
        for margin: Int64 in [0, 1, 250, 251] {
            let leading = segment(295_000 - margin, 296_000, " same")
            let leadingCopy = segment(295_000, 296_000, " same")
            let trailing = segment(299_000, 300_000, " same")
            let trailingCopy = segment(299_000, 300_000 + margin, " same")
            for (left, right) in [(leading, leadingCopy), (trailing, trailingCopy)] {
                let result = try LocalSegmentMerger.merge([window(0, [left]), window(1, [right])])
                XCTAssertEqual(result, margin <= 250 ? [left] : [left, right])
            }
        }
        // A wider custom endpoint tolerance must not widen the 250 ms edge band.
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(294_749, 296_000)]), window(1, [segment(295_000, 296_000)])
        ], toleranceMs: 750).count, 2)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(299_000, 300_000)]), window(1, [segment(299_000, 300_251)])
        ], toleranceMs: 750).count, 2)
        // Keep full text when only part of a crossing segment agrees.
        let partial = segment(299_000, 300_000, " Hello")
        let whole = segment(299_000, 300_100, " Hello world.")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [partial]), window(1, [whole])]), [partial, whole])
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(294_900, 296_000, " Hello world.")]),
            window(1, [segment(295_000, 296_000, " world.")])
        ]).count, 2)
        // Touching the edge without intersecting the overlap is not eligible.
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(294_900, 295_000)]), window(1, [segment(295_000, 295_100)])
        ]).count, 2)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(299_900, 300_000)]), window(1, [segment(300_000, 300_100)])
        ]).count, 2)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(299_000, 300_000, " same", "A")]),
            window(1, [segment(299_000, 300_100, " same", "B")])
        ]).count, 2)
        let leadingWords = [segment(294_900, 295_500, " Hello"), segment(295_500, 296_000, " world.")]
        let trailingWords = [segment(299_000, 299_500, " Hello"), segment(299_500, 300_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, leadingWords), window(1, [segment(295_000, 296_000, " Hello world.")])
        ]), leadingWords)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, trailingWords), window(1, [segment(299_000, 300_100, " Hello world.")])
        ]), trailingWords)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, trailingWords), window(1, [segment(299_000, 300_251, " Hello world.")])
        ]).count, 3)
    }

    func testEdgeEntriesCountTowardSafetyCap() throws {
        let value = segment()
        let crowded = [value] + Array(repeating: segment(297_000, 298_000, " other"), count: 63)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, crowded), window(1, [value])]), crowded)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(294_900, 295_100, " edge")] + crowded), window(1, [value])
        ]).count, 66)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [value]), window(1, crowded + [segment(299_900, 300_100, " edge")])
        ]).count, 66)
    }

    func testAnchoredDriftMinimumThresholdAndBothDirections() throws {
        for count in 0...4 {
            for drift: Int64 in [250, 251, 750, 751] {
                for backward in [true, false] {
                    let anchors = anchorWords(backward ? 298_000 : 295_500, count: count)
                    let original = segment(backward ? 296_000 : 297_000, backward ? 297_000 : 298_000, " drift")
                    let shift = backward ? -drift : drift
                    let copy = segment(original.startMs! + shift, original.endMs! + shift, " drift")
                    let a = backward ? [original] + anchors : anchors + [original]
                    let b = backward ? [copy] + anchors : anchors + [copy]
                    for swapSides in [false, true] {
                        let left = swapSides ? b : a
                        let right = swapSides ? a : b
                        let inputs = [window(0, left), window(1, right)]
                        let result = try LocalSegmentMerger.merge(inputs)
                        if drift <= 250 || (count >= 3 && drift <= 750) {
                            XCTAssertEqual(result, left)
                        } else {
                            XCTAssertEqual(result.count, left.count + 1)
                            XCTAssertTrue(result.contains(original))
                            XCTAssertTrue(result.contains(copy))
                        }
                        XCTAssertEqual(try LocalSegmentMerger.merge(inputs.reversed()), result)
                    }
                }
            }
        }
        let anchors = anchorWords(298_000)
        let value = segment(296_000, 297_000, " drift")
        for copy in [segment(295_250, 296_249, " drift"), segment(295_249, 296_250, " drift"),
                     segment(295_600, 296_000, " drift")] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [value] + anchors), window(1, [copy] + anchors)
            ]).count, 5) // Either endpoint beyond 750 ms, or no positive intersection.
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [value] + anchors), window(1, [segment(295_600, 296_600, " drift")] + anchors)
        ], toleranceMs: 0).count, 5)
    }

    func testAnchorsRequireConsecutiveOrderedNormalSingles() throws {
        let original = segment(296_000, 297_000, " drift")
        let copy = segment(295_600, 296_600, " drift")
        let anchors = anchorWords(298_000)
        let interrupted = [anchors[0], segment(nil, nil, " interruption"), anchors[1], anchors[2]]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [original] + anchors), window(1, [copy] + interrupted)
        ]).count, 6)
        let reversedTimes = [anchors[0], anchors[2], anchors[1]]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [original] + reversedTimes), window(1, [copy] + reversedTimes)
        ]).count, 5)
        for overlap: Int64 in [1, 2] {
            var rounded = anchors
            rounded[1].startMs = rounded[0].endMs! - overlap
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [original] + rounded), window(1, [copy] + rounded)
            ]).count, overlap == 1 ? 4 : 5)
        }
        // A sentence-to-three-words match is not three independent anchors.
        let sentence = segment(298_000, 298_600, anchors.map(\.text).joined())
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [original, sentence]), window(1, [copy] + anchors)
        ]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [original] + anchors), window(1, [copy, sentence])
        ]).count, 5)
    }

    func testAnchoredExtensionStopsOnTextSpeakerOrOrdering() throws {
        let anchors = anchorWords()
        for overlap: Int64 in [1, 2, 100] {
            let original = segment(296_000, 297_000 + overlap, " drift")
            let copy = segment(295_600, 296_600 + overlap, " drift")
            for swapped in [false, true] {
                let left = [swapped ? copy : original] + anchors
                let right = [swapped ? original : copy] + anchors
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                XCTAssertEqual(result.count, overlap == 1 ? 4 : 5)
            }
        }
        for text in [" other", " Drift", " drift.", " drift extra"] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [segment(296_000, 297_000, " drift")] + anchors),
                window(1, [segment(295_600, 296_600, text)] + anchors)
            ]).count, 5)
        }
        for label: String? in [nil, "A", "B"] {
            let original = segment(296_000, 297_000, " Café", "A")
            let copy = segment(295_600, 296_600, "\nCafe\u{301} ", label)
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [original] + anchors), window(1, [copy] + anchors)
            ]).count, label == "B" ? 5 : 4)
        }
    }

    func testAnchoredAmbiguityPreservesAlternatives() throws {
        let anchors = anchorWords(298_000)
        let original = segment(296_000, 297_000, " drift")
        let copy = segment(295_600, 296_600, " drift")
        let other = segment(295_500, 296_500, " drift")
        for swapped in [false, true] {
            let a = [original] + anchors
            let b = [other, copy] + anchors
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, swapped ? b : a), window(1, swapped ? a : b)
            ]).count, 6) // Do not select the nearer of two unmatched alternatives.
        }
        let tied = [segment(295_950, 296_950, " drift"), segment(296_050, 297_050, " drift")]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [original] + anchors), window(1, tied + anchors)
        ]).count, 6)
        // A competing word outside the eligible edge band still blocks recovery.
        let lateAnchors = anchorWords(298_000)
        let target = segment(299_000, 300_000, " drift")
        let shifted = segment(298_600, 299_600, " drift")
        let outside = segment(299_400, 300_400, " drift")
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, lateAnchors + [target]), window(1, lateAnchors + [shifted, outside])
        ]).count, 6)
    }

    func testAnchoredRecoveryPreservesUnmatchedTextAndDoesNotSkip() throws {
        let anchors = anchorWords(297_000)
        let a = segment(295_800, 296_300, " first")
        let b = segment(296_300, 297_000, " second")
        let copyA = segment(295_400, 295_900, " first")
        let copyB = segment(295_900, 296_600, " second")
        let tail = segment(297_600, 298_000, " unmatched tail")
        let left = [a, b] + anchors
        for _ in 0..<10 {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, left), window(1, [copyA, copyB] + anchors + [tail])
            ]), left + [tail])
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(1, [copyA, copyB] + anchors + [tail]), window(0, left)
            ]), left + [tail])
        }
        var blocker = copyB
        blocker.text = " other"
        let preserved = try LocalSegmentMerger.merge([
            window(0, left), window(1, [copyA, blocker] + anchors + [tail])
        ])
        XCTAssertEqual(preserved.count, 8)
        XCTAssertTrue(preserved.contains(copyA))
        XCTAssertTrue(preserved.contains(blocker))
        XCTAssertTrue(preserved.contains(tail))
    }

    func testAnchoredRecoveryCannotExpandEdgeBandOrSafetyCap() throws {
        let anchors = anchorWords()
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment(294_749, 296_000, " drift")] + anchors),
            window(1, [segment(295_100, 296_351, " drift")] + anchors)
        ]).count, 5)
        let left = [segment(296_000, 297_000, " drift")] + anchors
        let right = [segment(295_600, 296_600, " drift")] + anchors
        let crowded = right + Array(repeating: segment(299_000, 299_100, " other"), count: 61)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, left), window(1, crowded)]).count, 69)
    }

    func testFallbackSentenceAndAlignedWordsBothDirections() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]), [sentence])
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, words), window(1, [sentence])]), words)
    }

    func testRoundedWordBoundaryBothDirections() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        for overlap: Int64 in [0, 1, 2, 100] {
            let words = [segment(296_000, 297_000 + overlap, " Hello"),
                         segment(297_000, 298_000, " world.")]
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                if overlap <= 1 { XCTAssertEqual(result, left) }
                else { XCTAssertEqual(result.count, 3) }
            }
        }
        // Rounding permission must not allow backward starts or ends.
        for words in [
            [segment(296_001, 297_001, " Hello"), segment(296_000, 298_000, " world.")],
            [segment(296_000, 298_000, " Hello"), segment(297_999, 297_999 + 1, " world.")],
            [segment(296_000, 298_001, " Hello"), segment(297_999, 298_000, " world.")]
        ] {
            // Equal ends are monotonic; only the middle fixture may match.
            let monotonic = words[0].endMs == words[1].endMs
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                XCTAssertEqual(result.count, monotonic ? left.count : 3)
            }
        }
    }

    func testOverlapEntryLimitPreservesTextBothDirections() throws {
        for count in [64, 65, 256] {
            let words = (0..<count).map { index in
                segment(296_000 + Int64(index) * 10, 296_010 + Int64(index) * 10, " w\(index)")
            }
            let sentence = segment(296_000, 296_000 + Int64(count) * 10, words.map(\.text).joined())
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let inputs = [window(0, left), window(1, right)]
                let expected = count <= 64 ? left : try LocalSegmentMerger.merge([
                    window(0, left + right)
                ])
                XCTAssertEqual(try LocalSegmentMerger.merge(inputs), expected)
                XCTAssertEqual(try LocalSegmentMerger.merge(inputs.reversed()), expected)
            }
        }
        // Do not inspect only the first 64 entries and hide a later tied candidate.
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        let crowded = words + Array(repeating: segment(298_000, 299_000, " other"), count: 62) + [sentence]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, crowded)]).count, 66)
    }

    func testSequenceDriftAndPositiveIntersection() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        for drift: Int64 in [0, 250, 251, -250, -251] {
            let words = [segment(296_000 + drift, 297_000 + drift, " Hello"),
                         segment(297_000 + drift, 298_000 + drift, " world.")]
            for reversed in [false, true] {
                let left = reversed ? words : [sentence]
                let right = reversed ? [sentence] : words
                let result = try LocalSegmentMerger.merge([window(0, left), window(1, right)])
                XCTAssertEqual(result.count, abs(drift) <= 250 ? left.count : 3)
                if abs(drift) <= 250 { XCTAssertEqual(result, left) }
            }
        }
        let words = [segment(298_000, 298_100, " Hello"), segment(298_100, 298_200, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, words)
        ], toleranceMs: 3_000).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, [segment(296_001, 297_000, " Hello"),
                                           segment(297_000, 298_000, " world.")])
        ], toleranceMs: 0).count, 3)
        for endpoints: (Int64, Int64) in [(296_250, 298_251), (296_251, 298_250)] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [sentence]), window(1, [segment(endpoints.0, 297_000, " Hello"),
                                               segment(297_000, endpoints.1, " world.")])
            ]).count, 3)
        }
    }

    func testSequenceNormalizationPunctuationAndPartialText() throws {
        let sentence = segment(296_000, 298_000, " Café, world.")
        let words = [segment(296_000, 296_500, " Cafe\u{301}"),
                     segment(296_500, 297_000, ","),
                     segment(297_000, 298_000, "\n\tworld.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]), [sentence])
        let tail = segment(298_000, 299_000, " More.")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words + [tail])]),
                       [sentence, tail])
        let partial = segment(296_000, 297_000, " Café,")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [partial]), window(1, [sentence])]),
                       [partial, sentence])
        for text in [" Café world.", " café, world.", " Café,world."] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [segment(296_000, 298_000, text)]), window(1, words)
            ]).count, 4)
        }
    }

    func testSequenceSpeakerConflictsAndUnknowns() throws {
        for labels: [String?] in [[nil, nil], ["A", nil], [nil, "A"], ["A", "A"], ["A", "B"], ["B", "B"]] {
            let sentence = segment(296_000, 298_000, " Hello world.", "A")
            let words = [segment(296_000, 297_000, " Hello", labels[0]),
                         segment(297_000, 298_000, " world.", labels[1])]
            let conflict = labels.contains("B")
            XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]).count,
                           conflict ? 3 : 1)
            XCTAssertEqual(try LocalSegmentMerger.merge([window(0, words), window(1, [sentence])]).count,
                           conflict ? 3 : 2)
        }
        let unknown = segment(296_000, 298_000, " Hello world.")
        let conflicting = [segment(296_000, 297_000, " Hello", "A"),
                           segment(297_000, 298_000, " world.", "B")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [unknown]), window(1, conflicting)]).count, 3)
    }

    func testSequenceTiesCompetingRangesAndRepeatedPhrases() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence, sentence]), window(1, words)]).count, 4)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, words), window(1, [sentence, sentence])]).count, 4)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words + words)]).count, 5)
        // Two equal-distance matches share the middle word. Neither range is safe to remove.
        let repeated = segment(296_000, 296_300, " a a")
        let repeats = [segment(296_000, 296_100, " a"), segment(296_100, 296_200, " a"),
                       segment(296_200, 296_300, " a")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [repeated]), window(1, repeats)]).count, 4)
        // A one-to-one candidate competes with a sequence; ties remain unresolved.
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, [sentence] + words)
        ]).count, 4)
        let second = segment(298_000, 300_000, " Hello world.")
        let secondWords = [segment(298_000, 299_000, " Hello"), segment(299_000, 300_000, " world.")]
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence, second]), window(1, words + secondWords)
        ]), [sentence, second])
    }

    func testSequenceContainmentContiguityMissingWindowsAndDeterminism() throws {
        let sentence = segment(296_000, 298_000, " Hello world.")
        let words = [segment(296_000, 297_000, " Hello"), segment(297_000, 298_000, " world.")]
        for middle in [segment(nil, nil, " interruption"), segment(297_000, 297_001, ""),
                       segment(297_000, 297_001, " unmatched")] {
            XCTAssertEqual(try LocalSegmentMerger.merge([
                window(0, [sentence]), window(1, [words[0], middle, words[1]])
            ]).count, 4)
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, words.reversed())
        ]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [sentence]), window(1, [segment(296_000, 297_100, " Hello"), words[1]])
        ]).count, 3)
        let crossing = segment(294_900, 298_000, " Hello world.")
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [crossing]), window(1, [segment(295_000, 297_000, " Hello"), words[1]])
        ]), [crossing]) // Full equal text crosses the edge by only 100 ms.
        let trailing = segment(298_000, 300_000, " Hello world.")
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [trailing]),
            window(1, [segment(298_000, 299_000, " Hello"), segment(299_000, 300_100, " world.")])
        ]), [trailing])
        let later = words.map { segment($0.startMs! + 295_000, $0.endMs! + 295_000, $0.text) }
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(2, later)]).count, 3)
        for _ in 0..<20 {
            XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [sentence]), window(1, words)]), [sentence])
            XCTAssertEqual(try LocalSegmentMerger.merge([window(1, words), window(0, [sentence])]), [sentence])
        }
    }

    func testUnicodeWhitespaceAndCase() throws {
        let original = segment(296_000, 297_000, "  Caf\u{e9}\n world  ")
        let copy = segment(296_120, 297_120, "Cafe\u{301}\u{a0}world")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [original]), window(1, [copy])]), [original])
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [segment()]), window(1, [segment(296_000, 297_000, "hello")])
        ]).count, 2)
    }

    func testRepetitionNonintersectionAndOverlapContainment() throws {
        let repeats = [segment(296_000, 296_100), segment(296_100, 296_200)]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, repeats)]), repeats)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [repeats[0]]), window(1, [repeats[1]])
        ]).count, 2) // Touching endpoints are not intersection.
        let leading = segment(294_900, 296_000)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [leading]), window(1, [segment(295_000, 296_000)])
        ]), [leading])
        let trailing = segment(299_000, 300_000)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [trailing]), window(1, [segment(299_120, 300_120)])
        ]), [trailing])
    }

    func testUniqueNearestOneToOneAndTies() throws {
        let a = segment()
        let b = segment(296_100, 297_100)
        let near = segment(296_010, 297_010)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a, b]), window(1, [near])]), [a, b])
        let tie = segment(296_050, 297_050)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a, b]), window(1, [tie])]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [tie]), window(1, [a, b])]).count, 3)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a, a]), window(1, [a, a])]).count, 4)
        XCTAssertEqual(try LocalSegmentMerger.merge([
            window(0, [a, b]), window(1, [near, segment(296_110, 297_110)])
        ]), [a, b])
    }

    func testSpeakerConflictAndUnknown() throws {
        let a = segment(296_000, 297_000, "Hello", "speaker_1")
        let b = segment(296_120, 297_120, "Hello", "speaker_2")
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a]), window(1, [b])]).count, 2)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [a]), window(1, [segment()])]), [a])
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, [segment()]), window(1, [a])]), [segment()])
    }

    func testMissingWindowsUntimedStableOrderAndDeterminism() throws {
        let untimed = segment(nil, nil)
        let early = segment(100, 200, "early")
        let late = segment(590_100, 590_200, "late")
        let inputs = [window(2, [untimed, late]), window(0, [untimed, early, untimed])]
        let expected = [early, late, untimed, untimed, untimed]
        for _ in 0..<20 {
            XCTAssertEqual(try LocalSegmentMerger.merge(inputs), expected)
            XCTAssertEqual(try LocalSegmentMerger.merge(inputs.reversed()), expected)
        }
        XCTAssertEqual(try LocalSegmentMerger.merge([]), [])
        let tied = [segment(100, 300, "first"), segment(100, 200, "second")]
        XCTAssertEqual(try LocalSegmentMerger.merge([window(0, tied)]), tied)
        XCTAssertEqual(try LocalSegmentMerger.merge([window(24, [segment(7_199_000, 7_200_000)])]).count, 1)
    }

    func testInvalidGeometryAndTimestamps() throws {
        XCTAssertThrowsError(try LocalSegmentMerger.merge([], toleranceMs: -1))
        XCTAssertThrowsError(try LocalSegmentMerger.merge([window(0, []), window(0, [])]))
        let invalidWindows: [LocalTranscriptWindow] = [
            .init(index: -1, startMs: 0, endMs: 1, segments: []),
            .init(index: Int.max, startMs: 0, endMs: 1, segments: []),
            .init(index: 25, startMs: 7_375_000, endMs: 7_375_001, segments: []),
            .init(index: 1, startMs: 0, endMs: 300_000, segments: []),
            .init(index: 0, startMs: 0, endMs: 0, segments: []),
            .init(index: 0, startMs: 0, endMs: 300_001, segments: []),
            .init(index: 24, startMs: 7_080_000, endMs: 7_200_001, segments: [])
        ]
        for input in invalidWindows { XCTAssertThrowsError(try LocalSegmentMerger.merge([input])) }
        for s in [segment(nil, 1), segment(1, nil), segment(-1, 1), segment(1, 1),
                  segment(2, 1), segment(0, Int64.max), segment(0, 300_001)] {
            XCTAssertThrowsError(try LocalSegmentMerger.merge([window(0, [s])]))
        }
        XCTAssertThrowsError(try LocalSegmentMerger.merge([window(1, [segment(294_999, 296_000)])]))
        XCTAssertEqual(try LocalSegmentMerger.merge([
            .init(index: 0, startMs: 0, endMs: 100, segments: [segment(0, 100)])
        ]).count, 1)
    }
}

#if LOCAL_MERGE_STANDALONE
@main
enum LocalMergeTestRunner {
    static func main() {
        let suite = XCTestSuite(name: "Local overlap and attribution")
        suite.addTest(XCTestSuite(forTestCaseClass: LocalSegmentMergerTests.self))
        suite.addTest(XCTestSuite(forTestCaseClass: SpeakerAttributionTests.self))
        suite.run()
        guard let run = suite.testRun, run.executionCount == 28, run.hasSucceeded else { exit(1) }
    }
}
#endif
