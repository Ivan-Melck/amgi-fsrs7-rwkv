//
//  StatsClient.swift
//  AnkiClients
//
//  Created by Vladimir Gusev on 27.03.2026.
//

public import AnkiKit
public import Dependencies
import DependenciesMacros

@DependencyClient
public struct StatsClient: Sendable {
    public var fetchGraphs: @Sendable (_ search: String, _ days: Int) async throws -> GraphsSnapshot
    /// The calibration and UM+ graphs' data for a search and period; with
    /// `ensure`, missing RWKV data is generated first (long-running).
    public var fetchCalibration: @Sendable (_ search: String, _ days: Int, _ ensure: Bool) async throws -> CalibrationReport
}

extension StatsClient: TestDependencyKey {
    public static let testValue = StatsClient()
}

extension DependencyValues {
    public var statsClient: StatsClient {
        get { self[StatsClient.self] }
        set { self[StatsClient.self] = newValue }
    }
}
