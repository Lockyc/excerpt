import Foundation

/// On-screen lengths as excerpt writes them for people: points, labelled `px` the way they are
/// measured on screen, with thousands separators. The one length formatter: the seam pill and
/// the scrolling HUD both read it.
public enum LengthText {
    /// `1,240 px` for 2,480 pixels at 2×.
    public static func points(_ pixels: Int, scale: Double) -> String {
        let points = Int((Double(pixels) / scale).rounded())
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: points))!) px"
    }
}
