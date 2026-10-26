import ExcerptCore

/// One control on the item bar, carrying its current value.
enum ItemOption: Equatable {
    case color(Palette)
    case size(StrokeWidth)
    case background(Bool)
    /// Whether a path is closed; disabled on an open path of two points, which has no shape to
    /// close.
    case closed(Bool, enabled: Bool)
    /// A path's fill; disabled while the path is open, which can't show one.
    case fill(Bool, enabled: Bool)
    case moveEarlier(enabled: Bool)
    case moveLater(enabled: Bool)
    /// A recording blur's span starting, or ending, with the frame at the playhead; disabled
    /// with the reason while that can't be set.
    case spanStart(unavailable: String?)
    case spanEnd(unavailable: String?)
    /// A recording blur back over the whole clip; disabled when it already is.
    case wholeClip(enabled: Bool)
    case delete
}

extension EditorModel {
    /// The item bar for the text being typed or the path being built, else the selection, else
    /// (under the crop tool) the crop; nil when there is nothing to show a bar for.
    var itemOptions: [ItemOption]? {
        if let typing {
            return Self.options(for: typing, canMoveEarlier: false, canMoveLater: false)
        }
        if let building,
            let annotation = document.annotations.first(where: { $0.id == building.id })
        {
            return Self.options(for: annotation, canMoveEarlier: false, canMoveLater: false)
        }
        switch selection {
        case .annotation(let id):
            guard let annotation = document.annotations.first(where: { $0.id == id }) else {
                return nil
            }
            return Self.options(
                for: annotation, canMoveEarlier: canMoveStepEarlier,
                canMoveLater: canMoveStepLater)
        case .seam:
            return [.delete]
        case nil:
            return tool == .crop && document.crop != nil ? [.delete] : nil
        }
    }

    /// The options each kind of annotation takes: the one place they are decided.
    static func options(
        for annotation: Annotation, canMoveEarlier: Bool, canMoveLater: Bool
    ) -> [ItemOption] {
        let color = ItemOption.color(annotation.color)
        let size = ItemOption.size(annotation.width)
        switch annotation.shape {
        case .arrow, .rectangle:
            return [color, size, .delete]
        case .path(let points, let closed, let fill):
            return [
                color, size, .closed(closed, enabled: closed || points.count >= 3),
                .fill(fill, enabled: closed), .delete,
            ]
        case .highlight:
            return [color, .delete]
        case .text(_, _, let background):
            return [color, size, .background(background == true), .delete]
        case .step:
            return [
                color, size, .moveEarlier(enabled: canMoveEarlier),
                .moveLater(enabled: canMoveLater), .delete,
            ]
        case .blur:
            return [.delete]
        }
    }
}
