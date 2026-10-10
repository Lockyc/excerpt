import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct PNGTests {
    @Test func crcMatchesTheKnownVector() {
        #expect(PNGChunks.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func codecRoundTripsPixelsAndScale() throws {
        let image = Fixtures.sheet(width: 90, height: 60)
        let decoded = try PNGCodec.decode(PNGCodec.encode(image, scale: 2))
        #expect(decoded.scale == 2)
        #expect(PixelBuffer(decoded.image) == PixelBuffer(image))
    }

    @Test func textChunkRoundTripsAndReplaces() throws {
        let png = try PNGCodec.encode(Fixtures.sheet(width: 20, height: 20), scale: 1)
        let once = try PNGChunks.settingText("first", keyword: "k", in: png)
        let twice = try PNGChunks.settingText("second ⋯ unicode", keyword: "k", in: once)
        #expect(try PNGChunks.text(keyword: "k", in: twice) == "second ⋯ unicode")
        #expect(try PNGChunks.chunkTypes(in: twice).filter { $0 == "iTXt" }.count == 1)
        #expect(try PNGChunks.chunkTypes(in: twice).last == "IEND")
        _ = try PNGCodec.decode(twice)  // still a valid PNG
    }

    @Test func replacingTheEditsChunkLeavesImageDataUntouched() throws {
        let master = try MasterFile.encode(
            original: Fixtures.sheet(width: 90, height: 60), edits: EditDocument(scale: 2))
        let newJSON = String(
            decoding: try EditDocument(
                scale: 2, cuts: [Cut(axis: .horizontal, lower: 10, upper: 30)]
            )
            .encoded(), as: UTF8.self)
        let rewritten = try PNGChunks.settingText(
            newJSON, keyword: PNGChunks.editsKeyword, in: master)
        func idat(_ png: Data) throws -> [[UInt8]] {
            try PNGChunks.chunks(in: png).filter { $0.type == "IDAT" }.map(\.data)
        }
        #expect(try idat(rewritten) == idat(master))
        #expect(try PNGChunks.chunkTypes(in: rewritten).filter { $0 == "iTXt" }.count == 1)
        #expect(try PNGChunks.chunkTypes(in: rewritten).last == "IEND")
        #expect(try MasterFile.decode(rewritten).edits?.cuts.count == 1)
    }

    @Test func rejectsNonPNG() {
        #expect(throws: PNGError.notPNG) { try PNGChunks.chunkTypes(in: Data("hello".utf8)) }
    }

    @Test func masterFileRoundTrips() throws {
        let image = Fixtures.sheet(width: 90, height: 60)
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 10, upper: 30)])
        let (original, decodedEdits) = try MasterFile.decode(
            MasterFile.encode(original: image, edits: edits))
        #expect(decodedEdits == edits)
        #expect(original.scale == 2)
        #expect(PixelBuffer(original.image) == PixelBuffer(image))
    }

    @Test func plainPNGHasNoEdits() throws {
        let png = try PNGCodec.encode(Fixtures.sheet(width: 20, height: 20), scale: 1)
        #expect(try MasterFile.decode(png).edits == nil)
        #expect(try PNGChunks.text(keyword: PNGChunks.editsKeyword, in: png) == nil)
    }
}
