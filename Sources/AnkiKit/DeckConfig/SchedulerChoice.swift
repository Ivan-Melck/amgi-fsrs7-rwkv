//
//  SchedulerChoice.swift
//  AnkiKit
//

// Scheduler selection for JSChoreels/anki fork presets. A preset stores
// three independent fields — `fsrsVersion`, `rwkvReviewEnabled`
// (RWKV-Curve) and `rwkvReviewInstantOrderEnabled` (RWKV-Instant) — and the
// desktop UI presents them as one "Review scheduler" choice plus a
// "Fallback" due-date calculator for Instant. The mapping below mirrors
// the fork's `ts/routes/deck-options/scheduler-choice.ts`.

/// A review scheduler a preset can use.
public enum SchedulerChoice: String, Sendable, Hashable, CaseIterable {
    case fsrs4
    case fsrs5
    case fsrs6
    case fsrs7
    case rwkvCurve
    case rwkvInstant

    /// Choices for the "Fallback" due-date calculator shown under
    /// RWKV-Instant. FSRS-4/5 are legacy and only shown when in use.
    public static let dueDateChoices: [SchedulerChoice] = [.fsrs6, .fsrs7, .rwkvCurve]

    /// Choices for the "Review scheduler" picker.
    public static let reviewChoices: [SchedulerChoice] = SchedulerChoice.dueDateChoices + [.rwkvInstant]

    public var title: String {
        switch self {
        case .fsrs4: "FSRS-4"
        case .fsrs5: "FSRS-5"
        case .fsrs6: "FSRS-6"
        case .fsrs7: "FSRS-7"
        case .rwkvCurve: "RWKV-Curve"
        case .rwkvInstant: "RWKV-Instant"
        }
    }

    /// The FSRS generation this choice selects; `nil` for the RWKV choices,
    /// which leave the preset's `fsrsVersion` untouched.
    public var fsrsVersion: FsrsVersion? {
        switch self {
        case .fsrs4: .four
        case .fsrs5: .five
        case .fsrs6: .six
        case .fsrs7: .seven
        case .rwkvCurve, .rwkvInstant: nil
        }
    }
}

/// The three preset fields that together pick the scheduler.
public struct SchedulerSelection: Sendable, Hashable {
    public var fsrsVersion: FsrsVersion
    public var rwkvReviewEnabled: Bool
    public var rwkvReviewInstantOrderEnabled: Bool

    public init(
        fsrsVersion: FsrsVersion = .seven,
        rwkvReviewEnabled: Bool = false,
        rwkvReviewInstantOrderEnabled: Bool = false
    ) {
        self.fsrsVersion = fsrsVersion
        self.rwkvReviewEnabled = rwkvReviewEnabled
        self.rwkvReviewInstantOrderEnabled = rwkvReviewInstantOrderEnabled
    }

    /// The scheduler that writes due dates: RWKV-Curve when enabled, else
    /// the preset's FSRS version.
    public var dueDateScheduler: SchedulerChoice {
        if rwkvReviewEnabled { return .rwkvCurve }
        switch fsrsVersion {
        case .four: return .fsrs4
        case .five: return .fsrs5
        case .six: return .fsrs6
        case .seven: return .fsrs7
        }
    }

    /// The scheduler that picks reviews: RWKV-Instant when enabled, else
    /// the due-date scheduler.
    public var scheduler: SchedulerChoice {
        rwkvReviewInstantOrderEnabled ? .rwkvInstant : dueDateScheduler
    }

    /// Whether either RWKV mode is in use.
    public var usesRwkv: Bool {
        rwkvReviewEnabled || rwkvReviewInstantOrderEnabled
    }

    /// Sets the due-date scheduler, keeping the Instant flag. RWKV-Curve
    /// leaves `fsrsVersion` untouched; `.rwkvInstant` is not a due-date
    /// scheduler and changes nothing.
    public func withDueDateScheduler(_ choice: SchedulerChoice) -> SchedulerSelection {
        guard choice != .rwkvInstant else { return self }
        var updated = self
        updated.rwkvReviewEnabled = choice == .rwkvCurve
        if let version = choice.fsrsVersion {
            updated.fsrsVersion = version
        }
        return updated
    }

    /// Sets the review scheduler. Instant keeps the current due-date
    /// scheduler as its fallback; any other choice also becomes the
    /// due-date scheduler and turns Instant off.
    public func withScheduler(_ choice: SchedulerChoice) -> SchedulerSelection {
        var updated = choice == .rwkvInstant ? self : withDueDateScheduler(choice)
        updated.rwkvReviewInstantOrderEnabled = choice == .rwkvInstant
        return updated
    }
}

public extension DeckConfig.Config {
    var schedulerSelection: SchedulerSelection {
        get {
            SchedulerSelection(
                fsrsVersion: fsrsVersion,
                rwkvReviewEnabled: rwkvReviewEnabled,
                rwkvReviewInstantOrderEnabled: rwkvReviewInstantOrderEnabled
            )
        }
        set {
            fsrsVersion = newValue.fsrsVersion
            rwkvReviewEnabled = newValue.rwkvReviewEnabled
            rwkvReviewInstantOrderEnabled = newValue.rwkvReviewInstantOrderEnabled
        }
    }

    func withScheduler(_ choice: SchedulerChoice) -> Self {
        var updated = self
        updated.schedulerSelection = schedulerSelection.withScheduler(choice)
        return updated
    }

    func withDueDateScheduler(_ choice: SchedulerChoice) -> Self {
        var updated = self
        updated.schedulerSelection = schedulerSelection.withDueDateScheduler(choice)
        return updated
    }

    /// The parameter array the backend reads for `version`.
    func fsrsParams(for version: FsrsVersion) -> [Float] {
        switch version {
        case .seven: fsrsParams7
        case .six: fsrsParams6
        case .five: fsrsParams5
        case .four: fsrsParams4
        }
    }

    mutating func setFsrsParams(_ params: [Float], for version: FsrsVersion) {
        switch version {
        case .seven: fsrsParams7 = params
        case .six: fsrsParams6 = params
        case .five: fsrsParams5 = params
        case .four: fsrsParams4 = params
        }
    }

    /// The parameters of the preset's active FSRS version.
    var activeFsrsParams: [Float] {
        get { fsrsParams(for: fsrsVersion) }
        set { setFsrsParams(newValue, for: fsrsVersion) }
    }
}
