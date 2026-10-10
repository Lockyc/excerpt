/// Each row of a frame reduced to a hash of its pixels over a range of columns, plus whether the
/// row is one colour there. The stitcher compares signatures, never pixels, so matching a frame
/// pair costs one pass over each frame.
public struct RowSignatures: Equatable, Sendable {
    public let hashes: [UInt64]
    /// Rows that are a single colour across the columns: blank space, which matches blank space
    /// at any offset and so is no evidence of one.
    public let uniform: [Bool]

    /// An empty or out-of-range column range is clamped to the buffer; nothing left gives every
    /// row the same hash and marks it uniform.
    public init(_ buffer: PixelBuffer, columns: Range<Int>) {
        let columns = columns.clamped(to: 0..<buffer.width)
        var hashes = [UInt64](repeating: 0, count: buffer.height)
        var uniform = [Bool](repeating: true, count: buffer.height)
        buffer.bytes.withUnsafeBytes { raw in
            for y in 0..<buffer.height {
                let rowStart = y * buffer.width * 4
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a over 32-bit pixels
                var same = true
                if let firstColumn = columns.first {
                    let first = raw.loadUnaligned(
                        fromByteOffset: rowStart + firstColumn * 4, as: UInt32.self)
                    for x in columns {
                        let pixel = raw.loadUnaligned(
                            fromByteOffset: rowStart + x * 4, as: UInt32.self)
                        hash = (hash ^ UInt64(pixel)) &* 0x100_0000_01B3
                        if pixel != first { same = false }
                    }
                }
                hashes[y] = hash
                uniform[y] = same
            }
        }
        self.hashes = hashes
        self.uniform = uniform
    }
}
