// StorageByteFormatter.swift
// ZiroEdge — Privacy-first local AI assistant

import Foundation

/// Single source of truth for human-readable byte counts shown to users.
///
/// Every screen must render the same byte count identically: formatting is
/// pinned to a POSIX locale so it never drifts with device locale settings,
/// and defaults to the decimal `.file` count style that matches model catalog
/// sizes. Negative values clamp to zero. Zero renders numerically ("0 bytes")
/// like every other rung of the unit ladder ("500 bytes", "1 kB", "8 GB") —
/// the default nonnumeric "Zero kB" spelling is disabled at the formatter.
enum StorageByteFormatter {
    /// `ByteCountFormatter` cannot pin a locale; its FormatStyle counterpart
    /// (`ByteCountFormatStyle`) can, so delegate to it. `spellsOutZero: false`
    /// keeps zero in the same numeric format as all non-zero values.
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Formats a byte count for display. Stateless per call, safe off-main.
    static func string(
        fromByteCount byteCount: Int64,
        countStyle: ByteCountFormatStyle.Style = .file
    ) -> String {
        max(byteCount, 0).formatted(
            ByteCountFormatStyle(
                style: countStyle,
                spellsOutZero: false,
                locale: posixLocale
            )
        )
    }
}
