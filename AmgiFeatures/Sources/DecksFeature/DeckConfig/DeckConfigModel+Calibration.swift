//
//  DeckConfigModel+Calibration.swift
//  DecksFeature
//
//  The RWKV options' "Calculate Calibration Graph Data"
//  (`recompute_rwkv_calibration_data_with_progress` in the fork's
//  rwkv_scheduler.py) and the progress its maintenance steps report.
//

import AnkiClients
import AnkiKit
import Foundation

extension DeckConfigModel {
    /// The desktop's `rwkvActionInProgress`.
    var isRwkvMaintenanceRunning: Bool {
        isRebuildingRwkvState || isRecomputingRwkvCalibration
    }

    /// Rewrites RWKV's historical predictions for the calibration graph,
    /// keeping the resident state. Saves the options first.
    func recomputeRwkvCalibration() async {
        if hasUnsavedChanges {
            guard !isFallbackContext, await saveConfig() else { return }
            await loadConfig()
        }
        isRecomputingRwkvCalibration = true
        let polling = pollRwkvCalibrationProgress()
        defer {
            polling.cancel()
            rwkvCalibrationProgress = nil
            isRecomputingRwkvCalibration = false
        }
        do {
            let result = try await rwkvClient.recomputeCalibration()
            // Cancelled: nothing to report.
            guard result.recomputed else { return }
            destination = .alert(.notice(
                title: "RWKV Calibration Data",
                message: "RWKV calibration data recomputed."
            ))
        } catch {
            destination = .alert(.fsrsError(
                title: "RWKV Calibration Data",
                message: "RWKV calibration data recompute failed.\n\n\(error.localizedDescription)"
            ))
        }
    }

    func cancelRwkvCalibration() {
        Task { await rwkvClient.cancelCalibration() }
    }

    /// Mirrors the bridge's progress into `rwkvCalibrationProgress` until
    /// cancelled.
    func pollRwkvCalibrationProgress() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let client = self?.rwkvClient else { return }
                let progress = await client.calibrationProgress()
                guard !Task.isCancelled else { return }
                self?.rwkvCalibrationProgress = progress?.running == true ? progress : nil
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
