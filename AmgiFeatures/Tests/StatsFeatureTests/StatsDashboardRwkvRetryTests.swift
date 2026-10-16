//
//  StatsDashboardRwkvRetryTests.swift
//  StatsFeatureTests
//
//  The desktop's `WithGraphData.svelte`: graphs fetched while RWKV's scores
//  are pending are fetched again, at most 30 times per search and period.
//

import AnkiClients
import AnkiKit
import Dependencies
import Testing
@testable import StatsFeature

@MainActor
@Suite("StatsDashboardModel RWKV stats retry")
struct StatsDashboardRwkvRetryTests {

    @MainActor
    private final class Probe {
        var searches: [String] = []
        /// How many fetches report pending scores before RWKV is ready.
        var pendingFetches = 0
        /// The searches whose scores never become ready.
        var alwaysPending: Set<String> = []

        func fetched(_ search: String) -> Bool {
            searches.append(search)
            return alwaysPending.contains(search) || searches.count <= pendingFetches
        }
    }

    private func makeModel(_ probe: Probe, delay: Duration) -> StatsDashboardModel {
        let model = withDependencies {
            $0.statsClient = StatsClient(
                fetchGraphs: { (search: String, _: Int) async throws -> GraphsSnapshot in
                    let pending: Bool = await MainActor.run { probe.fetched(search) }
                    return GraphsSnapshot(rwkvStatsPending: pending)
                },
                fetchCalibration: { (_: String, _: Int, _: Bool) async throws -> CalibrationReport in
                    CalibrationReport(samples: [], fsrsPredictions: [:], rwkvPredictions: [:])
                }
            )
        } operation: {
            StatsDashboardModel()
        }
        model.rwkvStatsRetryDelay = delay
        return model
    }

    /// Polls for up to five seconds.
    private func waitUntil(_ condition: () -> Bool) async {
        var polls = 0
        while !condition(), polls < 500 {
            try? await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
    }

    @Test("pending graphs are fetched again until RWKV's scores are ready")
    func retriesUntilReady() async throws {
        let probe = Probe()
        probe.pendingFetches = 2
        let model = makeModel(probe, delay: .milliseconds(1))

        await model.loadStats(search: "", days: 30)
        await waitUntil { probe.searches.count >= 3 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(probe.searches.count == 3)
        guard case .loaded(let graphs) = model.state else {
            Issue.record("expected loaded graphs")
            return
        }
        #expect(graphs.rwkvStatsPending == false)
    }

    @Test("retries stop after 30 for one search and period")
    func retriesAreCapped() async throws {
        let probe = Probe()
        probe.alwaysPending = [""]
        let model = makeModel(probe, delay: .zero)

        await model.loadStats(search: "", days: 30)
        await waitUntil { probe.searches.count >= 1 + StatsDashboardModel.rwkvStatsMaxRetries }
        try await Task.sleep(for: .milliseconds(50))

        #expect(probe.searches.count == 1 + StatsDashboardModel.rwkvStatsMaxRetries)
    }

    @Test("another search drops the pending retry")
    func newSearchCancelsRetry() async throws {
        let probe = Probe()
        probe.alwaysPending = ["deck:a"]
        let model = makeModel(probe, delay: .milliseconds(50))

        await model.loadStats(search: "deck:a", days: 30)
        await model.loadStats(search: "deck:b", days: 30)
        try await Task.sleep(for: .milliseconds(200))

        #expect(probe.searches == ["deck:a", "deck:b"])
    }
}
