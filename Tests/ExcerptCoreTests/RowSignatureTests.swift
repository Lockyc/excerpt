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

    @Test func aThumbInTheExcludedStripDoesNotChangeTheSignatures() {
        let page = ScrollFixtures.page(width: 90, height: 100)
        let withThumb = ScrollFixtures.thumb(page, y: 10, height: 40)
        #expect(
            RowSignatures(withThumb, columns: 0..<74) == RowSignatures(page, columns: 0..<74))
        #expect(RowSignatures(withThumb, columns: 0..<90) != RowSignatures(page, columns: 0..<90))
    }

    @Test func aRowBlankInsideTheColumnsButMarkedOutsideIsUniform() {
        let page = ScrollFixtures.paint(width: 20, height: 1) { x, _ in
            x >= 15 ? ScrollFixtures.ink : ScrollFixtures.paper
        }
        #expect(RowSignatures(page, columns: 0..<10).uniform == [true])
        #expect(RowSignatures(page, columns: 0..<20).uniform == [false])
    }

    @Test func aOnePixelEditInsideTheColumnsChangesTheHash() {
        let page = ScrollFixtures.page(width: 90, height: 20)
        var edited = page
        let i = (5 * 90 + 40) * 4
        edited.bytes[i] = edited.bytes[i] ^ 0xFF
        let before = RowSignatures(page, columns: 0..<74)
        let after = RowSignatures(edited, columns: 0..<74)
        #expect(before.hashes[5] != after.hashes[5])
        #expect(before.hashes[4] == after.hashes[4])
    }

    @Test func whiteAndGreyRowsAreBothUniformWithDifferentHashes() {
        let grey = RGBA(r: 128, g: 128, b: 128, a: 255)
        let page = ScrollFixtures.stack([
            ScrollFixtures.paint(width: 30, height: 1) { _, _ in ScrollFixtures.paper },
            ScrollFixtures.paint(width: 30, height: 1) { _, _ in grey },
        ])
        let signatures = RowSignatures(page, columns: 0..<30)
        #expect(signatures.uniform == [true, true])
        #expect(signatures.hashes[0] != signatures.hashes[1])
    }

    /// Rows are hashed in pixel pairs across four lanes; every column counts wherever it falls,
    /// the last of an odd count and the columns past the last full group of four pairs included.
    @Test(arguments: [1, 2, 7, 8, 9, 17, 31])
    func everyColumnOfAnyWidthCounts(width: Int) {
        let blank = ScrollFixtures.paint(width: width + 3, height: 1) { _, _ in
            ScrollFixtures.paper
        }
        let columns = 3..<(width + 3)  // an odd start, so pairs straddle the buffer's pairs
        let plain = RowSignatures(blank, columns: columns)
        #expect(plain.uniform == [true])
        for x in columns {
            let marked = ScrollFixtures.paint(width: width + 3, height: 1) { px, _ in
                px == x ? ScrollFixtures.ink : ScrollFixtures.paper
            }
            let signature = RowSignatures(marked, columns: columns)
            #expect(signature.uniform == [width == 1], "column \(x)")
            #expect(signature.hashes != plain.hashes, "column \(x)")
        }
    }
}
