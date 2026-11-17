import ExcerptCore

/// The editor's tools, each on a single-letter key.
public enum Tool: CaseIterable {
    case select
    case arrow
    case rectangle
    case ellipse
    case path
    case text
    case step
    case click
    case highlight
    case blur
    case patch
    case replace
    case crop
    case cut

    public var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .path: "p"
        case .text: "t"
        case .step: "n"
        case .click: "m"
        case .highlight: "h"
        case .blur: "b"
        case .patch: "e"
        case .replace: "x"
        case .crop: "k"
        case .cut: "c"
        }
    }

    public var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .path: "Path"
        case .text: "Text"
        case .step: "Step"
        case .click: "Click"
        case .highlight: "Highlight"
        case .blur: "Blur"
        case .patch: "Patch"
        case .replace: "Replace"
        case .crop: "Crop"
        case .cut: "Cut"
        }
    }

    /// An SF Symbol for the toolbar; nil for a tool whose glyph `ToolGlyph` draws, since no
    /// symbol reads as it.
    public var symbol: String? {
        switch self {
        case .select: nil
        case .arrow: nil
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .path: "scribble.variable"
        case .text: "textformat"
        case .step: "1.circle"
        case .click: "cursorarrow.click"
        case .highlight: nil
        case .blur: "square.grid.3x3.fill"
        case .patch: "square.fill"
        case .replace: "character.cursor.ibeam"
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
        case (.arrow, .arrow), (.rectangle, .rectangle), (.ellipse, .ellipse), (.path, .path),
            (.text, .text),
            (.highlight, .highlight),
            (.blur, .blur), (.patch, .patch), (.step, .step), (.click, .click):
            true
        default: false
        }
    }
}
