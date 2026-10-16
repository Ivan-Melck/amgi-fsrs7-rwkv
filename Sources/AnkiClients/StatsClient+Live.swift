//
//  StatsClient+Live.swift
//  AnkiClients
//
//  Created by Vladimir Gusev on 27.03.2026.
//

import AnkiBackend
import AnkiKit
import AnkiProtoBridge
import AnkiServices
public import Dependencies

extension StatsClient: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend

        return Self(
            fetchGraphs: { search, days in
                try await backendOffload {
                    // RWKV presets' retrievability comes from RWKV, scored for
                    // exactly this search. Like the desktop, graphs don't wait
                    // for the model; they show FSRS values until it is ready,
                    // and say so, so the stats screen can fetch them again.
                    var pending = false
                    if RwkvEnvironment.modelPath != nil {
                        let status = try? backend.invoke(Request<Bool>.rwkvSearchScores(search: search, wait: false))
                        pending = status ?? false
                    }
                    var graphs: GraphsSnapshot = try backend.invoke(.graphs(search: search, days: days))
                    graphs.rwkvStatsPending = pending
                    return graphs
                }
            },
            fetchCalibration: { search, days, ensure in
                try await backendOffload {
                    // Without the model, RWKV rows are only read.
                    try backend.invoke(.rwkvCalibrationData(
                        search: search,
                        days: days,
                        modelPath: RwkvEnvironment.modelPath,
                        cacheDir: RwkvEnvironment.cacheDir(backend),
                        precision: RwkvEnvironment.precision,
                        ensure: ensure
                    ))
                }
            }
        )
    }()
}
