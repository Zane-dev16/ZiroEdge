// LicenseView.swift
// ZiroEdge — Privacy-first local AI assistant

import SwiftUI

/// Displays bundled third-party notices and one entry per unique model
/// provenance/license relationship. Artifact digests are transfer identities,
/// not legal identities, so quantized variants from one source are deduplicated.
struct LicenseView: View {
    private var uniqueModels: [AIModel] { Self.uniqueModels(from: ModelRegistry.libraryModels) }

    static func uniqueModels(from models: [AIModel]) -> [AIModel] {
        var legalKeys = Set<String>()
        return models.filter { model in
            let sourceKey: String
            if let provenance = model.huggingFaceProvenance {
                sourceKey = "hf:\(provenance.repositoryID.lowercased())"
            } else {
                sourceKey = "curated"
            }
            let key = [
                sourceKey,
                model.license.name.lowercased(),
                model.license.url.absoluteString.lowercased()
            ].joined(separator: "|")
            return legalKeys.insert(key).inserted
        }
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
                        .foregroundStyle(ZiroTheme.warningText)
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
