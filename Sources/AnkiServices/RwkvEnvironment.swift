//
//  RwkvEnvironment.swift
//  AnkiServices
//
//  Where RWKV scheduling (the FSRS7/RWKV Anki fork) finds its model and keeps
//  its state. Shared by every service that asks the bridge for RWKV scores.
//

package import AnkiBackend
import Foundation

package enum RwkvEnvironment {
    /// The bundled weights; nil in previews, tests and the watch app, which
    /// therefore never touch RWKV.
    package static let modelPath: String? = Bundle.main.path(
        forResource: "RWKV_trained_on_5000_10000",
        ofType: "bin"
    )

    /// `UserDefaults` key for the state precision: "f32", "int8" or "int4".
    /// The desktop's profile setting of the same name; int8 is its default.
    package static let precisionKey = "rwkvStatePrecision"

    package static var precision: String {
        UserDefaults.standard.string(forKey: precisionKey) ?? "int8"
    }

    /// The persisted model state lives beside the collection it describes.
    package static func cacheDir(_ backend: AnkiBackend) -> String? {
        backend.currentCollectionPath.map {
            URL(fileURLWithPath: $0)
                .deletingLastPathComponent()
                .appendingPathComponent("rwkv-state-cache", isDirectory: true)
                .path
        }
    }
}
