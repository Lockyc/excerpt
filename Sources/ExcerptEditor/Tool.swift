import ExcerptCore

/// The editor's tools, each on a single-letter key.
public enum Tool: CaseIterable {
    case select
    case arrow
    case rectangle
    case text
    case highlight
    case blur
    case crop
    case cut

    public var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .text: "t"
        case .highlight: "h"
        case .blur: "b"
        case .crop: "k"
        case .cut: "c"
        }
    }

    public var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .text: "Text"
        case .highlight: "Highlight"
        case .blur: "Blur"
        case .crop: "Crop"
        case .cut: "Cut"
        }
    }

    /// An SF Symbol for the toolbar.
    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .blur: "square.grid.3x3.fill"
        case .crop: "crop"
        case .cut: "scissors"
        }
    }

    /// The tool on `key`, case-insensitively.
    public init?(key: Character) {
        guard let tool = Tool.allCases.first(where: { $0.key == Character(key.lowercased()) })
        else { return nil }
        self = tool
    }
}

extension Tool {
    /// Whether this tool draws `shape`'s kind of annotation.
    func draws(_ shape: Shape) -> Bool {
        switch (self, shape) {
        case (.arrow, .arrow), (.rectangle, .rectangle), (.text, .text), (.highlight, .highlight),
            (.blur, .blur):
            true
        default: false
        }
    }
}
