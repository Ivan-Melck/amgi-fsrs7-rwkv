//
//  RwkvCalibrationLiveTests.swift
//  AnkiProtoBridgeTests
//
//  Round trips of the calibration graph's aux requests; the bridge's
//  replay and prediction logic is tested in anki-bridge-rs/src/rwkv/tests.rs.
//

import Foundation
import Testing
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct RwkvCalibrationLiveTests {
    @Test func calibrationData_isEmptyWithoutReviews() throws {
        try withScratchCollection("calibration-empty") { backend, _ in
            let report = try backend.invoke(.rwkvCalibrationData(
                search: "",
                days: 0,
                modelPath: nil,
                cacheDir: nil,
                precision: "int8",
                ensure: true
            ))
            #expect(report.samples.isEmpty)
            #expect(report.count(for: .both) == 0)
            #expect(report.umPlus.count == 0)
        }
    }

    @Test func rebuildFsrsCalibration_storesNothingWithoutReviews() throws {
        try withScratchCollection("calibration-fsrs") { backend, _ in
            #expect(try backend.invoke(.rwkvRebuildFsrsCalibration(clear: true, cacheDir: nil)) == 0)
            let progress = try backend.invoke(.rwkvCalibrationProgress(cancel: false))
            #expect(!progress.running)
        }
    }

    @Test func recomputeCalibration_needsTheModel() throws {
        try withScratchCollection("calibration-model") { backend, _ in
            #expect(throws: (any Error).self) {
                try backend.invoke(.rwkvRecomputeCalibration(
                    modelPath: "/nonexistent/RWKV.bin",
                    cacheDir: nil,
                    precision: "int8"
                ))
            }
        }
    }
}
