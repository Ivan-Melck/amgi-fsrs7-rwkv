//
//  MemorisedClient+Live.swift
//  AnkiClients
//

import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
import Foundation
public import Dependencies

extension MemorisedClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend

        return Self(
            fsrsHistory: { search, days in
                try await backendOffload { try backend.invoke(.statsFsrsMemorised(search: search, days: days)) }
            },
            rwkvAvailable: { RwkvEnvironment.modelPath != nil },
            rwkvHistory: { search in
                guard let modelPath = RwkvEnvironment.modelPath else {
                    throw MemorisedUnavailableError()
                }
                return try await backendOffload {
                    try backend.invoke(.rwkvMemorisedHistory(
                        search: search,
                        modelPath: modelPath,
                        precision: RwkvEnvironment.precision,
                        cacheDir: RwkvEnvironment.cacheDir(backend)
                    ))
                }
            },
            rwkvProgress: {
                try await backendOffload { try backend.invoke(Request<RwkvMemorisedProgress>.rwkvMemorisedProgress) }
            },
            cancelRwkv: {
                _ = try? await backendOffload { try backend.invoke(Request<Void>.rwkvCancelMemorised) }
            }
        )
    }()

    #if DEBUG
    /// A month of made-up history for `#Preview` blocks.
    public static let previewValue = MemorisedClient(
        fsrsHistory: { _, _ in .preview },
        rwkvAvailable: { true },
        rwkvHistory: { _ in .preview },
        rwkvProgress: { .preview },
        cancelRwkv: {}
    )
    #endif
}

private struct MemorisedUnavailableError: LocalizedError {
    var errorDescription: String? { "This Anki build does not provide RWKV Memorised history." }
}

#if DEBUG
private extension FsrsMemorisedHistory {
    static var preview: Self {
        let days = 30
        let retrievability = (0..<days).map { 40 + 2 * Double($0) - 6 * sin(Double($0) / 3) }
        return FsrsMemorisedHistory(
            today: 100,
            retrievability: MemorisedDaySeries(firstDay: 100 - days + 1, values: retrievability),
            noteRetrievability: MemorisedDaySeries(firstDay: 100 - days + 1, values: retrievability.map { $0 / 2 }),
            cardCount: MemorisedDaySeries(firstDay: 100 - days + 1, values: (0..<days).map { 50 + 2 * Double($0) }),
            stableRetrievability: MemorisedDaySeries(firstDay: 100 - days + 1, values: retrievability.map { $0 / 4 }),
            burden: MemorisedDaySeries(firstDay: 100 - days + 1, values: (0..<days).map { 5 + Double($0) / 10 })
        )
    }
}

private extension RwkvMemorisedProgress {
    static var preview: Self {
        let days = 30
        let retrievability = (0..<days).map { 42 + 2 * Double($0) - 5 * cos(Double($0) / 3) }
        return RwkvMemorisedProgress(
            phase: "complete",
            current: 1_500,
            total: 1_500,
            firstDay: 100 - days + 1,
            completedThroughDay: 100,
            retrievability: retrievability,
            noteRetrievability: retrievability.map { $0 / 2 },
            cardCount: (0..<days).map { 50 + 2 * Double($0) },
            done: true
        )
    }
}
#endif
