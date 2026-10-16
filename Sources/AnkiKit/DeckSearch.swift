//
//  DeckSearch.swift
//  AnkiKit
//
//  Created by Vladimir Gusev on 20.08.2026.
//

import Foundation

/// Anki search-query construction.
///
/// Lives in `AnkiKit` (no `AnkiClients` dependency) so the widget and the
/// watch can use it too.
public enum DeckSearch: Sendable {
    /// Builds a `deck:"..."` term for `name`, escaping the characters Anki
    /// treats specially inside a quoted term.
    ///
    /// Four call sites used to interpolate the name raw while two others
    /// each carried a private copy of this escaping, so a deck named
    /// `My "Korean" Deck` produced a malformed query and silently returned
    /// wrong stats and deck counts.
    public static func term(_ name: String) -> String {
        "deck:\"\(escape(name))\""
    }

    /// The desktop's `escapeSearchText` (ts/routes/deck-options/lib.ts):
    /// backslashes and double quotes, for text inside a quoted term.
    public static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The desktop's `preset:"<name>" -is:suspended`, the default search
    /// of a preset's optimizer and simulator.
    public static func presetSearch(_ presetName: String) -> String {
        "preset:\"\(escape(presetName))\" -is:suspended"
    }
}
