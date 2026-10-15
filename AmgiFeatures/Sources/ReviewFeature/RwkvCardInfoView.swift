//
//  RwkvCardInfoView.swift
//  ReviewFeature
//
//  The RWKV rows the desktop's Card Info shows for a card whose preset uses
//  RWKV-Curve or RWKV-Instant (FSRS7/RWKV Anki fork).
//

import SwiftUI
import AnkiClients
import AnkiKit
import Dependencies

struct RwkvCardInfoView: View {
    let cardId: CardID

    @Dependency(\.rwkvClient) private var rwkv
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [RwkvCardInfoRow]?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                } else if let rows {
                    if rows.isEmpty {
                        Text("This card's preset doesn't use RWKV-Curve or RWKV-Instant.")
                            .foregroundStyle(.secondary)
                    } else {
                        Section {
                            ForEach(rows) { row in
                                LabeledContent(row.label) {
                                    Text(row.value)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        } footer: {
                            Text("Predictions from the RWKV model's current state for this card.")
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("RWKV Card Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do {
                    rows = try await rwkv.cardInfo(cardId)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
