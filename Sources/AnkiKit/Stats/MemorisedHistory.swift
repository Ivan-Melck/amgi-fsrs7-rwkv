//
//  MemorisedHistory.swift
//  AnkiKit
//
//  The stats screen's "Memorised" chart, as the Search Stats Extended
//  add-on draws it on the fork desktop (src/ts/MemorisedBar.svelte,
//  LineGraph.ts, stores.ts): how many cards were known each day, from the
//  FSRS replay of the search's reviews and from the RWKV daily history.
//
//  Days are the collection's day numbers (today is `days_elapsed`).
//

public import Foundation

/// Values for consecutive days from `firstDay`.
public struct MemorisedDaySeries: Sendable, Hashable {
    public var firstDay: Int
    public var values: [Double]

    public init(firstDay: Int = 0, values: [Double] = []) {
        self.firstDay = firstDay
        self.values = values
    }

    /// One past the last day, like a JavaScript array's length.
    public var endDay: Int { values.isEmpty ? 0 : firstDay + values.count }

    public func value(at day: Int) -> Double? {
        let index = day - firstDay
        return values.indices.contains(index) ? values[index] : nil
    }
}

/// The add-on's `memorised_stats` series the chart reads, and
/// `revlogStats.burden` for "Cards/Load". Computed for the stats period.
public struct FsrsMemorisedHistory: Sendable, Hashable {
    public var today: Int
    /// The scheduler's rollover hour, to turn day numbers into dates.
    public var rollover: Int
    public var retrievability: MemorisedDaySeries
    public var noteRetrievability: MemorisedDaySeries
    public var cardCount: MemorisedDaySeries
    public var stableRetrievability: MemorisedDaySeries
    public var burden: MemorisedDaySeries

    public init(
        today: Int,
        rollover: Int = 4,
        retrievability: MemorisedDaySeries = .init(),
        noteRetrievability: MemorisedDaySeries = .init(),
        cardCount: MemorisedDaySeries = .init(),
        stableRetrievability: MemorisedDaySeries = .init(),
        burden: MemorisedDaySeries = .init()
    ) {
        self.today = today
        self.rollover = rollover
        self.retrievability = retrievability
        self.noteRetrievability = noteRetrievability
        self.cardCount = cardCount
        self.stableRetrievability = stableRetrievability
        self.burden = burden
    }
}

/// `RwkvMemorisedHistoryProgress`: the RWKV daily history so far, for the
/// search's cards, and how far its build is.
public struct RwkvMemorisedProgress: Sendable, Hashable {
    /// "idle", "loading", "resuming", "computing", "waiting", "complete",
    /// "cancelled", "failed", or "checkpointing" while a cancel saves.
    public var phase: String
    public var current: Int
    public var total: Int
    public var firstDay: Int?
    public var completedThroughDay: Int?
    public var retrievability: [Double]
    public var noteRetrievability: [Double]
    public var cardCount: [Double]
    public var done: Bool
    public var error: String?

    public init(
        phase: String,
        current: Int = 0,
        total: Int = 0,
        firstDay: Int? = nil,
        completedThroughDay: Int? = nil,
        retrievability: [Double] = [],
        noteRetrievability: [Double] = [],
        cardCount: [Double] = [],
        done: Bool = false,
        error: String? = nil
    ) {
        self.phase = phase
        self.current = current
        self.total = total
        self.firstDay = firstDay
        self.completedThroughDay = completedThroughDay
        self.retrievability = retrievability
        self.noteRetrievability = noteRetrievability
        self.cardCount = cardCount
        self.done = done
        self.error = error
    }

    /// `rwkvProgressPercent`.
    public var percent: Int {
        guard total > 0 else { return 0 }
        return min(100, Int((100 * Double(current) / Double(total) + 0.5).rounded(.down)))
    }

    /// The progress line above the bar (`memorised-rwkv-progress`).
    public var progressText: String {
        phase == "checkpointing"
            ? "Saving resumable RWKV checkpoint…"
            : "Computing RWKV history: \(current) / \(total) predictions — \(percent)%"
    }

    /// `anchoredRwkvDays`.
    func anchored(_ values: [Double]) -> MemorisedDaySeries {
        guard let firstDay else { return MemorisedDaySeries() }
        return MemorisedDaySeries(firstDay: firstDay, values: values)
    }
}

/// The source radio buttons above the chart (`memorisedMode`).
public enum MemorisedSource: String, CaseIterable, Sendable, Hashable {
    case fsrs
    case rwkv
    case both

    public var label: String {
        switch self {
        case .fsrs: "FSRS"
        case .rwkv: "RWKV"
        case .both: "Both"
        }
    }
}

/// The series radio buttons below the chart (`MemorisedType`).
public enum MemorisedKind: CaseIterable, Sendable, Hashable {
    case cards
    case notes
    case cardsByBurden
    case average
    case stable

    /// The radio button's text.
    public var label: String {
        switch self {
        case .cards: "Cards"
        case .notes: "Notes"
        case .cardsByBurden: "Cards/Load"
        case .average: "Average Per Card"
        case .stable: "Retrievability & Stability"
        }
    }

    /// `displayLabel`: the series' name in a single-series tooltip.
    public var seriesLabel: String {
        switch self {
        case .cards: "Cards"
        case .notes: "Notes"
        case .cardsByBurden: "Cards/Load"
        case .average: "Retrievability"
        case .stable: "Stable cards"
        }
    }

    /// RWKV has no stability, so Retrievability & Stability is FSRS-only.
    public var supportsRwkv: Bool { self != .stable }
}

/// The line colours the add-on uses.
public enum MemorisedLineColor: Sendable, Hashable {
    /// "steelblue": FSRS, and any single series.
    case steelBlue
    /// "seagreen": RWKV.
    case seaGreen
}

/// What `renderLineChart` draws: lines from the first day any series is
/// non-zero, with a tooltip per day.
public struct MemorisedChart: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public let label: String
        public let color: MemorisedLineColor
        /// Values from `startDay` (nil where the add-on's array has none).
        public let values: [Double?]

        /// The plotted value: missing values draw at 0; NaN and infinities
        /// leave a gap.
        public func plotted(_ index: Int) -> Double? {
            let value = values[index] ?? 0
            return value.isFinite ? value : nil
        }
    }

    public let startDay: Int
    public let lines: [Line]

    /// The last day any line reaches.
    public var endDay: Int { startDay + (lines.map(\.values.count).max() ?? 0) - 1 }

    /// d3's max of every plotted point.
    public var maxValue: Double {
        lines.flatMap { line in line.values.indices.compactMap(line.plotted) }.max() ?? 0
    }

    /// The tooltip's series lines for a day (`hoverData`).
    public func tooltip(day: Int) -> [String] {
        lines.compactMap { line in
            let index = day - startDay
            guard line.values.indices.contains(index), let value = line.values[index], value.isFinite else {
                return nil
            }
            return "\(line.label): \(Self.format(value))"
        }
    }

    /// `value > 10 ? value.toFixed(0) : value.toPrecision(2)`.
    public static func format(_ value: Double) -> String {
        if value > 10 {
            return String(format: "%.0f", value.rounded(.toNearestOrAwayFromZero))
        }
        return toPrecision2(value)
    }

    /// JavaScript's `Number.prototype.toPrecision(2)`.
    static func toPrecision2(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity") }
        if value == 0 { return "0.0" }
        // Round to two significant digits first: the exponent can move.
        let exponent = Int(floor(log10(abs(value))))
        var scale = pow(10, Double(1 - exponent))
        var mantissa = (abs(value) * scale).rounded(.toNearestOrAwayFromZero)
        var e = exponent
        if mantissa >= 100 {
            e += 1
            scale /= 10
            mantissa = (abs(value) * scale).rounded(.toNearestOrAwayFromZero)
        }
        let sign = value < 0 ? "-" : ""
        let digits = String(Int(mantissa))
        if e < -6 || e >= 2 {
            let exponentText = e < 0 ? "-\(-e)" : "+\(e)"
            return "\(sign)\(digits.prefix(1)).\(digits.dropFirst())e\(exponentText)"
        }
        if e >= 1 {
            return sign + digits
        }
        if e == 0 {
            return "\(sign)\(digits.prefix(1)).\(digits.dropFirst())"
        }
        return sign + "0." + String(repeating: "0", count: -e - 1) + digits
    }
}

/// A JavaScript number array: its length and elements (nil for holes).
private struct DayValues {
    let length: Int
    let element: (Int) -> Double?

    init(length: Int, element: @escaping (Int) -> Double?) {
        self.length = max(0, length)
        self.element = element
    }

    /// `Array.from(sparse)` of a series.
    init(_ series: MemorisedDaySeries) {
        self.init(length: series.endDay, element: series.value(at:))
    }

    static var empty: DayValues { DayValues(length: 0) { _ in nil } }

    func callAsFunction(_ day: Int) -> Double? {
        day < length ? element(day) : nil
    }
}

/// The days the series of one source cover.
private struct SourceSeries {
    let cards: DayValues
    let notes: DayValues
    let cardsByBurden: DayValues
    let average: DayValues
    let stable: DayValues

    func series(_ kind: MemorisedKind) -> DayValues {
        switch kind {
        case .cards: cards
        case .notes: notes
        case .cardsByBurden: cardsByBurden
        case .average: average
        case .stable: stable
        }
    }
}

/// `revlogStats.burden`: `Array.from(intervals).map(...)`, so 0 for days
/// before the first card and undefined after the last.
private func burdenValues(_ burden: MemorisedDaySeries) -> DayValues {
    DayValues(length: burden.endDay) { day in burden.value(at: day) ?? 0 }
}

/// `(retrievability ?? 0) / (burden[i] ?? 1)`.
private func perBurden(_ retrievability: Double?, _ burden: DayValues, _ day: Int) -> Double {
    (retrievability ?? 0) / (burden(day) ?? 1)
}

/// `_.zip(retrievability, cards).map(([r, c]) => (r ?? 0) / (c ?? 1))`.
private func average(_ retrievability: DayValues, _ cards: DayValues) -> DayValues {
    DayValues(length: max(retrievability.length, cards.length)) { day in
        (retrievability(day) ?? 0) / (cards(day) ?? 1)
    }
}

private func fsrsSeries(_ stats: FsrsMemorisedHistory?) -> SourceSeries {
    guard let stats else {
        return SourceSeries(cards: .empty, notes: .empty, cardsByBurden: .empty, average: .empty, stable: .empty)
    }
    let cards = DayValues(stats.retrievability)
    let burden = burdenValues(stats.burden)
    // The stable sum is only set on days a card has stability: a zero is
    // a hole in the add-on's array.
    let stableSeries = stats.stableRetrievability
    let stableEnd = (stableSeries.values.lastIndex { $0 != 0 }).map { stableSeries.firstDay + $0 + 1 } ?? 0
    let stable = DayValues(length: stableEnd) { day in
        stableSeries.value(at: day).flatMap { $0 == 0 ? nil : $0 }
    }
    return SourceSeries(
        cards: cards,
        notes: DayValues(stats.noteRetrievability),
        // A dense map of `Array.from(retrievabilityDays)`.
        cardsByBurden: DayValues(length: cards.length) { day in perBurden(cards(day), burden, day) },
        average: average(cards, DayValues(stats.cardCount)),
        stable: stable
    )
}

private func rwkvSeries(_ progress: RwkvMemorisedProgress?, burden: MemorisedDaySeries?) -> SourceSeries {
    guard let progress else {
        return SourceSeries(cards: .empty, notes: .empty, cardsByBurden: .empty, average: .empty, stable: .empty)
    }
    let cards = DayValues(progress.anchored(progress.retrievability))
    let burden = burden.map(burdenValues) ?? .empty
    let firstDay = progress.firstDay ?? 0
    return SourceSeries(
        cards: cards,
        notes: DayValues(progress.anchored(progress.noteRetrievability)),
        // `map` over the sparse anchored array keeps its holes.
        cardsByBurden: DayValues(length: cards.length) { day in
            day < firstDay ? nil : perBurden(cards(day), burden, day)
        },
        average: average(cards, DayValues(progress.anchored(progress.cardCount))),
        stable: .empty
    )
}

extension MemorisedChart {
    /// `MemorisedBar.svelte`'s series for a source and kind, laid out as
    /// `renderLineChart` draws them. Nil when nothing is drawn.
    public static func make(
        fsrs: FsrsMemorisedHistory?,
        rwkv: RwkvMemorisedProgress?,
        kind: MemorisedKind,
        source: MemorisedSource
    ) -> MemorisedChart? {
        let fsrsData = fsrsSeries(fsrs).series(kind)
        let rwkvData = rwkvSeries(rwkv, burden: fsrs?.burden).series(kind)
        let supportsRwkv = kind.supportsRwkv

        let series: [(label: String, color: MemorisedLineColor, data: DayValues)]
        switch (supportsRwkv, source) {
        case (true, .both):
            series = [("FSRS", .steelBlue, fsrsData), ("RWKV", .seaGreen, rwkvData)]
        case (true, .rwkv):
            series = [("RWKV", .seaGreen, rwkvData)]
        default:
            series = [(kind.seriesLabel, .steelBlue, fsrsData)]
        }

        // `first_non_zero_index`: the first truthy value of any series.
        let lowest = [
            fsrs.map { min($0.retrievability.firstDay, $0.burden.firstDay) },
            rwkv?.firstDay,
        ].compactMap { $0 }.min() ?? 0
        let truthy: (Double?) -> Bool = { value in value.map { $0 != 0 && !$0.isNaN } ?? false }
        let firsts = series.compactMap { item in
            (min(lowest, item.data.length)..<item.data.length).first { truthy(item.data($0)) }
        }
        guard let startDay = firsts.min() else { return nil }

        let lines = series.map { item in
            Line(
                label: item.label,
                color: item.color,
                values: (startDay..<max(startDay, item.data.length)).map { item.data($0) }
            )
        }
        guard lines.contains(where: { !$0.values.isEmpty }) else { return nil }
        return MemorisedChart(startDay: startDay, lines: lines)
    }
}

/// Day numbers as calendar dates: today is the local date the scheduler
/// calls today (before the rollover hour, that is still yesterday).
public struct MemorisedDates: Sendable, Hashable {
    public let today: Int
    public let todayStart: Date

    public init(today: Int, rollover: Int, now: Date = Date(), calendar: Calendar = .current) {
        self.today = today
        todayStart = calendar.startOfDay(for: now.addingTimeInterval(-Double(rollover) * 3600))
    }

    public func date(for day: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: day - today, to: todayStart) ?? todayStart
    }

    public func day(for date: Date, calendar: Calendar = .current) -> Int {
        today + (calendar.dateComponents([.day], from: todayStart, to: calendar.startOfDay(for: date)).day ?? 0)
    }
}
