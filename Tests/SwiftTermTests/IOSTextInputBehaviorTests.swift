#if canImport(UIKit)
import UIKit
import XCTest
import SwiftTerm

@MainActor
final class IOSTextInputBehaviorTests: XCTestCase {
    func testTerminalAdvertisesTextWhenLocalInputBufferIsEmpty() {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160)
        )

        XCTAssertNil(
            view.selectedTextRange,
            "An offset-zero selection makes UIKit stop native Delete auto-repeat at the local buffer boundary."
        )
        XCTAssertTrue(
            view.hasText,
            "A remote terminal may have deletable text even when UITextInput has no local buffer."
        )

        view.insertText("a")
        XCTAssertTrue(view.hasText)
        let localSelection = view.selectedTextRange
        XCTAssertNotNil(localSelection)
        XCTAssertEqual(
            view.offset(
                from: view.beginningOfDocument,
                to: localSelection?.end ?? view.beginningOfDocument
            ),
            1
        )

        view.insertText("\n")
        XCTAssertNil(view.selectedTextRange)
        XCTAssertTrue(
            view.hasText,
            "Submitting a line must not disable Backspace for remote history or pasted input."
        )
    }

    func testRepeatedDeleteBackwardWithEmptyLocalBufferForwardsEveryCallback() {
        let (view, delegate) = makeTerminalView()

        view.deleteBackward()
        view.deleteBackward()
        view.deleteBackward()

        XCTAssertEqual(delegate.sentBytes, [0x7F, 0x7F, 0x7F])
        XCTAssertNil(view.selectedTextRange)
        XCTAssertTrue(view.hasText)
    }

    func testLocalSelectionReturnsForUnicodeAndDisappearsAfterDeletion() throws {
        let (view, delegate) = makeTerminalView()

        view.insertText("🙂")

        let selection = try XCTUnwrap(view.selectedTextRange)
        XCTAssertEqual(
            view.offset(from: view.beginningOfDocument, to: selection.end),
            "🙂".utf16.count
        )

        delegate.reset()
        view.deleteBackward()

        XCTAssertEqual(delegate.sentBytes, [0x7F])
        XCTAssertNil(view.selectedTextRange)
        XCTAssertTrue(view.hasText)
    }

    func testMarkedTextCommitPreservesUTF16IMEStateAndSendsOnce() throws {
        let (view, delegate) = makeTerminalView()
        let text = "ฟหกดเ้"

        view.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0)
        )
        XCTAssertNotNil(view.markedTextRange)

        view.unmarkText()

        XCTAssertNil(view.markedTextRange)
        let documentRange = try XCTUnwrap(
            view.textRange(
                from: view.beginningOfDocument,
                to: view.endOfDocument
            )
        )
        XCTAssertEqual(view.text(in: documentRange), text)
        let selection = try XCTUnwrap(view.selectedTextRange)
        XCTAssertEqual(
            view.offset(from: view.beginningOfDocument, to: selection.end),
            text.utf16.count
        )
        XCTAssertEqual(delegate.sentBytes, Array(text.utf8))
    }

    func testAutoPeriodNormalizationSurvivesBackspaceAvailabilityChange() throws {
        let (splitView, splitDelegate) = makeTerminalView()
        splitView.insertText(" ")
        splitDelegate.reset()

        splitView.deleteBackward()
        splitView.insertText(".")

        XCTAssertEqual(try documentText(in: splitView), " ")
        XCTAssertEqual(splitDelegate.sentBytes, [0x7F, 0x20])

        let (replacementView, replacementDelegate) = makeTerminalView()
        replacementView.insertText(" ")
        replacementDelegate.reset()
        let replacementRange = try XCTUnwrap(
            replacementView.textRange(
                from: replacementView.beginningOfDocument,
                to: replacementView.endOfDocument
            )
        )

        replacementView.replace(replacementRange, withText: ". ")

        XCTAssertEqual(try documentText(in: replacementView), "  ")
        XCTAssertEqual(replacementDelegate.sentBytes, [0x7F, 0x20, 0x20])
        let selection = try XCTUnwrap(replacementView.selectedTextRange)
        XCTAssertEqual(
            replacementView.offset(
                from: replacementView.beginningOfDocument,
                to: selection.end
            ),
            2
        )
    }

    private func makeTerminalView() -> (TerminalView, CapturingTerminalViewDelegate) {
        let view = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 160)
        )
        let delegate = CapturingTerminalViewDelegate()
        view.terminalDelegate = delegate
        return (view, delegate)
    }

    private func documentText(in view: TerminalView) throws -> String {
        let range = try XCTUnwrap(
            view.textRange(
                from: view.beginningOfDocument,
                to: view.endOfDocument
            )
        )
        return try XCTUnwrap(view.text(in: range))
    }
}

private final class CapturingTerminalViewDelegate: TerminalViewDelegate {
    private(set) var sentBytes: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sentBytes.append(contentsOf: data)
    }

    func reset() {
        sentBytes.removeAll(keepingCapacity: true)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
