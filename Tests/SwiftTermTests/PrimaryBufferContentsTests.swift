import Foundation
import Testing
@testable import SwiftTerm

@Suite(.serialized)
final class PrimaryBufferContentsTests {
    private let esc = "\u{1b}"

    private final class Delegate: TerminalDelegate {
        var replies: [[UInt8]] = []
        var titles: [String] = []
        var bells = 0
        var scrolls: [Int] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) { replies.append(Array(data)) }
        func setTerminalTitle(source: Terminal, title: String) { titles.append(title) }
        func bell(source: Terminal) { bells += 1 }
        func scrolled(source: Terminal, yDisp: Int) { scrolls.append(yDisp) }
    }

    private func lines(_ terminal: Terminal) -> [String] {
        (0..<terminal.buffer.lines.count).map { index in
            terminal.buffer.translateBufferLineToString(
                lineIndex: index, trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) }
            ).replacingOccurrences(of: "\u{0}", with: " ")
        }
    }

    @Test func replacesHistoryWithinDestinationCapacityWithoutSharingCells() {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 2)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 10)
        live.feed(text: "old0\r\nold1\r\nold2\r\nold3\r\nold4\r\nold5")
        capture.feed(text: "L0\r\nL1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7")
        capture.feed(text: "\(esc)[2;4H")
        let originalBuffer = live.buffer

        #expect(live.replacePrimaryBufferContents(from: capture))

        #expect(live.buffer === originalBuffer)
        #expect(lines(live) == ["L3", "L4", "L5", "L6", "L7"])
        #expect(live.buffer.yBase == 2)
        #expect(live.buffer.yDisp == 2)
        #expect(live.buffer.linesTop == 0)
        TerminalTestHarness.assertCursor(live.buffer, col: 3, row: 1)
        capture.feed(text: "SOURCE")
        live.feed(text: "!")
        #expect(lines(live)[3] == "L6 !")
        #expect(lines(capture)[6] == "L6 SOURC")
        #expect(live.getScrollInvariantLine(row: 0)?.getData().first?.getCharacter() == "L")
    }

    @Test func preservesLiveModesSavedCursorPaletteAndEffects() {
        let delegate = Delegate()
        let live = Terminal(delegate: delegate, options: TerminalOptions(cols: 12, rows: 4, scrollback: 8))
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 4, scrollback: 8)
        live.feed(text: "\(esc)[31m\(esc)[3;5H\(esc)7")
        live.feed(text: "\(esc)[32m\(esc)[2;4r\(esc)[?69h\(esc)[2;10s\(esc)[?6h")
        live.feed(text: "\(esc)[?1h\(esc)[?2004h\(esc)[?1004h\(esc)[?7l\(esc)[4h\(esc)[>1u")
        live.feed(text: "\(esc)]4;1;rgb:12/34/56\u{7}\(esc)]2;live-title\u{7}\u{7}\(esc)[5n")
        live.buffer.tabStops[3] = true
        let parser = live.parser
        let color = live.ansiColors[1]
        let currentAttribute = live.currentAttribute
        let savedAttribute = live.buffer.savedAttr
        let replies = delegate.replies
        delegate.scrolls.removeAll()
        capture.feed(text: "history\r\none\r\ntwo\r\nthree\r\nfour\(esc)[2;3H")

        #expect(live.replacePrimaryBufferContents(from: capture))

        #expect(live.parser === parser)
        #expect(live.applicationCursor && live.bracketedPasteMode && live.sendFocus)
        #expect(live.originMode && live.marginMode && live.insertMode && !live.wraparound)
        #expect(live.keyboardEnhancementFlags == [.disambiguate])
        #expect(live.buffer.scrollTop == 1 && live.buffer.scrollBottom == 3)
        #expect(live.buffer.marginLeft == 1 && live.buffer.marginRight == 9)
        #expect(live.buffer.tabStops[3])
        #expect(live.ansiColors[1] == color)
        #expect(live.currentAttribute == currentAttribute)
        #expect(live.buffer.savedAttr == savedAttribute)
        #expect(delegate.replies == replies)
        #expect(delegate.titles == ["live-title"])
        #expect(delegate.bells == 1)
        #expect(delegate.scrolls == [1])
        live.feed(text: "\(esc)8X")
        TerminalTestHarness.assertCursor(live.buffer, col: 5, row: 2)
        #expect(live.buffer.lines[live.buffer.yBase + 2][4].attribute == savedAttribute)
        #expect(!live.originMode && !live.marginMode && live.wraparound)
    }

    @Test func rebindsGraphemesAndPreservesWidthsPayloadsAndLineMetadata() {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 5)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 5)
        live.feed(text: "👨‍👩‍👧‍👦a\u{301}\(esc)#6")
        capture.feed(text: "\(esc)[1;34m👩🏽‍💻e\u{308}界123456789\r\nend")
        let atom = TinyAtom.lookup(value: ";https://capture.example")!
        var linked = capture.buffer.lines[0][0]
        linked.setPayload(atom: atom)
        capture.buffer.lines[0][0] = linked

        #expect(live.replacePrimaryBufferContents(from: capture))

        #expect(live.getCharacter(for: live.buffer.lines[0][0]) == "👩🏽‍💻")
        #expect(live.getCharacter(for: live.buffer.lines[0][2]) == "e\u{308}")
        #expect(live.buffer.lines[0][0].width == 2)
        #expect(live.buffer.lines[0][1].width == 0)
        #expect(live.buffer.lines[0][0].attribute == linked.attribute)
        #expect(live.link(at: .buffer(Position(col: 0, row: 0)), mode: .explicitOnly) == "https://capture.example")
        #expect(live.buffer.lines[0].renderMode == .single)
        #expect(live.buffer.lines[1].isWrapped)
        live.resize(cols: 16, rows: 3)
        #expect(lines(live).contains { $0.hasPrefix("👩🏽‍💻e\u{308}界123456789") })
    }

    @Test func rebasesTheLastPrintedGlyphEvenAfterTheCursorMoved() {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        live.feed(text: "\(esc)[2;1He\(esc)[1;6H")
        capture.feed(text: "H0\r\nH1\r\nSCREEN\r\ne\r\nLAST\(esc)[1;6H")

        #expect(live.replacePrimaryBufferContents(from: capture))
        live.feed(text: "\u{301}")

        #expect(lines(live) == ["H0", "H1", "SCREEN", "e\u{301}", "LAST"])
        TerminalTestHarness.assertCursor(live.buffer, col: 5, row: 0)
    }

    @Test func discardsStaleCombiningCoordinatesWhenTheCapturedGlyphChanged() {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        live.feed(text: "e")
        capture.feed(text: "H0\r\nH1\r\nNEW\r\nNEXT\r\nLAST\(esc)[1;2H")

        #expect(live.replacePrimaryBufferContents(from: capture))
        live.feed(text: "\u{301}")

        #expect(lines(live) == ["H0", "H1", "NEW", "NEXT", "LAST"])
    }

    @Test func openHyperlinkOnlyCoversNewerOutputAfterReplacement() {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 3, scrollback: 8)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 12, rows: 3, scrollback: 8)
        live.feed(text: "\(esc)]8;;https://live.example\(esc)\\OLD")
        capture.feed(text: "H0\r\nH1\r\nSCREEN\r\nNEXT\r\nPRE suffix!\(esc)[3;5H")

        #expect(live.replacePrimaryBufferContents(from: capture))
        live.feed(text: "NEW\(esc)]8;;\(esc)\\")

        for row in 0..<capture.buffer.lines.count {
            for col in 0..<12 where row != 4 || !(4..<7).contains(col) {
                #expect(live.link(at: .buffer(Position(col: col, row: row)), mode: .explicitOnly) == nil)
            }
        }
        for col in 4..<7 {
            #expect(live.link(at: .buffer(Position(col: col, row: 4)), mode: .explicitOnly) == "https://live.example")
        }
        #expect(lines(live)[4] == "PRE NEWfix!")
        #expect(live.hyperLinkTracking == nil)
    }

    @Test func removesPrimaryGraphicsPlacementsButKeepsImageCacheAndPendingTransfer() {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 8)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 3, scrollback: 8)
        live.feed(text: "\(esc)_Ga=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1;AQID\(esc)\\")
        live.feed(text: "\(esc)_Ga=t,f=24,s=1,v=1,t=d,i=2,m=1;BA\(esc)\\")
        #expect(live.kittyGraphicsState.imagesById[1] != nil)
        #expect(!live.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(live.kittyGraphicsState.pending != nil)
        capture.feed(text: "new")

        #expect(live.replacePrimaryBufferContents(from: capture))

        #expect(live.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(live.kittyGraphicsState.imagesById[1] != nil)
        #expect(live.kittyGraphicsState.pending != nil)
        #expect(!live.buffer.hasAnyImages)
        live.feed(text: "\(esc)_Gm=0;UG\(esc)\\")
        #expect(live.kittyGraphicsState.pending == nil)
        #expect(live.kittyGraphicsState.imagesById[2] != nil)
    }

    @Test(arguments: ["live-alt", "capture-alt", "grid", "width-options", "live-sync", "capture-sync", "live-csi", "capture-osc", "live-utf8", "capture-utf8", "capture-graphics", "capture-open-link"])
    func refusesIncompatibleOrIncompleteTerminalsWithoutMutation(_ condition: String) {
        let (live, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        let (capture, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 3, scrollback: 8)
        live.feed(text: "OLD")
        capture.feed(text: "H0\r\nH1\r\nNEW\r\nNEXT")
        switch condition {
        case "live-alt": live.feed(text: "\(esc)[?47h")
        case "capture-alt": capture.feed(text: "\(esc)[?47h")
        case "grid": capture.resize(cols: 9, rows: 3)
        case "width-options": capture.options.regionalIndicatorWidth = .narrow
        case "live-sync": live.feed(text: "\(esc)[?2026h")
        case "capture-sync": capture.feed(text: "\(esc)[?2026h")
        case "live-csi": live.feed(text: "\(esc)[31")
        case "capture-osc": capture.feed(text: "\(esc)]2;partial")
        case "live-utf8": live.feed(buffer: [0xe2, 0x82][...])
        case "capture-utf8": capture.feed(buffer: [0xe2, 0x82][...])
        case "capture-graphics": capture.feed(text: "\(esc)_Ga=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1;AQID\(esc)\\")
        case "capture-open-link": capture.feed(text: "\(esc)]8;;https://capture.example\(esc)\\")
        default: break
        }
        let before = lines(live)
        let oldBuffer = live.buffer

        #expect(!live.replacePrimaryBufferContents(from: capture))

        #expect(live.buffer === oldBuffer)
        #expect(lines(live) == before)
        live.feed(text: "\(esc)[?2026l")
        capture.feed(text: "\(esc)[?2026l")
    }
}
