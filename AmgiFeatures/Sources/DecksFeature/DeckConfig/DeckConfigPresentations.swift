//
//  DeckConfigPresentations.swift
//  DecksFeature
//
//  Created by Vladimir Gusev on 14.05.2026.
//

import SwiftUI
import SwiftNavigation
import SwiftUINavigation

struct DeckConfigPresentations: ViewModifier {
    @Binding var destination: DeckConfigDestination?
    let currentAlert: DeckConfigAlert?
    let alertTitle: String
    @Binding var newPresetName: String
    @Binding var renamePresetDraft: String
    let currentPresetName: String?
    let deletingPresetName: String?
    let fallbackPresetName: String?
    let deleteRequiresFullSync: Bool
    let onCreate: (_ fromDefaults: Bool) async -> String?
    let onRename: () async -> String?
    let onDelete: () -> Void
    let onDiscard: () -> Void
    let onSaveThen: (DeckConfigPresetAction) -> Void
    let onDiscardThen: (DeckConfigPresetAction) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                alertTitle,
                isPresented: Binding($destination.alert),
                presenting: currentAlert
            ) { alert in
                DeckConfigAlertActions(
                    alert: alert,
                    onDelete: onDelete,
                    onDiscard: onDiscard,
                    onSaveThen: onSaveThen,
                    onDiscardThen: onDiscardThen
                )
            } message: { alert in
                DeckConfigAlertMessage(
                    alert: alert,
                    deletingPresetName: deletingPresetName,
                    fallbackPresetName: fallbackPresetName,
                    deleteRequiresFullSync: deleteRequiresFullSync
                )
            }
            .sheet(item: $destination.prompt) { prompt in
                promptSheet(prompt)
            }
            .navigationDestination(item: $destination.route) { route in
                switch route {
                case .simulator(let context):
                    FsrsSimulatorView(context: context)
                }
            }
    }

    @ViewBuilder
    private func promptSheet(_ prompt: DeckConfigPrompt) -> some View {
        switch prompt {
        case .createPreset:
            TextPromptSheet(
                title: "Add Preset",
                placeholder: "Preset name",
                footer: "Starts from the default settings and is selected for this deck.",
                confirmLabel: "Create",
                isValid: { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                onConfirm: { _ in await onCreate(true) },
                text: $newPresetName
            )
        case .clonePreset:
            TextPromptSheet(
                title: "Clone Preset",
                placeholder: "Preset name",
                footer: "Cloned from \(currentPresetName.map { "\"\($0)\"" } ?? "the current preset") and selected for this deck.",
                confirmLabel: "Create",
                isValid: { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                onConfirm: { _ in await onCreate(false) },
                text: $newPresetName
            )
        case .renamePreset:
            TextPromptSheet(
                title: "Rename Preset",
                placeholder: "Preset name",
                footer: nil,
                confirmLabel: "Save",
                isValid: { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                onConfirm: { _ in await onRename() },
                text: $renamePresetDraft
            )
        }
    }
}

struct DeckConfigAlertActions: View {
    let alert: DeckConfigAlert
    let onDelete: () -> Void
    let onDiscard: () -> Void
    let onSaveThen: (DeckConfigPresetAction) -> Void
    let onDiscardThen: (DeckConfigPresetAction) -> Void

    var body: some View {
        switch alert {
        case .saveFailed, .fsrsError, .presetError:
            Button("OK", role: .cancel) {}
        case .deletePresetConfirm:
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        case .discardChanges:
            Button("Discard", role: .destructive) { onDiscard() }
            Button("Cancel", role: .cancel) {}
        case .unsavedBeforePresetChange(let action):
            Button("Save and Continue") { onSaveThen(action) }
            Button("Discard and Continue", role: .destructive) { onDiscardThen(action) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct DeckConfigAlertMessage: View {
    let alert: DeckConfigAlert
    let deletingPresetName: String?
    let fallbackPresetName: String?
    let deleteRequiresFullSync: Bool

    var body: some View {
        switch alert {
        case .saveFailed(let msg), .presetError(let msg), .fsrsError(_, let msg):
            Text(msg)
        case .deletePresetConfirm:
            Text(deleteMessage)
        case .discardChanges:
            Text("You have unsaved changes to this deck's options. Discard them?")
        case .unsavedBeforePresetChange:
            Text("Changing presets applies right away. Save your changes to this deck's options first, or discard them?")
        }
    }

    private var deleteMessage: String {
        // deck-config-will-require-full-sync, as the desktop prefixes it.
        let sync = deleteRequiresFullSync
            ? "The requested change will require a one-way sync. If you have made changes on another device, and not synced them to this device yet, please do so before you proceed. "
            : ""
        if let name = deletingPresetName, let fallback = fallbackPresetName {
            return sync + "\"\(name)\" will be removed and decks using it will switch to \"\(fallback)\"."
        }
        return sync + "This preset will be removed."
    }
}
