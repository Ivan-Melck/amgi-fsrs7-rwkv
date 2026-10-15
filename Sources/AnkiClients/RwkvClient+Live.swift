//
//  RwkvClient+Live.swift
//  AnkiClients
//

import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
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
            }
        )
    }()
}
