//
//  DeckConfigModel+Presets.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 20.08.2026.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation

extension DeckConfigModel {
    /// Preset changes reload the page, so unsaved edits are saved or
    /// discarded first (the desktop keeps them across presets until Save).
    func requestPresetAction(_ action: DeckConfigPresetAction) {
        if hasUnsavedChanges {
            destination = .alert(.unsavedBeforePresetChange(action))
        } else {
            performPresetAction(action)
        }
    }

    func saveThenPerform(_ action: DeckConfigPresetAction) async {
        guard await saveConfig() else { return }
        await loadConfig()
        await waitForDismissal()
        performPresetAction(action)
    }

    func discardThenPerform(_ action: DeckConfigPresetAction) async {
        if let loaded {
            apply(config: loaded.config, context: loaded.context)
        }
        await waitForDismissal()
        performPresetAction(action)
    }

    /// Lets an alert or sheet finish dismissing before the next one is
    /// presented.
    func waitForDismissal() async {
        try? await Task.sleep(for: .milliseconds(450))
    }

    func showNoticeAfterDismissal(title: String, message: String) {
        Task {
            await waitForDismissal()
            destination = .alert(.notice(title: title, message: message))
        }
    }

    func performPresetAction(_ action: DeckConfigPresetAction) {
        switch action {
        case .select(let target):
            Task { await selectPreset(target) }
        case .add:
            newPresetName = ""
            destination = .prompt(.createPreset)
        case .clone:
            newPresetName = ""
            destination = .prompt(.clonePreset)
        case .rename:
            renamePresetDraft = currentPresetName ?? ""
            destination = .prompt(.renamePreset)
        case .delete:
            destination = .alert(.deletePresetConfirm)
        }
    }

    func selectPreset(_ target: DeckConfig) async {
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            try await deckClient.selectDeckPreset(deckId, target, applyToChildren)
            await loadConfig()
        } catch {
            destination = .alert(.presetError("Failed to switch preset: \(error.localizedDescription)"))
        }
    }

    /// `addConfig` starts from the defaults; `cloneConfig` copies the
    /// current preset.
    func createPreset(fromDefaults: Bool) async -> String? {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let loaded else { return nil }
        var base = loaded.config
        if fromDefaults, let defaults = loaded.context.defaults {
            base.config = defaults.config
        }
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            try await deckClient.createDeckPreset(deckId, base, uniqueName(name), applyToChildren)
            newPresetName = ""
            await loadConfig()
            return nil
        } catch {
            return "Failed to create preset: \(error.localizedDescription)"
        }
    }

    func renamePreset() async -> String? {
        guard var base = loaded?.config else { return nil }
        let trimmed = renamePresetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            base.name = trimmed
            // Reuse selectDeckPreset which writes the existing config's row in
            // place — same RPC the Anki Desktop "rename preset" flow uses.
            try await deckClient.selectDeckPreset(deckId, base, applyToChildren)
            await loadConfig()
            return nil
        } catch {
            return "Failed to rename preset: \(error.localizedDescription)"
        }
    }

    func deletePreset() async {
        guard let current = loaded?.config, let fallback = deleteFallbackPreset else { return }
        isPresetMutating = true
        defer { isPresetMutating = false }
        do {
            try await deckClient.deleteDeckPreset(deckId, current.id, fallback, applyToChildren)
            await loadConfig()
        } catch {
            destination = .alert(.presetError("Failed to delete preset: \(error.localizedDescription)"))
        }
    }

    func uniqueName(_ base: String) -> String {
        let existing = Set(presetOptions.map { $0.config.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Apply schedule to all presets

    var canApplyScheduleToAllPresets: Bool {
        presetOptions.count > 1 && !isFallbackContext
    }

    /// `applyScheduleToAllPresets`. The desktop copies into the other
    /// presets and saves on Save; here edits are saved first and the copies
    /// saved at once. Returns an error message for the sheet.
    func applyScheduleToAllPresets(_ options: ScheduleCopyOptions) async -> String? {
        guard canApplyScheduleToAllPresets else { return nil }
        if hasUnsavedChanges {
            guard await saveConfig() else { return "Couldn't save your changes." }
            await loadConfig()
        }
        guard let loaded else { return nil }
        let source = loaded.config.config
        let changed = loaded.context.allConfig.map(\.config).compactMap { target -> DeckConfig? in
            guard target.id != loaded.config.id else { return nil }
            var updated = target
            updated.config = target.config.withCopiedSchedule(from: source, options: options)
            return updated == target ? nil : updated
        }
        guard !changed.isEmpty else {
            showNoticeAfterDismissal(
                title: "Nothing to change",
                message: "The other presets already match this one."
            )
            return nil
        }
        do {
            // The current preset goes last so it stays this deck's preset.
            try await deckClient.updatePresets(deckId, changed + [loaded.config])
        } catch {
            return error.localizedDescription
        }
        await loadConfig()
        showNoticeAfterDismissal(
            title: "Schedule applied",
            message: "Copied to \(changed.count) preset\(changed.count == 1 ? "" : "s")."
        )
        return nil
    }

    // MARK: - RWKV maintenance

    var canRebuildRwkvState: Bool { rwkvClient.isAvailable() }

    /// The RWKV options' "Build Cache", which saves the options first.
    func rebuildRwkvState() async {
        if hasUnsavedChanges {
            guard !isFallbackContext, await saveConfig() else { return }
            await loadConfig()
        }
        isRebuildingRwkvState = true
        defer { isRebuildingRwkvState = false }
        do {
            let result = try await rwkvClient.rebuildState()
            destination = .alert(.notice(
                title: "RWKV state rebuilt",
                message: result.ready
                    ? "The RWKV state was rebuilt from your review history and saved."
                    : "No preset uses RWKV, so there was nothing to rebuild."
            ))
        } catch {
            destination = .alert(.fsrsError(
                title: "Couldn't rebuild the RWKV state",
                message: error.localizedDescription
            ))
        }
    }

    // MARK: - FSRS optimize

    func cancelOptimize() {
        optimizeGeneration &+= 1
        isOptimizingFsrs = false
    }

    func optimizeCurrentPreset() async {
        guard let loaded else { return }
        let generation = optimizeGeneration
        isOptimizingFsrs = true
        defer { if generation == optimizeGeneration { isOptimizingFsrs = false } }

        do {
            // Mirrors the fork's desktop request: the FSRS-7-only options
            // are sent only when the preset is on FSRS-7.
            let version = schedulerSelection.fsrsVersion
            let isFsrs7 = version == .seven
            let request = FsrsOptimizeRequest(
                search: effectiveParamSearch(),
                currentWeights: FsrsWeights(activeFsrsParams()),
                ignoreRevlogsBefore: Self.ignoreRevlogsBefore(
                    editedConfig(from: loaded.config).config.ignoreRevlogsBeforeDate
                ),
                relearningStepsPerDay: Int(relearningStepsInDay(parseSteps(relearningStepsText))),
                runHealthCheck: fsrsHealthCheck,
                fsrsVersion: version,
                includeSameDayReviews: isFsrs7 ? fsrs7IncludeSameDayReviews : nil,
                enableSchedulingPenalties: isFsrs7 ? fsrs7SchedulingPenaltiesEnabled : nil,
                dynamicDesiredRetentionEnabled: isFsrs7 && dynamicDesiredRetentionEnabled
            )

            let result = try await deckClient.computeFsrsParams(request)
            guard generation == optimizeGeneration else { return }
            guard !result.weights.isEmpty else {
                destination = .alert(.fsrsError(
                    title: "Not enough review history",
                    message: "FSRS needs more reviews before it can optimize. Try lowering historical retention or expanding the search."
                ))
                return
            }
            // The text field edits the active version's params, so the
            // optimized values land in that version's slot on save.
            fsrsWeightsText = formatWeights(result.weights.values)
            if let dynamicDesiredRetention = result.dynamicDesiredRetention {
                optimizedDynamicDesiredRetention = dynamicDesiredRetention
            }
            if result.healthCheck == .failed {
                destination = .alert(.fsrsError(
                    title: "FSRS health check failed",
                    message: "Review history may be inconsistent. Inspect the parameters before saving."
                ))
            }
        } catch {
            guard generation == optimizeGeneration else { return }
            destination = .alert(.fsrsError(
                title: "Couldn't optimize FSRS parameters",
                message: error.localizedDescription
            ))
        }
    }

    func optimizeAllPresets() async {
        guard let loaded, !isFallbackContext else { return }
        // The desktop's "Optimize all presets" is a save mode, so the
        // edits are kept: save them, then optimize from what was saved.
        guard await saveConfig() else { return }
        isOptimizingFsrs = true
        defer { isOptimizingFsrs = false }

        do {
            try await deckClient.optimizeFsrsPresets(deckId, editedConfig(from: loaded.config))
            await loadConfig()
        } catch {
            destination = .alert(.fsrsError(
                title: "Couldn't optimize all presets",
                message: error.localizedDescription
            ))
        }
    }

    /// As the desktop's `getIgnoreRevlogsBeforeMs`: `new Date(date)` reads
    /// a `YYYY-MM-DD` date as UTC midnight; empty means no cutoff.
    nonisolated static func ignoreRevlogsBefore(_ date: String) -> Date? {
        guard !date.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    // MARK: - FSRS simulator entry

    func openSimulator(mode: FsrsSimulatorMode) {
        guard let loaded else { return }
        // The preset as edited, like the desktop's simulator.
        let edited = editedConfig(from: loaded.config).config
        let weights = activeFsrsParams()
        guard !weights.isEmpty else {
            destination = .alert(.fsrsError(
                title: "Simulator needs FSRS weights",
                message: "This preset has no weights yet. Run Optimize Weights first, or save the preset."
            ))
            return
        }
        let context = FsrsSimulatorContext(
            mode: mode,
            weights: weights,
            desiredRetentionPercent: desiredRetentionPercent,
            historicalRetentionPercent: historicalRetentionPercent,
            newCardsPerDay: Int(max(0, newCardsPerDay)),
            reviewsPerDay: mode == .workload ? 9999 : Int(max(0, reviewsPerDay)),
            maxIntervalDays: max(1, edited.maximumReviewInterval),
            search: effectiveParamSearch(),
            ignoreNewLimit: newCardsIgnoreReviewLimit,
            suspendLeeches: leechAction == .suspend,
            leechThreshold: Int(max(1, leechThreshold)),
            learningStepCount: parseSteps(learningStepsText).count,
            relearningStepCount: parseSteps(relearningStepsText).count,
            easyDaysPercentages: edited.easyDaysPercentages,
            reviewOrder: edited.reviewOrder,
            reviewFuzz: editedSchedulingSettings,
            dynamicDesiredRetention: edited.fsrsDynamicDesiredRetention,
            dynamicDesiredRetentionClamp: edited.fsrsDynamicDesiredRetentionClamp
        )
        destination = .route(.simulator(context))
    }
}
