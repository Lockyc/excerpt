import CoreGraphics

extension EditDocument {
    /// Gives a document without a margin colour `color`, so the picture can grow from here on —
    /// but only while that leaves its render as it was saved: a document with an annotation past
    /// its edge keeps clipping it, so opening it never changes what its primary shows, and an
    /// annotation far off the image can't grow it past the size checked before it opened.
    public mutating func adoptMarginColor(_ color: RGBA, width: Int, height: Int) {
        guard marginColor == nil else { return }
        var adopted = self
        adopted.marginColor = color
        guard
            Renderer.map(width: width, height: height, edits: adopted)
                == Renderer.map(width: width, height: height, edits: self)
        else { return }
        self = adopted
    }

    /// Sets the crop, dropping the annotations it takes out of view: those that showed under the
    /// previous crop (or the whole image) and lie wholly outside the new one. One already outside
    /// the previous crop, such as a caption placed in the margin, stays.
    public mutating func setCrop(_ crop: PixelRect?, width: Int, height: Int) {
        let full = PixelRect(x: 0, y: 0, width: width, height: height)
        let before = (self.crop?.clamped(width: width, height: height) ?? full).cgRect
        let after = (crop?.clamped(width: width, height: height) ?? full).cgRect
        let scale = self.scale
        annotations.removeAll { annotation in
            let bounds = AnnotationGeometry.bounds(of: annotation, scale: scale)
            return bounds.intersects(before) && !bounds.intersects(after)
        }
        self.crop = crop
    }
}
