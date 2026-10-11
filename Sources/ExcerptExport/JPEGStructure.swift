import Foundation

/// A JPEG's marker structure, walked without decoding: ImageIO decodes a JPEG cut short without
/// complaint, filling the missing rows with grey, so a file must reach its end-of-image marker.
enum JPEGStructure {
    /// Whether `data` runs from its start-of-image marker through every segment and scan to an
    /// end-of-image marker. Segments are skipped by their lengths, so an embedded thumbnail's
    /// own end marker doesn't count; anything after the end marker is ignored.
    static func isComplete(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
            var i = 2
            while true {
                guard i < count, bytes[i] == 0xFF else { return false }
                while i < count, bytes[i] == 0xFF { i += 1 }
                guard i < count else { return false }
                let marker = bytes[i]
                i += 1
                switch marker {
                case 0xD9:
                    return true
                case 0x01, 0xD0...0xD8:
                    continue
                default:
                    guard i + 2 <= count else { return false }
                    let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                    guard length >= 2 else { return false }
                    i += length
                    guard i <= count else { return false }
                    if marker == 0xDA {
                        // Entropy-coded data: 0xFF is followed by a stuffed 0x00, a restart
                        // marker or more fill; anything else is the next marker.
                        while i < count {
                            guard bytes[i] == 0xFF else {
                                i += 1
                                continue
                            }
                            guard i + 1 < count else { return false }
                            let next = bytes[i + 1]
                            if next == 0x00 || (0xD0...0xD7).contains(next) {
                                i += 2
                            } else if next == 0xFF {
                                i += 1
                            } else {
                                break
                            }
                        }
                    }
                }
            }
        }
    }
}
