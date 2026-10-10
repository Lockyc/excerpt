/// The look of a cut's seam. Sizes are in points and scale with the capture.
public struct SeamStyle: Equatable, Sendable {
    public var gapPoints: Double = 18
    public var tearAmplitudePoints: Double = 3
    public var tearStepPoints: Double = 6
    public var gapColor = RGBA(r: 236, g: 236, b: 240, a: 255)

    public static let standard = SeamStyle()

    public func gapPixels(scale: Double) -> Int { Int((gapPoints * scale).rounded()) }
    public func amplitudePixels(scale: Double) -> Double { tearAmplitudePoints * scale }
    public func stepPixels(scale: Double) -> Double { tearStepPoints * scale }
}

/// SplitMix64: a tiny deterministic PRNG, so a tear's shape depends only on its seed.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}
