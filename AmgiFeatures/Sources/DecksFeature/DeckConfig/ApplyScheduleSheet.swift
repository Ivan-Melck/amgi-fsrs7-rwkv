//
//  ApplyScheduleSheet.swift
//  DecksFeature
//
//  The desktop's ApplyScheduleModal.svelte: what to copy from the current
//  preset into every other one.
//

import AnkiKit
import SwiftUI

struct ApplyScheduleSheet: View {
    let onApply: (ScheduleCopyOptions) async -> String?

    @State private var options = ScheduleCopyOptions()
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    option("Scheduler", "The selected review scheduler.", $options.scheduler)
                    option("Desired Retention", "The preset's desired retention. Deck-specific retention overrides remain unchanged.", $options.retention)
                    option("Fallback", "The due-date calculator for RWKV-Instant presets. Other review schedulers calculate their own due dates.", $options.fallback)
                    option("Settings", "FSRS and RWKV preset model settings, including parameters, interval limits, optimization options, Dynamic DR, and repeat spacing.", $options.settings)
                } footer: {
                    Text("Choose what to copy from the current preset into every other preset. Your changes on this page are saved first.")
                }
            }
            .navigationTitle("Apply Schedule to All Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await apply() } }
                        .disabled(!options.copiesAnything || isWorking)
                }
            }
            .alert(
                "Couldn't apply the schedule",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func option(_ title: String, _ description: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func apply() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await onApply(options) {
            errorMessage = failure
        } else {
            dismiss()
        }
    }
}
