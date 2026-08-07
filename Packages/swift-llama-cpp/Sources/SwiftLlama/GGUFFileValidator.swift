import Foundation
import llama

/// Uses llama.cpp's GGUF parser to validate the complete metadata and tensor
/// descriptor tables without allocating tensor payloads.
public enum GGUFFileValidator {
    public static func isStructurallyValid(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            return false
        }
        let fileSize = fileSizeNumber.uint64Value
        guard fileSize >= 24, hasReasonableHeader(atPath: path) else { return false }

        let parameters = gguf_init_params(no_alloc: true, ctx: nil)
        guard let context = path.withCString({ gguf_init_from_file($0, parameters) }) else {
            return false
        }
        defer { gguf_free(context) }

        let version = gguf_get_version(context)
        let tensorCount = gguf_get_n_tensors(context)
        guard (version == 2 || version == 3), tensorCount > 0 else { return false }

        let dataOffset = UInt64(gguf_get_data_offset(context))
        guard dataOffset <= fileSize else { return false }
        let payloadBytes = fileSize - dataOffset

        for index in 0..<tensorCount {
            let offset = UInt64(gguf_get_tensor_offset(context, index))
            let size = UInt64(gguf_get_tensor_size(context, index))
            let (end, overflow) = offset.addingReportingOverflow(size)
            guard !overflow, size > 0, end <= payloadBytes else { return false }
        }
        return true
    }

    /// Reject absurd table counts before entering the native parser. This keeps
    /// malformed untrusted files from requesting unbounded descriptor storage.
    private static func hasReasonableHeader(atPath path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24 else {
            return false
        }
        guard Array(header[0..<4]) == [0x47, 0x47, 0x55, 0x46] else { return false }
        let tensorCount = littleEndianUInt64(header, offset: 8)
        let metadataCount = littleEndianUInt64(header, offset: 16)
        return tensorCount > 0
            && tensorCount <= 1_000_000
            && metadataCount <= 100_000
    }

    private static func littleEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        (0..<8).reduce(into: UInt64(0)) { value, byte in
            value |= UInt64(data[offset + byte]) << UInt64(byte * 8)
        }
    }
}
