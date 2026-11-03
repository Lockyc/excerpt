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
}
