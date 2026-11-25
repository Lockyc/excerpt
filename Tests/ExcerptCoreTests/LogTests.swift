import ExcerptCore
import Foundation
import Testing

struct LogTests {
    @Test func aFrameworkErrorNamesItsDomainCodeAndUnderlyingChain() {
        let root = NSError(
            domain: "E5RTErrorDomain", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "precompiled operation failed"])
        let error = NSError(
            domain: "com.apple.TextRecognition.CRImageReader", code: 1,
            userInfo: [NSUnderlyingErrorKey: root, "stage": "recognition"])
        let described = Log.describe(error)
        #expect(described.contains("com.apple.TextRecognition.CRImageReader 1"))
        #expect(described.contains("stage=recognition"))
        #expect(described.contains("E5RTErrorDomain 13: precompiled operation failed"))
    }

    @Test func multipleUnderlyingErrorsAreEachNamed() {
        let error = NSError(
            domain: "Outer", code: 2,
            userInfo: [
                NSMultipleUnderlyingErrorsKey: [
                    NSError(domain: "A", code: 3), NSError(domain: "B", code: 4),
                ]
            ])
        let described = Log.describe(error)
        #expect(described.contains("A 3"))
        #expect(described.contains("B 4"))
    }

    @Test func aSwiftErrorKeepsItsCase() {
        enum Failure: Error { case cropFailed(width: Int) }
        #expect(Log.describe(Failure.cropFailed(width: 7)).contains("cropFailed(width: 7)"))
    }
}
