//
//  RwkvClient+Live.swift
//  AnkiClients
//

import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
import Foundation
public import Dependencies

extension RwkvClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend

        return Self(
            isAvailable: { RwkvEnvironment.modelPath != nil },
            cardInfo: { cardId in
                guard RwkvEnvironment.modelPath != nil else { return [] }
                return try await backendOffload { try backend.invoke(.rwkvCardInfo(cardId: cardId)) }
            },
            reschedule: { deckId in
                guard let modelPath = RwkvEnvironment.modelPath else {
                    return RwkvRescheduleResult(built: false, predicted: 0, updated: 0)
                }
                return try await backendOffload {
                    // Load the model if this is the first RWKV use this launch.
                    _ = try backend.invoke(.rwkvPrepare(
                        modelPath: modelPath,
                        cacheDir: RwkvEnvironment.cacheDir(backend),
                        precision: RwkvEnvironment.precision
                    ))
                    return try backend.invoke(.rwkvReschedule(deckId: deckId))
                }
            },
            rebuildState: {
                guard let modelPath = RwkvEnvironment.modelPath else {
                    return RwkvPrepareResult(active: false, ready: false, source: "inactive")
                }
                return try await backendOffload {
                    try backend.invoke(.rwkvRebuildState(
                        modelPath: modelPath,
                        cacheDir: RwkvEnvironment.cacheDir(backend),
                        precision: RwkvEnvironment.precision
                    ))
                }
            },
            simulateWorkload: { request in
                guard let modelPath = RwkvEnvironment.modelPath else {
                    throw RwkvUnavailableError()
                }
                return try await backendOffload {
                    _ = try backend.invoke(.rwkvPrepare(
                        modelPath: modelPath,
                        cacheDir: RwkvEnvironment.cacheDir(backend),
                        precision: RwkvEnvironment.precision
                    ))
                    return try backend.invoke(.rwkvSimulateWorkload(request))
                }
            },
            cancelWorkload: {
                _ = try? await backendOffload { try backend.invoke(Request<Void>.rwkvCancelWorkload) }
            }
        )
    }()
}

private struct RwkvUnavailableError: LocalizedError {
    var errorDescription: String? { "RWKV isn't available in this build." }
}
