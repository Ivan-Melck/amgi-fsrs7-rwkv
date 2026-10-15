//
//  DynamicDesiredRetentionPolicy.swift
//  AnkiKit
//

import Foundation

/// Port of the fork's desktop `dynamic-desired-retention.ts`: validation,
/// target calibration, cost-weight interpolation and the ADR policy that
/// maps (stability, difficulty, cost weight) to a desired retention. The
/// desktop works in JS doubles on the preset's f32 values, so this does too.
public enum DynamicDesiredRetentionPolicy {
    public static let parameterCount = 15
    public static let weightMin: Double = 0
    public static let weightMax: Double = 1024
    public static let defaultRetentionMin = 0.3
    public static let defaultRetentionMax = 0.995
    static let sMin = 0.0001
    static let sMax: Double = 36500
    static let dMin: Double = 1
    static let dMax: Double = 10

    /// `dynamicDesiredRetentionEnabled`: the switch is on and the preset
    /// holds a usable model.
    public static func isEnabled(_ enabled: Bool, model: FsrsDynamicDesiredRetention) -> Bool {
        let m = model.doubles
        return enabled
            && validPolicyParams(m.params)
            && validCalibration(m.weights, m.avgDrs)
            && validOptionalCalibration(m.fsrsEqWeights, m.fsrsEqDrs)
            && validOptionalFixedTargetCalibration(m.fixedTargetWeights, m.fixedTargetDrs)
            && validRetentionBounds(m.minimum, m.maximum)
    }

    public static func validPolicyParams(_ params: [Double]) -> Bool {
        params.count == parameterCount && params.allSatisfy(\.isFinite)
    }

    public static func validCalibration(_ weights: [Double], _ avgDrs: [Double]) -> Bool {
        weights.count == avgDrs.count
            && weights.count >= 2
            && weights.allSatisfy { $0.isFinite && $0 >= 0 }
            && avgDrs.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    public static func validRetentionBounds(_ retentionMin: Double, _ retentionMax: Double) -> Bool {
        retentionMin.isFinite
            && retentionMax.isFinite
            && retentionMin > 0
            && retentionMin < retentionMax
            && retentionMax < 1
    }

    public static func validOptionalCalibration(_ weights: [Double], _ drs: [Double]) -> Bool {
        weights.isEmpty && drs.isEmpty || validCalibration(weights, drs)
    }

    public static func validFixedTargetCalibration(_ weights: [Double], _ drs: [Double]) -> Bool {
        weights.count == drs.count
            && weights.count >= 1
            && weights.allSatisfy { $0.isFinite && $0 >= 0 }
            && drs.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }

    public static func validOptionalFixedTargetCalibration(_ weights: [Double], _ drs: [Double]) -> Bool {
        weights.isEmpty && drs.isEmpty || validFixedTargetCalibration(weights, drs)
    }

    /// `targetDrCalibration`: fixed-target values win, then the FSRS-7
    /// equivalents, then the average ADR DRs.
    public static func targetCalibration(
        avgWeights: [Double],
        avgDrs: [Double],
        fsrsEqWeights: [Double],
        fsrsEqDrs: [Double],
        fixedTargetWeights: [Double] = [],
        fixedTargetDrs: [Double] = []
    ) -> TargetCalibration {
        if validFixedTargetCalibration(fixedTargetWeights, fixedTargetDrs) {
            return TargetCalibration(
                weights: fixedTargetWeights, drs: fixedTargetDrs,
                label: "Fixed target DR", fixedTarget: true
            )
        }
        if validCalibration(fsrsEqWeights, fsrsEqDrs) {
            return TargetCalibration(
                weights: fsrsEqWeights, drs: fsrsEqDrs,
                label: "FSRS7 Eq. DR", fixedTarget: false
            )
        }
        return TargetCalibration(weights: avgWeights, drs: avgDrs, label: "Avg ADR DR", fixedTarget: false)
    }

    public static func targetCalibration(_ model: FsrsDynamicDesiredRetention) -> TargetCalibration {
        let m = model.doubles
        return targetCalibration(
            avgWeights: m.weights,
            avgDrs: m.avgDrs,
            fsrsEqWeights: m.fsrsEqWeights,
            fsrsEqDrs: m.fsrsEqDrs,
            fixedTargetWeights: m.fixedTargetWeights,
            fixedTargetDrs: m.fixedTargetDrs
        )
    }

    /// `costWeightForAverageDr`: the cost weight whose calibrated DR is
    /// `target`, interpolated in log1p(weight); nil when uncovered.
    public static func costWeight(
        forTarget target: Double,
        weights: [Double],
        drs: [Double],
        fixedTarget: Bool = false,
        retentionMin: Double? = nil
    ) -> Double? {
        guard target.isFinite else { return nil }
        if fixedTarget {
            return costWeightForFixedTarget(target, weights: weights, drs: drs, retentionMin: retentionMin)
        }
        guard validCalibration(weights, drs) else { return nil }
        let calibration = stableSorted(Array(zip(weights, drs))) { $0.0 < $1.0 }
        for i in 0..<(calibration.count - 1) {
            let left = calibration[i]
            let right = calibration[i + 1]
            if (left.1 - target) * (right.1 - target) > 0 {
                continue
            }
            if abs(left.1 - right.1) < Double.ulpOfOne {
                return left.0
            }
            let t = clamp((target - left.1) / (right.1 - left.1), 0, 1)
            let leftLog = log1p(left.0)
            let rightLog = log1p(right.0)
            return expm1(leftLog + (rightLog - leftLog) * t)
        }
        return nil
    }

    /// `costWeightForFixedTargetDr`: the weight of the first point whose DR
    /// covers `target`.
    static func costWeightForFixedTarget(
        _ target: Double,
        weights: [Double],
        drs: [Double],
        retentionMin: Double?
    ) -> Double? {
        guard validFixedTargetCalibration(weights, drs) else { return nil }
        if let retentionMin, target < retentionMin && !close(target, retentionMin) {
            return nil
        }
        let calibration = stableSorted(Array(zip(weights, drs))) { $0.1 < $1.1 }
        return calibration.first { target <= $0.1 || close(target, $0.1) }?.0
    }

    /// `supportedTargetRange`.
    public static func supportedTargetRange(
        weights: [Double],
        drs: [Double],
        fixedTarget: Bool = false,
        retentionMin: Double? = nil
    ) -> ClosedRangeValues? {
        if fixedTarget {
            guard validFixedTargetCalibration(weights, drs) else { return nil }
            return ClosedRangeValues(min: retentionMin ?? jsMin(drs), max: jsMax(drs))
        }
        guard validCalibration(weights, drs) else { return nil }
        return drs.reduce(ClosedRangeValues(min: drs[0], max: drs[0])) { range, target in
            ClosedRangeValues(min: jsMin([range.min, target]), max: jsMax([range.max, target]))
        }
    }

    /// `schedulingTargetDr`: with clamping on, an uncovered target is
    /// clamped into the calibrated range.
    public static func schedulingTarget(
        _ target: Double,
        weights: [Double],
        drs: [Double],
        clampTarget: Bool,
        fixedTarget: Bool = false,
        retentionMin: Double? = nil
    ) -> Double {
        if !clampTarget
            || costWeight(forTarget: target, weights: weights, drs: drs, fixedTarget: fixedTarget, retentionMin: retentionMin) != nil {
            return target
        }
        guard let range = supportedTargetRange(weights: weights, drs: drs, fixedTarget: fixedTarget, retentionMin: retentionMin) else {
            return target
        }
        return clamp(target, range.min, range.max)
    }

    /// `evaluateDynamicDesiredRetention`.
    public static func evaluate(
        params: [Double],
        stability: Double,
        difficulty: Double,
        costWeight: Double,
        retentionMin: Double = defaultRetentionMin,
        retentionMax: Double = defaultRetentionMax
    ) -> Double {
        let phi = stateFeatures(stability: stability, difficulty: difficulty)
        let z = normalizedCostWeight(costWeight)
        let base = dot(Array(params.prefix(5)), phi)
        let zEffect = softplus(dot(Array(params.dropFirst(5).prefix(5)), phi)) * z
        let z2Effect = softplus(dot(Array(params.dropFirst(10).prefix(5)), phi)) * z * z
        return retentionMin + (retentionMax - retentionMin) * sigmoid(base - zEffect - z2Effect)
    }

    static func stateFeatures(stability: Double, difficulty: Double) -> [Double] {
        let s = clamp(stability, sMin, sMax)
        let d = clamp(difficulty, dMin, dMax)
        let logSMin = log(sMin)
        let logSSpan = log(sMax) - logSMin
        let xS = clamp((log(s) - logSMin) / logSSpan, 0, 1)
        let xD = clamp((d - dMin) / (dMax - dMin), 0, 1)
        return [1, xS, xD, xS * xD, xS * xS]
    }

    static func normalizedCostWeight(_ costWeight: Double) -> Double {
        let weight = clamp(costWeight, weightMin, weightMax)
        let lo = log1p(weightMin)
        let hi = log1p(weightMax)
        return clamp((log1p(weight) - lo) / (hi - lo), 0, 1)
    }

    /// JS `reduce` over `lhs`: a missing `rhs` entry is `undefined`, i.e. NaN.
    static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        lhs.enumerated().reduce(0) { total, item in
            total + item.element * (item.offset < rhs.count ? rhs[item.offset] : .nan)
        }
    }

    static func sigmoid(_ value: Double) -> Double {
        if value >= 0 {
            let z = exp(-value)
            return 1 / (1 + z)
        }
        let z = exp(value)
        return z / (1 + z)
    }

    static func softplus(_ value: Double) -> Double {
        if value > 20 {
            return value
        } else if value < -20 {
            return exp(value)
        }
        return log1p(exp(value))
    }

    /// `Math.min(max, Math.max(min, value))`, NaN-propagating like JS.
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        jsMin([upper, jsMax([lower, value])])
    }

    static func close(_ left: Double, _ right: Double) -> Bool {
        let scale = jsMax([abs(left), abs(right), 1])
        return abs(left - right) <= 1e-6 * scale
    }

    /// `Math.min(...values)`: NaN if any value is NaN.
    static func jsMin(_ values: [Double]) -> Double {
        values.reduce(Double.infinity) { $0.isNaN || $1.isNaN ? .nan : Swift.min($0, $1) }
    }

    /// `Math.max(...values)`: NaN if any value is NaN.
    static func jsMax(_ values: [Double]) -> Double {
        values.reduce(-Double.infinity) { $0.isNaN || $1.isNaN ? .nan : Swift.max($0, $1) }
    }

    /// `Array.prototype.sort`, which is stable.
    static func stableSorted<T>(_ values: [T], by less: (T, T) -> Bool) -> [T] {
        values.enumerated()
            .sorted { less($0.element, $1.element) || !less($1.element, $0.element) && $0.offset < $1.offset }
            .map(\.element)
    }
}

extension DynamicDesiredRetentionPolicy {
    /// Result of `targetDrCalibration`.
    public struct TargetCalibration: Sendable, Equatable {
        public var weights: [Double]
        public var drs: [Double]
        public var label: String
        public var fixedTarget: Bool

        public init(weights: [Double], drs: [Double], label: String, fixedTarget: Bool) {
            self.weights = weights
            self.drs = drs
            self.label = label
            self.fixedTarget = fixedTarget
        }

        /// The modal's `hasTargetCalibration`.
        public var isValid: Bool {
            fixedTarget
                ? DynamicDesiredRetentionPolicy.validFixedTargetCalibration(weights, drs)
                : DynamicDesiredRetentionPolicy.validCalibration(weights, drs)
        }
    }

    public struct ClosedRangeValues: Sendable, Equatable {
        public var min: Double
        public var max: Double

        public init(min: Double, max: Double) {
            self.min = min
            self.max = max
        }
    }

    /// What `FsrsOptions.svelte` derives for its Dynamic DR row: the cost
    /// weight for the effective DR, whether "Visualize DR plot" is enabled,
    /// and the warning.
    public struct Status: Sendable, Equatable {
        public var weight: Double?
        public var ready: Bool
        public var warning: String
        public var retentionMin: Double
        public var retentionMax: Double

        /// `formatDynamicDrBound`.
        public static func formatBound(_ value: Double) -> String {
            value.isFinite ? "\(DynamicDesiredRetentionPolicy.toFixed(value * 100, 1))%" : "n/a"
        }
    }

    /// `dynamicDesiredRetentionSchedulingTarget`, `...Weight`, `...Ready`
    /// and `dynamicDesiredRetentionWarningMessage`.
    public static func status(
        enabled: Bool,
        clamp clampTarget: Bool,
        model: FsrsDynamicDesiredRetention,
        effectiveDesiredRetention: Double
    ) -> Status {
        let m = model.doubles
        let calibration = targetCalibration(model)
        let target = schedulingTarget(
            effectiveDesiredRetention,
            weights: calibration.weights,
            drs: calibration.drs,
            clampTarget: clampTarget,
            fixedTarget: calibration.fixedTarget,
            retentionMin: m.minimum
        )
        let weight = costWeight(
            forTarget: target,
            weights: calibration.weights,
            drs: calibration.drs,
            fixedTarget: calibration.fixedTarget,
            retentionMin: m.minimum
        )
        let configReady = isEnabled(enabled, model: model)
        var warning = ""
        if enabled {
            if !validPolicyParams(m.params)
                || !validCalibration(m.weights, m.avgDrs)
                || !validOptionalFixedTargetCalibration(m.fixedTargetWeights, m.fixedTargetDrs) {
                warning = "Dynamic DR requires 15 ADR policy parameters and matching calibration arrays."
            } else if !validRetentionBounds(m.minimum, m.maximum) {
                warning = "Dynamic DR requires valid retention bounds."
            } else if configReady && weight == nil {
                warning = "Dynamic DR target is outside the calibrated target range."
            }
        }
        return Status(
            weight: weight,
            ready: configReady && weight != nil,
            warning: warning,
            retentionMin: m.minimum,
            retentionMax: m.maximum
        )
    }
}

extension DynamicDesiredRetentionPolicy {
    /// JS `Number.prototype.toFixed`: rounds the exact binary value, and an
    /// exact tie goes up (unlike `%f`, which rounds ties to even).
    public static func toFixed(_ value: Double, _ digits: Int) -> String {
        if value.isNaN { return "NaN" }
        if value < 0 { return "-" + toFixed(-value, digits) }
        if value.isInfinite { return "Infinity" }
        let expanded = String(format: "%.\(digits + 30)f", value)
        let parts = expanded.split(separator: ".", omittingEmptySubsequences: false)
        var kept = Array(parts[0]) + Array(parts.count > 1 ? parts[1].prefix(digits) : "")
        let next = parts.count > 1 ? parts[1].dropFirst(digits).first : nil
        if let next, next >= "5" {
            var index = kept.count - 1
            while index >= 0 {
                if kept[index] == "9" {
                    kept[index] = "0"
                    index -= 1
                } else {
                    kept[index] = Character(String(kept[index].wholeNumberValue! + 1))
                    break
                }
            }
            if index < 0 { kept.insert("1", at: 0) }
        }
        let intCount = kept.count - digits
        let intPart = String(kept.prefix(intCount))
        return digits == 0 ? intPart : intPart + "." + String(kept.suffix(digits))
    }
}

extension FsrsDynamicDesiredRetention {
    /// The model as the JS numbers the desktop reads from the proto.
    struct Doubles {
        var params: [Double]
        var weights: [Double]
        var avgDrs: [Double]
        var minimum: Double
        var maximum: Double
        var fsrsEqWeights: [Double]
        var fsrsEqDrs: [Double]
        var fixedTargetWeights: [Double]
        var fixedTargetDrs: [Double]
    }

    var doubles: Doubles {
        Doubles(
            params: params.map(Double.init),
            weights: weights.map(Double.init),
            avgDrs: avgDrs.map(Double.init),
            minimum: Double(minimum),
            maximum: Double(maximum),
            fsrsEqWeights: fsrsEqWeights.map(Double.init),
            fsrsEqDrs: fsrsEqDrs.map(Double.init),
            fixedTargetWeights: fixedTargetWeights.map(Double.init),
            fixedTargetDrs: fixedTargetDrs.map(Double.init)
        )
    }
}
