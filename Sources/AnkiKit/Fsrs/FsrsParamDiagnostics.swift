//
//  FsrsParamDiagnostics.swift
//  AnkiKit
//
//  The fork desktop's ts/routes/deck-options/fsrs-param-diagnostics.ts and
//  the optimize error feedback of FsrsOptions.svelte.
//

public import Foundation

/// `fsrsParamDiagnostics`: whether a parameter list can be sent to FSRS.
public struct FsrsParamDiagnostics: Sendable, Hashable {
    public let count: Int
    public let validCount: Bool
    public let outdatedFsrs7PreviewParams: Bool
    public let nonFiniteIndexes: [Int]
    /// The first five non-finite values, as JavaScript's `String` shows them.
    public let nonFiniteValues: [String]
    public let valid: Bool

    /// `VALID_FSRS_PARAM_COUNTS`; 0 means the defaults.
    static let validCounts: Set<Int> = [0, 17, 19, 21, 34]
    static let outdatedFsrs7PreviewParamCount = 35

    /// `OUTDATED_FSRS7_PREVIEW_PARAMS_WARNING`.
    public static let outdatedFsrs7PreviewParamsWarning =
        "These FSRS-7 parameters were produced by an older preview version and have 35 values. Final FSRS-7 uses 34 values. Clear the field and optimize this preset, or run Optimize All Presets."

    public init(_ params: [Float]) {
        let nonFiniteIndexes = params.indices.filter { !params[$0].isFinite }
        count = params.count
        validCount = Self.validCounts.contains(params.count)
        outdatedFsrs7PreviewParams = params.count == Self.outdatedFsrs7PreviewParamCount
        self.nonFiniteIndexes = nonFiniteIndexes
        nonFiniteValues = nonFiniteIndexes.prefix(5).map { Self.javaScriptString(params[$0]) }
        valid = validCount && nonFiniteIndexes.isEmpty
    }

    /// `fsrsParamDiagnosticDetails` (FsrsOptions.svelte).
    public var details: String {
        if outdatedFsrs7PreviewParams {
            return Self.outdatedFsrs7PreviewParamsWarning
        }
        if !validCount {
            return "Expected 0, 17, 19, 21, or 34 values, but found \(count)."
        }
        if !nonFiniteIndexes.isEmpty {
            let positions = nonFiniteIndexes.prefix(5).map { String($0 + 1) }.joined(separator: ", ")
            return "Non-finite value at position \(positions)."
        }
        return ""
    }

    /// `fsrsParamsSupportSameDayEvaluation`: only FSRS-7 parameter sets.
    public static func supportsSameDayEvaluation(_ params: [Float]) -> Bool {
        params.count == 34
    }

    /// `fsrsSameDayEvaluationOverrideForComparison`: same-day targets are
    /// compared only when both parameter sets support them.
    public static func sameDayEvaluationOverrideForComparison(
        current: [Float],
        optimized: [Float],
        requested: Bool?
    ) -> Bool? {
        guard requested == true else { return requested }
        return supportsSameDayEvaluation(current) && supportsSameDayEvaluation(optimized)
    }

    private static func javaScriptString(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return "\(value)"
    }
}

/// `FsrsParamRole`: which side of the optimize comparison failed.
public enum FsrsParamRole: String, Sendable, Hashable {
    case current
    case optimized
}

/// `FsrsOptimizationFeedbackError`: a failure whose message is already the
/// text to show.
public struct FsrsOptimizationFeedbackError: Error, LocalizedError, Sendable, Hashable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The optimize error messages of FsrsOptions.svelte.
public enum FsrsOptimizationFeedback {
    /// `deck-config-invalid-parameters`, the backend's message when FSRS
    /// rejects the parameters.
    public static let invalidParametersMessage =
        "The provided FSRS parameters are invalid. Leave them blank to use the default values."

    /// `isInvalidFsrsParametersError`.
    public static func isInvalidParametersError(_ message: String) -> Bool {
        message.contains(invalidParametersMessage)
    }

    /// `invalidFsrsParamsFeedback`.
    public static func invalidParams(
        role: FsrsParamRole,
        diagnostics: FsrsParamDiagnostics,
        rejectedByBackend: Bool = false
    ) -> String {
        let backendDetail = rejectedByBackend ? "FSRS rejected these parameters during evaluation." : ""
        let reason = [diagnostics.details, backendDetail].filter { !$0.isEmpty }.joined(separator: "\n")
        let roleMessage = switch role {
        case .current:
            "Anki cannot evaluate the current FSRS parameters, so it cannot compare them with the optimized parameters."
        case .optimized:
            "Anki cannot evaluate the optimized FSRS parameters, so it cannot show the optimization comparison."
        }
        var nextStep = "Please report this with the console details."
        if role == .current {
            nextStep = diagnostics.outdatedFsrs7PreviewParams
                ? ""
                : "Leave the FSRS parameters field blank to use the default values, then optimize again."
        }
        return [roleMessage, reason, nextStep, "Details have been logged to the console."]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// `requireValidFsrsParams`.
    public static func requireValid(role: FsrsParamRole, params: [Float]) throws {
        let diagnostics = FsrsParamDiagnostics(params)
        guard !diagnostics.valid else { return }
        throw FsrsOptimizationFeedbackError(invalidParams(role: role, diagnostics: diagnostics))
    }

    /// `optimizationFailureFeedback`. `dynamicDesiredRetentionHint` is the
    /// desktop's "FSRS-7 with Dynamic DR enabled".
    public static func failure(
        _ error: any Error,
        params: [Float],
        dynamicDesiredRetentionHint: Bool
    ) -> String {
        if let feedback = error as? FsrsOptimizationFeedbackError {
            return feedback.message
        }
        let message = error.localizedDescription
        let diagnostics = FsrsParamDiagnostics(params)
        if isInvalidParametersError(message) && !diagnostics.valid {
            return invalidParams(role: .current, diagnostics: diagnostics, rejectedByBackend: true)
        }
        let hint = dynamicDesiredRetentionHint
            ? "\n\nDynamic DR (ADR) is enabled. Try disabling it and optimizing again to check whether it is involved."
            : ""
        return "FSRS optimization failed. Details have been logged to the console.\(hint)\n\n\(message)"
    }
}
