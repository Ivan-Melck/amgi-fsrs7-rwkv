//
//  FsrsDynamicDesiredRetention.swift
//  AnkiKit
//

/// The Dynamic Desired Retention (ADR) model the JSChoreels/anki fork's
/// FSRS-7 optimizer fits alongside the parameters. Stored per preset in
/// `DeckConfig.Config` (proto fields 56-62, 64-65) and returned by
/// `computeFsrsParams`; the values are opaque to the app, which only
/// copies them from the optimizer result into the preset.
public struct FsrsDynamicDesiredRetention: Sendable, Hashable {
    public var params: [Float]
    public var weights: [Float]
    public var avgDrs: [Float]
    public var minimum: Float
    public var maximum: Float
    public var fsrsEqWeights: [Float]
    public var fsrsEqDrs: [Float]
    public var fixedTargetWeights: [Float]
    public var fixedTargetDrs: [Float]

    public init(
        params: [Float] = [],
        weights: [Float] = [],
        avgDrs: [Float] = [],
        minimum: Float = 0,
        maximum: Float = 0,
        fsrsEqWeights: [Float] = [],
        fsrsEqDrs: [Float] = [],
        fixedTargetWeights: [Float] = [],
        fixedTargetDrs: [Float] = []
    ) {
        self.params = params
        self.weights = weights
        self.avgDrs = avgDrs
        self.minimum = minimum
        self.maximum = maximum
        self.fsrsEqWeights = fsrsEqWeights
        self.fsrsEqDrs = fsrsEqDrs
        self.fixedTargetWeights = fixedTargetWeights
        self.fixedTargetDrs = fixedTargetDrs
    }

    /// `true` when the optimizer produced no model (ADR off, or too little
    /// history).
    public var isEmpty: Bool { params.isEmpty }
}
