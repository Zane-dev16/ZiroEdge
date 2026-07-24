import Foundation
import CryptoKit
@testable import ZiroEdge

enum TestModelFixtures {
    static func gguf(fill: UInt8 = 0xA5, count: Int = 16) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00, 0x00, 0x00])
        data.append(contentsOf: repeatElement(fill, count: max(0, count - data.count)))
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func text(id: String = "fixture-\(UUID().uuidString.lowercased())", data: Data = gguf()) -> AIModel {
        AIModel(
            id: id,
            displayName: "Fixture Model",
            description: "Deterministic local test artifact",
            modelType: .text,
            baseURL: URL(string: "https://example.com/\(id).gguf")!,
            mmprojURL: nil,
            baseFileSizeBytes: Int64(data.count),
            mmprojFileSizeBytes: nil,
            baseSHA256: sha256(data),
            mmprojSHA256: nil,
            quantization: "Q4_K_M",
            config: .llama32,
            minimumDeviceRAM: 0,
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
    }

    static func install(_ data: Data, for model: AIModel) throws {
        ModelManagerService.ensureModelsDirectory()
        try data.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
    }
}
