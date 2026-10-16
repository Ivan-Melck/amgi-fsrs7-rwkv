//
//  FsrsParamsInputTests.swift
//  AnkiKitTests
//
//  The FSRS parameters field of ts/routes/deck-options/ParamsInput.svelte:
//  what it renders and which edits it accepts.
//

import Testing
@testable import AnkiKit

@Suite("FSRS params input")
struct FsrsParamsInputTests {
    @Test func rendersFourDecimalsLikeToFixed() {
        #expect(FsrsParamsInput.render([]) == "")
        #expect(FsrsParamsInput.render([0.4, 1, 2.5]) == "0.4000, 1.0000, 2.5000")
        // toFixed rounds an exact tie up, unlike printf.
        #expect(FsrsParamsInput.render([0.03125]) == "0.0313")
    }

    @Test func acceptsTheCountsFsrsTakes() {
        for count in [17, 19, 21, 34] {
            let text = Array(repeating: "0.5", count: count).joined(separator: ", ")
            #expect(FsrsParamsInput.parse(text) == Array(repeating: 0.5, count: count))
        }
    }

    @Test func emptyMeansTheDefaults() {
        #expect(FsrsParamsInput.parse("") == [])
        #expect(FsrsParamsInput.parse("  ") == [])
        #expect(FsrsParamsInput.parse(",,") == [])
    }

    @Test func rejectsOtherCounts() {
        #expect(FsrsParamsInput.parse("1, 2, 3") == nil)
        let outdatedPreview = Array(repeating: "1", count: 35).joined(separator: ",")
        #expect(FsrsParamsInput.parse(outdatedPreview) == nil)
    }

    @Test func rejectsAnEntryNumberCannotRead() {
        // Desktop: `Number("abc")` is NaN, so the whole edit is rejected
        // rather than the entry dropped.
        var entries = Array(repeating: "1", count: 17)
        entries[3] = "abc"
        #expect(FsrsParamsInput.parse(entries.joined(separator: ",")) == nil)
        entries[3] = "Infinity"
        #expect(FsrsParamsInput.parse(entries.joined(separator: ",")) == nil)
        entries[3] = "1e39"
        #expect(FsrsParamsInput.parse(entries.joined(separator: ",")) == nil)
    }

    @Test func splitsOnCommasOnly() {
        // Spaces are removed first, so "1 2" is the single entry "12".
        let text = "1 2" + String(repeating: ",1", count: 16)
        #expect(FsrsParamsInput.parse(text)?.first == 12)
        // A newline isn't a separator: "1\n2" is not a number.
        let newline = "1\n2" + String(repeating: ",1", count: 16)
        #expect(FsrsParamsInput.parse(newline) == nil)
    }

    @Test func readsEntriesLikeJavaScriptNumber() {
        #expect(FsrsParamsInput.javaScriptNumber("1.5") == 1.5)
        #expect(FsrsParamsInput.javaScriptNumber("\n2\t") == 2)
        #expect(FsrsParamsInput.javaScriptNumber("\n") == 0)
        #expect(FsrsParamsInput.javaScriptNumber(".5") == 0.5)
        #expect(FsrsParamsInput.javaScriptNumber("5.") == 5)
        #expect(FsrsParamsInput.javaScriptNumber("+1e-2") == 0.01)
        #expect(FsrsParamsInput.javaScriptNumber("-0.25") == -0.25)
        #expect(FsrsParamsInput.javaScriptNumber("0x1F") == 31)
        #expect(FsrsParamsInput.javaScriptNumber("0b101") == 5)
        #expect(FsrsParamsInput.javaScriptNumber("-Infinity") == -.infinity)
        #expect(FsrsParamsInput.javaScriptNumber("-0x1F").isNaN)
        #expect(FsrsParamsInput.javaScriptNumber("1,5").isNaN)
        #expect(FsrsParamsInput.javaScriptNumber("inf").isNaN)
        #expect(FsrsParamsInput.javaScriptNumber("nan").isNaN)
        #expect(FsrsParamsInput.javaScriptNumber(".").isNaN)
        #expect(FsrsParamsInput.javaScriptNumber("1e").isNaN)
        #expect(FsrsParamsInput.javaScriptNumber("0x").isNaN)
    }

    @Test func rendersAcceptedParamsBackUnchanged() {
        let params: [Float] = (0..<21).map { (index: Int) -> Float in Float(index) / 4 }
        #expect(FsrsParamsInput.parse(FsrsParamsInput.render(params)) == params)
    }
}
