import Foundation

/// Numbers as excerpt writes them for people, with thousands separators: lengths in points,
/// labelled `px` the way they are measured on screen, and plain counts. The one number
/// formatter: the seam pill, the scrolling HUD and error messages all read it.
public enum LengthText {
    /// `1,240 px` for 2,480 pixels at 2×.
    public static func points(_ pixels: Int, scale: Double) -> String {
        "\(count(Int((Double(pixels) / scale).rounded()))) px"
    }

    /// `5,041`.
    public static func count(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number))!
    }
}
