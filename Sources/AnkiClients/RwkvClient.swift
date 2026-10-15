//
//  RwkvClient.swift
//  AnkiClients
//
//  RWKV scheduling (the FSRS7/RWKV Anki fork) features the UI asks for
//  directly: Card Info rows and the RWKV-Curve reschedule. Queue scores,
//  deck counts and graph scores are applied inside the services that need
//  them.
//

public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct RwkvClient: Sendable {
    /// The app bundles the RWKV model (false in previews and tests).
    public var isAvailable: @Sendable () -> Bool = { false }
    /// RWKV Card Info rows; empty when the card's preset doesn't use RWKV.
    public var cardInfo: @Sendable (_ cardId: CardID) async throws -> [RwkvCardInfoRow]
    /// Reschedules review cards of RWKV-Curve presets in `deckId` and its
    /// subdecks, or in every deck when nil.
    public var reschedule: @Sendable (_ deckId: DeckID?) async throws -> RwkvRescheduleResult
    /// Rebuilds the RWKV state from the whole review history and saves it.
    public var rebuildState: @Sendable () async throws -> RwkvPrepareResult
    /// "Compare RWKV with FSRS": the RWKV workload sweep.
    public var simulateWorkload: @Sendable (_ request: RwkvWorkloadRequest) async throws -> FsrsWorkloadSimulation
    /// Stops a running `simulateWorkload`.
    public var cancelWorkload: @Sendable () async -> Void
}

extension RwkvClient: TestDependencyKey {
    public static let testValue = RwkvClient()
    public static let previewValue = RwkvClient(
        isAvailable: { false },
        cardInfo: { _ in [] },
        reschedule: { _ in RwkvRescheduleResult(built: true, predicted: 0, updated: 0) },
        rebuildState: { RwkvPrepareResult(active: true, ready: true, source: "replayed") },
        simulateWorkload: { _ in FsrsWorkloadSimulation(cost: [:], memorized: [:], reviewCount: [:]) },
        cancelWorkload: {}
    )
}

extension DependencyValues {
    public var rwkvClient: RwkvClient {
        get { self[RwkvClient.self] }
        set { self[RwkvClient.self] = newValue }
    }
}
