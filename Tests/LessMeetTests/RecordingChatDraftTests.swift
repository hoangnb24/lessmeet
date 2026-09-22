import XCTest
@testable import LessMeet

final class RecordingChatDraftTests: XCTestCase {
    func testPendingQuestionCannotBeSubmittedTwiceAndIsRestoredAfterFailure() {
        var composer = RecordingChatDraft()
        composer.text = "  What did we decide? \n"
        XCTAssertEqual(composer.beginSubmission(), "What did we decide?")
        XCTAssertEqual(composer.text, "")
        XCTAssertEqual(composer.pending, "What did we decide?")
        XCTAssertNil(composer.beginSubmission())
        composer.finishSubmission(failed: true)
        XCTAssertEqual(composer.text, "What did we decide?")
        XCTAssertNil(composer.pending)
        XCTAssertTrue(composer.canSubmit)
    }

    func testSuccessfulReplyDoesNotRestoreSentQuestionOrEraseNewDraft() {
        var composer = RecordingChatDraft()
        composer.text = "Summarize"
        _ = composer.beginSubmission()
        composer.text = "A follow-up draft"
        composer.finishSubmission(failed: false)
        XCTAssertEqual(composer.text, "A follow-up draft")
        XCTAssertNil(composer.pending)
    }

    func testEmptyAndOversizeMultibyteQuestionsRemainUnsent() {
        var composer = RecordingChatDraft()
        composer.text = " \n "
        XCTAssertNil(composer.beginSubmission())
        composer.text = String(repeating: "🙂", count: 2049)
        XCTAssertNil(composer.beginSubmission())
        XCTAssertEqual(composer.text.count, 2049)
        XCTAssertNil(composer.pending)
    }
}
