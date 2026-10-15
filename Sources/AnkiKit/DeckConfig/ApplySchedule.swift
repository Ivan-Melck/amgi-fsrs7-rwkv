//
//  ApplySchedule.swift
//  AnkiKit
//
//  The deck options' "Apply Schedule to All Presets", as the fork's desktop
//  ts/routes/deck-options/apply-schedule.ts copies it.
//

/// What to copy from the current preset into every other one.
public struct ScheduleCopyOptions: Sendable, Hashable {
    /// The review scheduler.
    public var scheduler = true
    /// The due-date calculator, for presets that end up on RWKV-Instant.
    public var fallback = true
    /// FSRS and RWKV preset model settings.
    public var settings = true
    /// The preset's desired retention.
    public var retention = true

    public init() {}

    public var copiesAnything: Bool { scheduler || fallback || settings || retention }
}

public extension DeckConfig.Config {
    /// `withCopiedSchedule` plus `withCopiedScheduleAuxData`.
    func withCopiedSchedule(from source: Self, options: ScheduleCopyOptions) -> Self {
        var updated = options.scheduler ? withScheduler(source.schedulerSelection.scheduler) : self
        // Non-Instant presets have no separate fallback; their review
        // scheduler owns due dates.
        if options.fallback && updated.rwkvReviewInstantOrderEnabled {
            updated = updated.withDueDateScheduler(source.schedulerSelection.dueDateScheduler)
        }
        if options.settings {
            // `modelSettingFields`: preset model settings only, as
            // collection-wide controls already apply to every preset.
            updated.fsrsParams4 = source.fsrsParams4
            updated.fsrsParams5 = source.fsrsParams5
            updated.fsrsParams6 = source.fsrsParams6
            updated.fsrsParams7 = source.fsrsParams7
            updated.fsrsMinimumIntervalSecs = source.fsrsMinimumIntervalSecs
            updated.maximumReviewInterval = source.maximumReviewInterval
            updated.historicalRetention = source.historicalRetention
            updated.ignoreRevlogsBeforeDate = source.ignoreRevlogsBeforeDate
            updated.paramSearch = source.paramSearch
            updated.fsrsDynamicDesiredRetentionEnabled = source.fsrsDynamicDesiredRetentionEnabled
            updated.fsrsDynamicDesiredRetentionClamp = source.fsrsDynamicDesiredRetentionClamp
            updated.fsrsDynamicDesiredRetention = source.fsrsDynamicDesiredRetention
            updated.rwkvReviewEnforceGradeOrder = source.rwkvReviewEnforceGradeOrder
            updated.rwkvReviewMinimumReviewsPerDay = source.rwkvReviewMinimumReviewsPerDay
            updated.rwkvReviewCandidateRefreshEnabled = source.rwkvReviewCandidateRefreshEnabled
            updated.rwkvReviewRefreshInterval = source.rwkvReviewRefreshInterval
            updated.rwkvReviewMinInterveningReviews = source.rwkvReviewMinInterveningReviews
            updated.rwkvReviewMinElapsedSecs = source.rwkvReviewMinElapsedSecs
            // The settings kept in `other`.
            updated.fsrs7IncludeSameDayReviews = source.fsrs7IncludeSameDayReviews
            updated.fsrs7SchedulingPenaltiesEnabled = source.fsrs7SchedulingPenaltiesEnabled
            updated.fsrsEvaluationSearch = source.fsrsEvaluationSearch
        }
        if options.retention {
            updated.desiredRetention = source.desiredRetention
        }
        return updated
    }
}
