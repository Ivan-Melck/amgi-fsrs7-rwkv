//
//  MemorisedModel.swift
//  StatsFeature
//
//  The Memorised graph's data flow, as the Search Stats Extended add-on's
//  stores.ts drives it: the FSRS replay runs on "Show?" for the search and
//  period; RWKV, when chosen as a source, builds (or reads) its daily
//  history, polled every 500 ms until done.
//

import AnkiClients
import AnkiKit
import Dependencies
import Foundation
import StatsCharts
import SwiftUI

@Observable
@MainActor
final class MemorisedModel {
    private(set) var phase: MemorisedCardPhase = .hidden
    private(set) var fsrs: FsrsMemorisedHistory?
    private(set) var rwkv: RwkvMemorisedProgress?
    var source: MemorisedSource = .fsrs {
        didSet { if source != oldValue { syncRwkv() } }
    }
    var kind: MemorisedKind = .cards

    @ObservationIgnored @Dependency(\.memorisedClient) private var client
    @ObservationIgnored private var search: String?
    @ObservationIgnored private var days = 0
    @ObservationIgnored private var fsrsGeneration = 0
    @ObservationIgnored private var rwkvGeneration = 0
    @ObservationIgnored private var rwkvHistory: Task<RwkvMemorisedProgress?, Never>?

    var rwkvAvailable: Bool { client.rwkvAvailable() }

    /// The stats search or period changed. A new search hides the graph
    /// until "Show?" again (`cids` resets `showRevlogStats`); a new period
    /// replays the shown graph's reviews again (`searchLimit`).
    func update(search: String, days: Int) async {
        guard search == self.search else {
            self.search = search
            self.days = days
            fsrsGeneration &+= 1
            phase = .hidden
            fsrs = nil
            syncRwkv()
            return
        }
        guard days != self.days else { return }
        self.days = days
        if phase != .hidden {
            await loadFsrs()
        }
    }

    /// `MemorisedCalculator`'s "Show?".
    func show() async {
        phase = .loading
        syncRwkv()
        await loadFsrs()
    }

    private func loadFsrs() async {
        guard let search else { return }
        fsrsGeneration &+= 1
        let generation = fsrsGeneration
        if fsrs == nil { phase = .loading }
        do {
            let history = try await client.fsrsHistory(search, days)
            guard generation == fsrsGeneration else { return }
            fsrs = history
            phase = .loaded
        } catch {
            guard generation == fsrsGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// The `rwkvMemorisedStats` store: follows the source, search and
    /// whether the graph is shown.
    private func syncRwkv() {
        rwkvGeneration &+= 1
        rwkv = nil
        guard source != .fsrs, phase != .hidden, let search, rwkvAvailable else { return }
        let generation = rwkvGeneration
        let client = client
        let history = Task { () -> RwkvMemorisedProgress? in
            do {
                return try await client.rwkvHistory(search)
            } catch is CancellationError {
                return nil
            } catch {
                return RwkvMemorisedProgress(phase: "failed", done: true, error: error.localizedDescription)
            }
        }
        rwkvHistory = history
        Task { [weak self] in
            await self?.poll(generation: generation)
        }
        Task { [weak self] in
            let result = await history.value
            guard let self, generation == self.rwkvGeneration, let result else { return }
            self.rwkv = result
        }
    }

    /// The add-on polls the build's progress every 500 ms until it's done.
    private func poll(generation: Int) async {
        while generation == rwkvGeneration {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == rwkvGeneration, rwkv?.done != true else { return }
            guard let progress = try? await client.rwkvProgress(), !progress.done else { continue }
            guard generation == rwkvGeneration, rwkv?.done != true else { return }
            rwkv = progress
        }
    }

    /// `cancelRwkvMemorisedComputation`: stops polling, shows the checkpoint
    /// being saved, then the cancelled build's series.
    func cancelRwkv() async {
        rwkvGeneration &+= 1
        if var progress = rwkv {
            progress.phase = "checkpointing"
            progress.done = false
            rwkv = progress
        }
        await client.cancelRwkv()
        _ = await rwkvHistory?.value
        if var progress = rwkv {
            progress.phase = "cancelled"
            progress.done = true
            rwkv = progress
        }
    }
}

/// The Memorised card on the stats screen.
struct MemorisedSection: View {
    @Bindable var model: MemorisedModel
    let truncated: Bool
    let onIncreaseRange: () -> Void

    var body: some View {
        MemorisedCard(
            phase: model.phase,
            fsrs: model.fsrs,
            rwkv: model.rwkv,
            rwkvAvailable: model.rwkvAvailable,
            truncated: truncated,
            source: $model.source,
            kind: $model.kind,
            onShow: { Task { await model.show() } },
            onIncreaseRange: onIncreaseRange,
            onCancelRwkv: { Task { await model.cancelRwkv() } }
        )
    }
}
