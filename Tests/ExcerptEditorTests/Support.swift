import CoreGraphics
import ExcerptCore

func note(_ id: Int, _ rect: CGRect) -> Annotation {
    Annotation(id: id, shape: .rectangle(rect: rect))
}
