//
//  ReviewTimeMatrixTests.swift
//  AnkiKitTests
//
//  Ports the fork desktop's ts/routes/deck-options/review-time-matrix.test.ts,
//  plus SimulatorModal.svelte's derived values (expected values from the
//  desktop's functions run in node) and JS number formatting.
//

import Foundation
import Testing
@testable import AnkiKit

@Suite("Review time matrix")
struct ReviewTimeMatrixTests {
    @Test func matrixIndexIsRowMajorByRThenS() {
        #expect(ReviewTimeMatrix.cellIndex(rIndex: 0, sIndex: 0, sBucketCount: 3) == 0)
        #expect(ReviewTimeMatrix.cellIndex(rIndex: 0, sIndex: 2, sBucketCount: 3) == 2)
        #expect(ReviewTimeMatrix.cellIndex(rIndex: 1, sIndex: 0, sBucketCount: 3) == 3)
        #expect(ReviewTimeMatrix.cellIndex(rIndex: 2, sIndex: 1, sBucketCount: 3) == 7)
    }

    @Test func sLineSeriesGroupsValuesBySLinesOverR() {
        // R0: [1,2], R1: [3,4], R2: [5,6]
        let lines = ReviewTimeMatrix.sLineSeries([1, 2, 3, 4, 5, 6], rBucketCount: 3, sBucketCount: 2)
        #expect(lines[0] == [1, 3, 5])
        #expect(lines[1] == [2, 4, 6])
    }

    @Test func failPassRatioSeriesComputesFailOverPassBySLineOverR() {
        let lines = ReviewTimeMatrix.failPassRatioSeries(
            fail: [5, 10, 10, 20],
            pass: [10, 20, 30, 40],
            rBucketCount: 2,
            sBucketCount: 2
        )
        #expect(lines[0] == [0.5, 0.3333333333333333])
        #expect(lines[1] == [0.5, 0.5])
    }

    @Test func failPassRatioSeriesClampsDivisionByZeroToZero() {
        let lines = ReviewTimeMatrix.failPassRatioSeries(fail: [10], pass: [0], rBucketCount: 1, sBucketCount: 1)
        #expect(lines[0][0] == 0)
    }

    @Test func rBucketLabelsFollowFivePercentDescendingBands() {
        #expect(ReviewTimeMatrix.rBucketLabel(0) == "95-100%")
        #expect(ReviewTimeMatrix.rBucketLabel(1) == "90-95%")
        #expect(ReviewTimeMatrix.rBucketLabel(19) == "0-5%")
    }

    @Test func sBucketBoundsAreIncreasingOnLogScale() {
        let (a0, b0) = ReviewTimeMatrix.sBucketBounds(0, sBucketCount: 12)
        let (a1, b1) = ReviewTimeMatrix.sBucketBounds(1, sBucketCount: 12)
        #expect(a0 < b0)
        #expect(abs(b0 - a1) < 1e-12)
        #expect(a1 < b1)
    }

    @Test func sBucketLabelCollapsesWhenOnlyOneBucketIsPresent() {
        #expect(ReviewTimeMatrix.sBucketLabel(0, sBucketCount: 1) == "All S")
        // As node prints them.
        #expect((0..<12).map { ReviewTimeMatrix.sBucketLabel($0, sBucketCount: 12) } == [
            "0.0010-0.0043", "0.0043-0.018", "0.018-0.078", "0.078-0.33", "0.33-1.4", "1.4-6.0",
            "6.0-26", "26-1.1e+2", "1.1e+2-4.7e+2", "4.7e+2-2.0e+3", "2.0e+3-8.6e+3", "8.6e+3-3.6e+4",
        ])
    }

    @Test func seriesMinMaxHandlesEqualValues() {
        #expect(ReviewTimeMatrix.seriesMinMax([[5, 5], [5]]) == (4, 6))
        #expect(ReviewTimeMatrix.seriesMinMax([]) == (0, 1))
        #expect(ReviewTimeMatrix.seriesMinMax([[1, .nan, 3]]) == (0, 1))
        #expect(ReviewTimeMatrix.seriesMinMax([[0.5, 0.5]]) == (0, 1.5))
    }

    @Test func medianHandlesOddAndEvenLengths() {
        #expect(ReviewTimeMatrix.median([5, 1, 3]) == 3)
        #expect(ReviewTimeMatrix.median([5, 1, 3, 7]) == 4)
        #expect(ReviewTimeMatrix.median([]) == 0)
    }
}

@Suite("Simulator review time breakdown")
struct FsrsReviewTimeTests {
    /// 3 R buckets x 2 S buckets.
    private let reviewTime = FsrsReviewTime(
        rBucketCount: 3,
        sBucketCount: 2,
        againSeconds: [20.5, 22, 18.25, 19, 15, 0],
        hardSeconds: [12, 13, 11, 10.5, 9, 8],
        goodSeconds: [6.1, 7.2, 5.3, 6.4, 4.5, 5.6],
        easySeconds: [3, 3.5, 2.75, 3.25, 2.5, 3],
        sampleCounts: [10, 0, 4, 7, 1, 25],
        againCoeffs: [1.5, -2.25],
        gradeWeights: [0.1, 0.2, 0.5, 0.2],
        transitionProbs: Array(repeating: 0.25, count: 15),
        transitionCounts: [3, 0, 1],
        successGradeProbs: [0.2, 0.7, 0.1, 0, 0.6, 0.4, 0.3, 0.3, 0.4],
        successGradeCounts: [12, 0]
    )

    @Test func cellsAndMissingValues() {
        #expect(reviewTime.cellSeconds(.again, rIndex: 1, sIndex: 1) == 19)
        #expect(reviewTime.cellSampleCount(rIndex: 2, sIndex: 1) == 25)
        #expect(reviewTime.sampleMedian == 5.5)
        #expect(reviewTime.transitionProb(from: 3, to: 3) == 0)
        #expect(reviewTime.transitionCount(from: 0, to: 0) == 3)
        #expect(reviewTime.transitionCount(from: 3, to: 3) == 0)
        #expect(reviewTime.successGradeCount(rIndex: 2) == 0)
        #expect(reviewTime.coeffText(.again, 1) == "-2.2500")
        #expect(reviewTime.coeffText(.again, 4) == "0.0000")
        #expect(reviewTime.coeffText(.easy, 0) == "0.0000")
        #expect(reviewTime.gradeWeightText(.good) == "0.500")
        #expect(FsrsReviewTime().gradeWeightText(.again) == "0.000")
    }

    @Test func successPriorAndBlendedProbabilities() {
        let prior = (0..<3).map { reviewTime.transitionSuccessPrior($0) }
        #expect(prior == [0.22222222406187175, 0.5555555518762566, 0.22222222406187175])
        let blended = (0..<3).map { r in (0..<3).map { reviewTime.blendedSuccessGradeProb(rIndex: r, successGrade: $0) } }
        #expect(blended == [
            [0.20000000447034838, 0.6999999932944774, 0.10000000223517419],
            // A zero share falls back to a third before normalising.
            [0.24999999441206466, 0.4500000078231095, 0.2999999977648259],
            [0.30000000298023216, 0.30000000298023216, 0.3999999940395357],
        ])
        let percents = (0..<3).map { r in
            (0..<3).map { FsrsReviewTime.percentText(reviewTime.blendedSuccessGradeProb(rIndex: r, successGrade: $0)) }
        }
        #expect(percents == [["20.0%", "70.0%", "10.0%"], ["25.0%", "45.0%", "30.0%"], ["30.0%", "30.0%", "40.0%"]])

        let half = (0..<3).map { r in
            (0..<3).map { reviewTime.blendedSuccessGradeProb(rIndex: r, successGrade: $0, alpha: 0.5) }
        }
        let expectedHalf = [
            [0.2143555358487694, 0.6340722111676897, 0.15157225298354093],
            [0.237148592124134, 0.5030681391663695, 0.25978326870949653],
            [0.2676774637135385, 0.42323522866257923, 0.3090873076238824],
        ]
        for (got, want) in zip(half.joined(), expectedHalf.joined()) {
            #expect(abs(got - want) < 1e-12)
        }
    }

    @Test func finalGradeProbabilities() {
        let final = (0..<3).map { r in (0..<4).map { reviewTime.finalGradeProb(rIndex: r, grade: $0) } }
        #expect(final == [
            [0.025000000000000022, 0.19500000435858966, 0.6824999934621154, 0.09750000217929483],
            [0.07499999999999996, 0.23124999483115982, 0.4162500072363763, 0.27749999793246394],
            [0.125, 0.2625000026077031, 0.2625000026077031, 0.3499999947845937],
        ])
        #expect(FsrsReviewTime.bucketRetrievability(0) == 0.975)
        #expect(FsrsReviewTime.bucketRetrievability(25) == 0)
    }

    @Test func graphLinesAndAxes() {
        let graph = reviewTime.graph()
        #expect(graph.lines.count == 10)
        #expect(graph.lines.map(\.kind) == Array(repeating: ReviewTimeGraph.Kind.allCases, count: 2).flatMap { $0 })
        #expect(graph.lines[0].values == [20.5, 18.25, 15])
        #expect(graph.lines[5].values == [22, 19, 0])
        #expect(graph.lines[4].values == [7.308249953871593, 6.881750055203216, 6.293750022165477])
        #expect(graph.lines[9].values == [8.340249887039887, 7.419000025017188, 4.6199999947845924])
        // At least 60 seconds.
        #expect(graph.yMax == 60)
        #expect(graph.yTicks == [0, 15, 30, 45, 60])
        #expect(graph.xTicks.map(\.rIndex) == [0, 1, 2])

        var slow = FsrsReviewTime(rBucketCount: 20, sBucketCount: 1, againSeconds: Array(repeating: 8, count: 20))
        slow.againSeconds[3] = 75
        let slowGraph = slow.graph()
        #expect(slowGraph.yMax == 75)
        #expect(slowGraph.xTicks.map(\.rIndex) == [0, 3, 6, 9, 12, 15, 18, 19])
        #expect(slowGraph.xTicks.first?.label == "95-100%")
        #expect(slowGraph.xTicks.last?.label == "0-5%")
        // Missing grades read as 0 seconds.
        #expect(slowGraph.lines[1].values == Array(repeating: 0, count: 20))
    }

    @Test func secondsText() {
        #expect(FsrsReviewTime.secondsText(8.25) == "8.3s")
        #expect(FsrsReviewTime.secondsText(Double(Float(6.1))) == "6.1s")
    }
}

@Suite("JS number formatting")
struct JSNumberFormatTests {
    @Test func toFixedMatchesJavaScript() {
        // Expected values from node.
        let cases: [(Double, Int, String)] = [
            (0.25, 1, "0.3"), (8.25, 1, "8.3"), (1.005, 2, "1.00"), (-0.05, 1, "-0.1"),
            (-0.0, 1, "0.0"), (-0.01, 1, "-0.0"), (0, 4, "0.0000"), (123.456, 0, "123"),
            (0.5, 0, "1"), (1.5, 0, "2"), (2.5, 0, "3"), (1e21, 2, "1e+21"), (6.25, 1, "6.3"),
            (0.1, 3, "0.100"), (12.34567, 4, "12.3457"), (-2.625, 4, "-2.6250"),
            (999.95, 1, "1000.0"), (0.0005, 3, "0.001"), (1e-10, 2, "0.00"), (.leastNonzeroMagnitude, 2, "0.00"),
            (.nan, 1, "NaN"), (-.infinity, 1, "-Infinity"),
        ]
        for (x, digits, expected) in cases {
            #expect(JSNumberFormat.toFixed(x, digits) == expected, "\(x).toFixed(\(digits))")
        }
    }

    @Test func toPrecisionMatchesJavaScript() {
        let cases: [(Double, Int, String)] = [
            (0.001, 2, "0.0010"), (36500, 2, "3.7e+4"), (12.3, 2, "12"), (123, 2, "1.2e+2"),
            (125, 2, "1.3e+2"), (0.00000123, 2, "0.0000012"), (0.000000123, 2, "1.2e-7"),
            (9.99, 2, "10"), (99.9, 2, "1.0e+2"), (0, 2, "0.0"), (-0.5, 1, "-0.5"), (0.15, 1, "0.1"),
            (1.25, 2, "1.3"), (3.0414, 2, "3.0"), (0.0001, 1, "0.0001"), (1e21, 3, "1.00e+21"),
        ]
        for (x, precision, expected) in cases {
            #expect(JSNumberFormat.toPrecision(x, precision) == expected, "\(x).toPrecision(\(precision))")
        }
    }
}
