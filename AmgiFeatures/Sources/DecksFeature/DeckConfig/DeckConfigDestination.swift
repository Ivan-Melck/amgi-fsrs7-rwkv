//
//  DeckConfigDestination.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 14.05.2026.
//

import AnkiKit
import CasePaths

@CasePathable
enum DeckConfigDestination {
    case alert(DeckConfigAlert)
    case prompt(DeckConfigPrompt)
    case route(DeckConfigRoute)
}

@CasePathable
enum DeckConfigAlert {
    case saveFailed(String)
    case fsrsError(title: String, message: String)
    case presetError(String)
    case deletePresetConfirm
    case discardChanges
    /// A preset change would reload the page over unsaved edits.
    case unsavedBeforePresetChange(DeckConfigPresetAction)
}

/// Preset changes, which (unlike the desktop's) apply at once and reload.
enum DeckConfigPresetAction: Hashable {
    case select(DeckConfig)
    case add
    case clone
    case rename
    case delete
}

enum DeckConfigPrompt: String, Identifiable {
    case createPreset
    case clonePreset
    case renamePreset

    var id: String { rawValue }
}

enum DeckConfigRoute: Hashable {
    case simulator(FsrsSimulatorContext)
}
