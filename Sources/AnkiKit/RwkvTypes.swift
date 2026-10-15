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
