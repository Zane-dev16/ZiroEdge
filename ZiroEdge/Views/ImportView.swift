import SwiftUI

struct ImportView: View {
    @StateObject private var viewModel: ImportViewModel
    @Environment(\.dismiss) private var dismiss

    init(downloadManager: DownloadManager, repositoryInput: String = "") {
        _viewModel = StateObject(wrappedValue: ImportViewModel(
            downloadManager: downloadManager,
            repositoryInput: repositoryInput
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Public Hugging Face Repository") {
                    TextField("owner/repository or URL", text: $viewModel.repositoryInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Inspect Repository") { Task { await viewModel.inspect() } }
                        .disabled(viewModel.repositoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.phase == .inspecting)
                }

                switch viewModel.phase {
                case .idle: privacyNotice
                case .inspecting:
                    Section { HStack { ProgressView(); Text("Resolving an immutable revision…") } }
                case .review, .importing, .completed:
                    reviewSections
                case .failed(let message):
                    Section("Import Rejected") {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Button("Retry Inspection") { Task { await viewModel.retryInspection() } }
                    }
                }
            }
            .navigationTitle("Import Model")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private var privacyNotice: some View {
        Section("Privacy") {
            Text("Only repository inspection and selected artifact downloads contact Hugging Face. Prompts, images, conversations, and inference stay on this device.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var reviewSections: some View {
        if let review = viewModel.review {
            Section("Pinned Source") {
                LabeledContent("Repository", value: review.repositoryID)
                LabeledContent("Revision", value: String(review.revision.prefix(12)))
                LabeledContent("License", value: review.licenseName)
            }

            Section("Choose GGUF Artifact") {
                if viewModel.baseCandidates.isEmpty {
                    EmptyVariantView(repositoryID: review.repositoryID)
                } else {
                    VariantPickerView(
                        candidates: viewModel.baseCandidates,
                        selection: Binding(
                            get: { viewModel.selectedBase },
                            set: { artifact in
                                viewModel.selectedBase = artifact
                                viewModel.visionPairConfirmed = false
                            }
                        )
                    )
                }
            }

            // MARK: - Vision Pair Review

            if !review.projectorArtifacts.isEmpty, viewModel.selectedBase != nil {
                Section {
                    visionPairSection
                } header: {
                    Text("Vision Projector")
                } footer: {
                    if let note = viewModel.suggestedPair?.projectorArchitectureNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if viewModel.importAsVision, viewModel.selectedBase != nil {
                Section("Vision Unavailable") {
                    Label(viewModel.noVisionPairReason ?? "Vision import is not available for this repository.", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.selectedBase != nil { preflightSection }

            Section("Confirmation") {
                Toggle("I reviewed and accept the license", isOn: $viewModel.licenseConfirmed)
                if viewModel.ramAssessment.classification == .risky {
                    Toggle("Download despite RAM risk", isOn: $viewModel.ramRiskAccepted)
                    Text(viewModel.ramAssessment.warning ?? "").font(.caption).foregroundStyle(.orange)
                }
                Button(viewModel.existingModel == nil ? "Import Selected Model" : "Open Existing Import") {
                    if viewModel.existingModel == nil {
                        viewModel.confirmImport()
                    } else {
                        // The presenting Models screen already owns navigation to this
                        // record; return there instead of repeating duplicate detection.
                        dismiss()
                    }
                }
                .disabled(!viewModel.canConfirm || viewModel.phase == .importing)
            }

            if viewModel.phase == .importing {
                Section { Label("Transfer started. You can pause, resume, or repair it from Models.", systemImage: "arrow.down.circle") }
            } else if viewModel.phase == .completed {
                Section { Label("This exact revision and artifact is already imported.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
    }

    // MARK: - Vision Pair Section

    @ViewBuilder
    private var visionPairSection: some View {
        Toggle("Import as vision model", isOn: Binding<Bool>(
            get: { viewModel.importAsVision },
            set: { newValue in
                viewModel.importAsVision = newValue
                viewModel.toggleVisionImport()
            }
        ))

        if viewModel.importAsVision {
            if let pair = viewModel.suggestedPair {
                VStack(alignment: .leading, spacing: 8) {
                    // Confidence badge
                    HStack {
                        confidenceBadge(pair.confidence)
                        Spacer()
                        Text(pair.formattedCombinedSize)
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    // Base artifact summary
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Base Model", systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                        Text(pair.base.filename).font(.subheadline)
                        Text("\(pair.base.quantization) · \(ByteCountFormatter.string(fromByteCount: pair.base.size, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("SHA-256 \(pair.base.sha256.prefix(12))…").font(.caption2).foregroundStyle(.tertiary)
                    }

                    Divider()

                    // Projector artifact summary
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Vision Projector", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                        Text(pair.projector.filename).font(.subheadline)
                        Text("\(pair.projector.quantization) · \(ByteCountFormatter.string(fromByteCount: pair.projector.size, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("SHA-256 \(pair.projector.sha256.prefix(12))…").font(.caption2).foregroundStyle(.tertiary)
                    }

                    // Confidence explanation
                    Text(pair.confidenceExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Confirmation requirement for medium/low confidence
                    if pair.confidence != .high {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("This pairing requires explicit confirmation before import.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    // Confirmation button
                    if !viewModel.visionPairConfirmed {
                        Button {
                            viewModel.confirmVisionPair()
                        } label: {
                            Label(
                                pair.confidence == .high
                                    ? "Confirm Recommended Pair"
                                    : "Accept This Pairing",
                                systemImage: "checkmark.shield"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label("Vision pair confirmed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } else if let error = viewModel.visionPairingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Label("Resolving compatible vision pair…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: VisionPairConfidence) -> some View {
        HStack(spacing: 4) {
            Image(systemName: confidence == .high ? "checkmark.shield.fill" : confidence == .medium ? "shield" : "exclamationmark.shield")
            Text(confidence.label)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(confidence == .high ? Color.green.opacity(0.15) : confidence == .medium ? Color.orange.opacity(0.15) : Color.red.opacity(0.10))
        )
        .foregroundStyle(confidence == .high ? .green : confidence == .medium ? .orange : .red)
    }

    // MARK: - Preflight

    private var preflightSection: some View {
        let storage = viewModel.storagePreflight
        let ram = viewModel.ramAssessment
        return Section("Device Preflight") {
            LabeledContent("Download storage", value: ByteCountFormatter.string(fromByteCount: storage.requiredBytes, countStyle: .file))
            LabeledContent("Safety margin", value: ByteCountFormatter.string(fromByteCount: storage.safetyMarginBytes, countStyle: .file))
            LabeledContent("Available storage", value: ByteCountFormatter.string(fromByteCount: storage.availableBytes, countStyle: .file))
            if !storage.canProceed {
                Label("Not enough storage. No download can start.", systemImage: "internaldrive.fill.badge.xmark").foregroundStyle(.red)
            }
            LabeledContent("Estimated RAM", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: ram.estimatedBytes), countStyle: .memory))
            LabeledContent("Device RAM", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: ram.physicalBytes), countStyle: .memory))
        }
    }
}
