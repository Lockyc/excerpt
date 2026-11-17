import ExcerptCore
import Foundation
import Testing

@testable import ExcerptEditor

@Suite struct AnnotationStyleTests {
    @Test func decodesASavedPreference() throws {
        let json = Data(#"{"color":"red","width":"medium","background":true}"#.utf8)
        #expect(
            try JSONDecoder().decode(AnnotationStyle.self, from: json)
                == AnnotationStyle(color: .palette(.red), width: .medium, background: true))
    }

    @Test func aPreferenceSavedBeforeStepSizesKeepsItsStyle() throws {
        let json = Data(#"{"color":"blue","width":"thick","background":false}"#.utf8)
        let style = try JSONDecoder().decode(AnnotationStyle.self, from: json)
        #expect(style.color == .palette(.blue) && style.width == .thick && !style.background)
        #expect(style.markerWidth == AnnotationStyle.initial.markerWidth)
    }
}
