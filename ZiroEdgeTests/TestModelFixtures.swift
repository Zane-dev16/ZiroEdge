import Foundation
import CryptoKit
@testable import ZiroEdge

enum TestModelFixtures {
    /// Smallest useful GGUF fixture: one scalar F32 tensor with complete
    /// descriptor tables and an aligned payload. `count` remains a lower bound
    /// so large-file verification tests can cheaply add deterministic padding.
    static func gguf(fill: UInt8 = 0xA5, count: Int = 68) -> Data {
        var data = Data([0x47, 0x47, 0x55, 0x46]) // GGUF
        append(UInt32(3), to: &data)               // version
        append(UInt64(1), to: &data)               // tensor count
        append(UInt64(0), to: &data)               // metadata count
        append(UInt64(1), to: &data)               // tensor name length
        data.append(UInt8(ascii: "x"))
        append(UInt32(1), to: &data)               // dimensions
        append(UInt64(1), to: &data)               // scalar extent
        append(UInt32(0), to: &data)               // GGML_TYPE_F32
        append(UInt64(0), to: &data)               // payload-relative offset
        data.append(Data(repeating: 0, count: (32 - data.count % 32) % 32))
        data.append(contentsOf: [fill, fill, fill, fill])
        data.append(contentsOf: repeatElement(fill, count: max(0, count - data.count)))
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
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
            license: LicenseInfo(name: "Test", url: URL(string: "https://example.com/license")!, copyright: "Test")
        )
    }

    static func install(_ data: Data, for model: AIModel) throws {
        ModelManagerService.ensureModelsDirectory()
        try data.write(to: ModelManagerService.baseModelPath(for: model), options: .atomic)
    }
}
