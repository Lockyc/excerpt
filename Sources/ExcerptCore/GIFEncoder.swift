import Foundation

/// An animated GIF89a that loops forever, built frame by frame. Each frame stores only the
/// rectangle that changed since the previous frame, its unchanged pixels transparent over what
/// the viewer already shows, with its own colour table; a frame with no change extends the
/// previous frame's delay. Frames are written one behind, once their delay is known, so
/// `byteCount` grows as frames are added and a caller can abandon an attempt over budget.
public struct GIFEncoder {
    /// GitHub's upload limit for an image: the size a GIF must fit.
    public static let byteBudget = 10_000_000
    /// `byteBudget` as the user reads it: "10 MB".
    public static let byteBudgetText = "\(byteBudget / 1_000_000) MB"

    public let width: Int
    public let height: Int
    private var output: [UInt8] = []
    private var previous: PixelBuffer?
    private var pending: Frame?

    /// GIF's delay field is 16 bits of centiseconds.
    static let longestDelay = 65_535

    public init(width: Int, height: Int) {
        precondition((1...65_535).contains(width) && (1...65_535).contains(height))
        self.width = width
        self.height = height
        output += Array("GIF89a".utf8)
        output += Self.little(width) + Self.little(height)
        // No global colour table; background index and aspect ratio unused.
        output += [0x70, 0, 0]
        output += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
    }

    /// The bytes written so far: every frame but the last added.
    public var byteCount: Int { output.count }

    /// Adds `frame`, shown for `delay` centiseconds. Frames must be opaque and the encoder's size.
    public mutating func add(_ frame: PixelBuffer, delay: Int) {
        precondition(frame.width == width && frame.height == height && delay >= 0)
        guard let previous else {
            pending = encode(frame, in: (0, 0, width, height), over: nil, delay: delay)
            self.previous = frame
            return
        }
        guard let rect = Self.changedRect(frame, previous) else {
            pending!.delay += delay
            return
        }
        flush()
        pending = encode(frame, in: rect, over: previous, delay: delay)
        self.previous = frame
    }

    /// The finished GIF.
    public mutating func finish() -> Data {
        precondition(previous != nil, "a GIF needs a frame")
        flush()
        output.append(0x3B)
        return Data(output)
    }

    /// An encoded image waiting for its delay.
    private struct Frame {
        var image: [UInt8]
        var transparent: UInt8
        var delay: Int
    }

    /// Writes the pending frame. A delay past GIF's 16-bit field continues in blank 1×1 frames.
    private mutating func flush() {
        guard let frame = pending else { return }
        pending = nil
        var remaining = frame.delay
        var image = frame.image
        var transparent = frame.transparent
        repeat {
            let delay = min(remaining, Self.longestDelay)
            // Disposal 1, "do not dispose": the next frame draws over this one.
            output += [0x21, 0xF9, 0x04, 0x05] + Self.little(delay) + [transparent, 0x00]
            output += image
            remaining -= delay
            image = Self.blank
            transparent = 0
        } while remaining > 0
    }

    /// A transparent 1×1 image: a frame that holds the picture for more time.
    private static let blank: [UInt8] =
        [0x2C] + little(0) + little(0) + little(1) + little(1) + [0x80, 0, 0, 0, 0, 0, 0]
        + subBlocks(minimumCodeSize: 2, GIFLZW.encode([0], minimumCodeSize: 2))

    /// The image descriptor, local colour table and LZW data for `rect` of `frame`. Pixels equal
    /// to `previous` take the transparent index; the rest are quantised to 255 colours.
    private func encode(
        _ frame: PixelBuffer, in rect: (x: Int, y: Int, width: Int, height: Int),
        over previous: PixelBuffer?, delay: Int
    ) -> Frame {
        var changed: [RGBA] = []
        var positions: [Int32] = []
        changed.reserveCapacity(rect.width * rect.height)
        positions.reserveCapacity(rect.width * rect.height)
        let diffing = previous != nil
        frame.bytes.withUnsafeBytes { current in
            (previous ?? frame).bytes.withUnsafeBytes { earlier in
                let pixels = current.bindMemory(to: UInt32.self)
                let before = earlier.bindMemory(to: UInt32.self)
                let bytes = current.bindMemory(to: UInt8.self)
                for y in 0..<rect.height {
                    let row = (rect.y + y) * width + rect.x
                    for x in 0..<rect.width {
                        let pixel = row + x
                        if diffing && before[pixel] == pixels[pixel] { continue }
                        let i = pixel * 4
                        changed.append(
                            RGBA(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3]))
                        positions.append(Int32(y * rect.width + x))
                    }
                }
            }
        }
        let palette = GIFQuantizer.palette(changed, maximum: 255)
        let transparent = UInt8(palette.count)
        var indices = [UInt8](repeating: transparent, count: rect.width * rect.height)
        for (position, index) in zip(positions, GIFQuantizer.index(changed, into: palette)) {
            indices[Int(position)] = index
        }

        var tableBits = 1
        while 1 << tableBits < palette.count + 1 { tableBits += 1 }
        var image: [UInt8] = [0x2C]
        image += Self.little(rect.x) + Self.little(rect.y)
        image += Self.little(rect.width) + Self.little(rect.height)
        image.append(0x80 | UInt8(tableBits - 1))
        for colour in palette { image += [colour.r, colour.g, colour.b] }
        image += [UInt8](repeating: 0, count: ((1 << tableBits) - palette.count) * 3)
        let minimumCodeSize = max(2, tableBits)
        image += Self.subBlocks(
            minimumCodeSize: minimumCodeSize,
            GIFLZW.encode(indices, minimumCodeSize: minimumCodeSize))
        return Frame(image: image, transparent: transparent, delay: delay)
    }

    /// The bounding box of the pixels that differ between `frame` and `previous`, or nil when
    /// none do.
    static func changedRect(_ frame: PixelBuffer, _ previous: PixelBuffer)
        -> (x: Int, y: Int, width: Int, height: Int)?
    {
        let width = frame.width
        var top = -1
        var bottom = -1
        var left = width
        var right = -1
        frame.bytes.withUnsafeBytes { a in
            previous.bytes.withUnsafeBytes { b in
                let pa = a.bindMemory(to: UInt32.self)
                let pb = b.bindMemory(to: UInt32.self)
                for y in 0..<frame.height {
                    let row = y * width
                    guard memcmp(a.baseAddress! + row * 4, b.baseAddress! + row * 4, width * 4) != 0
                    else { continue }
                    if top < 0 { top = y }
                    bottom = y
                    var x = 0
                    while x < left, pa[row + x] == pb[row + x] { x += 1 }
                    left = min(left, x)
                    x = width - 1
                    while x > right, pa[row + x] == pb[row + x] { x -= 1 }
                    right = max(right, x)
                }
            }
        }
        guard top >= 0 else { return nil }
        return (left, top, right - left + 1, bottom - top + 1)
    }

    /// `data` in GIF's sub-blocks of at most 255 bytes, after its minimum code size and before
    /// the zero-length terminator.
    static func subBlocks(minimumCodeSize: Int, _ data: [UInt8]) -> [UInt8] {
        var blocks: [UInt8] = [UInt8(minimumCodeSize)]
        blocks.reserveCapacity(data.count + data.count / 255 + 3)
        var start = 0
        while start < data.count {
            let end = min(start + 255, data.count)
            blocks.append(UInt8(end - start))
            blocks += data[start..<end]
            start = end
        }
        blocks.append(0)
        return blocks
    }

    static func little(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}
