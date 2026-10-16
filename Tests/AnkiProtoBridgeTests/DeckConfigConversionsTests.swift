//
//  DeckConfigConversionsTests.swift
//  AnkiProtoBridgeTests
//
//  Created by Vladimir Gusev on 08.05.2026.
//

import Testing
import Foundation
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend
import AnkiProto
private import SwiftProtobuf

@Suite struct DeckConfigConversionsTests {
    // MARK: - Enum exhaustiveness

    @Test func LeechAction_round_trip_covers_all_cases() {
        for mirror in LeechAction.allCases {
            let proto = Anki_DeckConfig_DeckConfig.Config.LeechAction(mirror)
            #expect(LeechAction(proto) == mirror)
        }
    }

    @Test func NewCardInsertOrder_round_trip_covers_all_cases() {
        for mirror in NewCardInsertOrder.allCases {
            #expect(NewCardInsertOrder(.init(mirror)) == mirror)
        }
    }

    @Test func NewCardGatherPriority_round_trip_covers_all_cases() {
        for mirror in NewCardGatherPriority.allCases {
            #expect(NewCardGatherPriority(.init(mirror)) == mirror)
        }
    }

    @Test func NewCardSortOrder_round_trip_covers_all_cases() {
        for mirror in NewCardSortOrder.allCases {
            #expect(NewCardSortOrder(.init(mirror)) == mirror)
        }
    }

    @Test func ReviewCardOrder_round_trip_covers_all_cases() {
        for mirror in ReviewCardOrder.allCases {
            #expect(ReviewCardOrder(.init(mirror)) == mirror)
        }
    }

    @Test func ReviewMix_round_trip_covers_all_cases() {
        for mirror in ReviewMix.allCases {
            #expect(ReviewMix(.init(mirror)) == mirror)
        }
    }

    @Test func AnswerAction_round_trip_covers_all_cases() {
        for mirror in AnswerAction.allCases {
            #expect(AnswerAction(.init(mirror)) == mirror)
        }
    }

    @Test func QuestionAction_round_trip_covers_all_cases() {
        for mirror in QuestionAction.allCases {
            #expect(QuestionAction(.init(mirror)) == mirror)
        }
    }

    @Test func UpdateDeckConfigsMode_round_trip_covers_all_cases() {
        for mirror in UpdateDeckConfigsMode.allCases {
            #expect(UpdateDeckConfigsMode(.init(mirror)) == mirror)
        }
    }

    @Test func FsrsVersion_round_trip_covers_all_cases() {
        for mirror in FsrsVersion.allCases {
            #expect(FsrsVersion(.init(mirror)) == mirror)
        }
    }

    @Test func FsrsVersion_wire_values_match_proto() {
        #expect(Anki_DeckConfig_DeckConfig.Config.FsrsVersion(FsrsVersion.seven).rawValue == 0)
        #expect(Anki_DeckConfig_DeckConfig.Config.FsrsVersion(FsrsVersion.six).rawValue == 1)
        #expect(Anki_DeckConfig_DeckConfig.Config.FsrsVersion(FsrsVersion.five).rawValue == 2)
        #expect(Anki_DeckConfig_DeckConfig.Config.FsrsVersion(FsrsVersion.four).rawValue == 3)
    }

    @Test func UNRECOGNIZED_proto_falls_back_to_default() {
        let unknown: Anki_DeckConfig_DeckConfig.Config.LeechAction = .UNRECOGNIZED(99)
        #expect(LeechAction(unknown) == .suspend)
        #expect(FsrsVersion(.UNRECOGNIZED(99)) == .seven)
    }

    // MARK: - DeckConfig.Config round-trip

    @Test func DeckConfig_Config_round_trip_preserves_scalar_fields() {
        var proto = Anki_DeckConfig_DeckConfig.Config()
        proto.newPerDay = 25
        proto.reviewsPerDay = 250
        proto.leechThreshold = 9
        proto.leechAction = .tagOnly
        proto.maximumReviewInterval = 36500
        proto.intervalMultiplier = 1.05
        proto.fsrsParams6 = [0.1, 0.2, 0.3]
        proto.desiredRetention = 0.9
        proto.paramSearch = "deck:Korean"
        proto.buryNew = true

        let mirror = DeckConfig.Config(proto)
        #expect(mirror.newPerDay == 25)
        #expect(mirror.reviewsPerDay == 250)
        #expect(mirror.leechThreshold == 9)
        #expect(mirror.leechAction == .tagOnly)
        #expect(mirror.maximumReviewInterval == 36500)
        #expect(mirror.intervalMultiplier == 1.05)
        #expect(mirror.fsrsParams6 == [0.1, 0.2, 0.3])
        #expect(mirror.desiredRetention == 0.9)
        #expect(mirror.paramSearch == "deck:Korean")
        #expect(mirror.buryNew)

        let reproto = mirror.toProto()
        #expect(reproto.newPerDay == 25)
        #expect(reproto.leechAction == .tagOnly)
        #expect(reproto.fsrsParams6 == [0.1, 0.2, 0.3])
        #expect(reproto.desiredRetention == 0.9)
    }

    @Test func DeckConfig_Config_round_trip_preserves_fork_fields() {
        var proto = Anki_DeckConfig_DeckConfig.Config()
        proto.fsrsParams7 = [0.7, 0.8]
        proto.fsrsParams6 = [0.6]
        proto.fsrsVersion = .five
        proto.fsrsMinimumIntervalSecs = 600
        proto.fsrsDynamicDesiredRetentionEnabled = true
        proto.fsrsDynamicDesiredRetentionClamp = true
        proto.fsrsDynamicDesiredRetentionParams = [1, 2]
        proto.fsrsDynamicDesiredRetentionWeights = [3]
        proto.fsrsDynamicDesiredRetentionAvgDrs = [4]
        proto.fsrsDynamicDesiredRetentionMin = 0.75
        proto.fsrsDynamicDesiredRetentionMax = 0.95
        proto.fsrsDynamicDesiredRetentionFsrsEqWeights = [5]
        proto.fsrsDynamicDesiredRetentionFsrsEqDrs = [6]
        proto.fsrsDynamicDesiredRetentionFixedTargetWeights = [7]
        proto.fsrsDynamicDesiredRetentionFixedTargetDrs = [8]
        proto.leechOnlyIfYoung = true
        proto.sameDayReviewsIgnoreReviewLimit = true
        proto.rwkvReviewEnabled = true
        proto.rwkvReviewInstantOrderEnabled = true
        proto.rwkvReviewRefreshInterval = 3
        proto.rwkvReviewCandidateRefreshEnabled = true
        proto.rwkvReviewMinInterveningReviews = 7
        proto.rwkvReviewMinElapsedSecs = 45
        proto.rwkvReviewEnforceGradeOrder = true
        proto.rwkvReviewMinimumReviewsPerDay = 20

        let mirror = DeckConfig.Config(proto)
        #expect(mirror.fsrsParams7 == [0.7, 0.8])
        #expect(mirror.fsrsVersion == .five)
        #expect(mirror.fsrsMinimumIntervalSecs == 600)
        #expect(mirror.fsrsDynamicDesiredRetentionEnabled)
        #expect(mirror.fsrsDynamicDesiredRetentionClamp)
        #expect(mirror.fsrsDynamicDesiredRetention.params == [1, 2])
        #expect(mirror.fsrsDynamicDesiredRetention.minimum == 0.75)
        #expect(mirror.fsrsDynamicDesiredRetention.maximum == 0.95)
        #expect(mirror.fsrsDynamicDesiredRetention.fixedTargetDrs == [8])
        #expect(mirror.leechOnlyIfYoung)
        #expect(mirror.sameDayReviewsIgnoreReviewLimit)
        #expect(mirror.rwkvReviewEnabled)
        #expect(mirror.rwkvReviewInstantOrderEnabled)
        #expect(mirror.rwkvReviewRefreshInterval == 3)
        #expect(mirror.rwkvReviewCandidateRefreshEnabled)
        #expect(mirror.rwkvReviewMinInterveningReviews == 7)
        #expect(mirror.rwkvReviewMinElapsedSecs == 45)
        #expect(mirror.rwkvReviewEnforceGradeOrder)
        #expect(mirror.rwkvReviewMinimumReviewsPerDay == 20)
        #expect(mirror.activeFsrsParams == [])

        #expect(mirror.toProto() == proto)
    }

    @Test func DeckConfig_Config_writes_edited_fork_fields() {
        var mirror = DeckConfig.Config(Anki_DeckConfig_DeckConfig.Config())
        mirror.fsrsParams7 = [0.1, 0.2]
        mirror.fsrsVersion = .six
        mirror.fsrsMinimumIntervalSecs = 36_500 * 86_400
        mirror.fsrsDynamicDesiredRetentionEnabled = true
        mirror.fsrsDynamicDesiredRetention = FsrsDynamicDesiredRetention(params: [9], minimum: 0.7)
        mirror.leechOnlyIfYoung = true
        mirror.sameDayReviewsIgnoreReviewLimit = true
        mirror.rwkvReviewInstantOrderEnabled = true
        mirror.rwkvReviewMinElapsedSecs = 86_400
        mirror.rwkvReviewEnforceGradeOrder = true

        let proto = mirror.toProto()
        #expect(proto.fsrsParams7 == [0.1, 0.2])
        #expect(proto.fsrsVersion == .six)
        #expect(proto.fsrsMinimumIntervalSecs == 3_153_600_000)
        #expect(proto.fsrsDynamicDesiredRetentionEnabled)
        #expect(!proto.fsrsDynamicDesiredRetentionClamp)
        #expect(proto.fsrsDynamicDesiredRetentionParams == [9])
        #expect(proto.fsrsDynamicDesiredRetentionMin == 0.7)
        #expect(proto.leechOnlyIfYoung)
        #expect(proto.sameDayReviewsIgnoreReviewLimit)
        #expect(proto.rwkvReviewInstantOrderEnabled)
        #expect(!proto.rwkvReviewEnabled)
        #expect(proto.rwkvReviewMinElapsedSecs == 86_400)
        #expect(proto.rwkvReviewEnforceGradeOrder)
    }

    // MARK: - Scheduler choice

    @Test func scheduler_is_derived_from_version_curve_and_instant() {
        #expect(SchedulerSelection(fsrsVersion: .seven).scheduler == .fsrs7)
        #expect(SchedulerSelection(fsrsVersion: .six).scheduler == .fsrs6)
        #expect(SchedulerSelection(fsrsVersion: .five).scheduler == .fsrs5)
        #expect(SchedulerSelection(fsrsVersion: .four).scheduler == .fsrs4)
        #expect(SchedulerSelection(fsrsVersion: .six, rwkvReviewEnabled: true).scheduler == .rwkvCurve)

        let instant = SchedulerSelection(fsrsVersion: .six, rwkvReviewInstantOrderEnabled: true)
        #expect(instant.scheduler == .rwkvInstant)
        #expect(instant.dueDateScheduler == .fsrs6)
        let instantOnCurve = SchedulerSelection(rwkvReviewEnabled: true, rwkvReviewInstantOrderEnabled: true)
        #expect(instantOnCurve.scheduler == .rwkvInstant)
        #expect(instantOnCurve.dueDateScheduler == .rwkvCurve)
    }

    @Test func withScheduler_fsrs_choice_sets_version_and_clears_rwkv() {
        let start = SchedulerSelection(fsrsVersion: .seven, rwkvReviewEnabled: true, rwkvReviewInstantOrderEnabled: true)
        let updated = start.withScheduler(.fsrs6)
        #expect(updated == SchedulerSelection(fsrsVersion: .six))
    }

    @Test func withScheduler_curve_keeps_version() {
        let updated = SchedulerSelection(fsrsVersion: .six).withScheduler(.rwkvCurve)
        #expect(updated == SchedulerSelection(fsrsVersion: .six, rwkvReviewEnabled: true))
        #expect(updated.scheduler == .rwkvCurve)
    }

    @Test func withScheduler_instant_keeps_due_date_scheduler() {
        let curve = SchedulerSelection(fsrsVersion: .six, rwkvReviewEnabled: true)
        let updated = curve.withScheduler(.rwkvInstant)
        #expect(updated == SchedulerSelection(fsrsVersion: .six, rwkvReviewEnabled: true, rwkvReviewInstantOrderEnabled: true))
        #expect(updated.dueDateScheduler == .rwkvCurve)
    }

    @Test func withDueDateScheduler_keeps_instant() {
        let instant = SchedulerSelection(fsrsVersion: .seven, rwkvReviewInstantOrderEnabled: true)
        let curve = instant.withDueDateScheduler(.rwkvCurve)
        #expect(curve == SchedulerSelection(fsrsVersion: .seven, rwkvReviewEnabled: true, rwkvReviewInstantOrderEnabled: true))
        let fsrs6 = curve.withDueDateScheduler(.fsrs6)
        #expect(fsrs6 == SchedulerSelection(fsrsVersion: .six, rwkvReviewInstantOrderEnabled: true))
        #expect(fsrs6.withDueDateScheduler(.rwkvInstant) == fsrs6)
    }

    @Test func Config_withScheduler_writes_the_three_fields() {
        let config = DeckConfig.Config(fsrsVersion: .six).withScheduler(.fsrs7)
        #expect(config.fsrsVersion == .seven)
        #expect(!config.rwkvReviewEnabled)
        #expect(!config.rwkvReviewInstantOrderEnabled)
        #expect(config.withScheduler(.rwkvInstant).schedulerSelection.scheduler == .rwkvInstant)
        #expect(config.withDueDateScheduler(.rwkvCurve).rwkvReviewEnabled)
    }

    @Test func activeFsrsParams_follow_the_version() {
        var config = DeckConfig.Config(
            fsrsParams4: [4],
            fsrsParams5: [5],
            fsrsParams6: [6],
            fsrsParams7: [7]
        )
        #expect(config.activeFsrsParams == [7])
        config.fsrsVersion = .six
        #expect(config.activeFsrsParams == [6])
        config.activeFsrsParams = [6.5]
        #expect(config.fsrsParams6 == [6.5])
        #expect(config.fsrsParams7 == [7])
        #expect(config.fsrsParams(for: .five) == [5])
        #expect(config.fsrsParams(for: .four) == [4])
    }

    // MARK: - Aux data (`other` JSON)

    @Test func auxData_defaults_when_other_is_empty() {
        let config = DeckConfig.Config()
        #expect(config.fsrs7IncludeSameDayReviews)
        #expect(!config.fsrs7SchedulingPenaltiesEnabled)
        #expect(config.fsrsEvaluationSearch == "")
        #expect(config.intradayLearningMix == .mixWithReviews)
    }

    @Test func auxData_setters_skip_unchanged_values() {
        var config = DeckConfig.Config()
        config.fsrs7IncludeSameDayReviews = true
        config.fsrs7SchedulingPenaltiesEnabled = false
        config.fsrsEvaluationSearch = ""
        config.intradayLearningMix = .mixWithReviews
        #expect(config.other.isEmpty)
    }

    @Test func auxData_setters_preserve_other_keys() throws {
        var config = DeckConfig.Config(other: Data(#"{"addon":{"x":1},"jschoreels.deckoptions":{"keep":true}}"#.utf8))
        config.fsrs7IncludeSameDayReviews = false
        config.fsrs7SchedulingPenaltiesEnabled = true
        config.fsrsEvaluationSearch = "deck:Korean"
        config.intradayLearningMix = .afterReviews

        #expect(!config.fsrs7IncludeSameDayReviews)
        #expect(config.fsrs7SchedulingPenaltiesEnabled)
        #expect(config.fsrsEvaluationSearch == "deck:Korean")
        #expect(config.intradayLearningMix == .afterReviews)

        let object = try JSONSerialization.jsonObject(with: config.other)
        let json = try #require(object as? [String: Any])
        #expect(json["fsrs7IncludeSameDayOptimize"] as? Bool == false)
        #expect(json["fsrs7EnableSchedulingPenalties"] as? Bool == true)
        #expect((json["addon"] as? [String: Any])?["x"] as? Int == 1)
        let metadata = try #require(json["jschoreels.deckoptions"] as? [String: Any])
        #expect(metadata["keep"] as? Bool == true)
        #expect(metadata["intraday_learning_mix"] as? Int == 1)
    }

    @Test func auxData_reads_and_migrates_legacy_keys() throws {
        var config = DeckConfig.Config(other: Data(
            #"{"fsrs7IncludeSameDayEvaluate":false,"jschoreels.deckoptions":{"intraday_learning_before_reviews":true}}"#.utf8
        ))
        #expect(!config.fsrs7IncludeSameDayReviews)
        #expect(config.intradayLearningMix == .beforeReviews)

        // Writing the same values still rewrites them under the current keys.
        config.fsrs7IncludeSameDayReviews = false
        config.intradayLearningMix = .beforeReviews
        let object = try JSONSerialization.jsonObject(with: config.other)
        let json = try #require(object as? [String: Any])
        #expect(!json.keys.contains("fsrs7IncludeSameDayEvaluate"))
        #expect(json["fsrs7IncludeSameDayOptimize"] as? Bool == false)
        let metadata = try #require(json["jschoreels.deckoptions"] as? [String: Any])
        #expect(!metadata.keys.contains("intraday_learning_before_reviews"))
        #expect(metadata["intraday_learning_mix"] as? Int == 2)
    }

    // MARK: - computeFsrsParams fork fields

    @Test func computeFsrsParams_encodes_fork_fields() throws {
        let request = FsrsOptimizeRequest(
            search: "deck:Korean",
            currentWeights: FsrsWeights([0.1]),
            relearningStepsPerDay: 1,
            runHealthCheck: false,
            fsrsVersion: .seven,
            includeSameDayReviews: false,
            enableSchedulingPenalties: true,
            dynamicDesiredRetentionEnabled: true
        )
        let envelope: Request<FsrsOptimizeResult> = .computeFsrsParams(request)
        let proto = try Anki_Scheduler_ComputeFsrsParamsRequest(serializedBytes: envelope.body)

        #expect(proto.hasFsrsVersion)
        #expect(proto.fsrsVersion == .seven)
        #expect(proto.hasIncludeSameDayReviews)
        #expect(!proto.includeSameDayReviews)
        #expect(proto.hasEnableSchedulingPenalties)
        #expect(proto.enableSchedulingPenalties)
        #expect(proto.dynamicDesiredRetentionEnabled)
        #expect(!proto.hasDynamicDesiredRetentionReviewLimit)
    }

    @Test func computeFsrsParams_leaves_optional_fork_fields_unset_by_default() throws {
        let request = FsrsOptimizeRequest(
            search: "deck:Korean",
            currentWeights: FsrsWeights([0.1]),
            relearningStepsPerDay: 1,
            runHealthCheck: false
        )
        let envelope: Request<FsrsOptimizeResult> = .computeFsrsParams(request)
        let proto = try Anki_Scheduler_ComputeFsrsParamsRequest(serializedBytes: envelope.body)

        #expect(!proto.hasFsrsVersion)
        #expect(!proto.hasIncludeSameDayReviews)
        #expect(!proto.hasEnableSchedulingPenalties)
        #expect(!proto.dynamicDesiredRetentionEnabled)
    }

    @Test func computeFsrsParams_decodes_dynamic_desired_retention() throws {
        var resp = Anki_Scheduler_ComputeFsrsParamsResponse()
        resp.params = [0.4]
        resp.fsrsDynamicDesiredRetentionParams = [1, 2]
        resp.fsrsDynamicDesiredRetentionWeights = [3]
        resp.fsrsDynamicDesiredRetentionMin = 0.7
        resp.fsrsDynamicDesiredRetentionMax = 0.97
        resp.fsrsDynamicDesiredRetentionFixedTargetDrs = [8]
        let request = FsrsOptimizeRequest(
            search: "",
            currentWeights: FsrsWeights(),
            relearningStepsPerDay: 0,
            runHealthCheck: false
        )
        let envelope: Request<FsrsOptimizeResult> = .computeFsrsParams(request)

        let result = try envelope.decode(resp.serializedData())
        let adr = try #require(result.dynamicDesiredRetention)
        #expect(adr.params == [1, 2])
        #expect(adr.weights == [3])
        #expect(adr.minimum == 0.7)
        #expect(adr.maximum == 0.97)
        #expect(adr.fixedTargetDrs == [8])

        let withoutAdr = try envelope.decode(Anki_Scheduler_ComputeFsrsParamsResponse().serializedData())
        #expect(withoutAdr.dynamicDesiredRetention == nil)
    }

    // MARK: - DeckConfigsForUpdate.CurrentDeck.Limits — optional handling

    @Test func Limits_unset_optionals_decode_to_nil() {
        let proto = Anki_DeckConfig_DeckConfigsForUpdate.CurrentDeck.Limits()
        let mirror = DeckConfigsForUpdate.CurrentDeck.Limits(proto)
        #expect(mirror.review == nil)
        #expect(mirror.new == nil)
        #expect(mirror.reviewToday == nil)
        #expect(mirror.newToday == nil)
        #expect(mirror.desiredRetention == nil)
        #expect(!mirror.reviewTodayActive)
    }

    @Test func Limits_set_optionals_decode_to_value() {
        var proto = Anki_DeckConfig_DeckConfigsForUpdate.CurrentDeck.Limits()
        proto.review = 100
        proto.desiredRetention = 0.92
        let mirror = DeckConfigsForUpdate.CurrentDeck.Limits(proto)
        #expect(mirror.review == 100)
        #expect(mirror.desiredRetention == 0.92)
    }

    @Test func Limits_round_trip_keeps_optional_distinction() throws {
        var proto = Anki_DeckConfig_DeckConfigsForUpdate.CurrentDeck.Limits()
        proto.new = 7
        let mirror = DeckConfigsForUpdate.CurrentDeck.Limits(proto)
        let reproto = mirror.toProto()
        #expect(reproto.hasNew)
        #expect(reproto.new == 7)
        #expect(!reproto.hasReview)
    }

    @Test func CurrentDeck_round_trips_subtree_config_ids() {
        var proto = Anki_DeckConfig_DeckConfigsForUpdate.CurrentDeck()
        proto.name = "Parent"
        proto.configID = 1
        proto.subtreeConfigIds = [1, 42]
        let mirror = DeckConfigsForUpdate.CurrentDeck(proto)
        #expect(mirror.subtreeConfigIds == [DeckConfigID(1), DeckConfigID(42)])
        #expect(mirror.toProto().subtreeConfigIds == [1, 42])
    }

    // MARK: - DeckConfigsForUpdate

    @Test func DeckConfigsForUpdate_decodes_with_or_without_optional_fields() {
        var proto = Anki_DeckConfig_DeckConfigsForUpdate()
        proto.cardStateCustomizer = "card-state"
        proto.fsrs = true
        // No currentDeck, no defaults set — both should decode to nil.

        let mirror = DeckConfigsForUpdate(proto)
        #expect(mirror.cardStateCustomizer == "card-state")
        #expect(mirror.fsrs)
        #expect(mirror.currentDeck == nil)
        #expect(mirror.defaults == nil)
    }

    // MARK: - Fields the mirror doesn't name

    @Test func Config_round_trip_keeps_unmirrored_fork_fields() {
        var proto = Anki_DeckConfig_DeckConfig.Config()
        proto.newPerDay = 20
        proto.fsrsParams7 = [0.1, 0.2, 0.3]
        proto.fsrsVersion = .six
        proto.rwkvReviewEnabled = true
        proto.reviewFuzzBase = 1.5

        var mirror = DeckConfig.Config(proto)
        mirror.newPerDay = 30
        let reproto = mirror.toProto()

        #expect(reproto.newPerDay == 30)
        #expect(reproto.fsrsParams7 == [0.1, 0.2, 0.3])
        #expect(reproto.fsrsVersion == .six)
        #expect(reproto.rwkvReviewEnabled)
        #expect(reproto.reviewFuzzBase == 1.5)
    }

    @Test func UpdateDeckConfigsRequest_echoes_collection_scheduling_settings() {
        var contextProto = Anki_DeckConfig_DeckConfigsForUpdate()
        contextProto.loadBalancerEnabled = true
        contextProto.fsrsLearningQueuesDisabled = true
        contextProto.reviewFuzzFactorMid = 0.2
        let context = DeckConfigsForUpdate(contextProto)

        let proto = UpdateDeckConfigsRequest(
            targetDeckID: DeckID(1),
            configs: [],
            schedulingSettings: context.schedulingSettings
        ).toProto()

        #expect(proto.loadBalancerEnabled)
        #expect(proto.fsrsLearningQueuesDisabled)
        #expect(!proto.fsrsShortTermWithStepsEnabled)
        #expect(proto.reviewFuzzFactorMid == 0.2)
    }

    @Test func UpdateDeckConfigsRequest_sends_edited_collection_scheduling_settings() {
        let edited = CollectionSchedulingSettings(
            loadBalancerEnabled: false,
            fsrsShortTermWithStepsEnabled: true,
            fsrsLearningQueuesDisabled: false,
            reviewFuzzEnabled: true,
            reviewFuzzBase: 2.5,
            reviewFuzzFactorShort: 0.15,
            reviewFuzzFactorMid: 0.1,
            reviewFuzzFactorLong: 0.05
        )
        let proto = UpdateDeckConfigsRequest(
            targetDeckID: DeckID(1),
            configs: [],
            schedulingSettings: edited
        ).toProto()

        #expect(!proto.loadBalancerEnabled)
        #expect(proto.fsrsShortTermWithStepsEnabled)
        #expect(proto.reviewFuzzEnabled)
        #expect(proto.reviewFuzzBase == 2.5)
        #expect(proto.reviewFuzzFactorShort == 0.15)
        #expect(proto.reviewFuzzFactorLong == 0.05)
        #expect(DeckConfigsForUpdate(Self.contextProto(from: proto)).schedulingSettings == edited)
    }

    /// The context fields 13-20 carry the same values the request's 12-19 do.
    private static func contextProto(
        from request: Anki_DeckConfig_UpdateDeckConfigsRequest
    ) -> Anki_DeckConfig_DeckConfigsForUpdate {
        var context = Anki_DeckConfig_DeckConfigsForUpdate()
        context.loadBalancerEnabled = request.loadBalancerEnabled
        context.fsrsShortTermWithStepsEnabled = request.fsrsShortTermWithStepsEnabled
        context.fsrsLearningQueuesDisabled = request.fsrsLearningQueuesDisabled
        context.reviewFuzzEnabled = request.reviewFuzzEnabled
        context.reviewFuzzBase = request.reviewFuzzBase
        context.reviewFuzzFactorShort = request.reviewFuzzFactorShort
        context.reviewFuzzFactorMid = request.reviewFuzzFactorMid
        context.reviewFuzzFactorLong = request.reviewFuzzFactorLong
        return context
    }

    // MARK: - UpdateDeckConfigsRequest

    @Test func UpdateDeckConfigsRequest_encodes_mode_and_passes_through_limits() throws {
        let limits = DeckConfigsForUpdate.CurrentDeck.Limits(review: 50)
        let request = UpdateDeckConfigsRequest(
            targetDeckID: DeckID(1),
            configs: [DeckConfig(id: DeckConfigID(7), name: "Test")],
            removedConfigIds: [DeckConfigID(2)],
            mode: .computeAllParams,
            cardStateCustomizer: "custom",
            limits: limits,
            newCardsIgnoreReviewLimit: true,
            fsrs: true,
            applyAllParentLimits: false,
            fsrsHealthCheck: true
        )

        let proto = request.toProto()
        #expect(proto.targetDeckID == 1)
        #expect(proto.configs.count == 1)
        #expect(proto.configs[0].id == 7)
        #expect(proto.removedConfigIds == [2])
        #expect(proto.mode == .computeAllParams)
        #expect(proto.cardStateCustomizer == "custom")
        #expect(proto.hasLimits)
        #expect(proto.limits.review == 50)
        #expect(proto.newCardsIgnoreReviewLimit)
        #expect(proto.fsrs)
        #expect(proto.fsrsHealthCheck)
    }

    // MARK: - Request factories

    @Test func deckConfigsForUpdate_dispatches_correctly() {
        let envelope: Request<DeckConfigsForUpdate> = .deckConfigsForUpdate(deckId: DeckID(42))
        #expect(envelope.serviceId == ServiceID.deckConfig)
        #expect(envelope.methodId == DeckConfigMethod.getDeckConfigsForUpdate)
    }

    @Test func deckConfig_dispatches_correctly() {
        let envelope: Request<DeckConfig> = .deckConfig(for: DeckConfigID(99))
        #expect(envelope.serviceId == ServiceID.deckConfig)
        #expect(envelope.methodId == DeckConfigMethod.getDeckConfig)
    }

    @Test func updateDeckConfigs_dispatches_correctly() {
        let request = UpdateDeckConfigsRequest(targetDeckID: DeckID(1), configs: [])
        let envelope: Request<Void> = .updateDeckConfigs(request)
        #expect(envelope.serviceId == ServiceID.deckConfig)
        #expect(envelope.methodId == DeckConfigMethod.updateDeckConfigs)
    }
}
