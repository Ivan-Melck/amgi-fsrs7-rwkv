//
//  RwkvCalibrationRequests.swift
//  AnkiProtoBridge
//
//  The calibration graph's data (anki-bridge-rs/src/rwkv/calibration.rs):
//  the deck options' Calculate Calibration Graph Data and Build Cache
//  steps, and the stats screen's read for a search. JSON over the aux
//  service, like the other RWKV requests.
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

private struct ModelBody: Encodable {
    let modelPath: String
    let cacheDir: String?
    let precision: String
}

private struct RecomputeResponse: Decodable {
    let recomputed: Bool
    let reviews: Int
}

private struct RebuildFsrsBody: Encodable {
    let clear: Bool
    let cacheDir: String?
}

private struct RebuildFsrsResponse: Decodable {
    let predictions: Int
}

private struct CalibrationDataBody: Encodable {
    let search: String
    let dayRange: UInt32
    let modelPath: String?
    let cacheDir: String?
    let precision: String
    let ensure: Bool
}

private struct CalibrationDataResponse: Decodable {
    let sampleRevlogIds: [Int64]
    let sampleCardIds: [Int64]
    let sampleActual: [UInt8]
    let fsrsRevlogIds: [Int64]
    let fsrsPredictions: [Double]
    let rwkvRevlogIds: [Int64]
    let rwkvPredictions: [Double]
    let rwkvWarnings: [String]
}

private struct ProgressBody: Encodable {
    let cancel: Bool
}

private struct ProgressResponse: Decodable {
    let running: Bool
    let label: String
    let current: Int
    let total: Int
}

extension Request where Response == RwkvCalibrationRecomputeResult {
    /// "Calculate Calibration Graph Data": replays the whole history on a
    /// temporary state, recording every review's RWKV prediction under its
    /// FSRS-aligned fold. Long-running; see `rwkvCalibrationProgress`.
    public static func rwkvRecomputeCalibration(modelPath: String, cacheDir: String?, precision: String) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvRecomputeCalibration,
            bypassesCallLock: true,
            encode: { try encoder.encode(ModelBody(modelPath: modelPath, cacheDir: cacheDir, precision: precision)) },
            decode: { data in
                let response = try decoder.decode(RecomputeResponse.self, from: data)
                return RwkvCalibrationRecomputeResult(recomputed: response.recomputed, reviews: response.reviews)
            }
        )
    }
}

extension Request where Response == Int {
    /// Build Cache's FSRS step: optionally clears both prediction caches,
    /// then rebuilds FSRS's historical predictions and validation folds for
    /// every preset. Returns the predictions stored.
    public static func rwkvRebuildFsrsCalibration(clear: Bool, cacheDir: String?) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvRebuildFsrsCalibration,
            bypassesCallLock: true,
            encode: { try encoder.encode(RebuildFsrsBody(clear: clear, cacheDir: cacheDir)) },
            decode: { data in try decoder.decode(RebuildFsrsResponse.self, from: data).predictions }
        )
    }
}

extension Request where Response == CalibrationReport {
    /// The calibration and UM+ graphs' data for `search` over the last
    /// `days` (0: all history), binned with bootstrap intervals. With
    /// `ensure` and a model, missing RWKV data is generated first, as the
    /// desktop add-on does (long-running).
    public static func rwkvCalibrationData(
        search: String,
        days: Int,
        modelPath: String?,
        cacheDir: String?,
        precision: String,
        ensure: Bool
    ) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvCalibrationData,
            bypassesCallLock: true,
            encode: {
                try encoder.encode(CalibrationDataBody(
                    search: search,
                    dayRange: UInt32(clamping: max(0, days)),
                    modelPath: modelPath,
                    cacheDir: cacheDir,
                    precision: precision,
                    ensure: ensure
                ))
            },
            decode: { data in
                let response = try decoder.decode(CalibrationDataResponse.self, from: data)
                let samples = zip(zip(response.sampleRevlogIds, response.sampleCardIds), response.sampleActual)
                    .map { ids, actual in
                        CalibrationSample(revlogId: ids.0, cardId: ids.1, actual: Double(actual))
                    }
                return CalibrationReport(
                    samples: samples,
                    fsrsPredictions: Dictionary(
                        zip(response.fsrsRevlogIds, response.fsrsPredictions),
                        uniquingKeysWith: { _, last in last }
                    ),
                    rwkvPredictions: Dictionary(
                        zip(response.rwkvRevlogIds, response.rwkvPredictions),
                        uniquingKeysWith: { _, last in last }
                    ),
                    rwkvWarnings: response.rwkvWarnings
                )
            }
        )
    }
}

extension Request where Response == RwkvCalibrationProgress {
    /// The running recompute or FSRS rebuild's progress; `cancel` stops it.
    /// Answers while those run.
    public static func rwkvCalibrationProgress(cancel: Bool) -> Self {
        Self(
            serviceId: ServiceID.aux,
            methodId: AuxMethod.rwkvCalibrationProgress,
            bypassesCallLock: true,
            encode: { try encoder.encode(ProgressBody(cancel: cancel)) },
            decode: { data in
                let response = try decoder.decode(ProgressResponse.self, from: data)
                return RwkvCalibrationProgress(
                    running: response.running,
                    label: response.label,
                    current: response.current,
                    total: response.total
                )
            }
        )
    }
}
