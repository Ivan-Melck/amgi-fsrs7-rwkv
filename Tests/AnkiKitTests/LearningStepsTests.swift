//
//  LearningStepsTests.swift
//  AnkiKitTests
//
//  Ports ts/routes/deck-options/steps.test.ts, plus the edges of
//  steps.ts's parsing the iOS field used to read differently.
//

import Testing
@testable import AnkiKit

@Suite("Learning steps")
struct LearningStepsTests {
    // MARK: - steps.test.ts

    @Test func wholeSteps() {
        let steps: [Float] = [1, 10, 60, 120, 1440]
        let string = "1m 10m 1h 2h 1d"
        #expect(LearningSteps.format(steps) == string)
        #expect(LearningSteps.parse(string) == steps)
    }

    @Test func fractionalSteps() {
        let steps: [Float] = [Float(1.0 / 60), Float(5.0 / 60), 1.5, 400]
        let string = "1s 5s 90s 400m"
        #expect(LearningSteps.format(steps) == string)
        #expect(LearningSteps.parse(string) == steps)
    }

    @Test func rounding() {
        #expect(LearningSteps.format([0.1666666716337204]) == "10s")
    }

    @Test func parsing() {
        #expect(LearningSteps.parse("") == [])
        #expect(LearningSteps.parse("    ") == [])
        #expect(LearningSteps.parse("1 hello 2") == [1, 2])
    }

    // MARK: - stringToSteps edges

    @Test func splitsOnSpacesOnly() {
        // "1m,10m" is one entry: its digits are 1, its suffix "m,10m".
        #expect(LearningSteps.parse("1m,10m") == [1])
        #expect(LearningSteps.parse("1h\t10m") == [1])
        #expect(LearningSteps.parse("1m  10m") == [1, 10])
    }

    @Test func suffixesAreCaseSensitiveAndExact() {
        #expect(LearningSteps.minutes("2H") == 2)
        #expect(LearningSteps.minutes("1D") == 1)
        #expect(LearningSteps.minutes("10sec") == 10)
        #expect(LearningSteps.minutes("1h30m") == 1)
        #expect(LearningSteps.minutes("1.5m") == 1)
        #expect(LearningSteps.minutes("30s") == 0.5)
        #expect(LearningSteps.minutes("2h") == 120)
        #expect(LearningSteps.minutes("1d") == 1440)
    }

    @Test func readsTheFirstDigitsAnywhere() {
        #expect(LearningSteps.minutes("abc") == 0)
        #expect(LearningSteps.minutes("x5") == 5)
        #expect(LearningSteps.minutes("-5") == 5)
        #expect(LearningSteps.minutes("step3h") == 180)
        // Only ASCII digits, as `\d`.
        #expect(LearningSteps.minutes("٣") == 0)
    }

    @Test func suffixStopsAtALineBreak() {
        #expect(LearningSteps.minutes("5h\n3m") == 300)
        #expect(LearningSteps.minutes("10\nh") == 10)
    }

    @Test func capsAtTheLargestRevlogInterval() {
        #expect(LearningSteps.minutes("99999999d") == Float(2_147_483_648.0 / 60))
    }

    // MARK: - stepsToString edges

    @Test func wholeMonthsAndYearsShowAsDays() {
        // A year is a whole number of days; a month (365/12 days) is not,
        // but `naturalWholeUnit` stops at months and days round it.
        #expect(LearningSteps.string(525_600) == "365d")
        #expect(LearningSteps.string(43_800) == "30d")
        #expect(LearningSteps.string(4320) == "3d")
    }

    @Test func storedStepsRoundTrip() {
        for minutes: Float in [0.5, 1, 1.5, 10, 90, 120, 1440, 4320] {
            let text = LearningSteps.string(minutes)
            #expect(LearningSteps.minutes(text) == minutes, "\(text)")
        }
    }
}
