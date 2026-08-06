// LicenseView.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

/// Displays bundled third-party notices and one entry per unique shipped model artifact.
struct LicenseView: View {
    private var uniqueModels: [AIModel] {
        var storageIDs = Set<String>()
        return ModelRegistry.libraryModels.filter { storageIDs.insert($0.baseArtifactStorageID).inserted }
    }

    var body: some View {
        List {
            Section("llama.cpp") {
                LabeledContent("License", value: "MIT License")
                LabeledContent("Copyright", value: "Copyright © 2023–2026 The ggml authors")
                Link(destination: URL(string: "https://github.com/ggml-org/llama.cpp")!) {
                    Label("View Upstream Project", systemImage: "shippingbox")
                }
            }

            ForEach(uniqueModels) { model in
                Section(model.displayName.replacingOccurrences(of: " Text", with: "")) {
                    LabeledContent("License", value: model.license.name)
                    if !model.license.copyright.isEmpty {
                        LabeledContent("Copyright", value: model.license.copyright)
                    }
                    Link(destination: model.license.url) {
                        Label("View Full License", systemImage: "doc.text")
                    }
                }
            }

            Section("Complete Notices") {
                if let notice = Self.bundledNotice() {
                    Text(notice)
                        .font(.caption)
                        .textSelection(.enabled)
                } else {
                    Label("The bundled notice could not be loaded.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func bundledNotice(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

#Preview {
    NavigationStack { LicenseView() }
}
