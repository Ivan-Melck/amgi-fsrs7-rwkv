//
//  CalibrationFixtures.swift
//  AnkiKit
//
//  Sample calibration data for the stats `#Preview` blocks. Deterministic,
//  and gated like StatsFixtures.swift.
//

#if DEBUG && canImport(SwiftUI)
extension CalibrationReport {
    /// 600 cards with 1–4 reviews each; FSRS slightly overconfident, RWKV
    /// slightly underconfident.
    public static let sample: CalibrationReport = {
        var samples: [CalibrationSample] = []
        var fsrs: [Int64: Double] = [:]
        var rwkv: [Int64: Double] = [:]
        var id: Int64 = 1
        for card in 0..<600 {
            for review in 0..<(1 + card % 4) {
                let truth = 0.35 + Double((card * 37 + review * 11) % 64) / 100
                let recalled = Double((card * 7 + review * 13) % 100) / 100 < truth
                samples.append(CalibrationSample(revlogId: id, cardId: Int64(card), actual: recalled ? 1 : 0))
                fsrs[id] = min(1, truth + 0.03)
                rwkv[id] = max(0, truth - 0.01)
                id += 1
            }
        }
        return CalibrationReport(samples: samples, fsrsPredictions: fsrs, rwkvPredictions: rwkv)
    }()
}
#endif
