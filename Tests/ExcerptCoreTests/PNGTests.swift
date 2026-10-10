import ExcerptTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

    @Test func scaleComesFromDPIOnlyInTheRetinaRange() {
        #expect(PNGCodec.scale(dpi: nil) == 1)
        #expect(PNGCodec.scale(dpi: 72) == 1)
        #expect(PNGCodec.scale(dpi: 144) == 2)
        #expect(PNGCodec.scale(dpi: 216) == 3)
        #expect(PNGCodec.scale(dpi: 300) == 1)
        #expect(PNGCodec.scale(dpi: 1e300) == 1)
        #expect(PNGCodec.scale(dpi: .nan) == 1)
        #expect(PNGCodec.scale(dpi: 0) == 1)
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
            var chunks: [[UInt8]] = []
            try PNGChunks.forEachChunk(in: png) { type, range, bytes in
                if type == PNGChunks.ChunkType("IDAT") { chunks.append(Array(bytes[range])) }
            }
            return chunks
        }
        #expect(try idat(rewritten) == idat(master))
        #expect(try PNGChunks.chunkTypes(in: rewritten).filter { $0 == "iTXt" }.count == 1)
        #expect(try PNGChunks.chunkTypes(in: rewritten).last == "IEND")
        #expect(try MasterFile.decode(rewritten).edits?.cuts.count == 1)
    }

    @Test func rejectsNonPNG() {
        #expect(throws: PNGError.notPNG) { try PNGChunks.chunkTypes(in: Data("hello".utf8)) }
    }

    @Test func decodeRejectsAJPEGEvenWhenNamedPNG() throws {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, Fixtures.sheet(width: 40, height: 40), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(throws: PNGError.notPNG) { try PNGCodec.decode(data as Data) }
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
