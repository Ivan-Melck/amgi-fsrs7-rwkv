//
//  FsrsLiveTests.swift
//  AnkiProtoBridgeTests
//
//  The deck options' FSRS health check (`evaluateFsrsParams`, its legacy
//  fixed-parameter form), the progress / abort pair that drives its
//  progress bar and Cancel button, and the stats screen's FSRS Memorised
//  series, against the real backend.
//

import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct FsrsLiveTests {
    /// FSRS-6's default weights.
    private static let fsrs6Defaults: [Float] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    /// FSRS on, and `cards` cards with six weeks of history each.
    private func studiedCollection(_ backend: AnkiBackend, cards: Int) throws {
        try configureDefaultPreset(backend, curve: false, instant: false)
        try addStudiedCards(backend, count: cards)
    }

    private func evaluateRequest(_ search: String) -> FsrsEvaluateRequest {
        FsrsEvaluateRequest(
            search: search,
            searchForTraining: search,
            ignoreRevlogsBefore: nil,
            relearningStepsPerDay: 1,
            fsrsVersion: .six,
            includeSameDayReviews: true,
            enableSchedulingPenalties: false
        )
    }

    private func legacyRequest(_ search: String) -> FsrsEvaluateLegacyRequest {
        FsrsEvaluateLegacyRequest(
            params: Self.fsrs6Defaults,
            search: search,
            ignoreRevlogsBefore: nil,
            includeSameDayReviews: true
        )
    }

    @Test func latestProgress_isNilBeforeAnyJob() throws {
        try withScratchCollection("fsrs-progress-idle") { backend, _ in
            let progress = try backend.invoke(.latestFsrsComputeProgress)
            #expect(progress == nil)
        }
    }

    @Test func evaluateLegacy_scoresTheHistory_andReportsItsReviewCount() throws {
        try withScratchCollection("fsrs-eval-legacy") { backend, _ in
            try studiedCollection(backend, cards: 8)

            let evaluation = try backend.invoke(.evaluateFsrsParamsLegacy(legacyRequest("deck:*")))
            #expect(evaluation.logLoss.isFinite && evaluation.logLoss > 0)
            #expect(evaluation.rmseBins.isFinite && evaluation.rmseBins >= 0)

            // The job's progress stays readable after it finishes, with the
            // number of reviews it scored.
            let latest = try backend.invoke(.latestFsrsComputeProgress)
            let progress = try #require(latest)
            #expect(progress.reviews > 0)
            #expect(!progress.isTrainingDynamicDesiredRetention)

            // Nothing to score: no reviews match.
            #expect(throws: BackendError.self) {
                try backend.invoke(.evaluateFsrsParamsLegacy(legacyRequest("deck:Nonexistent")))
            }
        }
    }

    @Test func evaluate_trainsAndScoresTheHistory() throws {
        try withScratchCollection("fsrs-eval") { backend, _ in
            try studiedCollection(backend, cards: 8)

            let evaluation = try backend.invoke(.evaluateFsrsParams(evaluateRequest("deck:*")))
            #expect(evaluation.logLoss.isFinite && evaluation.logLoss > 0)
            #expect(evaluation.rmseBins.isFinite && evaluation.rmseBins >= 0)
            let latest = try backend.invoke(.latestFsrsComputeProgress)
            let progress = try #require(latest)
            #expect(progress.reviews > 0)
        }
    }

    @Test func setWantsAbort_whileIdle_doesNotCancelTheNextJob() throws {
        try withScratchCollection("fsrs-abort-idle") { backend, _ in
            try studiedCollection(backend, cards: 4)
            try backend.invoke(.setWantsAbort)
            // A new job resets the flag, so a stale Cancel can't kill it.
            let evaluation = try backend.invoke(.evaluateFsrsParamsLegacy(legacyRequest("deck:*")))
            #expect(evaluation.logLoss.isFinite)
        }
    }

    @Test func setWantsAbort_interruptsARunningEvaluation() throws {
        try withScratchCollection("fsrs-abort-running") { backend, _ in
            try studiedCollection(backend, cards: 30)

            // Keep asking to abort (it bypasses the call lock the job holds)
            // until the evaluation returns: whichever progress update the
            // job reaches after starting sees the flag.
            let done = Atomic(false)
            let aborter = Thread {
                while !done.value {
                    try? backend.invoke(.setWantsAbort)
                }
            }
            aborter.start()
            defer { done.value = true }

            let result = Result { try backend.invoke(.evaluateFsrsParamsLegacy(legacyRequest("deck:*"))) }
            done.value = true
            switch result {
            case .success(let evaluation):
                Issue.record("evaluation finished despite the abort: \(evaluation)")
            case .failure(let error):
                #expect((error as? BackendError)?.kind == .interrupted, "\(error)")
            }
        }
    }

    @Test func statsFsrsMemorised_isEmptyWithoutReviews() throws {
        try withScratchCollection("fsrs-memorised-empty") { backend, _ in
            try addBasicNotes(backend, count: 2)
            let history = try backend.invoke(.statsFsrsMemorised(search: "deck:*", days: 0))
            #expect((0...23).contains(history.rollover))
            #expect(history.retrievability.values.isEmpty)
            #expect(history.cardCount.values.allSatisfy { $0 == 0 })
            #expect(history.bwMatrix.isEmpty)
        }
    }

    @Test func statsFsrsMemorised_countsTheStudiedCardsToday() throws {
        try withScratchCollection("fsrs-memorised") { backend, _ in
            try studiedCollection(backend, cards: 3)
            let history = try backend.invoke(.statsFsrsMemorised(search: "deck:*", days: 0))
            // The series start with the first review, 40 days back.
            #expect(history.cardCount.firstDay <= history.today - 39)
            #expect(history.cardCount.value(at: history.today) == 3)
            let r = try #require(history.retrievability.value(at: history.today))
            #expect(r > 0 && r < 3, "three cards, none certainly remembered")
            #expect(!history.burden.values.isEmpty)
            #expect(!history.bwMatrix.isEmpty)

            // A 10-day window starts later than the whole history.
            let recent = try backend.invoke(.statsFsrsMemorised(search: "deck:*", days: 10))
            #expect(recent.cardCount.firstDay > history.cardCount.firstDay)
        }
    }
}

/// A flag two threads share.
private final class Atomic<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
