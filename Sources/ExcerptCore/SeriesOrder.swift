import Foundation

/// The order a series opens in: its captures by creation date, oldest first.
public enum SeriesOrder {
    /// `items` in creation order with duplicates dropped; those in `open`, already in an editor
    /// of their own, go to `alreadyOpen` instead, so their windows come forward.
    public static func arrange(
        _ items: [(url: URL, created: Date)], open: Set<URL>
    ) -> (series: [URL], alreadyOpen: [URL]) {
        var seen = Set<URL>()
        let unique = items.filter { seen.insert($0.url).inserted }
        let sorted = unique.sorted { $0.created < $1.created }.map(\.url)
        return (sorted.filter { !open.contains($0) }, sorted.filter { open.contains($0) })
    }
}
