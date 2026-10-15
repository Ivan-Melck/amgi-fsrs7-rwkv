//
//  ApplyScheduleTests.swift
//  AnkiKitTests
//
//  Ports the fork desktop's ts/routes/deck-options/apply-schedule.test.ts.
//

import Foundation
import Testing
@testable import AnkiKit

@Suite("Apply schedule to all presets")
struct ApplyScheduleTests {
    private func options(scheduler: Bool, fallback: Bool, settings: Bool, retention: Bool) -> ScheduleCopyOptions {
        var options = ScheduleCopyOptions()
        options.scheduler = scheduler
        options.fallback = fallback
        options.settings = settings
        options.retention = retention
        return options
    }

    @Test func eachCategoryCopiesIndependently() {
        var source = DeckConfig.Config()
        source.rwkvReviewInstantOrderEnabled = true
        source.fsrsVersion = .seven
        source.desiredRetention = 0.9
        source.fsrsParams7 = Array(repeating: 2, count: 34)
        source.rwkvReviewMinElapsedSecs = 60
        source.maximumReviewInterval = 1000
        source.newPerDay = 50
        var target = DeckConfig.Config()
        target.rwkvReviewEnabled = true
        target.desiredRetention = 0.8
        target.fsrsParams7 = Array(repeating: 1, count: 34)
        target.rwkvReviewMinElapsedSecs = 10
        target.maximumReviewInterval = 500
        target.newPerDay = 20

        for scheduler in [false, true] {
            for fallback in [false, true] {
                for settings in [false, true] {
                    for retention in [false, true] {
                        let updated = target.withCopiedSchedule(
                            from: source,
                            options: options(scheduler: scheduler, fallback: fallback, settings: settings, retention: retention)
                        )
                        #expect(updated.schedulerSelection.scheduler == (scheduler ? .rwkvInstant : .rwkvCurve))
                        #expect(updated.schedulerSelection.dueDateScheduler == (scheduler && fallback ? .fsrs7 : .rwkvCurve))
                        #expect(updated.desiredRetention == (retention ? 0.9 : 0.8))
                        #expect(updated.fsrsParams7 == Array(repeating: settings ? 2 : 1, count: 34))
                        #expect(updated.rwkvReviewMinElapsedSecs == (settings ? 60 : 10))
                        #expect(updated.maximumReviewInterval == (settings ? 1000 : 500))
                        #expect(updated.newPerDay == 20)
                    }
                }
            }
        }
    }

    @Test func fallbackAloneChangesOnlyInstantDueDates() {
        var source = DeckConfig.Config()
        source.fsrsVersion = .six
        let options = options(scheduler: false, fallback: true, settings: false, retention: false)
        var instant = DeckConfig.Config()
        instant.rwkvReviewInstantOrderEnabled = true
        instant.rwkvReviewEnabled = true
        let updated = instant.withCopiedSchedule(from: source, options: options)
        #expect(updated.schedulerSelection.scheduler == .rwkvInstant)
        #expect(updated.schedulerSelection.dueDateScheduler == .fsrs6)

        var curve = DeckConfig.Config()
        curve.rwkvReviewEnabled = true
        #expect(curve.withCopiedSchedule(from: source, options: options) == curve)
        var fsrs = DeckConfig.Config()
        fsrs.fsrsVersion = .seven
        #expect(fsrs.withCopiedSchedule(from: source, options: options) == fsrs)
    }

    @Test func copyingAnIntervalSchedulerDisablesInstant() {
        var target = DeckConfig.Config()
        target.rwkvReviewInstantOrderEnabled = true
        target.rwkvReviewEnabled = true
        let options = options(scheduler: true, fallback: false, settings: false, retention: false)
        var fsrsSource = DeckConfig.Config()
        fsrsSource.fsrsVersion = .six
        let fsrs = target.withCopiedSchedule(from: fsrsSource, options: options)
        #expect(fsrs.schedulerSelection.scheduler == .fsrs6)
        #expect(fsrs.schedulerSelection.dueDateScheduler == .fsrs6)
        var curveSource = DeckConfig.Config()
        curveSource.rwkvReviewEnabled = true
        let curve = target.withCopiedSchedule(from: curveSource, options: options)
        #expect(curve.schedulerSelection.scheduler == .rwkvCurve)
        #expect(!curve.rwkvReviewInstantOrderEnabled)
    }

    @Test func auxSettingsKeepAddOnDataAndResetAbsentOptions() throws {
        func aux(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func object(_ config: DeckConfig.Config) -> NSDictionary {
            ((try? JSONSerialization.jsonObject(with: config.other)) as? NSDictionary) ?? [:]
        }
        let settings = options(scheduler: false, fallback: false, settings: true, retention: false)

        var target = DeckConfig.Config()
        target.other = try aux([
            "fsrs7IncludeSameDayEvaluate": false,
            "fsrs7EnableSchedulingPenalties": true,
            "fsrsEvaluationSearch": "deck:Old",
            "addon": ["enabled": true],
        ])
        let reset = target.withCopiedSchedule(from: DeckConfig.Config(), options: settings)
        #expect(object(reset) == [
            "fsrs7IncludeSameDayOptimize": true,
            "fsrs7EnableSchedulingPenalties": false,
            "fsrsEvaluationSearch": "",
            "addon": ["enabled": true],
        ] as NSDictionary)

        var source = DeckConfig.Config()
        source.other = try aux([
            "fsrs7IncludeSameDayOptimize": false,
            "fsrs7EnableSchedulingPenalties": true,
            "fsrsEvaluationSearch": "tag:study",
            "addon": ["enabled": false],
        ])
        let copied = DeckConfig.Config().withCopiedSchedule(from: source, options: settings)
        #expect(object(copied) == [
            "fsrs7IncludeSameDayOptimize": false,
            "fsrs7EnableSchedulingPenalties": true,
            "fsrsEvaluationSearch": "tag:study",
        ] as NSDictionary)
    }
}
