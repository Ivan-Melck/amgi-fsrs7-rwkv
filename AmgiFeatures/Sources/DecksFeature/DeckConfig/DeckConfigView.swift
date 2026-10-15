//
//  DeckConfigView.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 14.05.2026.
//

import SwiftUI
import Theme
import AnkiKit
import AnkiClients
import Dependencies

/// Per-deck study options. The editable state and all load/save plumbing
/// live in `DeckConfigModel`; this Container binds each form section to
/// `$model.field` and translates engine outcomes into `destination`
/// transitions. Each form section lives in `DeckConfigSections.swift` so
/// SwiftUI can diff the section in isolation and `body` stays readable.
/// Modal presentation (alert + sheet) is driven by a single
/// `DeckConfigDestination?`, applied via the `DeckConfigPresentations`
/// modifier. See the Decks preview-decoupling spec.
struct DeckConfigView: View {
    let deckId: DeckID
    let deckName: String
    let onDismiss: () -> Void

    @State private var model: DeckConfigModel

    @Environment(\.palette) private var palette

    init(deckId: DeckID, deckName: String, onDismiss: @escaping () -> Void) {
        self.deckId = deckId
        self.deckName = deckName
        self.onDismiss = onDismiss
        _model = State(wrappedValue: DeckConfigModel(deckId: deckId, deckName: deckName))
    }

    var body: some View {
        formContent
            .navigationTitle("Deck Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .interactiveDismissDisabled(model.hasUnsavedChanges)
            .modifier(DeckConfigPresentations(
                destination: $model.destination,
                currentAlert: model.currentAlert,
                alertTitle: model.alertTitle,
                newPresetName: $model.newPresetName,
                renamePresetDraft: $model.renamePresetDraft,
                currentPresetName: model.currentPresetName,
                deletingPresetName: model.currentPresetName,
                fallbackPresetName: model.deleteFallbackPresetName,
                deleteRequiresFullSync: model.deleteRequiresFullSync,
                onCreate: { await model.createPreset(fromDefaults: $0) },
                onRename: { await model.renamePreset() },
                onDelete: { Task { await model.deletePreset() } },
                onDiscard: onDismiss,
                onSaveThen: { action in Task { await model.saveThenPerform(action) } },
                onDiscardThen: { action in Task { await model.discardThenPerform(action) } },
                onApplySchedule: { await model.applyScheduleToAllPresets($0) }
            ))
            .task { await model.loadConfig() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { attemptDismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { if await model.saveConfig() { onDismiss() } } }
                // Without the real context the collection-wide values shown
                // are guesses; saving them would overwrite the stored ones.
                .disabled(!model.hasLoadedConfig || model.isSaving || model.isFallbackContext)
        }
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            if model.isLoading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let loadError = model.loadError {
                Section {
                    Text(loadError).foregroundStyle(palette.danger)
                    Button("Retry") { Task { await model.loadConfig() } }
                }
            } else {
                loadedSections
            }
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        if model.isFallbackContext {
            Section {
                Text("Some deck options couldn't be loaded, so saving is turned off. Close and reopen this screen to try again.")
                    .foregroundStyle(.secondary)
            }
        }
        PresetSection(
            presetOptions: model.presetOptions,
            selectedPresetID: model.selectedPresetID,
            selectedPresetName: model.currentPresetName ?? "—",
            presetUseCount: model.presetUseCount,
            canDeletePreset: model.canDeletePreset,
            isPresetMutating: model.isPresetMutating,
            hasLoadedConfig: model.hasLoadedConfig,
            onSelect: { model.requestPresetAction(.select($0)) },
            onAdd: { model.requestPresetAction(.add) },
            onClone: { model.requestPresetAction(.clone) },
            onRename: { model.requestPresetAction(.rename) },
            onDelete: { model.requestPresetAction(.delete) }
        )
        SchedulerSection(
            fsrsEnabled: $model.fsrsEnabled,
            scheduler: model.schedulerSelection.scheduler,
            dueDateScheduler: model.schedulerSelection.dueDateScheduler,
            onSelectScheduler: { model.selectScheduler($0) },
            onSelectDueDateScheduler: { model.selectDueDateScheduler($0) },
            canApplyToAllPresets: model.canApplyScheduleToAllPresets,
            onApplyToAllPresets: { model.destination = .prompt(.applySchedule) }
        )
        if model.schedulerSelection.usesRwkv {
            RwkvSection(
                instantEnabled: model.schedulerSelection.rwkvReviewInstantOrderEnabled,
                curveEnabled: model.schedulerSelection.rwkvReviewEnabled,
                minimumReviewsPerDay: $model.rwkvMinimumReviewsPerDay,
                candidateRefreshEnabled: $model.rwkvCandidateRefreshEnabled,
                refreshInterval: $model.rwkvRefreshInterval,
                minInterveningReviews: $model.rwkvMinInterveningReviews,
                minElapsedSecs: $model.rwkvMinElapsedSecs,
                enforceGradeOrder: $model.rwkvEnforceGradeOrder,
                canRebuildState: model.canRebuildRwkvState,
                isRebuildingState: model.isRebuildingRwkvState,
                onRebuildState: { Task { await model.rebuildRwkvState() } }
            )
        }
        DailyLimitsSection(
            newLimitScope: $model.newLimitScope,
            newCardsPerDay: $model.shownNewLimit,
            reviewLimitScope: $model.reviewLimitScope,
            reviewsPerDay: $model.shownReviewLimit,
            newCardsIgnoreReviewLimit: $model.newCardsIgnoreReviewLimit,
            sameDayReviewsIgnoreReviewLimit: $model.sameDayReviewsIgnoreReviewLimit,
            applyAllParentLimits: $model.applyAllParentLimits
        )
        NewCardsSection(
            learningStepsText: $model.learningStepsText,
            graduatingGoodDays: $model.graduatingGoodDays,
            graduatingEasyDays: $model.graduatingEasyDays
        )
        LapsesSection(
            relearningStepsText: $model.relearningStepsText,
            leechThreshold: $model.leechThreshold,
            leechAction: $model.leechAction,
            leechOnlyIfYoung: $model.leechOnlyIfYoung
        )
        OrderSection(
            newCardInsertOrder: $model.newCardInsertOrder,
            newCardGatherPriority: $model.newCardGatherPriority,
            newCardSortOrder: $model.newCardSortOrder,
            newMix: $model.newMix,
            reviewOrder: $model.reviewOrder,
            interdayLearningMix: $model.interdayLearningMix,
            intradayLearningMix: $model.intradayLearningMix,
            fsrsEnabled: model.fsrsEnabled
        )
        BurySection(
            buryNew: $model.buryNew,
            buryReviews: $model.buryReviews,
            buryInterdayLearning: $model.buryInterdayLearning
        )
        TimerSection(
            showTimer: $model.showTimer,
            capAnswerTimeToSecs: $model.capAnswerTimeToSecs,
            stopTimerOnAnswer: $model.stopTimerOnAnswer
        )
        AutoAdvanceSection(
            secondsToShowQuestion: $model.secondsToShowQuestion,
            secondsToShowAnswer: $model.secondsToShowAnswer,
            questionAction: $model.questionAction,
            answerAction: $model.answerAction
        )
        AdvancedSection(
            fsrsEnabled: model.fsrsEnabled,
            maximumReviewIntervalDays: $model.maximumReviewIntervalDays,
            intervalMultiplierPercent: $model.intervalMultiplierPercent,
            hardMultiplierPercent: $model.hardMultiplierPercent,
            easyMultiplierPercent: $model.easyMultiplierPercent,
            disableAutoplay: $model.disableAutoplay,
            waitForAudio: $model.waitForAudio
        )
        FsrsSection(
            fsrsEnabled: model.fsrsEnabled,
            fsrsVersion: model.schedulerSelection.fsrsVersion,
            paramsLabel: model.fsrsParamsLabel,
            defaultParamSearch: model.defaultParamSearch,
            desiredRetentionPercent: $model.desiredRetentionPercent,
            deckDesiredRetentionPercent: $model.deckDesiredRetentionPercent,
            historicalRetentionPercent: $model.historicalRetentionPercent,
            fsrsHealthCheck: $model.fsrsHealthCheck,
            fsrsReschedule: $model.fsrsReschedule,
            fsrsMinimumIntervalSecs: $model.fsrsMinimumIntervalSecs,
            fsrsWeightsText: $model.fsrsWeightsText,
            fsrsParamSearch: $model.fsrsParamSearch,
            fsrsEvaluationSearch: $model.fsrsEvaluationSearch,
            fsrs7IncludeSameDayReviews: $model.fsrs7IncludeSameDayReviews,
            fsrs7SchedulingPenaltiesEnabled: $model.fsrs7SchedulingPenaltiesEnabled,
            dynamicDesiredRetentionEnabled: $model.dynamicDesiredRetentionEnabled,
            dynamicDesiredRetentionClamp: $model.dynamicDesiredRetentionClamp,
            isOptimizingFsrs: model.isOptimizingFsrs,
            isCheckingHealth: model.isCheckingFsrsHealth,
            onCheckHealth: { Task { await model.checkFsrsHealth() } },
            onOptimizeCurrent: { Task { await model.optimizeCurrentPreset() } },
            onCancelOptimize: { model.cancelOptimize() },
            onOpenSimulatorReview: { model.openSimulator(mode: .review) },
            onOpenSimulatorWorkload: { model.openSimulator(mode: .workload) },
            onOptimizeAll: { Task { await model.optimizeAllPresets() } }
        )
        EasyDaysSection(
            fsrsEnabled: model.fsrsEnabled,
            easyDayPercentages: $model.easyDayPercentages
        )
        if model.hasSchedulingSettings {
            CollectionSchedulingSection(
                fsrsEnabled: model.fsrsEnabled,
                instantEnabled: model.schedulerSelection.rwkvReviewInstantOrderEnabled,
                loadBalancerEnabled: $model.loadBalancerEnabled,
                fsrsShortTermWithStepsEnabled: $model.fsrsShortTermWithStepsEnabled,
                fsrsLearningQueuesDisabled: $model.fsrsLearningQueuesDisabled,
                reviewFuzzEnabled: $model.reviewFuzzEnabled,
                reviewFuzzBase: $model.reviewFuzzBase,
                reviewFuzzFactorShort: $model.reviewFuzzFactorShort,
                reviewFuzzFactorMid: $model.reviewFuzzFactorMid,
                reviewFuzzFactorLong: $model.reviewFuzzFactorLong
            )
        }
        ApplySection(applyToChildren: $model.applyToChildren)
    }

    private func attemptDismiss() {
        if model.hasUnsavedChanges {
            model.destination = .alert(.discardChanges)
        } else {
            onDismiss()
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let _ = prepareDependencies {
        let config = DeckConfig(
            id: DeckConfigID(1),
            name: "Default",
            config: .init(
                learnSteps: [1, 10],
                relearnSteps: [10],
                newPerDay: 20,
                reviewsPerDay: 200,
                graduatingIntervalGood: 1,
                graduatingIntervalEasy: 4,
                leechThreshold: 8,
                desiredRetention: 0.9,
                historicalRetention: 0.9
            )
        )
        $0.deckClient.getDeckConfig = { _ in config }
        $0.deckClient.fetchDeckConfigContext = { _ in
            DeckConfigsForUpdate(
                allConfig: [DeckConfigsForUpdate.ConfigWithExtra(config: config, useCount: 12)],
                currentDeck: DeckConfigsForUpdate.CurrentDeck(name: "Japanese", configID: config.id),
                defaults: config
            )
        }
    }
    return NavigationStack {
        DeckConfigView(deckId: DeckID(1), deckName: "Japanese", onDismiss: {})
    }
}
#endif
