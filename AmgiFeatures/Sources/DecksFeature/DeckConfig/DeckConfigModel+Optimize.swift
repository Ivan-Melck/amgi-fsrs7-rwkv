//
//  DeckConfigModel+Optimize.swift
//  DecksFeature
//
//  The fork desktop's FsrsOptions.svelte optimize flow: Optimize compares
//  the current and optimized parameters before applying them, and FSRS-7
//  presets get the same-day reviews Help Me Decide.
//

import AnkiClients
import AnkiKit
import AppCore
import Dependencies
import Foundation
import OSLog

extension DeckConfigModel {
    // MARK: - Shared inputs

    /// `evaluateSearchFilter`: the evaluation search, else the optimize one.
    func effectiveEvaluationSearch() -> String {
        fsrsEvaluationSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? effectiveParamSearch()
            : fsrsEvaluationSearch
    }

    /// `includeSameDayOverride`: only FSRS-7 has the option.
    var includeSameDayOverride: Bool? {
        schedulerSelection.fsrsVersion == .seven ? fsrs7IncludeSameDayReviews : nil
    }

    /// `enableSchedulingPenaltiesOverride`.
    var enableSchedulingPenaltiesOverride: Bool {
        schedulerSelection.fsrsVersion == .seven && fsrs7SchedulingPenaltiesEnabled
    }

    /// `fsrsParamsForEvaluation`: the legacy evaluation reads an empty list
    /// as the FSRS-6 defaults, so FSRS-7 defaults are sent explicitly.
    func fsrsParamsForEvaluation() -> [Float] {
        let params = activeFsrsParams()
        guard schedulerSelection.fsrsVersion == .seven, params.isEmpty,
              let defaults = loaded?.context.defaults else { return params }
        return defaults.config.fsrsParams7
    }

    /// `getIgnoreRevlogsBeforeMs`, from the edited preset.
    var editedIgnoreRevlogsBefore: Date? {
        guard let loaded else { return nil }
        return Self.ignoreRevlogsBefore(editedConfig(from: loaded.config).config.ignoreRevlogsBeforeDate)
    }

    /// The desktop's `computing`: one FSRS job at a time.
    var isFsrsComputing: Bool {
        isOptimizingFsrs || isCheckingFsrsHealth || isCheckingSameDayDecision
    }

    /// The failure hint of `optimizationFailureFeedback`.
    private var dynamicDesiredRetentionHint: Bool {
        schedulerSelection.fsrsVersion == .seven && dynamicDesiredRetentionEnabled
    }

    // MARK: - Optimize

    /// The desktop's `setWantsAbort`: the backend stops the running job,
    /// whose result (an interrupted error) is then ignored.
    func cancelOptimize() {
        optimizeGeneration &+= 1
        isOptimizingFsrs = false
        isCheckingSameDayDecision = false
        isCheckingFsrsHealth = false
        Task { await deckClient.abortFsrsComputation() }
    }

    /// `runWithBackendProgress`: polls the backend's progress every 100 ms
    /// while `work` runs. The last value stays, for its review count.
    func withFsrsProgress<T>(_ work: () async throws -> T) async rethrows -> T {
        fsrsComputeProgress = nil
        let poll = Task { [deckClient] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if let progress = await deckClient.latestFsrsComputeProgress() {
                    fsrsComputeProgress = progress
                }
            }
        }
        defer { poll.cancel() }
        return try await work()
    }

    // MARK: - Check Health

    /// `checkHealth` (`evaluateParams`): trains on the optimize search and
    /// reports the fit on the evaluation search.
    func checkFsrsHealth() async {
        guard loaded != nil, !isFsrsComputing else { return }
        let params = activeFsrsParams()
        let generation = optimizeGeneration
        isCheckingFsrsHealth = true
        defer { if generation == optimizeGeneration { isCheckingFsrsHealth = false } }
        do {
            try requireValidFsrsParams(.current, params)
            let request = FsrsEvaluateRequest(
                search: effectiveEvaluationSearch(),
                searchForTraining: effectiveParamSearch(),
                ignoreRevlogsBefore: editedIgnoreRevlogsBefore,
                relearningStepsPerDay: Int(relearningStepsInDay(parseSteps(relearningStepsText))),
                fsrsVersion: schedulerSelection.fsrsVersion,
                includeSameDayReviews: includeSameDayOverride,
                enableSchedulingPenalties: enableSchedulingPenaltiesOverride
            )
            let result = try await withFsrsProgress {
                try await deckClient.evaluateFsrsParams(request)
            }
            guard generation == optimizeGeneration else { return }
            let logLoss = JSNumberFormat.toFixed(Double(result.logLoss), 4)
            let rmse = JSNumberFormat.toFixed(Double(result.rmseBins) * 100, 2)
            destination = .alert(.notice(
                title: "FSRS health",
                message: "Log loss: \(logLoss), RMSE(bins): \(rmse)%. "
                    // deck-config-smaller-is-better
                    + "Smaller numbers indicate a better fit to your review history."
            ))
        } catch {
            guard generation == optimizeGeneration else { return }
            destination = .alert(.fsrsError(
                title: "Couldn't check FSRS health",
                message: optimizationFailureFeedback(error, params: params)
            ))
        }
    }

    /// `computeParams`: optimizes, then shows the Optimization Result unless
    /// the parameters are already optimal.
    func optimizeCurrentPreset() async {
        await withFsrsProgress { await optimizeCurrentPresetJob() }
    }

    private func optimizeCurrentPresetJob() async {
        guard loaded != nil, !isFsrsComputing else { return }
        let generation = optimizeGeneration
        isOptimizingFsrs = true
        defer { if generation == optimizeGeneration { isOptimizingFsrs = false } }

        let params = activeFsrsParams()
        let currentEvaluationParams = fsrsParamsForEvaluation()
        let ignoreRevlogsBefore = editedIgnoreRevlogsBefore
        do {
            try requireValidFsrsParams(.current, params)
            let version = schedulerSelection.fsrsVersion
            let request = FsrsOptimizeRequest(
                search: effectiveParamSearch(),
                currentWeights: FsrsWeights(params),
                ignoreRevlogsBefore: ignoreRevlogsBefore,
                relearningStepsPerDay: Int(relearningStepsInDay(parseSteps(relearningStepsText))),
                runHealthCheck: fsrsHealthCheck,
                fsrsVersion: version,
                includeSameDayReviews: includeSameDayOverride,
                enableSchedulingPenalties: enableSchedulingPenaltiesOverride,
                dynamicDesiredRetentionEnabled: version == .seven && dynamicDesiredRetentionEnabled
            )
            let result = try await deckClient.computeFsrsParams(request)
            guard generation == optimizeGeneration else { return }
            let optimizedParams = result.weights.values
            try requireValidFsrsParams(.optimized, optimizedParams)

            let alreadyOptimal = FsrsOptimizeOutcome.alreadyOptimal(current: params, optimized: optimizedParams)
            let notice = FsrsOptimizeOutcome.notice(
                alreadyOptimal: alreadyOptimal,
                trainingItemCount: result.trainingItemCount,
                healthCheck: result.healthCheck
            )
            if alreadyOptimal {
                if let dynamicDesiredRetention = result.dynamicDesiredRetention {
                    optimizedDynamicDesiredRetention = dynamicDesiredRetention
                }
                if let notice {
                    destination = .alert(.notice(title: "Optimize FSRS parameters", message: notice))
                }
                return
            }

            let includeSameDayReviews = FsrsParamDiagnostics.sameDayEvaluationOverrideForComparison(
                current: currentEvaluationParams,
                optimized: optimizedParams,
                requested: includeSameDayOverride
            )
            let evaluationSearch = effectiveEvaluationSearch()
            let current = try await evaluateParamsLegacyForOptimization(.current, FsrsEvaluateLegacyRequest(
                params: currentEvaluationParams,
                search: evaluationSearch,
                ignoreRevlogsBefore: ignoreRevlogsBefore,
                includeSameDayReviews: includeSameDayReviews
            ))
            let optimized = try await evaluateParamsLegacyForOptimization(.optimized, FsrsEvaluateLegacyRequest(
                params: optimizedParams,
                search: evaluationSearch,
                ignoreRevlogsBefore: ignoreRevlogsBefore,
                includeSameDayReviews: includeSameDayReviews
            ))
            guard generation == optimizeGeneration else { return }
            // The desktop alerts the health check over the popup; here it
            // is shown inside it.
            destination = .sheet(.optimizationComparison(FsrsOptimizationComparison(
                optimizedParams: optimizedParams,
                dynamicDesiredRetention: result.dynamicDesiredRetention,
                search: evaluationSearch,
                ignoreRevlogsBefore: ignoreRevlogsBefore,
                includeSameDayReviews: includeSameDayReviews,
                current: current,
                optimized: optimized,
                notice: notice
            )))
        } catch {
            guard generation == optimizeGeneration else { return }
            destination = .alert(.fsrsError(
                title: "Couldn't optimize FSRS parameters",
                message: optimizationFailureFeedback(error, params: params)
            ))
        }
    }

    /// `keepCurrentParams`.
    func keepCurrentParams() {
        destination = nil
    }

    /// `applyOptimizedParams`. The values are kept at full precision, as
    /// the desktop stores them, while the field shows them rounded.
    func applyOptimizedParams(_ comparison: FsrsOptimizationComparison) {
        parkedFsrsParams[schedulerSelection.fsrsVersion] = comparison.optimizedParams
        fsrsWeightsText = formatWeights(comparison.optimizedParams)
        if let dynamicDesiredRetention = comparison.dynamicDesiredRetention {
            optimizedDynamicDesiredRetention = dynamicDesiredRetention
        }
        destination = nil
    }

    /// `loadCustomDecayTable`: the optimized parameters with each candidate
    /// decay, scored like the comparison.
    func loadCustomDecayRows(_ comparison: FsrsOptimizationComparison) async throws -> [FsrsDecayRow] {
        guard comparison.supportsCustomDecayTable else { return [] }
        var results: [(decay: Double, evaluation: FsrsEvaluation)] = []
        for (decay, request) in comparison.customDecayRequests() {
            results.append((decay, try await deckClient.evaluateFsrsParamsLegacy(request)))
        }
        return comparison.customDecayRows(results)
    }

    // MARK: - Same-day reviews: Help Me Decide

    /// `checkSameDayDecision`: optimizes FSRS-7 with and without same-day
    /// reviews and scores both on all targets and on long-term ones.
    func checkSameDayDecision() async {
        await withFsrsProgress { await checkSameDayDecisionJob() }
    }

    private func checkSameDayDecisionJob() async {
        guard loaded != nil, !isFsrsComputing else { return }
        let currentParams = activeFsrsParams()
        do {
            try requireValidFsrsParams(.current, currentParams)
        } catch {
            destination = .alert(.fsrsError(
                title: "Couldn't compare same-day settings",
                message: optimizationFailureFeedback(error, params: currentParams)
            ))
            return
        }
        let generation = optimizeGeneration
        isCheckingSameDayDecision = true
        defer { if generation == optimizeGeneration { isCheckingSameDayDecision = false } }

        let ignoreRevlogsBefore = editedIgnoreRevlogsBefore
        do {
            let withSameDay = try await sameDayParamsCandidate(
                includeSameDayReviews: true,
                currentParams: currentParams,
                ignoreRevlogsBefore: ignoreRevlogsBefore
            )
            let withoutSameDay = try await sameDayParamsCandidate(
                includeSameDayReviews: false,
                currentParams: currentParams,
                ignoreRevlogsBefore: ignoreRevlogsBefore
            )
            guard generation == optimizeGeneration else { return }
            guard withSameDay.trainingItemCount != 0, withoutSameDay.trainingItemCount != 0 else {
                destination = .alert(.notice(
                    title: "Same-day reviews",
                    message: FsrsSameDayDecisionComparison.notEnoughHistoryMessage
                ))
                return
            }
            let withSameDayRow = try await sameDayDecisionRow(
                label: FsrsSameDayDecisionComparison.withSameDayLabel,
                candidate: withSameDay,
                ignoreRevlogsBefore: ignoreRevlogsBefore
            )
            let withoutSameDayRow = try await sameDayDecisionRow(
                label: FsrsSameDayDecisionComparison.withoutSameDayLabel,
                candidate: withoutSameDay,
                ignoreRevlogsBefore: ignoreRevlogsBefore
            )
            guard generation == optimizeGeneration else { return }
            destination = .sheet(.sameDayDecision(FsrsSameDayDecisionComparison(
                withSameDay: withSameDayRow,
                withoutSameDay: withoutSameDayRow
            )))
        } catch {
            guard generation == optimizeGeneration else { return }
            destination = .alert(.fsrsError(
                title: "Couldn't compare same-day settings",
                message: optimizationFailureFeedback(error, params: currentParams)
            ))
        }
    }

    /// `sameDayParamsCandidate`: FSRS-7 without health check or ADR.
    private func sameDayParamsCandidate(
        includeSameDayReviews: Bool,
        currentParams: [Float],
        ignoreRevlogsBefore: Date?
    ) async throws -> FsrsOptimizeResult {
        try await deckClient.computeFsrsParams(FsrsOptimizeRequest(
            search: effectiveParamSearch(),
            currentWeights: FsrsWeights(currentParams),
            ignoreRevlogsBefore: ignoreRevlogsBefore,
            relearningStepsPerDay: Int(relearningStepsInDay(parseSteps(relearningStepsText))),
            runHealthCheck: false,
            fsrsVersion: .seven,
            includeSameDayReviews: includeSameDayReviews,
            enableSchedulingPenalties: enableSchedulingPenaltiesOverride,
            dynamicDesiredRetentionEnabled: false
        ))
    }

    /// `sameDayDecisionRow`.
    private func sameDayDecisionRow(
        label: String,
        candidate: FsrsOptimizeResult,
        ignoreRevlogsBefore: Date?
    ) async throws -> FsrsSameDayDecisionRow {
        let search = effectiveEvaluationSearch()
        let allTargets = try await deckClient.evaluateFsrsParamsLegacy(FsrsEvaluateLegacyRequest(
            params: candidate.weights.values,
            search: search,
            ignoreRevlogsBefore: ignoreRevlogsBefore,
            includeSameDayReviews: true
        ))
        let longTermTargets = try await deckClient.evaluateFsrsParamsLegacy(FsrsEvaluateLegacyRequest(
            params: candidate.weights.values,
            search: search,
            ignoreRevlogsBefore: ignoreRevlogsBefore,
            includeSameDayReviews: false
        ))
        return FsrsSameDayDecisionRow(
            label: label,
            fsrsItems: candidate.trainingItemCount,
            allTargets: allTargets,
            longTermTargets: longTermTargets
        )
    }

    // MARK: - Error feedback

    /// `requireValidFsrsParams`.
    private func requireValidFsrsParams(_ role: FsrsParamRole, _ params: [Float]) throws {
        do {
            try FsrsOptimizationFeedback.requireValid(role: role, params: params)
        } catch {
            logFsrsParamProblem("validation failed before backend call", role: role, params: params)
            throw error
        }
    }

    /// `evaluateParamsLegacyForOptimization`.
    private func evaluateParamsLegacyForOptimization(
        _ role: FsrsParamRole,
        _ request: FsrsEvaluateLegacyRequest
    ) async throws -> FsrsEvaluation {
        try requireValidFsrsParams(role, request.params)
        do {
            return try await deckClient.evaluateFsrsParamsLegacy(request)
        } catch {
            logFsrsParamProblem("backend evaluation failed", role: role, params: request.params, error: error)
            if FsrsOptimizationFeedback.isInvalidParametersError(error.localizedDescription) {
                throw FsrsOptimizationFeedbackError(FsrsOptimizationFeedback.invalidParams(
                    role: role,
                    diagnostics: FsrsParamDiagnostics(request.params),
                    rejectedByBackend: true
                ))
            }
            throw error
        }
    }

    /// `optimizationFailureFeedback`, logging what the message says was
    /// logged.
    private func optimizationFailureFeedback(_ error: any Error, params: [Float]) -> String {
        if !(error is FsrsOptimizationFeedbackError) {
            let rejected = FsrsOptimizationFeedback.isInvalidParametersError(error.localizedDescription)
                && !FsrsParamDiagnostics(params).valid
            logFsrsParamProblem(
                rejected ? "backend rejected current parameters" : "optimization failed",
                role: .current,
                params: params,
                error: error
            )
        }
        return FsrsOptimizationFeedback.failure(
            error,
            params: params,
            dynamicDesiredRetentionHint: dynamicDesiredRetentionHint
        )
    }

    /// `logFsrsParamProblem`.
    private func logFsrsParamProblem(
        _ reason: String,
        role: FsrsParamRole,
        params: [Float],
        error: (any Error)? = nil
    ) {
        let diagnostics = FsrsParamDiagnostics(params)
        let details = [
            "params=\(params)",
            "count=\(diagnostics.count)",
            "valid=\(diagnostics.valid)",
            "nonFiniteIndexes=\(diagnostics.nonFiniteIndexes)",
            "fsrsVersion=\(schedulerSelection.fsrsVersion)",
            "includeSameDayReviews=\(includeSameDayOverride.map(String.init) ?? "nil")",
            "enableSchedulingPenalties=\(enableSchedulingPenaltiesOverride)",
            "dynamicDesiredRetentionEnabled=\(dynamicDesiredRetentionEnabled)",
            "search=\(effectiveParamSearch())",
            "evaluationSearch=\(effectiveEvaluationSearch())",
            "ignoreRevlogsBefore=\(editedIgnoreRevlogsBefore.map { String($0.timeIntervalSince1970) } ?? "nil")",
            "error=\(error.map { $0.localizedDescription } ?? "nil")",
        ].joined(separator: " ")
        Log.decks.warning("FSRS \(role.rawValue, privacy: .public) parameter \(reason, privacy: .public): \(details)")
    }
}
