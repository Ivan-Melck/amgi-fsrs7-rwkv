//
//  RwkvTypes.swift
//  AnkiKit
//
//  RWKV scheduling for the FSRS7/RWKV Anki fork (anki-bridge-rs/src/rwkv).
//

/// Outcome of preparing the RWKV engine for the open collection.
public struct RwkvPrepareResult: Sendable, Hashable {
    /// Some deck preset uses RWKV-Curve or RWKV-Instant.
    public let active: Bool
    /// The model's state matches the collection's review history.
    public let ready: Bool
    /// How that state was obtained: "resident", "revalidated", "restored",
    /// "restored+suffix", "suffix", "replayed" or "inactive".
    public let source: String

    public init(active: Bool, ready: Bool, source: String) {
        self.active = active
        self.ready = ready
        self.source = source
    }
}

/// One row of RWKV Card Info, labelled as on the desktop.
public struct RwkvCardInfoRow: Sendable, Hashable, Identifiable {
    public let label: String
    public let value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Outcome of rescheduling review cards with RWKV-Curve.
public struct RwkvRescheduleResult: Sendable, Hashable {
    /// False when the model state couldn't be prepared.
    public let built: Bool
    public let predicted: Int
    public let updated: Int

    public init(built: Bool, predicted: Int, updated: Int) {
        self.built = built
        self.predicted = predicted
        self.updated = updated
    }
}

/// The deck options' "Compare RWKV with FSRS": the RWKV side of a workload
/// sweep, from the same settings as the FSRS simulator's.
public struct RwkvWorkloadRequest: Sendable, Hashable {
    public var search: String
    public var daysToSimulate: Int
    public var reviewLimit: Int
    public var newLimit: Int
    public var newCardsIgnoreReviewLimit: Bool
    public var maxInterval: Int
    public var reviewOrder: ReviewCardOrder
    public var suspendAfterLapseCount: Int?
    /// 0 simulates every card; the comparison does, as on the desktop.
    public var sampleLimit = 0
    public var targetStep = 1
    public var stateUpdateInterval = 1

    public init(
        search: String,
        daysToSimulate: Int,
        reviewLimit: Int,
        newLimit: Int,
        newCardsIgnoreReviewLimit: Bool,
        maxInterval: Int,
        reviewOrder: ReviewCardOrder,
        suspendAfterLapseCount: Int?
    ) {
        self.search = search
        self.daysToSimulate = daysToSimulate
        self.reviewLimit = reviewLimit
        self.newLimit = newLimit
        self.newCardsIgnoreReviewLimit = newCardsIgnoreReviewLimit
        self.maxInterval = maxInterval
        self.reviewOrder = reviewOrder
        self.suspendAfterLapseCount = suspendAfterLapseCount
    }
}
