//
//  DeckConfigSections.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 14.05.2026.
//

import SwiftUI
import Theme
import AnkiKit

// Section structs for the deck-options Form. Each is dedicated so SwiftUI can
// skip its body when its inputs don't change — e.g. tapping a Stepper in
// Daily Limits doesn't force the FSRS Weights TextField to re-evaluate.
// Bindings are scoped to exactly the @State each section reads/writes;
// everything else is `let`.

struct PresetSection: View {
    let presetOptions: [DeckConfigsForUpdate.ConfigWithExtra]
    let selectedPresetID: DeckConfigID
    let selectedPresetName: String
    let presetUseCount: Int
    let canDeletePreset: Bool
    let isPresetMutating: Bool
    let hasLoadedConfig: Bool
    let onSelect: (DeckConfig) -> Void
    let onAdd: () -> Void
    let onClone: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Section("Preset") {
            LabeledContent("Preset") {
                Menu {
                    Picker("Preset", selection: Binding(
                        get: { selectedPresetID },
                        set: { newID in
                            guard newID != selectedPresetID,
                                  let target = presetOptions.first(where: { $0.config.id == newID })?.config
                            else { return }
                            onSelect(target)
                        }
                    )) {
                        ForEach(presetOptions, id: \.config.id) { option in
                            Text(option.config.name).tag(option.config.id)
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedPresetName).foregroundStyle(palette.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .amgiFont(.micro)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .disabled(isPresetMutating || presetOptions.isEmpty)
            }

            LabeledContent("Used by") {
                Text("\(presetUseCount) deck\(presetUseCount == 1 ? "" : "s")")
                    .foregroundStyle(palette.textSecondary)
            }

            Menu {
                Button { onAdd() } label: {
                    Label("Add Preset…", systemImage: "plus")
                }
                Button { onClone() } label: {
                    Label("Clone Preset…", systemImage: "plus.square.on.square")
                }
                .disabled(!hasLoadedConfig)
                Button { onRename() } label: {
                    Label("Rename Preset…", systemImage: "pencil")
                }
                .disabled(!hasLoadedConfig)
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete Preset", systemImage: "trash")
                }
                .disabled(!canDeletePreset)
            } label: {
                if isPresetMutating {
                    HStack { ProgressView().controlSize(.small); Text("Working…") }
                } else {
                    Label("Manage Preset", systemImage: "slider.horizontal.below.rectangle")
                }
            }
            .disabled(isPresetMutating)
        }
    }
}

struct DailyLimitsSection: View {
    @Binding var newLimitScope: DailyLimitScope
    @Binding var newCardsPerDay: Int32
    @Binding var reviewLimitScope: DailyLimitScope
    @Binding var reviewsPerDay: Int32
    @Binding var newCardsIgnoreReviewLimit: Bool
    @Binding var sameDayReviewsIgnoreReviewLimit: Bool
    @Binding var applyAllParentLimits: Bool

    var body: some View {
        Section("Daily Limits") {
            scopePicker("New cards limit", selection: $newLimitScope)
            Stepper("New cards/day: \(newCardsPerDay)", value: $newCardsPerDay, in: 0...9999)
            scopePicker("Reviews limit", selection: $reviewLimitScope)
            Stepper("Reviews/day: \(reviewsPerDay)", value: $reviewsPerDay, in: 0...9999)
            Toggle("New cards ignore review limit", isOn: $newCardsIgnoreReviewLimit)
            Toggle("Same-day reviews ignore review limit", isOn: $sameDayReviewsIgnoreReviewLimit)
            Toggle("Apply all parent limits", isOn: $applyAllParentLimits)
        }
    }

    private func scopePicker(_ title: String, selection: Binding<DailyLimitScope>) -> some View {
        Picker(title, selection: selection) {
            ForEach(DailyLimitScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
    }
}

struct NewCardsSection: View {
    @Binding var learningStepsText: String
    @Binding var graduatingGoodDays: Int32
    @Binding var graduatingEasyDays: Int32

    var body: some View {
        Section("New Cards") {
            LabeledContent("Learning steps") {
                TextField("1m 10m", text: $learningStepsText)
                    .multilineTextAlignment(.trailing)
                    .amgiFont(.body, .monospaced)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Stepper("Graduating interval: \(graduatingGoodDays)d", value: $graduatingGoodDays, in: 1...36500)
            Stepper("Easy interval: \(graduatingEasyDays)d", value: $graduatingEasyDays, in: 1...36500)
        }
    }
}

struct LapsesSection: View {
    @Binding var relearningStepsText: String
    @Binding var leechThreshold: Int32
    @Binding var leechAction: LeechAction
    @Binding var leechOnlyIfYoung: Bool

    var body: some View {
        Section("Lapses") {
            LabeledContent("Relearning steps") {
                TextField("10m", text: $relearningStepsText)
                    .multilineTextAlignment(.trailing)
                    .amgiFont(.body, .monospaced)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Stepper("Leech threshold: \(leechThreshold)", value: $leechThreshold, in: 1...9999)
            Picker("Leech action", selection: $leechAction) {
                Text("Suspend card").tag(LeechAction.suspend)
                Text("Tag only").tag(LeechAction.tagOnly)
            }
            if leechAction == .suspend {
                Toggle("Only mark if young again", isOn: $leechOnlyIfYoung)
            }
        }
    }
}

struct OrderSection: View {
    @Binding var newCardInsertOrder: NewCardInsertOrder
    @Binding var newCardGatherPriority: NewCardGatherPriority
    @Binding var newCardSortOrder: NewCardSortOrder
    @Binding var newMix: ReviewMix
    @Binding var reviewOrder: ReviewCardOrder
    @Binding var interdayLearningMix: ReviewMix
    @Binding var intradayLearningMix: ReviewMix
    /// FSRS relabels the ease orders as difficulty orders.
    let fsrsEnabled: Bool

    var body: some View {
        Section("Order") {
            Picker("New card insert order", selection: $newCardInsertOrder) {
                Text("Sequential (oldest first)").tag(NewCardInsertOrder.due)
                Text("Random").tag(NewCardInsertOrder.random)
            }
            Picker("New gather priority", selection: $newCardGatherPriority) {
                Text("Deck").tag(NewCardGatherPriority.deck)
                Text("Deck, then random notes").tag(NewCardGatherPriority.deckThenRandomNotes)
                Text("Position — lowest first").tag(NewCardGatherPriority.lowestPosition)
                Text("Position — highest first").tag(NewCardGatherPriority.highestPosition)
                Text("Random notes").tag(NewCardGatherPriority.randomNotes)
                Text("Random cards").tag(NewCardGatherPriority.randomCards)
                Text("Descending retrievability (RWKV)").tag(NewCardGatherPriority.descendingRetrievability)
                Text("Ascending retrievability (RWKV)").tag(NewCardGatherPriority.ascendingRetrievability)
            }
            Picker("New card sort order", selection: $newCardSortOrder) {
                Text("Card template, then gather order").tag(NewCardSortOrder.template)
                Text("Gather order").tag(NewCardSortOrder.noSort)
                Text("Card template, then random").tag(NewCardSortOrder.templateThenRandom)
                Text("Random note, then template").tag(NewCardSortOrder.randomNoteThenTemplate)
                Text("Random").tag(NewCardSortOrder.randomCard)
            }
            Picker("New/review mix", selection: $newMix) {
                Text("Mix with reviews").tag(ReviewMix.mixWithReviews)
                Text("After reviews").tag(ReviewMix.afterReviews)
                Text("Before reviews").tag(ReviewMix.beforeReviews)
            }
            Picker("Review order", selection: $reviewOrder) {
                Text("Mixed by day").tag(ReviewCardOrder.day)
                Text("Day, then deck").tag(ReviewCardOrder.dayThenDeck)
                Text("Deck, then day").tag(ReviewCardOrder.deckThenDay)
                Text("Intervals — ascending").tag(ReviewCardOrder.intervalsAscending)
                Text("Intervals — descending").tag(ReviewCardOrder.intervalsDescending)
                Text(easeAscendingLabel).tag(ReviewCardOrder.easeAscending)
                Text(easeDescendingLabel).tag(ReviewCardOrder.easeDescending)
                Text("Retrievability — ascending").tag(ReviewCardOrder.retrievabilityAscending)
                Text("Retrievability — descending").tag(ReviewCardOrder.retrievabilityDescending)
                Text("Relative overdueness").tag(ReviewCardOrder.relativeOverdueness)
                Text("Random").tag(ReviewCardOrder.random)
                Text("Order added").tag(ReviewCardOrder.added)
                Text("Latest added first").tag(ReviewCardOrder.reverseAdded)
            }
            Picker("Interday learning mix", selection: $interdayLearningMix) {
                Text("Mix with reviews").tag(ReviewMix.mixWithReviews)
                Text("After reviews").tag(ReviewMix.afterReviews)
                Text("Before reviews").tag(ReviewMix.beforeReviews)
            }
            Picker("Intraday learning/review order", selection: $intradayLearningMix) {
                Text("Mix with reviews").tag(ReviewMix.mixWithReviews)
                Text("After reviews").tag(ReviewMix.afterReviews)
                Text("Before reviews").tag(ReviewMix.beforeReviews)
            }
        }
    }

    private var easeAscendingLabel: String {
        fsrsEnabled ? "Difficult cards first" : "Ease — ascending"
    }

    private var easeDescendingLabel: String {
        fsrsEnabled ? "Easy cards first" : "Ease — descending"
    }
}

struct BurySection: View {
    @Binding var buryNew: Bool
    @Binding var buryReviews: Bool
    @Binding var buryInterdayLearning: Bool

    var body: some View {
        Section("Bury siblings") {
            Toggle("Bury new siblings", isOn: $buryNew)
            Toggle("Bury review siblings", isOn: $buryReviews)
            Toggle("Bury interday-learning siblings", isOn: $buryInterdayLearning)
        }
    }
}

struct TimerSection: View {
    @Binding var showTimer: Bool
    @Binding var capAnswerTimeToSecs: Int32
    @Binding var stopTimerOnAnswer: Bool

    var body: some View {
        Section("Answer timer") {
            Toggle("Show answer timer", isOn: $showTimer)
            Stepper("Max answer seconds: \(capAnswerTimeToSecs)", value: $capAnswerTimeToSecs, in: 5...600, step: 5)
            Toggle("Stop timer on answer", isOn: $stopTimerOnAnswer)
        }
    }
}

struct AutoAdvanceSection: View {
    @Binding var secondsToShowQuestion: Double
    @Binding var secondsToShowAnswer: Double
    @Binding var questionAction: QuestionAction
    @Binding var answerAction: AnswerAction

    var body: some View {
        Section("Auto-advance") {
            LabeledSlider(
                label: "Seconds to show question",
                value: $secondsToShowQuestion,
                in: 0...60,
                step: 0.5,
                valueText: String(format: "%.1f s", secondsToShowQuestion)
            )
            LabeledSlider(
                label: "Seconds to show answer",
                value: $secondsToShowAnswer,
                in: 0...60,
                step: 0.5,
                valueText: String(format: "%.1f s", secondsToShowAnswer)
            )
            Picker("After question", selection: $questionAction) {
                Text("Show answer").tag(QuestionAction.showAnswer)
                Text("Show reminder").tag(QuestionAction.showReminder)
            }
            Picker("After answer", selection: $answerAction) {
                Text("Bury card").tag(AnswerAction.buryCard)
                Text("Answer Again").tag(AnswerAction.answerAgain)
                Text("Answer Hard").tag(AnswerAction.answerHard)
                Text("Answer Good").tag(AnswerAction.answerGood)
                Text("Show reminder").tag(AnswerAction.showReminder)
            }
        }
    }
}

struct AdvancedSection: View {
    let fsrsEnabled: Bool
    @Binding var maximumReviewIntervalDays: Int32
    @Binding var intervalMultiplierPercent: Double
    @Binding var hardMultiplierPercent: Double
    @Binding var easyMultiplierPercent: Double
    @Binding var disableAutoplay: Bool
    @Binding var waitForAudio: Bool

    var body: some View {
        // As on the desktop, the SM-2 multipliers are hidden under FSRS.
        Section(fsrsEnabled ? "Advanced" : "Advanced (SM-2)") {
            Stepper("Maximum review interval: \(maximumReviewIntervalDays)d", value: $maximumReviewIntervalDays, in: 1...36500, step: 30)
            if !fsrsEnabled {
                LabeledSlider(
                    label: "Interval multiplier",
                    value: $intervalMultiplierPercent,
                    in: 50...200,
                    step: 1,
                    valueText: "\(Int(intervalMultiplierPercent))%"
                )
                LabeledSlider(
                    label: "Hard multiplier",
                    value: $hardMultiplierPercent,
                    in: 50...130,
                    step: 1,
                    valueText: "\(Int(hardMultiplierPercent))%"
                )
                LabeledSlider(
                    label: "Easy multiplier",
                    value: $easyMultiplierPercent,
                    in: 100...500,
                    step: 1,
                    valueText: "\(Int(easyMultiplierPercent))%"
                )
            }
            Toggle("Disable autoplay audio", isOn: $disableAutoplay)
            Toggle("Wait for audio before answering", isOn: $waitForAudio)
        }
    }
}

struct SchedulerSection: View {
    @Binding var fsrsEnabled: Bool
    let scheduler: SchedulerChoice
    let dueDateScheduler: SchedulerChoice
    let onSelectScheduler: (SchedulerChoice) -> Void
    let onSelectDueDateScheduler: (SchedulerChoice) -> Void
    let canApplyToAllPresets: Bool
    let onApplyToAllPresets: () -> Void

    var body: some View {
        Section {
            Toggle("Machine Learning Based scheduling", isOn: $fsrsEnabled)
            Picker("Review scheduler", selection: Binding(
                get: { scheduler },
                set: { onSelectScheduler($0) }
            )) {
                ForEach(Self.choices(SchedulerChoice.reviewChoices, showing: scheduler), id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            if scheduler == .rwkvInstant {
                Picker("Fallback: Due-Date Calculator", selection: Binding(
                    get: { dueDateScheduler },
                    set: { onSelectDueDateScheduler($0) }
                )) {
                    ForEach(Self.choices(SchedulerChoice.dueDateChoices, showing: dueDateScheduler), id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            }
            if canApplyToAllPresets {
                Button {
                    onApplyToAllPresets()
                } label: {
                    Label("Apply Schedule to All Presets…", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("Scheduler")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        let models = "RWKV runs on this device. RWKV-Curve computes answer intervals; "
            + "RWKV-Instant picks which reviews are due by predicted recall, while its "
            + "fallback writes due dates for sync and statistics. "
            + "Machine Learning Based scheduling applies to all presets."
        guard fsrsEnabled else {
            return "Machine learning scheduling is disabled for this collection. "
                + "Selecting a model enables it; RWKV settings remain independent. " + models
        }
        return models
    }

    /// Legacy FSRS-4/5 presets keep showing their current value.
    private static func choices(_ base: [SchedulerChoice], showing current: SchedulerChoice) -> [SchedulerChoice] {
        base.contains(current) ? base : [current] + base
    }
}

struct RwkvSection: View {
    let instantEnabled: Bool
    let curveEnabled: Bool
    @Binding var minimumReviewsPerDay: Int32
    @Binding var candidateRefreshEnabled: Bool
    @Binding var refreshInterval: Int32
    @Binding var minInterveningReviews: Int32
    @Binding var minElapsedSecs: Int32
    @Binding var enforceGradeOrder: Bool
    let canRebuildState: Bool
    let isRebuildingState: Bool
    let onRebuildState: () -> Void
    let onCompareWithFsrs: () -> Void

    var body: some View {
        if instantEnabled {
            Section {
                Stepper("Minimum reviews per day: \(minimumReviewsPerDay)", value: $minimumReviewsPerDay, in: 0...9999)
                Toggle("Use faster, approximate queue updates", isOn: $candidateRefreshEnabled)
                Stepper("Update the RWKV queue every \(refreshInterval) answers", value: $refreshInterval, in: 1...10_000)
            } header: {
                Text("RWKV-Instant")
            } footer: {
                Text("Instant picks review cards by predicted recall, ignoring scheduled due dates. RWKV runs on this device; setting a daily review limit is recommended.")
            }
            Section {
                Stepper("Minimum reviews between repeats: \(minInterveningReviews)", value: $minInterveningReviews, in: 0...10_000)
                Stepper("Minimum seconds between repeats: \(minElapsedSecs)", value: $minElapsedSecs, in: 0...86_400, step: 5)
            } header: {
                Text("Same-day repeats")
            } footer: {
                Text("Both minimums must be met before RWKV repeats a card. Set either to 0 to remove it.")
            }
        }
        if curveEnabled {
            Section {
                Toggle("Enforce Again ≤ Hard ≤ Good ≤ Easy intervals", isOn: $enforceGradeOrder)
            } header: {
                Text("RWKV-Curve")
            } footer: {
                Text("Curve replaces FSRS answer intervals with RWKV ones, computed on this device.")
            }
        }
        if canRebuildState, instantEnabled || curveEnabled {
            Section {
                Button(action: onRebuildState) {
                    if isRebuildingState {
                        HStack { ProgressView().controlSize(.small); Text("Rebuilding RWKV state…") }
                    } else {
                        Text("Rebuild RWKV State")
                    }
                }
                .disabled(isRebuildingState)
                Button(action: onCompareWithFsrs) {
                    Label("Compare RWKV with FSRS", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(isRebuildingState)
            } header: {
                Text("RWKV maintenance")
            } footer: {
                Text("Replays your whole review history, ignoring the saved state. Saves these options first. This can take a while on large collections.")
            }
        }
    }
}

struct FsrsSection: View {
    let fsrsEnabled: Bool
    let fsrsVersion: FsrsVersion
    let paramsLabel: String
    let defaultParamSearch: String
    @Binding var desiredRetentionPercent: Double
    @Binding var deckDesiredRetentionPercent: Double?
    @Binding var historicalRetentionPercent: Double
    @Binding var fsrsHealthCheck: Bool
    @Binding var fsrsReschedule: Bool
    @Binding var fsrsMinimumIntervalSecs: Int
    @Binding var fsrsWeightsText: String
    @Binding var fsrsParamSearch: String
    @Binding var fsrsEvaluationSearch: String
    @Binding var fsrs7IncludeSameDayReviews: Bool
    @Binding var fsrs7SchedulingPenaltiesEnabled: Bool
    @Binding var dynamicDesiredRetentionEnabled: Bool
    @Binding var dynamicDesiredRetentionClamp: Bool
    let isOptimizingFsrs: Bool
    let isCheckingHealth: Bool
    let onCheckHealth: () -> Void
    let onOptimizeCurrent: () -> Void
    let onCancelOptimize: () -> Void
    let onOpenSimulatorReview: () -> Void
    let onOpenSimulatorWorkload: () -> Void
    let onOptimizeAll: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Section("FSRS") {
            LabeledSlider(
                label: "Desired retention (preset)",
                value: $desiredRetentionPercent,
                in: 10...99,
                step: 1,
                valueText: "\(Int(desiredRetentionPercent))%"
            )
            // The desktop's "This deck" tab: an override for this deck only.
            Toggle("Different desired retention for this deck", isOn: Binding(
                get: { deckDesiredRetentionPercent != nil },
                set: { deckDesiredRetentionPercent = $0 ? (deckDesiredRetentionPercent ?? desiredRetentionPercent) : nil }
            ))
            if let deckRetention = deckDesiredRetentionPercent {
                LabeledSlider(
                    label: "Desired retention (this deck)",
                    value: Binding(
                        get: { deckRetention },
                        set: { deckDesiredRetentionPercent = $0 }
                    ),
                    in: 10...99,
                    step: 1,
                    valueText: "\(Int(deckRetention))%"
                )
            }
            LabeledSlider(
                label: "Historical retention",
                value: $historicalRetentionPercent,
                in: 70...97,
                step: 1,
                valueText: "\(Int(historicalRetentionPercent))%"
            )
            Toggle("Reschedule cards on change", isOn: $fsrsReschedule)
            if fsrsReschedule {
                Text("Depending on your desired retention, this can result in a large number of cards becoming due, so is not recommended when first switching from SM-2. Use this option sparingly, as it will add a review entry to each of your cards, and increase the size of your collection.")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.warning)
            }
            Toggle("Run FSRS health check on save", isOn: $fsrsHealthCheck)

            if fsrsEnabled {
                Picker("Minimum interval", selection: $fsrsMinimumIntervalSecs) {
                    ForEach(Self.minimumIntervalOptions(showing: fsrsMinimumIntervalSecs), id: \.self) { secs in
                        Text(Self.formatInterval(secs)).tag(secs)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(paramsLabel).amgiFont(.body)
                    TextField(
                        "Empty uses the default parameters",
                        text: $fsrsWeightsText,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                    .amgiFont(.caption, .monospaced)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Optimize search filter").amgiFont(.body)
                    TextField(defaultParamSearch, text: $fsrsParamSearch)
                        .amgiFont(.caption, .monospaced)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Evaluation search filter").amgiFont(.body)
                    TextField("Same as the optimize search", text: $fsrsEvaluationSearch)
                        .amgiFont(.caption, .monospaced)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if fsrsVersion == .seven {
                    Toggle("Include same-day reviews in FSRS-7", isOn: $fsrs7IncludeSameDayReviews)
                    Toggle("Use scheduling penalties in FSRS-7 optimization", isOn: $fsrs7SchedulingPenaltiesEnabled)
                    Toggle("Dynamic DR (ADR)", isOn: $dynamicDesiredRetentionEnabled)
                    if dynamicDesiredRetentionEnabled {
                        Toggle("Clamp unsupported dynamic DR targets", isOn: $dynamicDesiredRetentionClamp)
                        Text("Optimize the parameters to fit the dynamic DR model.")
                            .amgiFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                Button(action: onOptimizeCurrent) {
                    HStack {
                        if isOptimizingFsrs { ProgressView().controlSize(.small) }
                        Text(isOptimizingFsrs ? "Optimizing…" : "Optimize Weights")
                    }
                }
                .disabled(isOptimizingFsrs)

                if isOptimizingFsrs {
                    Button("Cancel", role: .cancel, action: onCancelOptimize)
                }

                Button(action: onCheckHealth) {
                    HStack {
                        if isCheckingHealth { ProgressView().controlSize(.small) }
                        Text(isCheckingHealth ? "Checking Health…" : "Check Health")
                    }
                }
                .disabled(isOptimizingFsrs || isCheckingHealth)

                Button(action: onOpenSimulatorReview) {
                    Label("Open FSRS Simulator", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(isOptimizingFsrs)

                Button(action: onOpenSimulatorWorkload) {
                    Label("Help Me Decide (Workload)", systemImage: "scale.3d")
                }
                .disabled(isOptimizingFsrs)

                Button(action: onOptimizeAll) {
                    HStack {
                        if isOptimizingFsrs { ProgressView().controlSize(.small) }
                        Text("Optimize All Presets")
                    }
                }
                .disabled(isOptimizingFsrs)
            }
        }
    }
}

struct CollectionSchedulingSection: View {
    let fsrsEnabled: Bool
    let instantEnabled: Bool
    @Binding var loadBalancerEnabled: Bool
    @Binding var fsrsShortTermWithStepsEnabled: Bool
    @Binding var fsrsLearningQueuesDisabled: Bool
    @Binding var reviewFuzzEnabled: Bool
    @Binding var reviewFuzzBase: Double
    @Binding var reviewFuzzFactorShort: Double
    @Binding var reviewFuzzFactorMid: Double
    @Binding var reviewFuzzFactorLong: Double

    var body: some View {
        Section {
            Toggle("Enable load balancer", isOn: $loadBalancerEnabled)
            if fsrsEnabled || instantEnabled {
                Toggle("Allow same-day review for (re)learning steps", isOn: $fsrsShortTermWithStepsEnabled)
            }
            if fsrsEnabled {
                Toggle("Skip learning/relearning queues with FSRS/RWKV", isOn: $fsrsLearningQueuesDisabled)
            }
            Toggle("Enable review fuzz", isOn: $reviewFuzzEnabled)
            LabeledSlider(
                label: "Base fuzz (days)",
                value: $reviewFuzzBase,
                in: 0...10,
                step: 0.1,
                valueText: String(format: "%.1f", reviewFuzzBase)
            )
            LabeledSlider(
                label: "Fuzz factor (2.5–7 days)",
                value: $reviewFuzzFactorShort,
                in: 0...1,
                step: 0.01,
                valueText: Self.percent(reviewFuzzFactorShort)
            )
            LabeledSlider(
                label: "Fuzz factor (7–20 days)",
                value: $reviewFuzzFactorMid,
                in: 0...1,
                step: 0.01,
                valueText: Self.percent(reviewFuzzFactorMid)
            )
            LabeledSlider(
                label: "Fuzz factor (20+ days)",
                value: $reviewFuzzFactorLong,
                in: 0...1,
                step: 0.01,
                valueText: Self.percent(reviewFuzzFactorLong)
            )
        } header: {
            Text("Scheduling (all presets)")
        } footer: {
            Text("These settings apply to every preset in the collection. The load balancer spreads day-based reviews within the fuzz range to smooth out the workload.")
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

struct EasyDaysSection: View {
    let fsrsEnabled: Bool
    @Binding var easyDayPercentages: [Double]

    @Environment(\.palette) private var palette

    var body: some View {
        // FSRS interprets these as per-weekday workload multipliers; only
        // shown when FSRS is enabled, matching Anki desktop's gating.
        Section {
            if fsrsEnabled {
                ForEach(0..<7, id: \.self) { idx in
                    // The desktop's three positions; the scheduler reads 1.0
                    // as Normal, 0.0 as Minimum and anything else as Reduced.
                    Picker(Self.weekdayLabel(idx), selection: $easyDayPercentages[idx]) {
                        Text("Normal").tag(100.0)
                        Text("Reduced").tag(50.0)
                        Text("Minimum").tag(0.0)
                        if ![0.0, 50.0, 100.0].contains(easyDayPercentages[idx]) {
                            Text("Reduced (\(Int(easyDayPercentages[idx].rounded()))%)").tag(easyDayPercentages[idx])
                        }
                    }
                }
            } else {
                Text("Enable FSRS to configure Easy Days.")
                    .foregroundStyle(palette.textSecondary)
            }
        } header: {
            Text("Easy Days")
        } footer: {
            Text("Reduced and Minimum days get fewer reviews, moved to the days around them. Minimum keeps only the reviews that can't be moved.")
        }
    }
}

struct ApplySection: View {
    @Binding var applyToChildren: Bool

    var body: some View {
        Section {
            Toggle("Apply to subdecks", isOn: $applyToChildren)
        } footer: {
            Text("Settings will be applied to this deck and any nested subdecks that share its preset.")
        }
    }
}

/// Reused across sections: "<label> ...... <valueText>" with a slider below.
struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    @Environment(\.palette) private var palette

    init(label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, valueText: String) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(valueText).foregroundStyle(palette.textSecondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private extension FsrsSection {
    static let commonMinimumIntervals = [1, 60, 600, 3600, 86_400]

    /// Common choices, plus the preset's value when it is something else.
    static func minimumIntervalOptions(showing current: Int) -> [Int] {
        commonMinimumIntervals.contains(current)
            ? commonMinimumIntervals
            : (commonMinimumIntervals + [current]).sorted()
    }

    /// "1s", "10m", "1h", "2d" — the largest unit that divides evenly,
    /// matching the desktop's minimum-interval field.
    static func formatInterval(_ seconds: Int) -> String {
        let units: [(String, Int)] = [("d", 86_400), ("h", 3600), ("m", 60), ("s", 1)]
        let value = max(1, seconds)
        let (suffix, unit) = units.first { value % $0.1 == 0 } ?? ("s", 1)
        return "\(value / unit)\(suffix)"
    }
}

private extension EasyDaysSection {
    /// Anki stores easyDaysPercentages indexed Mon=0..Sun=6. Use fixed
    /// short labels rather than `Calendar.shortWeekdaySymbols` so the UI
    /// order matches the underlying storage regardless of locale.
    static func weekdayLabel(_ idx: Int) -> String {
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][idx]
    }
}
