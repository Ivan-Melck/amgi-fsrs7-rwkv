//
//  DeckConfigModel.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 14.05.2026.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation



/// Owns the per-deck study-options editing surface: the `deckClient`
/// dependency, the loaded config + context, every editable form field, and
/// all load/save/preset/FSRS I/O. The `DeckConfigView` Container binds its
/// sections to `$model.field` and translates engine outcomes into
/// `destination` transitions, so the view itself carries no `@Dependency`.
@Observable
@MainActor
final class DeckConfigModel {
    let deckId: DeckID
    let deckName: String

    // Internal rather than private: the preset/FSRS methods live in
    // DeckConfigModel+Presets.swift now, and `private` is file-scoped.
    @ObservationIgnored @Dependency(\.deckClient) var deckClient
    @ObservationIgnored @Dependency(\.rwkvClient) var rwkvClient

    var loaded: LoadedConfig?
    var baseline: DeckConfig?
    /// `editedLimits` as loaded, so an untouched page isn't "changed".
    var baselineLimits: DeckConfigsForUpdate.CurrentDeck.Limits?
    var isLoading = true
    var isSaving = false
    var loadError: String?
    var destination: DeckConfigDestination?

    /// The preset's limits; `newLimitTabs`/`reviewLimitTabs` say whether
    /// this deck or today overrides them.
    var newCardsPerDay: Int32 = 20
    var reviewsPerDay: Int32 = 200
    var newLimitTabs = DailyLimitTabs(deck: nil, today: nil, todayActive: false)
    var reviewLimitTabs = DailyLimitTabs(deck: nil, today: nil, todayActive: false)
    var newCardsIgnoreReviewLimit = false
    var applyAllParentLimits = false
    var sameDayReviewsIgnoreReviewLimit = false

    var learningStepsText: String = "1m 10m"
    var graduatingGoodDays: Int32 = 1
    var graduatingEasyDays: Int32 = 4

    var relearningStepsText: String = "10m"
    var leechThreshold: Int32 = 8
    var leechAction: LeechAction = .suspend
    var leechOnlyIfYoung = false

    // Scheduler — the preset's FSRS version / RWKV-Curve / RWKV-Instant.
    var schedulerSelection = SchedulerSelection()

    var fsrsEnabled = false
    /// The shared preset's desired retention.
    var desiredRetentionPercent: Double = 90
    /// This deck's own desired retention ("This deck" on the desktop), which
    /// wins over the preset's; nil when the deck uses the preset's.
    var deckDesiredRetentionPercent: Double?
    /// The deck options context couldn't be loaded, so the collection-wide
    /// values on screen are guesses: saving would overwrite the real ones.
    var isFallbackContext = false
    var historicalRetentionPercent: Double = 90
    var fsrsHealthCheck = false
    /// The desktop's "Reschedule cards on change": collection-wide and,
    /// as there, not saved — it only applies to this save.
    var fsrsReschedule = false
    var fsrsWeightsText: String = ""
    var fsrsParamSearch: String = ""
    var fsrsEvaluationSearch: String = ""
    /// Params of FSRS versions switched away from in this session, keyed by
    /// version; `fsrsWeightsText` always edits the active version.
    var parkedFsrsParams: [FsrsVersion: [Float]] = [:]
    var fsrsMinimumIntervalSecs: Int = 1
    var fsrs7IncludeSameDayReviews = true
    var fsrs7SchedulingPenaltiesEnabled = false
    var dynamicDesiredRetentionEnabled = false
    var dynamicDesiredRetentionClamp = false
    /// ADR model from the last optimization; written on save.
    var optimizedDynamicDesiredRetention: FsrsDynamicDesiredRetention?
    var isOptimizingFsrs = false
    @ObservationIgnored var optimizeGeneration = 0

    // RWKV
    var rwkvMinimumReviewsPerDay: Int32 = 0
    var rwkvCandidateRefreshEnabled = false
    var rwkvRefreshInterval: Int32 = 1
    var rwkvMinInterveningReviews: Int32 = 5
    var rwkvMinElapsedSecs: Int32 = 30
    var rwkvEnforceGradeOrder = true

    // Collection-wide scheduling (all presets)
    var loadBalancerEnabled = false
    var fsrsShortTermWithStepsEnabled = true
    var fsrsLearningQueuesDisabled = false
    var reviewFuzzEnabled = true
    var reviewFuzzBase: Double = 1
    var reviewFuzzFactorShort: Double = 0.15
    var reviewFuzzFactorMid: Double = 0.1
    var reviewFuzzFactorLong: Double = 0.05

    var applyToChildren = false

    // Preset CRUD — text-field draft state for the create/rename alerts.
    // (Presentation state itself lives in `destination`.)
    var isPresetMutating = false
    var isRebuildingRwkvState = false
    var isCheckingFsrsHealth = false
    var newPresetName = ""
    var renamePresetDraft = ""

    // Bury
    var buryNew = true
    var buryReviews = true
    var buryInterdayLearning = false

    // Order
    var newCardInsertOrder: NewCardInsertOrder = .due
    var newCardGatherPriority: NewCardGatherPriority = .deck
    var newCardSortOrder: NewCardSortOrder = .template
    var newMix: ReviewMix = .mixWithReviews
    var reviewOrder: ReviewCardOrder = .day
    var interdayLearningMix: ReviewMix = .mixWithReviews
    var intradayLearningMix: ReviewMix = .mixWithReviews

    // Timer
    var showTimer = false
    var capAnswerTimeToSecs: Int32 = 60
    var stopTimerOnAnswer = true

    // Auto-Advance
    var secondsToShowQuestion: Double = 0
    var secondsToShowAnswer: Double = 0
    var questionAction: QuestionAction = .showAnswer
    var answerAction: AnswerAction = .buryCard

    // Advanced
    var maximumReviewIntervalDays: Int32 = 36500
    var intervalMultiplierPercent: Double = 100
    var hardMultiplierPercent: Double = 120
    var easyMultiplierPercent: Double = 130
    var disableAutoplay = false
    var waitForAudio = false

    // Easy Days — per-weekday FSRS workload multipliers (Mon..Sun, 50..150%).
    var easyDayPercentages: [Double] = Array(repeating: 100, count: 7)

    struct LoadedConfig {
        var config: DeckConfig
        var context: DeckConfigsForUpdate
    }

    init(deckId: DeckID, deckName: String) {
        self.deckId = deckId
        self.deckName = deckName
    }

    // MARK: - Derived presentation values

    var currentAlert: DeckConfigAlert? {
        if case .alert(let a) = destination { return a }
        return nil
    }

    var alertTitle: String {
        switch currentAlert {
        case .saveFailed: "Couldn't save deck options"
        case .fsrsError(let title, _), .notice(let title, _): title
        case .presetError: "Couldn't change preset"
        case .deletePresetConfirm: "Delete \"\(currentPresetName ?? "this preset")\"?"
        case .discardChanges, .unsavedBeforePresetChange: "Unsaved changes"
        case nil: ""
        }
    }

    var hasLoadedConfig: Bool { loaded != nil }
    var currentPresetName: String? { loaded?.config.name }
    var deleteFallbackPresetName: String? { deleteFallbackPreset?.name }
    /// `removalWilLForceFullSync`: removing a saved preset modifies the
    /// schema, unless it was already modified since the last sync.
    var deleteRequiresFullSync: Bool { loaded?.context.schemaModified == false }

    var presetOptions: [DeckConfigsForUpdate.ConfigWithExtra] {
        (loaded?.context.allConfig ?? [])
            .sorted { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
    }

    var selectedPresetID: DeckConfigID { loaded?.config.id ?? DeckConfigID(0) }

    var canDeletePreset: Bool {
        // Preset id 1 is the built-in Default preset and cannot be removed.
        selectedPresetID.rawValue != 0 && selectedPresetID.rawValue != 1 && presetOptions.count > 1
    }

    var deleteFallbackPreset: DeckConfig? {
        presetOptions.first(where: { $0.config.id.rawValue == 1 && $0.config.id != selectedPresetID })?.config
            ?? presetOptions.first(where: { $0.config.id != selectedPresetID })?.config
    }

    var presetUseCount: Int {
        loaded.flatMap { l in l.context.allConfig.first(where: { $0.config.id == l.config.id })?.useCount } ?? 0
    }

    /// Whether the backend reported the collection-wide scheduling settings;
    /// without them there is nothing safe to edit.
    var hasSchedulingSettings: Bool { loaded?.context.schedulingSettings != nil }

    var editedSchedulingSettings: CollectionSchedulingSettings? {
        guard hasSchedulingSettings else { return nil }
        return CollectionSchedulingSettings(
            loadBalancerEnabled: loadBalancerEnabled,
            fsrsShortTermWithStepsEnabled: fsrsShortTermWithStepsEnabled,
            fsrsLearningQueuesDisabled: fsrsLearningQueuesDisabled,
            reviewFuzzEnabled: reviewFuzzEnabled,
            reviewFuzzBase: Float(reviewFuzzBase),
            reviewFuzzFactorShort: Float(reviewFuzzFactorShort),
            reviewFuzzFactorMid: Float(reviewFuzzFactorMid),
            reviewFuzzFactorLong: Float(reviewFuzzFactorLong)
        )
    }

    var defaultParamSearch: String {
        let escaped = (loaded?.config.name ?? deckName)
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "preset:\"\(escaped)\" -is:suspended"
    }

    // MARK: - Load / save

    func loadConfig() async {
        isLoading = true
        loadError = nil
        do {
            let config = try await deckClient.getDeckConfig(deckId)
            let fetched = try? await deckClient.fetchDeckConfigContext(deckId)
            isFallbackContext = fetched == nil
            apply(config: config, context: fetched ?? fallbackContext(from: config))
            isLoading = false
        } catch {
            loadError = "Failed to load deck options: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func apply(config: DeckConfig, context: DeckConfigsForUpdate) {
        loaded = LoadedConfig(config: config, context: context)
        let cfg = config.config
        newCardsPerDay = Int32(cfg.newPerDay)
        reviewsPerDay = Int32(cfg.reviewsPerDay)
        learningStepsText = formatSteps(cfg.learnSteps)
        relearningStepsText = formatSteps(cfg.relearnSteps)
        graduatingGoodDays = Int32(cfg.graduatingIntervalGood)
        graduatingEasyDays = Int32(cfg.graduatingIntervalEasy)
        leechThreshold = Int32(max(1, cfg.leechThreshold))
        leechAction = cfg.leechAction
        leechOnlyIfYoung = cfg.leechOnlyIfYoung
        sameDayReviewsIgnoreReviewLimit = cfg.sameDayReviewsIgnoreReviewLimit
        schedulerSelection = cfg.schedulerSelection

        newCardsIgnoreReviewLimit = context.newCardsIgnoreReviewLimit
        applyAllParentLimits = context.applyAllParentLimits
        fsrsHealthCheck = context.fsrsHealthCheck
        fsrsEnabled = context.fsrs
        if let settings = context.schedulingSettings {
            loadBalancerEnabled = settings.loadBalancerEnabled
            fsrsShortTermWithStepsEnabled = settings.fsrsShortTermWithStepsEnabled
            fsrsLearningQueuesDisabled = settings.fsrsLearningQueuesDisabled
            reviewFuzzEnabled = settings.reviewFuzzEnabled
            reviewFuzzBase = Double(settings.reviewFuzzBase)
            reviewFuzzFactorShort = Double(settings.reviewFuzzFactorShort)
            reviewFuzzFactorMid = Double(settings.reviewFuzzFactorMid)
            reviewFuzzFactorLong = Double(settings.reviewFuzzFactorLong)
        }

        desiredRetentionPercent = cfg.desiredRetention > 0 ? Double(cfg.desiredRetention * 100) : 90
        deckDesiredRetentionPercent = context.currentDeck?.limits?.desiredRetention.map { Double($0 * 100) }
        let limits = context.currentDeck?.limits
        newLimitTabs = DailyLimitTabs(
            deck: limits?.new,
            today: limits?.newToday,
            todayActive: limits?.newTodayActive ?? false
        )
        reviewLimitTabs = DailyLimitTabs(
            deck: limits?.review,
            today: limits?.reviewToday,
            todayActive: limits?.reviewTodayActive ?? false
        )
        historicalRetentionPercent = cfg.historicalRetention > 0 ? Double(cfg.historicalRetention * 100) : 90

        parkedFsrsParams = [:]
        optimizedDynamicDesiredRetention = nil
        fsrsWeightsText = formatWeights(cfg.activeFsrsParams)
        fsrsParamSearch = cfg.paramSearch
        fsrsEvaluationSearch = cfg.fsrsEvaluationSearch
        fsrsMinimumIntervalSecs = min(Self.maximumIntervalSecs, max(1, cfg.fsrsMinimumIntervalSecs))
        fsrs7IncludeSameDayReviews = cfg.fsrs7IncludeSameDayReviews
        fsrs7SchedulingPenaltiesEnabled = cfg.fsrs7SchedulingPenaltiesEnabled
        dynamicDesiredRetentionEnabled = cfg.fsrsDynamicDesiredRetentionEnabled
        dynamicDesiredRetentionClamp = cfg.fsrsDynamicDesiredRetentionClamp

        // Clamped to the ranges the backend enforces on save.
        rwkvMinimumReviewsPerDay = Int32(min(9999, max(0, cfg.rwkvReviewMinimumReviewsPerDay)))
        rwkvCandidateRefreshEnabled = cfg.rwkvReviewCandidateRefreshEnabled
        rwkvRefreshInterval = Int32(min(10_000, max(1, cfg.rwkvReviewRefreshInterval)))
        rwkvMinInterveningReviews = Int32(min(10_000, max(0, cfg.rwkvReviewMinInterveningReviews)))
        rwkvMinElapsedSecs = Int32(min(86_400, max(0, cfg.rwkvReviewMinElapsedSecs)))
        rwkvEnforceGradeOrder = cfg.rwkvReviewEnforceGradeOrder

        buryNew = cfg.buryNew
        buryReviews = cfg.buryReviews
        buryInterdayLearning = cfg.buryInterdayLearning

        newCardInsertOrder = cfg.newCardInsertOrder
        newCardGatherPriority = cfg.newCardGatherPriority
        newCardSortOrder = cfg.newCardSortOrder
        newMix = cfg.newMix
        reviewOrder = cfg.reviewOrder
        interdayLearningMix = cfg.interdayLearningMix
        intradayLearningMix = cfg.intradayLearningMix

        showTimer = cfg.showTimer
        capAnswerTimeToSecs = Int32(max(5, cfg.capAnswerTimeToSecs))
        stopTimerOnAnswer = cfg.stopTimerOnAnswer

        secondsToShowQuestion = Double(cfg.secondsToShowQuestion)
        secondsToShowAnswer = Double(cfg.secondsToShowAnswer)
        questionAction = cfg.questionAction
        answerAction = cfg.answerAction

        maximumReviewIntervalDays = Int32(max(1, cfg.maximumReviewInterval))
        intervalMultiplierPercent = cfg.intervalMultiplier > 0 ? Double(cfg.intervalMultiplier * 100) : 100
        hardMultiplierPercent = cfg.hardMultiplier > 0 ? Double(cfg.hardMultiplier * 100) : 120
        easyMultiplierPercent = cfg.easyMultiplier > 0 ? Double(cfg.easyMultiplier * 100) : 130
        disableAutoplay = cfg.disableAutoplay
        waitForAudio = cfg.waitForAudio

        if cfg.easyDaysPercentages.count == 7 {
            easyDayPercentages = cfg.easyDaysPercentages.map { Double($0) * 100 }
        } else {
            easyDayPercentages = Array(repeating: 100, count: 7)
        }

        baseline = editedConfig(from: config)
        baselineLimits = editedLimits
    }

    var hasUnsavedChanges: Bool {
        guard let loaded, let baseline else { return false }
        return editedConfig(from: loaded.config) != baseline
            || newCardsIgnoreReviewLimit != loaded.context.newCardsIgnoreReviewLimit
            || applyAllParentLimits != loaded.context.applyAllParentLimits
            || fsrsHealthCheck != loaded.context.fsrsHealthCheck
            || fsrsEnabled != loaded.context.fsrs
            || editedSchedulingSettings != loaded.context.schedulingSettings
            || editedLimits != baselineLimits
    }

    /// The deck's own limits as the desktop saves them: the daily-limit
    /// tabs and the desired retention override. A today-only limit is sent
    /// only while its tab is active, since sending one makes it today's.
    var editedLimits: DeckConfigsForUpdate.CurrentDeck.Limits? {
        guard let loaded else { return nil }
        let stored = loaded.context.currentDeck?.limits
        var limits = stored ?? DeckConfigsForUpdate.CurrentDeck.Limits()
        (limits.new, limits.newToday) = newLimitTabs.saved
        (limits.review, limits.reviewToday) = reviewLimitTabs.saved
        limits.newTodayActive = limits.newToday != nil
        limits.reviewTodayActive = limits.reviewToday != nil
        limits.desiredRetention = deckDesiredRetentionPercent.map { Float($0 / 100) }
        if stored == nil && limits == DeckConfigsForUpdate.CurrentDeck.Limits() {
            return nil
        }
        return limits
    }

    // MARK: - Daily limit tabs

    var shownNewLimit: Int32 {
        get { Int32(newLimitTabs.value(preset: Int(newCardsPerDay))) }
        set {
            var preset = Int(newCardsPerDay)
            newLimitTabs.set(Int(newValue), preset: &preset)
            newCardsPerDay = Int32(preset)
        }
    }

    var shownReviewLimit: Int32 {
        get { Int32(reviewLimitTabs.value(preset: Int(reviewsPerDay))) }
        set {
            var preset = Int(reviewsPerDay)
            reviewLimitTabs.set(Int(newValue), preset: &preset)
            reviewsPerDay = Int32(preset)
        }
    }

    var newLimitScope: DailyLimitScope {
        get { newLimitTabs.scope }
        set {
            newLimitTabs.select(newValue, showing: Int(shownNewLimit))
            // An obscured preset tab keeps its saved value, as on the desktop.
            if newValue != .preset, let loaded {
                newCardsPerDay = Int32(loaded.config.config.newPerDay)
            }
        }
    }

    var reviewLimitScope: DailyLimitScope {
        get { reviewLimitTabs.scope }
        set {
            reviewLimitTabs.select(newValue, showing: Int(shownReviewLimit))
            if newValue != .preset, let loaded {
                reviewsPerDay = Int32(loaded.config.config.reviewsPerDay)
            }
        }
    }

    func editedConfig(from base: DeckConfig) -> DeckConfig {
        var updated = base
        var cfg = updated.config
        cfg.newPerDay = Int(max(0, newCardsPerDay))
        cfg.reviewsPerDay = Int(max(0, reviewsPerDay))
        cfg.learnSteps = parseSteps(learningStepsText)
        cfg.relearnSteps = parseSteps(relearningStepsText)
        cfg.graduatingIntervalGood = Int(max(1, graduatingGoodDays))
        cfg.graduatingIntervalEasy = Int(max(1, graduatingEasyDays))
        cfg.leechThreshold = Int(max(1, leechThreshold))
        cfg.leechAction = leechAction
        cfg.leechOnlyIfYoung = leechOnlyIfYoung
        cfg.sameDayReviewsIgnoreReviewLimit = sameDayReviewsIgnoreReviewLimit
        cfg.desiredRetention = Float(desiredRetentionPercent / 100)
        cfg.historicalRetention = Float(historicalRetentionPercent / 100)
        cfg.paramSearch = fsrsParamSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.fsrsEvaluationSearch = fsrsEvaluationSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        cfg.schedulerSelection = schedulerSelection
        // Only the edited arrays are written; the fork treats an empty array
        // as "use defaults", so the other versions' params are left alone.
        for (version, params) in parkedFsrsParams {
            cfg.setFsrsParams(params, for: version)
        }
        cfg.setFsrsParams(activeFsrsParams(), for: schedulerSelection.fsrsVersion)
        cfg.fsrsMinimumIntervalSecs = min(Self.maximumIntervalSecs, max(1, fsrsMinimumIntervalSecs))
        cfg.fsrs7IncludeSameDayReviews = fsrs7IncludeSameDayReviews
        cfg.fsrs7SchedulingPenaltiesEnabled = fsrs7SchedulingPenaltiesEnabled
        cfg.fsrsDynamicDesiredRetentionEnabled = dynamicDesiredRetentionEnabled
        cfg.fsrsDynamicDesiredRetentionClamp = dynamicDesiredRetentionClamp
        if let optimizedDynamicDesiredRetention {
            cfg.fsrsDynamicDesiredRetention = optimizedDynamicDesiredRetention
        }

        cfg.rwkvReviewMinimumReviewsPerDay = Int(rwkvMinimumReviewsPerDay)
        cfg.rwkvReviewCandidateRefreshEnabled = rwkvCandidateRefreshEnabled
        cfg.rwkvReviewRefreshInterval = Int(max(1, rwkvRefreshInterval))
        cfg.rwkvReviewMinInterveningReviews = Int(max(0, rwkvMinInterveningReviews))
        cfg.rwkvReviewMinElapsedSecs = Int(max(0, rwkvMinElapsedSecs))
        cfg.rwkvReviewEnforceGradeOrder = rwkvEnforceGradeOrder

        cfg.buryNew = buryNew
        cfg.buryReviews = buryReviews
        cfg.buryInterdayLearning = buryInterdayLearning

        cfg.newCardInsertOrder = newCardInsertOrder
        cfg.newCardGatherPriority = newCardGatherPriority
        cfg.newCardSortOrder = newCardSortOrder
        cfg.newMix = newMix
        cfg.reviewOrder = reviewOrder
        cfg.interdayLearningMix = interdayLearningMix
        cfg.intradayLearningMix = intradayLearningMix

        cfg.showTimer = showTimer
        cfg.capAnswerTimeToSecs = Int(max(5, capAnswerTimeToSecs))
        cfg.stopTimerOnAnswer = stopTimerOnAnswer

        cfg.secondsToShowQuestion = Float(max(0, secondsToShowQuestion))
        cfg.secondsToShowAnswer = Float(max(0, secondsToShowAnswer))
        cfg.questionAction = questionAction
        cfg.answerAction = answerAction

        cfg.maximumReviewInterval = Int(max(1, maximumReviewIntervalDays))
        cfg.intervalMultiplier = Float(intervalMultiplierPercent / 100)
        cfg.hardMultiplier = Float(hardMultiplierPercent / 100)
        cfg.easyMultiplier = Float(easyMultiplierPercent / 100)
        cfg.disableAutoplay = disableAutoplay
        cfg.waitForAudio = waitForAudio

        // Stored as is: the scheduler treats 1.0 as Normal, 0.0 as Minimum and
        // anything else as Reduced (the desktop's 0.5).
        cfg.easyDaysPercentages = easyDayPercentages.map { Float($0 / 100) }

        updated.config = cfg
        return updated
    }

    func saveConfig() async -> Bool {
        guard let loaded else { return false }
        isSaving = true
        defer { isSaving = false }

        do {
            try await deckClient.updateDeckConfig(
                deckId,
                editedConfig(from: loaded.config),
                applyToChildren,
                fsrsEnabled,
                newCardsIgnoreReviewLimit,
                applyAllParentLimits,
                fsrsHealthCheck,
                editedSchedulingSettings,
                editedLimits,
                fsrsReschedule
            )
            return true
        } catch {
            destination = .alert(.saveFailed(error.localizedDescription))
            return false
        }
    }

    // MARK: - Scheduler

    /// Longest FSRS minimum interval the backend accepts (36500 days).
    static let maximumIntervalSecs = 36_500 * 86_400

    func selectScheduler(_ choice: SchedulerChoice) {
        updateSchedulerSelection(schedulerSelection.withScheduler(choice))
    }

    func selectDueDateScheduler(_ choice: SchedulerChoice) {
        updateSchedulerSelection(schedulerSelection.withDueDateScheduler(choice))
    }

    private func updateSchedulerSelection(_ updated: SchedulerSelection) {
        let previous = schedulerSelection.fsrsVersion
        if updated.fsrsVersion != previous {
            // Park the edited params of the old version and show the new
            // version's; each version keeps its own array.
            parkedFsrsParams[previous] = activeFsrsParams()
            fsrsWeightsText = formatWeights(fsrsParams(for: updated.fsrsVersion))
        }
        schedulerSelection = updated
        // Picking a model enables machine-learning scheduling, as on desktop.
        fsrsEnabled = true
    }

    // MARK: - Helpers

    func fallbackContext(from config: DeckConfig) -> DeckConfigsForUpdate {
        let cfg = config.config
        let fsrsBacked = !cfg.fsrsParams7.isEmpty || !cfg.fsrsParams6.isEmpty
            || !cfg.fsrsParams5.isEmpty || !cfg.fsrsParams4.isEmpty
        return DeckConfigsForUpdate(
            allConfig: [DeckConfigsForUpdate.ConfigWithExtra(config: config, useCount: 0)],
            currentDeck: DeckConfigsForUpdate.CurrentDeck(name: deckName, configID: config.id),
            defaults: config,
            fsrs: fsrsBacked
        )
    }

    /// Anki stores learn/relearn steps as Float minutes. Accept "1m 10m 1h 1d"
    /// shorthand on input and emit "1m 10m" on output (matching the FSRS
    /// scheduler's expected unit).
}
