import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct RowSignatureTests {
    @Test func everyMarkedRowOfThePageIsUnique() {
        let page = ScrollFixtures.page(width: 90, height: 400)
        let signatures = RowSignatures(page, columns: 0..<90)
        let marked = (0..<400).filter { !signatures.uniform[$0] }
        #expect(marked.count > 250)
        #expect(Set(marked.map { signatures.hashes[$0] }).count == marked.count)
    }

    @Test func blankRowsAreUniformAndAlike() {
        let page = ScrollFixtures.page(width: 90, height: 40)
        let signatures = RowSignatures(page, columns: 0..<90)
        #expect(signatures.uniform[15] && signatures.uniform[35])
        #expect(signatures.hashes[15] == signatures.hashes[35])
    }

    @Test func columnsOutsideTheBufferAreClamped() {
        let page = ScrollFixtures.page(width: 20, height: 4)
        #expect(RowSignatures(page, columns: 0..<50) == RowSignatures(page, columns: 0..<20))
        #expect(RowSignatures(page, columns: 30..<50).uniform.allSatisfy { $0 })
    }
}
