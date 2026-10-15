//
//  StatsDashboardModel.swift
//  StatsFeature
//
//  Created by Vladimir Gusev on 27.06.2026.
//

import AppCore
import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import StatsCharts

@Observable
@MainActor
final class StatsDashboardModel {
    var state: StatsDashboardContent.State = .loading
    private(set) var isRefreshing = false
    var decks: [DeckInfo] = [] {
        didSet { topLevelDecks = decks.filter { !$0.name.contains("::") } }
    }

    private(set) var topLevelDecks: [DeckInfo] = []

    private(set) var streak: StreakSummary?

    /// The calibration and UM+ graphs, loaded on request like the desktop
    /// add-on's FSRS graphs, then kept following the search and period.
    private(set) var calibration: CalibrationLoadState = .notRequested
    private var calibrationRequested = false

    @ObservationIgnored @Dependency(\.statsClient) private var statsClient
    @ObservationIgnored @Dependency(\.deckClient) private var deckClient
    @ObservationIgnored @Dependency(\.rwkvClient) private var rwkvClient

    func loadDecks() async {
        decks = (try? await deckClient.fetchAll()) ?? []
    }

    func loadStreak(search: String) async {
        guard let graphs = try? await statsClient.fetchGraphs(search, StreakSummary.window) else {
            streak = nil
            return
        }
        guard !Task.isCancelled else { return }
        streak = StreakSummary(reviews: graphs.reviews.count)
    }

    /// "Show?": load the calibration graphs now and on later changes.
    func showCalibration(search: String, days: Int) async {
        calibrationRequested = true
        await loadCalibration(search: search, days: days)
    }

    /// The add-on's `fsrsCalibrationStats` / `rwkvCalibrationStats`: reads
    /// both models' historical predictions for the search, generating
    /// missing RWKV ones first (with progress).
    func loadCalibration(search: String, days: Int) async {
        guard calibrationRequested else { return }
        calibration = .loading(nil)
        let polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let client = self?.rwkvClient else { return }
                let progress = await client.calibrationProgress()
                guard !Task.isCancelled, let self else { return }
                if case .loading = self.calibration {
                    self.calibration = .loading(progress)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { polling.cancel() }
        do {
            let report = try await statsClient.fetchCalibration(search, days, true)
            guard !Task.isCancelled else { return }
            calibration = .loaded(report)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            calibration = .failed(error.localizedDescription)
        }
    }

    /// Stops generating RWKV calibration data; the graphs then show what
    /// exists.
    func cancelCalibration() {
        Task { await rwkvClient.cancelCalibration() }
    }

    func loadStats(search: String, days: Int) async {
        await AppSignpost.measure("StatsLoad") { await loadStatsBody(search: search, days: days) }
    }

    private func loadStatsBody(search: String, days: Int) async {
        if case .loaded = state { isRefreshing = true } else { state = .loading }
        defer { isRefreshing = false }
        do {
            let graphs = try await statsClient.fetchGraphs(search, days)
            guard !Task.isCancelled else { return }
            state = .loaded(graphs)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
