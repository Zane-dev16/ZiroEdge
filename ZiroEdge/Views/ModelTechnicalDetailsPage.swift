// ModelTechnicalDetailsPage.swift
// ZiroEdge — Privacy-first local AI assistant
//
// The deep end. Everything the surface deliberately does not say: catalog
// identity, the exact runtime shape, the evidence (or estimate) behind the
// memory floor, the digits of every artifact digest, and the current numbers
// the admission policy compares.
//
// This page exists because of a trade the app now makes on purpose: the
// surface speaks plain English, and the precise facts stay one tap away for
// the reader who wants them. Deleting the facts would have been the lazy fix;
// hiding them behind a single entry point is the honest one.
//
// Everything here is read-only. Nothing on this page can change a model, a
// download, or a load decision.

import Darwin
import SwiftUI

/// Reachable from a model's page via "Technical Details".
struct ModelTechnicalDetailsPage: View {
    let model: AIModel
    @ObservedObject var viewModel: ModelsViewModel

    private var profile: MemoryProfile? {
        MemoryProfileRegistry.profile(for: model)
    }

    var body: some View {
        List {
            identitySection
            runtimeShapeSection
            memorySection
            filesSection
            explainerSection
        }
        .scrollContentBackground(.hidden)
        .background(ZiroTheme.pageBackground.ignoresSafeArea())
        .listRowBackground(ZiroTheme.raisedBackground)
        .navigationTitle("Technical Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section("Model") {
            technicalRow("Name", model.displayName)
            technicalRow("Catalog ID", model.id)
            technicalRow("Source", model.isImported ? "Hugging Face import" : "Built into ZiroEdge")
            technicalRow("Quantization", model.quantization)
            technicalRow("Total size", model.formattedSize)
            technicalRow("Catalog version", ModelCatalogValidator.catalogVersion)
            if let repository = model.huggingFaceProvenance?.repositoryID,
               let revision = model.huggingFaceProvenance?.revision {
                technicalRow("Repository", repository)
                technicalRow("Revision", String(revision.prefix(12)))
            }
        }
    }

    // MARK: - Runtime shape

    private var runtimeShapeSection: some View {
        Section("Runtime Shape") {
            technicalRow("Capability", model.modelType == .vision ? "Text + images" : "Text")
            technicalRow("Context length", "\(model.config.contextLength) tokens")
            technicalRow("Batch", "\(model.config.batchSize)")
            technicalRow("Micro-batch", "\(model.config.microBatchSize)")
            technicalRow("Threads", "\(model.config.threadCount)")
            technicalRow(
                "GPU offload",
                model.config.gpuLayers > 0
                    ? "Metal, \(model.config.gpuLayers) layers (clamped to model)"
                    : "CPU only"
            )
            technicalRow("mmap", model.config.useMmap ? "Enabled" : "Disabled")
            technicalRow("KV cache", model.config.f16KV ? "f16" : "f32")
            technicalRow(
                "Image support",
                model.requiresMMProj ? "Required (projector)" : "Not used"
            )
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            if let profile {
                technicalRow("Shape ID", profile.id)
                technicalRow("Evidence", RuntimeEligibilityCopy.technicalDetail(
                    for: profile.runtimeEligibility
                ))
                technicalRow(
                    "Measured full workload",
                    MemoryLoadDecision.format(bytes: profile.measuredFullWorkloadPeakDeltaBytes ?? 0)
                        .ifAbsent(profile.measuredFullWorkloadPeakDeltaBytes)
                )
                technicalRow(
                    "Measured load delta",
                    MemoryLoadDecision.format(bytes: profile.measuredLoadDeltaBytes ?? 0)
                        .ifAbsent(profile.measuredLoadDeltaBytes)
                )
                technicalRow(
                    "Static estimate",
                    MemoryLoadDecision.format(bytes: profile.estimatedLoadDeltaBytes ?? 0)
                        .ifAbsent(profile.estimatedLoadDeltaBytes)
                )
                technicalRow("Admission floor", requiredHeadroomLabel(profile))
                technicalRow(
                    "Physics floor",
                    MemoryLoadDecision.format(bytes: profile.minimumPhysicalRAMBytes)
                )
                technicalRow(
                    "Policy",
                    "×\(MemoryProfile.productionSafetyMultiplier) safety, "
                        + "+\(MemoryLoadDecision.format(bytes: MemoryProfile.productionReserveBytes)) reserve, "
                        + "rounded to \(MemoryLoadDecision.format(bytes: MemoryProfile.roundingQuantumBytes))"
                )
                technicalRow("Policy version", "\(profile.policyVersion)")
            } else {
                // Structurally unreachable for a catalog row; say so rather than
                // render an empty section the reader would have to interpret.
                Text("No runtime memory shape is registered for this model.")
                    .font(ZiroType.supporting)
                    .foregroundStyle(ZiroTheme.warningText)
            }
            technicalRow("Device memory", MemoryLoadDecision.format(bytes: physicalMemory()))
            technicalRow("Headroom now", MemoryLoadDecision.format(bytes: currentHeadroom()))
        } header: {
            Text("Memory")
        } footer: {
            Text(
                "The admission floor is what ZiroEdge requires before it starts this "
                + "model. It is the largest measured (or, with no measurement, "
                + "estimated) footprint, inflated by the policy above."
            )
        }
    }

    private func requiredHeadroomLabel(_ profile: MemoryProfile) -> String {
        if let measured = try? profile.requiredProcessHeadroomBytes() {
            return "\(MemoryLoadDecision.format(bytes: measured)) (measured)"
        }
        if let experimental = try? profile.experimentalRequiredProcessHeadroomBytes() {
            return "\(MemoryLoadDecision.format(bytes: experimental)) (measured load)"
        }
        if let estimated = try? profile.estimatedRequiredProcessHeadroomBytes() {
            return "\(MemoryLoadDecision.format(bytes: estimated)) (estimated)"
        }
        return "None — the app will not attempt a load"
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            technicalRow("File name", ModelManagerService.baseModelPath(for: model).lastPathComponent)
            technicalRow("Size", "\(model.baseFileSizeBytes) bytes")
            digestRow(model.baseSHA256)
            if let projectorName = model.mmprojURL?.lastPathComponent {
                technicalRow("Image file", projectorName)
                technicalRow("Size", "\(model.mmprojFileSizeBytes ?? 0) bytes")
                if let digest = model.mmprojSHA256 { digestRow(digest) }
            }
        } header: {
            Text("Files")
        } footer: {
            Text(
                "Files are verified against these digests every time availability is "
                + "confirmed. A mismatch means the file is replaced, not patched."
            )
        }
    }

    private func digestRow(_ digest: String) -> some View {
        VStack(alignment: .leading, spacing: ZiroTheme.Spacing.micro) {
            Text("SHA-256")
                .font(ZiroType.caption)
                .foregroundStyle(ZiroTheme.secondaryText)
            Text(digest)
                .font(ZiroType.technical(.caption2))
                .foregroundStyle(ZiroTheme.tertiaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, ZiroTheme.Spacing.micro)
    }

    // MARK: - Explainer

    private var explainerSection: some View {
        Section {
            Text(
                "This page is read-only. Load decisions use the numbers above plus a "
                + "live reading of free memory; nothing here can be edited."
            )
            .font(ZiroType.supporting)
            .foregroundStyle(ZiroTheme.secondaryText)
        } header: {
            Text("About")
        }
    }

    // MARK: - Helpers

    private func technicalRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(ZiroType.supporting)
                .foregroundStyle(ZiroTheme.secondaryText)
            Spacer(minLength: ZiroTheme.Spacing.small)
            Text(value)
                .font(ZiroType.technical(.caption))
                .foregroundStyle(ZiroTheme.primaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, ZiroTheme.Spacing.micro)
    }

    private func physicalMemory() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    private func currentHeadroom() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}

private extension String {
    /// Render "Not measured" instead of a formatted zero, so an absent
    /// measurement can never be mistaken for a measured 0 bytes.
    func ifAbsent(_ value: UInt64?) -> String {
        value == nil ? "Not measured" : self
    }
}
