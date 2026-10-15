//
//  FsrsOptimize.swift
//  AnkiKit
//
//  Created by Vladimir Gusev on 07.05.2026.
//

public import Foundation

/// Inputs for `Request.computeFsrsParams`. Mirrors the wire-level
/// `Anki_Scheduler_ComputeFsrsParamsRequest` but uses `Date` for the
/// review-cutoff field and `Int` for relearning-step counts so the type
/// is comfortable for SwiftUI consumers.
public struct FsrsOptimizeRequest: Sendable, Hashable {
    /// Search string used to gather the training set.
    public let search: String
    /// Existing weights — the optimizer uses them as a starting point.
    public let currentWeights: FsrsWeights
    /// Ignore review-log entries earlier than this instant. `nil` means
    /// the entire review history is fair game.
    public let ignoreRevlogsBefore: Date?
    /// Number of relearning steps that the deck performs per day.
    public let relearningStepsPerDay: Int
    /// Whether the optimizer should also report a health-check verdict.
    public let runHealthCheck: Bool
    /// FSRS generation to fit (JSChoreels/anki fork). `nil` lets the
    /// backend infer it from `currentWeights`.
    public let fsrsVersion: FsrsVersion?
    /// FSRS-7 only: train on same-day reviews too. `nil` uses the
    /// backend's default for the version.
    public let includeSameDayReviews: Bool?
    /// FSRS-7 only: apply scheduling penalties while optimizing.
    public let enableSchedulingPenalties: Bool?
    /// FSRS-7 only: also fit the Dynamic Desired Retention model.
    public let dynamicDesiredRetentionEnabled: Bool

    public init(
        search: String,
        currentWeights: FsrsWeights,
        ignoreRevlogsBefore: Date? = nil,
        relearningStepsPerDay: Int,
        runHealthCheck: Bool,
        fsrsVersion: FsrsVersion? = nil,
        includeSameDayReviews: Bool? = nil,
        enableSchedulingPenalties: Bool? = nil,
        dynamicDesiredRetentionEnabled: Bool = false
    ) {
        self.search = search
        self.currentWeights = currentWeights
        self.ignoreRevlogsBefore = ignoreRevlogsBefore
        self.relearningStepsPerDay = relearningStepsPerDay
        self.runHealthCheck = runHealthCheck
        self.fsrsVersion = fsrsVersion
        self.includeSameDayReviews = includeSameDayReviews
        self.enableSchedulingPenalties = enableSchedulingPenalties
        self.dynamicDesiredRetentionEnabled = dynamicDesiredRetentionEnabled
    }
}

/// Output of `Request.computeFsrsParams`.
public struct FsrsOptimizeResult: Sendable, Hashable {
    /// Health-check verdict. Distinct from "didn't run" — the wire
    /// type uses `hasHealthCheckPassed` to encode that.
    public enum HealthCheck: Sendable, Hashable {
        case passed
        case failed
    }

    /// Optimized weights. Empty when the backend couldn't produce a
    /// result (typically: insufficient review history).
    public let weights: FsrsWeights
    /// Number of training items the optimizer actually used.
    public let trainingItemCount: Int
    /// Health-check verdict if the request asked for one. `nil`
    /// when health-check was disabled.
    public let healthCheck: HealthCheck?
    /// Dynamic Desired Retention model fitted alongside the weights; `nil`
    /// unless the request enabled it and the optimizer produced one.
    public let dynamicDesiredRetention: FsrsDynamicDesiredRetention?

    public init(
        weights: FsrsWeights,
        trainingItemCount: Int,
        healthCheck: HealthCheck?,
        dynamicDesiredRetention: FsrsDynamicDesiredRetention? = nil
    ) {
        self.weights = weights
        self.trainingItemCount = trainingItemCount
        self.healthCheck = healthCheck
        self.dynamicDesiredRetention = dynamicDesiredRetention
    }
}

/// Inputs for `Request.evaluateFsrsParams` (the deck options' Check
/// Health): parameters are trained on `searchForTraining` and scored on
/// `search`.
public struct FsrsEvaluateRequest: Sendable, Hashable {
    public var search: String
    public var searchForTraining: String
    public var ignoreRevlogsBefore: Date?
    public var relearningStepsPerDay: Int
    public var fsrsVersion: FsrsVersion
    /// FSRS-7 only; `nil` uses the backend's default.
    public var includeSameDayReviews: Bool?
    public var enableSchedulingPenalties: Bool

    public init(
        search: String,
        searchForTraining: String,
        ignoreRevlogsBefore: Date?,
        relearningStepsPerDay: Int,
        fsrsVersion: FsrsVersion,
        includeSameDayReviews: Bool?,
        enableSchedulingPenalties: Bool
    ) {
        self.search = search
        self.searchForTraining = searchForTraining
        self.ignoreRevlogsBefore = ignoreRevlogsBefore
        self.relearningStepsPerDay = relearningStepsPerDay
        self.fsrsVersion = fsrsVersion
        self.includeSameDayReviews = includeSameDayReviews
        self.enableSchedulingPenalties = enableSchedulingPenalties
    }
}

/// How well FSRS fits the review history; smaller is better.
public struct FsrsEvaluation: Sendable, Hashable {
    public let logLoss: Float
    public let rmseBins: Float

    public init(logLoss: Float, rmseBins: Float) {
        self.logLoss = logLoss
        self.rmseBins = rmseBins
    }
}

/// Inputs for `Request.evaluateFsrsParamsLegacy`: scores fixed `params`
/// on `search` without training.
public struct FsrsEvaluateLegacyRequest: Sendable, Hashable {
    public var params: [Float]
    public var search: String
    public var ignoreRevlogsBefore: Date?
    /// `nil` uses the backend's default for the parameters' version.
    public var includeSameDayReviews: Bool?

    public init(
        params: [Float],
        search: String,
        ignoreRevlogsBefore: Date?,
        includeSameDayReviews: Bool?
    ) {
        self.params = params
        self.search = search
        self.ignoreRevlogsBefore = ignoreRevlogsBefore
        self.includeSameDayReviews = includeSameDayReviews
    }
}
