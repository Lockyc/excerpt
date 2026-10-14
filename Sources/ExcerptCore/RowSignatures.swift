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
                let start = (y * buffer.width + columns.lowerBound) * 4
                (hashes[y], uniform[y]) = Self.signature(
                    UnsafeRawBufferPointer(rebasing: raw[start..<(start + columns.count * 4)]))
            }
        }
        self.hashes = hashes
        self.uniform = uniform
    }

    /// FNV-1a over the row's pixels two at a time, in four lanes that take every fourth pair:
    /// the lanes' multiplies don't wait on each other, so a row hashes several times faster than
    /// through one chain. Each step is a bijection of the lane's state, so rows that differ in
    /// one pixel never share a hash. A trailing odd pixel goes to its own step.
    private static func signature(_ row: UnsafeRawBufferPointer) -> (UInt64, Bool) {
        let basis: UInt64 = 0xCBF2_9CE4_8422_2325
        let prime: UInt64 = 0x100_0000_01B3
        var lanes = (basis, basis, basis, basis)
        guard row.count >= 4 else { return (basis, true) }
        let first = row.loadUnaligned(as: UInt32.self)
        let firstPair = UInt64(first) | UInt64(first) << 32
        var differs: UInt64 = 0
        let pairs = row.count / 8
        var i = 0
        while i + 4 <= pairs {
            let a = row.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
            let b = row.loadUnaligned(fromByteOffset: i * 8 + 8, as: UInt64.self)
            let c = row.loadUnaligned(fromByteOffset: i * 8 + 16, as: UInt64.self)
            let d = row.loadUnaligned(fromByteOffset: i * 8 + 24, as: UInt64.self)
            lanes.0 = (lanes.0 ^ a) &* prime
            lanes.1 = (lanes.1 ^ b) &* prime
            lanes.2 = (lanes.2 ^ c) &* prime
            lanes.3 = (lanes.3 ^ d) &* prime
            differs |= (a ^ firstPair) | (b ^ firstPair) | (c ^ firstPair) | (d ^ firstPair)
            i += 4
        }
        while i < pairs {
            let a = row.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
            lanes.0 = (lanes.0 ^ a) &* prime
            differs |= a ^ firstPair
            i += 1
        }
        if row.count % 8 != 0 {
            let last = row.loadUnaligned(fromByteOffset: row.count - 4, as: UInt32.self)
            lanes.1 = (lanes.1 ^ UInt64(last)) &* prime
            differs |= UInt64(last ^ first)
        }
        var hash = lanes.0
        hash = (hash ^ lanes.1) &* prime
        hash = (hash ^ lanes.2) &* prime
        hash = (hash ^ lanes.3) &* prime
        return (hash, differs == 0)
    }
}
