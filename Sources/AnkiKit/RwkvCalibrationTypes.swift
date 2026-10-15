//
//  RwkvCalibrationTypes.swift
//  AnkiKit
//
//  Results of the calibration graph's data operations
//  (anki-bridge-rs/src/rwkv/calibration.rs).
//

/// Outcome of "Calculate Calibration Graph Data".
public struct RwkvCalibrationRecomputeResult: Sendable, Hashable {
    /// False when it was cancelled.
    public let recomputed: Bool
    /// Reviews whose predictions were recorded.
    public let reviews: Int

    public init(recomputed: Bool, reviews: Int) {
        self.recomputed = recomputed
        self.reviews = reviews
    }
}

/// A running calibration operation, as the desktop's progress dialog shows
/// it: a label, and while replaying a count.
public struct RwkvCalibrationProgress: Sendable, Hashable {
    public let running: Bool
    public let label: String
    public let current: Int
    public let total: Int

    public init(running: Bool, label: String, current: Int, total: Int) {
        self.running = running
        self.label = label
        self.current = current
        self.total = total
    }

    /// `current / total`, when there is a count.
    public var fraction: Double? {
        total > 0 ? Double(min(current, total)) / Double(total) : nil
    }
}
