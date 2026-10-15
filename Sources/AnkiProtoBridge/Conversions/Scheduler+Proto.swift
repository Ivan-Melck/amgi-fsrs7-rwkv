//
//  Scheduler+Proto.swift
//  AnkiProtoBridge
//
//  Created by Vladimir Gusev on 12.05.2026.
//

package import AnkiKit
package import AnkiProto
import Foundation

// MARK: - Rating

package func protoRating(_ rating: Rating) -> Anki_Scheduler_CardAnswer.Rating {
    switch rating {
    case .again: .again
    case .hard:  .hard
    case .good:  .good
    case .easy:  .easy
    }
}

// MARK: - CardRecord

package extension CardRecord {
    init(_ proto: Anki_Cards_Card) {
        self.init(
            id: CardID(proto.id),
            nid: NoteID(proto.noteID),
            did: DeckID(proto.deckID),
            ord: Int32(proto.templateIdx),
            mod: proto.mtimeSecs,
            usn: proto.usn,
            type: Int16(proto.ctype),
            queue: Int16(proto.queue),
            due: proto.due,
            ivl: Int32(proto.interval),
            factor: Int32(proto.easeFactor),
            reps: Int32(proto.reps),
            lapses: Int32(proto.lapses),
            left: Int32(proto.remainingSteps),
            odue: proto.originalDue,
            odid: DeckID(proto.originalDeckID),
            flags: Int32(proto.flags),
            data: proto.customData
        )
    }
}

extension CardRecord: BridgeDecodable {
    package typealias Proto = Anki_Cards_Card
}

// MARK: - SchedulingState seconds

package func scheduledSecs(_ state: Anki_Scheduler_SchedulingState) -> UInt32 {
    switch state.kind {
    case .normal(let n):
        return normalScheduledSecs(n)
    case .filtered(let f):
        switch f.kind {
        case .rescheduling(let r): return normalScheduledSecs(r.originalState)
        case .preview(let p):      return p.scheduledSecs
        case .none:                return 0
        }
    case .none:
        return 0
    }
}

package func normalScheduledSecs(_ normal: Anki_Scheduler_SchedulingState.Normal) -> UInt32 {
    switch normal.kind {
    case .new: return 0
    case .learning(let s):  return s.scheduledSecs
    case .review(let s):    return s.scheduledDays * 86400
    case .relearning(let s): return s.learning.scheduledSecs
    case .none: return 0
    }
}

// MARK: - Fuzz delta

/// " (+2d)" for a Review state whose interval was fuzzed by 2 days, as the
/// FSRS7/RWKV fork's desktop shows next to the answer buttons when
/// "Show fuzz delta next to answer button intervals" is on; empty otherwise.
package func fuzzDeltaSuffix(_ state: Anki_Scheduler_SchedulingState) -> String {
    let review: Anki_Scheduler_SchedulingState.Review? = switch state.kind {
    case .normal(let n):
        if case .review(let r) = n.kind { r } else { nil }
    case .filtered(let f):
        if case .rescheduling(let r) = f.kind, case .review(let review) = r.originalState.kind {
            review
        } else {
            nil
        }
    case .none:
        nil
    }
    guard let delta = review?.fuzzDeltaDays, delta != 0 else { return "" }
    return " (\(delta > 0 ? "+" : "")\(delta)d)"
}

/// The answer button label for a state.
package func intervalLabel(_ state: Anki_Scheduler_SchedulingState, showFuzzDelta: Bool) -> String {
    formatInterval(scheduledSecs(state)) + (showFuzzDelta ? fuzzDeltaSuffix(state) : "")
}

// MARK: - Interval formatting

package func formatInterval(_ secs: UInt32) -> String {
    if secs < 60 { return "\(secs)s" }
    let mins = secs / 60
    if mins < 60 { return "\(mins)m" }
    let hours = mins / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    let years = Double(days) / 365.0
    return String(format: "%.1fy", years)
}
