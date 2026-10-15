//
//  MemorisedClient.swift
//  AnkiClients
//
//  The stats screen's Memorised chart: the FSRS replay of a search's
//  reviews, and the RWKV daily history (the fork desktop's Search Stats
//  Extended add-on).
//

public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct MemorisedClient: Sendable {
    /// The FSRS series of a search over the last `days` days (0: all).
    public var fsrsHistory: @Sendable (_ search: String, _ days: Int) async throws -> FsrsMemorisedHistory
    /// The app bundles the RWKV model.
    public var rwkvAvailable: @Sendable () -> Bool = { false }
    /// The RWKV daily history for a search; returns when its build
    /// finishes, fails or is cancelled (minutes for a large collection).
    public var rwkvHistory: @Sendable (_ search: String) async throws -> RwkvMemorisedProgress
    /// The running `rwkvHistory`'s progress and series so far.
    public var rwkvProgress: @Sendable () async throws -> RwkvMemorisedProgress
    /// Stops a running `rwkvHistory`, keeping a checkpoint to resume from.
    public var cancelRwkv: @Sendable () async -> Void
}

extension MemorisedClient: TestDependencyKey {
    public static let testValue = MemorisedClient()
}

extension DependencyValues {
    public var memorisedClient: MemorisedClient {
        get { self[MemorisedClient.self] }
        set { self[MemorisedClient.self] = newValue }
    }
}
