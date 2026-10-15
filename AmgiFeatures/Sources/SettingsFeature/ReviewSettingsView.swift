//
//  ReviewSettingsView.swift
//  SettingsFeature
//
//  Created by Vladimir Gusev on 02.05.2026.
//

import SwiftUI
import AppCore
import Theme
import Sharing
import ReviewCore
import ReviewFeature
import AnkiBackend
import AnkiClients
import AnkiKit
import AnkiServices
import AppShared
import Dependencies

struct ReviewSettingsView: View {
    @Shared(.appStorage(ReviewPreferences.Keys.openLinksExternally))
    private var openLinksExternally: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.cardContentAlignment))
    private var cardContentAlignment: String = CardWebViewContentAlignment.center.rawValue

    @Shared(.appStorage(ReviewPreferences.Keys.autoMatchCardBackground))
    private var autoMatchCardBackground: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showRemainingDays))
    private var showRemainingDays: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.showNextReviewTime))
    private var showNextReviewTime: Bool = true

    @Shared(.appStorage(ReviewPreferences.Keys.playAudioInSilentMode))
    private var playAudioInSilentMode: Bool = false

    /// Read by AnkiServices' `RwkvEnvironment.precisionKey`; the desktop's
    /// profile setting of the same name.
    @Shared(.appStorage("rwkvStatePrecision"))
    private var rwkvStatePrecision: String = "int8"

    @Dependency(\.rwkvClient) private var rwkv
    @Dependency(\.collectionStore) private var store
    @Dependency(\.ankiBackend) private var backend
    /// Synced with the collection, like the desktop's preference.
    @State private var showFuzzDelta = false
    @State private var confirmRescheduleAll = false
    @State private var rescheduling = false
    @State private var rescheduleMessage: String?

    var body: some View {
        SettingsPage {
            cardDisplaySection
            answerButtonsSection
            audioSection
            if rwkv.isAvailable() {
                rwkvSection
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let stored: Bool? = try? backend.getConfigJSONValue(for: fuzzDeltaConfigKey)
            showFuzzDelta = stored ?? false
        }
    }

    private var cardDisplaySection: some View {
        Group {
            SettingsSectionHeader(title: "Card Display")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Match toolbar to card background",
                    systemImage: "paintbrush",
                    tone: .mature,
                    isOn: Binding($autoMatchCardBackground)
                )
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Open links externally",
                    systemImage: "arrow.up.right.square",
                    tone: .accent,
                    isOn: Binding($openLinksExternally)
                )
                SettingsSeparator()
                SettingsPickerRow(
                    title: "Content alignment",
                    systemImage: "arrow.up.and.down.text.horizontal",
                    tone: .link,
                    selection: Binding($cardContentAlignment)
                ) {
                    Text("Center").tag(CardWebViewContentAlignment.center.rawValue)
                    Text("Top").tag(CardWebViewContentAlignment.top.rawValue)
                }
            }
        }
    }

    private var answerButtonsSection: some View {
        Group {
            SettingsSectionHeader(title: "Answer Buttons")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Show remaining counts",
                    systemImage: "number",
                    tone: .review,
                    isOn: Binding($showRemainingDays)
                )
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Show next review time",
                    systemImage: "clock",
                    tone: .info,
                    isOn: Binding($showNextReviewTime)
                )
                SettingsSeparator()
                SettingsToggleRow(
                    title: "Show fuzz delta next to answer button intervals",
                    systemImage: "plusminus",
                    tone: .review,
                    isOn: Binding(
                        get: { showFuzzDelta },
                        set: { newValue in
                            showFuzzDelta = newValue
                            try? backend.setConfigJSONValue(newValue, for: fuzzDeltaConfigKey)
                        }
                    )
                )
            }
        }
    }

    private var rwkvSection: some View {
        Group {
            SettingsSectionHeader(title: "RWKV State")
            SettingsGroup {
                SettingsPickerRow(
                    title: "Storage precision",
                    systemImage: "cpu",
                    tone: .info,
                    selection: Binding($rwkvStatePrecision)
                ) {
                    Text("f32 — full precision fallback").tag("f32")
                    Text("int8 — recommended").tag("int8")
                    Text("int4 — experimental, reduced accuracy").tag("int4")
                }
                SettingsSeparator()
                SettingsButtonRow(
                    title: "Reschedule All Decks with RWKV-Curve",
                    systemImage: "brain",
                    tone: .accent,
                    isBusy: rescheduling
                ) {
                    confirmRescheduleAll = true
                }
                .disabled(rescheduling)
            }
            Text("Precision applies to card and note state in memory and on disk. Computation remains at full precision; the next RWKV use rebuilds state from review history. int4 saves more memory but can noticeably change predictions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .alert("Reschedule all decks with RWKV-Curve?", isPresented: $confirmRescheduleAll) {
            Button("Reschedule") {
                Task { await rescheduleAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Review cards whose preset uses RWKV-Curve get RWKV's current interval and stability. No review history is added.")
        }
        .alert(
            "RWKV Reschedule",
            isPresented: Binding(
                get: { rescheduleMessage != nil },
                set: { if !$0 { rescheduleMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rescheduleMessage ?? "")
        }
    }

    private func rescheduleAll() async {
        rescheduling = true
        defer { rescheduling = false }
        do {
            let result = try await rwkv.reschedule(nil)
            if !result.built {
                rescheduleMessage = "RWKV reschedule could not be started."
            } else if result.predicted == 0 {
                rescheduleMessage = "No review cards use RWKV-Curve."
            } else {
                rescheduleMessage = "RWKV rescheduled \(result.updated) cards."
                store.apply(CollectionChanges(card: true, deck: true, studyQueues: true))
            }
        } catch {
            rescheduleMessage = "RWKV reschedule failed: \(error.localizedDescription)"
        }
    }

    private var audioSection: some View {
        Group {
            SettingsSectionHeader(title: "Audio")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Play audio in silent mode",
                    systemImage: "speaker.wave.2",
                    tone: .learning,
                    isOn: Binding($playAudioInSilentMode)
                )
            }
        }
    }
}

#if DEBUG

#Preview {
    NavigationStack {
        ReviewSettingsView()
    }
}
#endif
