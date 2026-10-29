/// GIF's variable-length LZW: codes grow from `minimumCodeSize + 1` bits to 12, and a full table
/// is answered with a clear code rather than frozen, so long recordings keep compressing.
public enum GIFLZW {
    /// The packed code stream for `indices`, starting with a clear code and ending with the
    /// end-of-information code: the bytes a GIF image carries in sub-blocks after its minimum
    /// code size. Every index must be below `1 << minimumCodeSize`.
    public static func encode(_ indices: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        precondition((2...8).contains(minimumCodeSize))
        let alphabet = 1 << minimumCodeSize
        let clear = alphabet
        let end = clear + 1
        var writer = BitWriter(capacity: indices.count / 2 + 16)
        var codeSize = minimumCodeSize + 1
        writer.write(clear, bits: codeSize)
        guard let first = indices.first else {
            writer.write(end, bits: codeSize)
            return writer.finish()
        }
        // The string table as a flat trie: the code for `prefix` followed by `symbol` sits at
        // `prefix * alphabet + symbol`, 0 meaning absent (no added code is ever 0). A clear
        // zeroes only the keys it filled, not the whole table.
        var table = [UInt16](repeating: 0, count: 4096 * alphabet)
        var filled: [Int] = []
        filled.reserveCapacity(4096)
        var next = end + 1
        var prefix = Int(first)
        indices.withUnsafeBufferPointer { input in
            table.withUnsafeMutableBufferPointer { trie in
                for position in 1..<input.count {
                    let symbol = Int(input[position])
                    precondition(symbol < alphabet)
                    let key = prefix * alphabet + symbol
                    let code = trie[key]
                    if code != 0 {
                        prefix = Int(code)
                        continue
                    }
                    writer.write(prefix, bits: codeSize)
                    if next == 4096 {
                        writer.write(clear, bits: codeSize)
                        for filledKey in filled { trie[filledKey] = 0 }
                        filled.removeAll(keepingCapacity: true)
                        codeSize = minimumCodeSize + 1
                        next = end + 1
                    } else {
                        if next >= 1 << codeSize { codeSize += 1 }
                        trie[key] = UInt16(next)
                        filled.append(key)
                        next += 1
                    }
                    prefix = symbol
                }
            }
        }
        writer.write(prefix, bits: codeSize)
        // The decoder adds its entry for the last code before reading the end code, so it may
        // already have grown a bit.
        if next >= 1 << codeSize && codeSize < 12 { codeSize += 1 }
        writer.write(end, bits: codeSize)
        return writer.finish()
    }
}

/// Packs codes least-significant bit first, as GIF reads them.
private struct BitWriter {
    private var bytes: [UInt8] = []
    private var accumulator: UInt64 = 0
    private var count = 0

    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    mutating func write(_ code: Int, bits: Int) {
        accumulator |= UInt64(code) << UInt64(count)
        count += bits
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            count -= 8
        }
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: accumulator)) }
        return bytes
    }
}
