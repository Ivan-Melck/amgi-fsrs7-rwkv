//
//  MemorisedRequests.swift
//  AnkiProtoBridge
//
//  The stats screen's Memorised chart, from anki-bridge-rs/src/rwkv
//  (fsrs_memorised.rs and memorised.rs). JSON over the aux service. None of
//  them touch the RWKV engine; all bypass the global call lock, so a long
//  RWKV history build never holds up anything else.
//

import Foundation
public import AnkiBackend
public import AnkiKit

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
}()

private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

private struct FsrsMemorisedBody: Encodable {
    let search: String
    let days: UInt32
}

private struct FsrsMemorisedResponse: Decodable {
    let today: Int
    let rollover: Int
    let firstDay: Int
    let retrievability: [Double]
    let noteRetrievability: [Double]
    let cardCount: [Double]
    let stableRetrievability: [Double]
    let burdenFirstDay: Int
    let burden: [Double]
    let bwMatrix: [BwRow]

    struct BwRow: Decodable {
        let rBin: Double
        let cells: [Cell]
    }

    struct Cell: Decodable {
        let dBin: Int
        let predicted: Double
        let real: Double
        let count: Int
    }
}

private struct HistoryBody: Encodable {
    let search: String
    let modelPath: String
    let precision: String
    let cacheDir: String?
}

private struct ProgressResponse: Decodable {
    let phase: String
    let current: Int
    let total: Int
    let firstDay: Int?
    let completedThroughDay: Int?
    let retrievabilityByDay: [Double]
    let noteRetrievabilityByDay: [Double]
    let cardCountByDay: [Double]
    let done: Bool
    let error: String?

    var progress: RwkvMemorisedProgress {
        RwkvMemorisedProgress(
            phase: phase,
            current: current,
            total: total,
            firstDay: firstDay,
            completedThroughDay: completedThroughDay,
            retrievability: retrievabilityByDay,
            noteRetrievability: noteRetrievabilityByDay,
            cardCount: cardCountByDay,
            done: done,
            error: error
        )
    }
}

extension Request where Response == FsrsMemorisedHistory {
    /// The FSRS Memorised series of a search: its reviews in the last
    /// `days` days (0 for the whole history) replayed with each card's
    /// preset, plus the daily load for "Cards/Load".
    public static func statsFsrsMemorised(search: String, days: Int) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.statsFsrsMemorised,
            bypassesCallLock: true,
            encode: {
                try encoder.encode(FsrsMemorisedBody(search: search, days: UInt32(clamping: max(0, days))))
            },
            decode: { data in
                let response = try decoder.decode(FsrsMemorisedResponse.self, from: data)
                let series = { (values: [Double]) in
                    MemorisedDaySeries(firstDay: response.firstDay, values: values)
                }
                return FsrsMemorisedHistory(
                    today: response.today,
                    rollover: response.rollover,
                    retrievability: series(response.retrievability),
                    noteRetrievability: series(response.noteRetrievability),
                    cardCount: series(response.cardCount),
                    stableRetrievability: series(response.stableRetrievability),
                    burden: MemorisedDaySeries(firstDay: response.burdenFirstDay, values: response.burden),
                    bwMatrix: response.bwMatrix.map { row in
                        MemorisedBwRow(
                            rBin: row.rBin,
                            cells: row.cells.map {
                                MemorisedBwCell(dBin: $0.dBin, predicted: $0.predicted, real: $0.real, count: $0.count)
                            }
                        )
                    }
                )
            }
        )
    }
}

extension Request where Response == RwkvMemorisedProgress {
    /// The RWKV daily history for a search: the cached history when it is
    /// current, else a (resumed) build on a private model, which can take
    /// minutes. Returns when it finishes, fails or is cancelled.
    public static func rwkvMemorisedHistory(
        search: String,
        modelPath: String,
        precision: String,
        cacheDir: String?
    ) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvMemorisedHistory,
            bypassesCallLock: true,
            encode: {
                try encoder.encode(HistoryBody(
                    search: search,
                    modelPath: modelPath,
                    precision: precision,
                    cacheDir: cacheDir
                ))
            },
            decode: { data in try decoder.decode(ProgressResponse.self, from: data).progress }
        )
    }

    /// How far the running `rwkvMemorisedHistory` is, with its series so far.
    public static var rwkvMemorisedProgress: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvMemorisedProgress,
            bypassesCallLock: true,
            encode: { Data("{}".utf8) },
            decode: { data in try decoder.decode(ProgressResponse.self, from: data).progress }
        )
    }
}

extension Request where Response == Void {
    /// Stops a running `rwkvMemorisedHistory`, which saves a checkpoint and
    /// returns "cancelled".
    public static var rwkvCancelMemorised: Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvCancelMemorised,
            bypassesCallLock: true,
            encode: { Data("{}".utf8) },
            decode: { _ in () }
        )
    }
}
