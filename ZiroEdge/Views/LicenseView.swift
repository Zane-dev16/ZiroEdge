// LicenseView.swift
// ZiroEdge — Privacy-first local AI assistant
//
// License attribution screen. Lists all models from the registry with
// their license name, copyright, and a tappable link to the full license text.

import SwiftUI

/// Displays license attribution for all models in the ZiroEdge registry.
struct LicenseView: View {
    var body: some View {
        List {
            ForEach(ModelRegistry.allModels) { model in
                Section(model.displayName) {
                    LabeledContent("License", value: model.license.name)

                    if !model.license.copyright.isEmpty {
                        LabeledContent("Copyright", value: model.license.copyright)
                    }

                    Link(destination: model.license.url) {
                        Label("View Full License", systemImage: "doc.text")
                    }
                }
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        LicenseView()
    }
}
