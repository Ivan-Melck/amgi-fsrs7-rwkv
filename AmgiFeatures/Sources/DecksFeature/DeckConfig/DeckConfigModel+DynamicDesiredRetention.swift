//
//  DeckConfigModel+DynamicDesiredRetention.swift
//  DecksFeature
//

import AnkiKit
import Foundation

/// The Dynamic DR row of the desktop's `FsrsOptions.svelte`: its weight,
/// bounds and warning, and the "Visualize DR plot" modal it opens.
extension DeckConfigModel {
    /// The edited preset's Dynamic DR model (the desktop's `$config`): an
    /// unsaved optimization's model wins over the stored one, as on save.
    var editedDynamicDesiredRetention: FsrsDynamicDesiredRetention {
        optimizedDynamicDesiredRetention
            ?? loaded?.config.config.fsrsDynamicDesiredRetention
            ?? FsrsDynamicDesiredRetention()
    }

    /// `effectiveDesiredRetention`: this deck's DR when it has its own,
    /// else the preset's.
    var effectiveDesiredRetention: Double {
        (deckDesiredRetentionPercent ?? desiredRetentionPercent) / 100
    }

    var dynamicDesiredRetentionStatus: DynamicDesiredRetentionPolicy.Status {
        DynamicDesiredRetentionPolicy.status(
            enabled: dynamicDesiredRetentionEnabled,
            clamp: dynamicDesiredRetentionClamp,
            model: editedDynamicDesiredRetention,
            effectiveDesiredRetention: effectiveDesiredRetention
        )
    }

    /// The modal's props, from the edited preset.
    var dynamicDesiredRetentionPlot: DynamicDesiredRetentionPlot {
        DynamicDesiredRetentionPlot(model: editedDynamicDesiredRetention)
    }

    func openDynamicDesiredRetentionPlot() {
        destination = .prompt(.dynamicDesiredRetentionPlot)
    }

    /// `saveDynamicDesiredRetentionPlotTarget`: sets the desired retention
    /// the page is showing (this deck's when it has its own, else the
    /// preset's) as an unsaved edit.
    func saveDynamicDesiredRetentionPlotTarget(_ target: Double) {
        if deckDesiredRetentionPercent != nil {
            deckDesiredRetentionPercent = target * 100
        } else {
            desiredRetentionPercent = target * 100
        }
    }
}
