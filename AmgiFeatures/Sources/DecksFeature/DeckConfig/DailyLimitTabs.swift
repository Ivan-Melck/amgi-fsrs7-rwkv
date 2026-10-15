//
//  DailyLimitTabs.swift
//  DecksFeature
//
//  The desktop's daily-limit tabs (ts/routes/deck-options/TabbedValue.svelte
//  and DailyLimits.svelte): a limit comes from the shared preset, this deck,
//  or today only, and the active tab decides what a save sends.
//

enum DailyLimitScope: Hashable, CaseIterable {
    case preset
    case deck
    case today

    var title: String {
        switch self {
        case .preset: "Preset"
        case .deck: "This deck"
        case .today: "Today only"
        }
    }
}

struct DailyLimitTabs: Hashable {
    private(set) var scope: DailyLimitScope
    /// The "This deck" tab's value, kept after leaving the tab.
    private(set) var deck: Int?
    /// The "Today only" tab's value, kept after leaving the tab.
    private(set) var today: Int?
    /// The stored deck limit, restored when "Today only" is active.
    private let storedDeck: Int?
    /// The last today-only limit, offered when the tab is chosen again.
    private let lastToday: Int?

    /// - Parameters mirror `DeckConfigsForUpdate.CurrentDeck.Limits`.
    init(deck: Int?, today: Int?, todayActive: Bool) {
        storedDeck = deck
        lastToday = today
        self.deck = deck
        self.today = todayActive ? today : nil
        // The last tab holding a value, as `lastSetTab()`.
        scope = self.today != nil ? .today : deck != nil ? .deck : .preset
    }

    /// The value shown for the active tab.
    func value(preset: Int) -> Int {
        switch scope {
        case .preset: preset
        case .deck: deck ?? 0
        case .today: today ?? 0
        }
    }

    /// `ValueTab.enable`: the tab's value, else its start value, else the
    /// value on screen.
    mutating func select(_ newScope: DailyLimitScope, showing current: Int) {
        guard newScope != scope else { return }
        switch newScope {
        case .preset: break
        case .deck: deck = deck ?? current
        case .today: today = today ?? lastToday ?? current
        }
        scope = newScope
    }

    /// Edits the active tab's value; the preset tab edits the preset itself.
    mutating func set(_ value: Int, preset: inout Int) {
        switch scope {
        case .preset: preset = value
        case .deck: deck = value
        case .today: today = value
        }
    }

    /// What a save sends: tabs after the active one are cleared and tabs
    /// before it keep their stored values.
    var saved: (deck: Int?, today: Int?) {
        switch scope {
        case .preset: (nil, nil)
        case .deck: (deck, nil)
        case .today: (storedDeck, today)
        }
    }
}
