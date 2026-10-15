//
//  FsrsComputeProgressTests.swift
//  AnkiKitTests
//

import Testing
@testable import AnkiKit

@Suite("FSRS compute progress")
struct FsrsComputeProgressTests {
    @Test func unknownTotalShowsNothing() {
        let progress = FsrsComputeProgress(current: 0, total: 0, reviews: 10)
        #expect(progress.percent == nil)
        #expect(progress.text == "")
    }

    @Test func percentOfReviews() {
        let progress = FsrsComputeProgress(current: 1, total: 8, reviews: 1234)
        #expect(progress.percent == 12.5)
        #expect(progress.text == "12.5% of 1234 reviews")
        #expect(FsrsComputeProgress(current: 1, total: 3, reviews: 1).text == "33.3% of 1 review")
    }

    @Test func finishedChecksForImprovement() {
        #expect(FsrsComputeProgress(current: 5, total: 5, reviews: 9).text == "Checking for improvement...")
    }

    @Test func dynamicDesiredRetentionPhase() {
        let progress = FsrsComputeProgress(current: 5, total: 5, reviews: 9, isTrainingDynamicDesiredRetention: true)
        #expect(progress.text == "Compute ADR values: 100.0%")
    }

    @Test func percentIsClamped() {
        #expect(FsrsComputeProgress(current: 12, total: 10, reviews: 0).percent == 100)
    }

    @Test func reviewsText() {
        #expect(FsrsComputeProgress(current: 0, total: 0, reviews: 1).reviewsText == "1 review")
        #expect(FsrsComputeProgress(current: 0, total: 0, reviews: 2).reviewsText == "2 reviews")
    }
}
