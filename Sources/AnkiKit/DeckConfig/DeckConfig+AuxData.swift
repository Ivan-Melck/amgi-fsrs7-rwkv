//
//  DeckConfig+AuxData.swift
//  AnkiKit
//

import Foundation

// Preset settings the JSChoreels/anki fork keeps in the `other` JSON object
// rather than in proto fields. Readers mirror the desktop's
// `ts/routes/deck-options/*-settings.ts` (including legacy keys); setters
// only rewrite `other` when the value actually changes, and keep every
// other key (add-on data included).

public extension DeckConfig.Config {
    /// FSRS-7 optimization includes same-day reviews (default on).
    var fsrs7IncludeSameDayReviews: Bool {
        get {
            let aux = auxData ?? [:]
            return (aux[AuxKey.fsrs7IncludeSameDayOptimize] as? Bool)
                ?? (aux[AuxKey.fsrs7IncludeSameDayEvaluateLegacy] as? Bool)
                ?? true
        }
        set {
            guard var aux = auxData else { return }
            let hasLegacyKey = aux[AuxKey.fsrs7IncludeSameDayEvaluateLegacy] != nil
            guard newValue != fsrs7IncludeSameDayReviews || hasLegacyKey else { return }
            aux.removeValue(forKey: AuxKey.fsrs7IncludeSameDayEvaluateLegacy)
            aux[AuxKey.fsrs7IncludeSameDayOptimize] = newValue
            writeAuxData(aux)
        }
    }

    /// FSRS-7 optimization uses scheduling penalties (default off).
    var fsrs7SchedulingPenaltiesEnabled: Bool {
        get { (auxData?[AuxKey.fsrs7EnableSchedulingPenalties] as? Bool) ?? false }
        set {
            guard var aux = auxData, newValue != fsrs7SchedulingPenaltiesEnabled else { return }
            aux[AuxKey.fsrs7EnableSchedulingPenalties] = newValue
            writeAuxData(aux)
        }
    }

    /// Search used when evaluating parameters; empty means the optimize
    /// search.
    var fsrsEvaluationSearch: String {
        get { (auxData?[AuxKey.fsrsEvaluationSearch] as? String) ?? "" }
        set {
            guard var aux = auxData, newValue != fsrsEvaluationSearch else { return }
            aux[AuxKey.fsrsEvaluationSearch] = newValue
            writeAuxData(aux)
        }
    }

    /// Where intraday learning cards go relative to reviews. Stored as an
    /// int under `jschoreels.deckoptions.intraday_learning_mix`; the legacy
    /// `intraday_learning_before_reviews: true` means before reviews.
    var intradayLearningMix: ReviewMix {
        get {
            let metadata = displayOrderMetadata(auxData ?? [:])
            if let raw = metadata[AuxKey.intradayLearningMix] as? Int,
               let mix = ReviewMix(rawValue: raw) {
                return mix
            }
            let legacyBefore = metadata[AuxKey.intradayLearningMix] == nil
                && (metadata[AuxKey.intradayLearningBeforeReviewsLegacy] as? Bool) == true
            return legacyBefore ? .beforeReviews : .mixWithReviews
        }
        set {
            guard var aux = auxData else { return }
            var metadata = displayOrderMetadata(aux)
            let hasLegacyKey = metadata[AuxKey.intradayLearningBeforeReviewsLegacy] != nil
            guard newValue != intradayLearningMix || hasLegacyKey else { return }
            metadata.removeValue(forKey: AuxKey.intradayLearningBeforeReviewsLegacy)
            metadata[AuxKey.intradayLearningMix] = newValue.rawValue
            aux[AuxKey.displayOrderMetadata] = metadata
            writeAuxData(aux)
        }
    }
}

private enum AuxKey {
    static let fsrs7IncludeSameDayOptimize = "fsrs7IncludeSameDayOptimize"
    static let fsrs7IncludeSameDayEvaluateLegacy = "fsrs7IncludeSameDayEvaluate"
    static let fsrs7EnableSchedulingPenalties = "fsrs7EnableSchedulingPenalties"
    static let fsrsEvaluationSearch = "fsrsEvaluationSearch"
    static let displayOrderMetadata = "jschoreels.deckoptions"
    static let intradayLearningMix = "intraday_learning_mix"
    static let intradayLearningBeforeReviewsLegacy = "intraday_learning_before_reviews"
}

private extension DeckConfig.Config {
    /// `other` parsed as a JSON object; empty data reads as `[:]`. `nil`
    /// when it holds something else, in which case setters leave it alone.
    var auxData: [String: Any]? {
        guard !other.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: other)) as? [String: Any]
    }

    mutating func writeAuxData(_ aux: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: aux, options: [.sortedKeys]) {
            other = data
        }
    }

    func displayOrderMetadata(_ aux: [String: Any]) -> [String: Any] {
        (aux[AuxKey.displayOrderMetadata] as? [String: Any]) ?? [:]
    }
}
