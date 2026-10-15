//
//  FsrsComputeProgress.swift
//  AnkiKit
//
//  The backend's `ComputeParamsProgress` while FSRS parameters are fitted or
//  evaluated, shown as the desktop's deck options show it (FsrsOptions.svelte
//  `renderWeightProgress` / `renderComputeParamsProgressPct`).
//

public struct FsrsComputeProgress: Sendable, Hashable {
    public var current: Int
    public var total: Int
    /// Training targets the optimizer uses.
    public var reviews: Int
    /// `Phase.TRAINING_DYNAMIC_DESIRED_RETENTION`.
    public var isTrainingDynamicDesiredRetention: Bool

    public init(current: Int, total: Int, reviews: Int, isTrainingDynamicDesiredRetention: Bool = false) {
        self.current = current
        self.total = total
        self.reviews = reviews
        self.isTrainingDynamicDesiredRetention = isTrainingDynamicDesiredRetention
    }

    /// `renderComputeParamsProgressPct`: nil until the total is known.
    public var percent: Double? {
        guard total != 0 else { return nil }
        return min(100, max(0, Double(current) / Double(total) * 100))
    }

    /// `renderWeightProgress`; empty until the total is known.
    public var text: String {
        guard let percent else { return "" }
        let pct = JSNumberFormat.toFixed(percent, 1)
        if isTrainingDynamicDesiredRetention {
            return "Compute ADR values: \(pct)%"
        }
        if current == total {
            // deck-config-checking-for-improvement
            return "Checking for improvement..."
        }
        // deck-config-percent-of-reviews
        return "\(pct)% of \(reviews) review\(reviews == 1 ? "" : "s")"
    }

    /// `statistics-reviews`, shown once a job has finished.
    public var reviewsText: String {
        "\(reviews) review\(reviews == 1 ? "" : "s")"
    }
}
