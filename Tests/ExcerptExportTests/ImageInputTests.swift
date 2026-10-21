import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ExcerptExport

@Suite struct ImageInputTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("excerpt-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(
        _ image: CGImage, as type: UTType, dpi: Double?, to url: URL,
        properties extra: [CFString: Any] = [:]
    ) throws {
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] =
            dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] } ?? [:]
        properties.merge(extra) { _, new in new }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// A saved, cut capture: rows 100..<200 of a 100×300 sheet removed at 2×.
    static func savedCapture(in folder: URL) throws -> (primary: URL, edits: EditDocument) {
        let store = LibraryStore(folder: folder)
        let original = Fixtures.sheet(width: 100, height: 300)
        let primary = try store.saveCapture(original, scale: 2, at: Date())
        let edits = EditDocument(scale: 2, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)])
        try store.saveEdits(primary: primary, original: original, edits: edits)
        return (primary, edits)
    }

    static func master(of primary: URL) -> URL {
        primary.deletingLastPathComponent()
            .appendingPathComponent(
                LibraryNaming.originalName(forPrimary: primary.lastPathComponent))
    }

    /// A file of `bytes` that takes no disk space.
    static func sparse(_ url: URL, bytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    /// One PNG chunk: length, type, data, CRC.
    static func chunk(_ type: String, _ payload: [UInt8]) -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian, Array.init)
        }
        let body = Array(type.utf8) + payload
        return Data(bigEndian(UInt32(payload.count)) + body + bigEndian(PNGChunks.crc32(body)))
    }

    /// `png` with `chunks` inserted before its `IEND`, the last 12 bytes.
    static func inserting(_ chunks: [Data], into png: Data) -> Data {
        var out = png.prefix(png.count - 12)
        for chunk in chunks { out.append(chunk) }
        out.append(png.suffix(12))
        return out
    }

    @Test func aForeignRetinaScreenshotReadsAtTwoTimes() throws {
        let url = try Self.folder().appendingPathComponent("Screenshot 2026-10-10.png")
        try Self.write(Fixtures.sheet(width: 80, height: 60), as: .png, dpi: 144, to: url)
        let input = try ImageInput.load(url)
        #expect(input.edits == EditDocument(scale: 2, salt: input.edits.salt))
        #expect(input.primary == url)
        #expect(input.original.width == 80)
    }

    /// Review focus: a JPEG is read like any image, at the scale its DPI gives.
    @Test func aJPEGWithoutDPIReadsAtOneTimes() throws {
        let url = try Self.folder().appendingPathComponent("photo.jpg")
        try Self.write(Fixtures.sheet(width: 80, height: 60), as: .jpeg, dpi: nil, to: url)
        let input = try ImageInput.load(url)
        #expect(input.edits.scale == 1)
        #expect(input.edits.cuts.isEmpty)
        #expect(input.primary == url)
    }

    /// A phone photo stores its pixels sideways with an EXIF orientation; it reads upright.
    @Test func anOrientedJPEGReadsUpright() throws {
        let url = try Self.folder().appendingPathComponent("phone.jpg")
        // Orientation 6: the stored image is rotated 90° clockwise to display.
        try Self.write(
            Fixtures.sheet(width: 80, height: 60), as: .jpeg, dpi: nil, to: url,
            properties: [kCGImagePropertyOrientation: 6])
        let input = try ImageInput.load(url)
        #expect(input.original.width == 60)
        #expect(input.original.height == 80)
    }

    @Test func aMasterBringsItsEditsAndThePrimarysName() throws {
        let (primary, edits) = try Self.savedCapture(in: try Self.folder())
        for url in [primary, Self.master(of: primary)] {
            let input = try ImageInput.load(url)
            #expect(input.edits == edits)
            #expect(input.original.height == 300)
            #expect(input.primary.standardizedFileURL == primary.standardizedFileURL)
        }
    }

    /// Review focus (privacy): a primary changed outside excerpt — here one pixel, as a redaction
    /// box would — is read as itself; the master's original, with what the user hid, never is.
    @Test func aChangedPrimaryReadsFlatNotFromItsMaster() throws {
        let (primary, _) = try Self.savedCapture(in: try Self.folder())
        var pixels = PixelBuffer(try PNGCodec.decode(Data(contentsOf: primary)).image)
        pixels.bytes[0...3] = [0, 0, 0, 255]
        try PNGCodec.encode(pixels.makeImage(), scale: 2).write(to: primary)
        let input = try ImageInput.load(primary)
        #expect(input.edits.cuts.isEmpty)
        #expect(input.edits.scale == 2)
        #expect(PixelBuffer(input.original) == pixels)
        #expect(input.original.height != 300)
    }

    /// One reason per error, in each surface's voice: the command line names the path then the
    /// reason, with `excerpt` lowercase; the app names the file in its title and gives the
    /// reason alone, with `Excerpt` capitalised.
    @Test func reasonsSpeakInEachSurfacesVoice() {
        let path = "/tmp/shot.png"
        let errors: [ImageInputError] = [
            .missing(path), .folder(path), .unreadable(path, "permission denied"),
            .notAnImage(path), .fileTooLarge(path, bytes: 600 * 1_048_576),
            .tooManyPixels(path, width: 200, height: 300),
            .rendersTooLarge(path, width: 113_000, height: 2),
            .damagedEdits(path, EditDocumentError.damaged.errorDescription!),
        ]
        for error in errors {
            #expect(error.path == path)
            #expect(error.errorDescription == "\(path): \(error.reason(product: "excerpt"))")
            let app = error.reason(product: "Excerpt")
            #expect(!app.contains(path), "\(app)")
            #expect(!app.contains("excerpt"), "\(app)")
            #expect(app.first!.isUppercase && app.hasSuffix("."), "\(app)")
        }
        #expect(
            ImageInputError.notAnImage(path).reason(product: "Excerpt")
                == "It isn't an image Excerpt can read.")
        #expect(
            ImageInputError.notAnImage(path).errorDescription
                == "/tmp/shot.png: It isn't an image excerpt can read.")
    }

    /// Review focus: a file that isn't an image fails with a message, never a trap.
    @Test func whatIsNotAnImageFailsWithItsPath() throws {
        let folder = try Self.folder()
        let text = folder.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: text)
        let empty = folder.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        let missing = folder.appendingPathComponent("gone.png")
        #expect(throws: ImageInputError.notAnImage(text.path)) { try ImageInput.load(text) }
        #expect(throws: ImageInputError.notAnImage(empty.path)) { try ImageInput.load(empty) }
        #expect(throws: ImageInputError.missing(missing.path)) { try ImageInput.load(missing) }
        #expect(throws: ImageInputError.folder(folder.path)) { try ImageInput.load(folder) }
        let message = ImageInputError.notAnImage(text.path).errorDescription!
        #expect(message.contains("notes.png"))
    }

    @Test func aTruncatedPNGFailsWithItsPath() throws {
        let url = try Self.folder().appendingPathComponent("cut-short.png")
        let png = try PNGCodec.encode(Fixtures.sheet(width: 200, height: 200), scale: 2)
        try png.prefix(40).write(to: url)
        #expect(throws: ImageInputError.notAnImage(url.path)) { try ImageInput.load(url) }
        try png.prefix(png.count / 2).write(to: url)
        #expect(throws: ImageInputError.notAnImage(url.path)) { try ImageInput.load(url) }
    }

    /// ImageIO decodes a JPEG cut short as a whole image, its missing rows grey; it is refused.
    @Test(arguments: [false, true]) func aTruncatedJPEGFailsWithItsPath(progressive: Bool) throws {
        let url = try Self.folder().appendingPathComponent("cut-short.jpg")
        try Self.write(
            Fixtures.sheet(width: 200, height: 200), as: .jpeg, dpi: nil, to: url,
            properties: [
                kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: progressive]
            ])
        let jpeg = try Data(contentsOf: url)
        _ = try ImageInput.load(url)
        try (jpeg + Data([0, 0, 0x12, 0x34])).write(to: url)
        _ = try ImageInput.load(url)
        for length in [jpeg.count / 2, jpeg.count - 2] {
            try jpeg.prefix(length).write(to: url)
            #expect(throws: ImageInputError.notAnImage(url.path)) { try ImageInput.load(url) }
        }
    }

    /// Review focus: a FIFO would block a read forever; it is refused at once.
    @Test(.timeLimit(.minutes(1))) func aFIFOOrDeviceIsRefused() throws {
        let fifo = try Self.folder().appendingPathComponent("pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ImageInputError.unreadable(fifo.path, "not a regular file")) {
            try ImageInput.load(fifo)
        }
        let device = URL(fileURLWithPath: "/dev/zero")
        #expect(throws: ImageInputError.unreadable(device.path, "not a regular file")) {
            try ImageInput.load(device)
        }
    }

    /// A link reads its target, and the size limit is the target's.
    @Test func aSymlinkIsReadThroughToItsTarget() throws {
        let folder = try Self.folder()
        let image = folder.appendingPathComponent("real.png")
        try Self.write(Fixtures.sheet(width: 80, height: 60), as: .png, dpi: 144, to: image)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        #expect(try ImageInput.load(link).original.width == 80)

        let huge = folder.appendingPathComponent("huge.png")
        let bytes = ImageInput.maximumBytes + 1
        try Self.sparse(huge, bytes: UInt64(bytes))
        let hugeLink = folder.appendingPathComponent("huge-link.png")
        try FileManager.default.createSymbolicLink(at: hugeLink, withDestinationURL: huge)
        #expect(throws: ImageInputError.fileTooLarge(hugeLink.path, bytes: bytes)) {
            try ImageInput.load(hugeLink)
        }
        let dangling = folder.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: folder.appendingPathComponent("nothing.png"))
        #expect(throws: ImageInputError.missing(dangling.path)) { try ImageInput.load(dangling) }
    }

    /// Review focus: a huge image is refused from its header, before its pixels are decoded.
    @Test func anImageOverThePixelLimitIsRefused() throws {
        let folder = try Self.folder()
        let url = folder.appendingPathComponent("huge.png")
        try Self.write(Fixtures.sheet(width: 200, height: 300), as: .png, dpi: 144, to: url)
        #expect(throws: ImageInputError.tooManyPixels(url.path, width: 200, height: 300)) {
            try ImageInput.load(url, maximumPixels: 50_000)
        }
        #expect(throws: ImageInputError.tooManyPixels(url.path, width: 200, height: 300)) {
            try ImageInput.load(url, maximumSide: 250)
        }
        let jpeg = folder.appendingPathComponent("huge.jpg")
        try Self.write(Fixtures.sheet(width: 200, height: 300), as: .jpeg, dpi: nil, to: jpeg)
        #expect(throws: ImageInputError.tooManyPixels(jpeg.path, width: 200, height: 300)) {
            try ImageInput.load(jpeg, maximumPixels: 50_000)
        }
        let message = ImageInputError.tooManyPixels(url.path, width: 200, height: 300)
            .errorDescription!
        #expect(message.contains("200×300"))
    }

    /// Review focus: cuts add a seam gap each, so a master with thousands of them is refused for
    /// the size it would render at, before anything is drawn.
    @Test func aMasterWhoseRenderIsOverTheLimitIsRefused() throws {
        let master = try Self.folder().appendingPathComponent("Excerpt x original.png")
        let original = Fixtures.sheet(width: 60_000, height: 2)
        let cuts = stride(from: 0, to: 60_000, by: 60).map {
            Cut(axis: .vertical, lower: $0, upper: $0 + 1)
        }
        #expect(cuts.count == EditDocument.maximumCutsPerAxis)
        let edits = EditDocument(scale: 3, cuts: cuts)
        try MasterFile.encode(original: original, edits: edits).write(to: master)
        // 59,000 kept columns and 1,000 seams of 54 pixels.
        let width = 59_000 + 1_000 * 54
        #expect(throws: ImageInputError.rendersTooLarge(master.path, width: width, height: 2)) {
            try ImageInput.load(master)
        }
        #expect(throws: ImageInputError.rendersTooLarge(master.path, width: width, height: 2)) {
            try ImageInput.load(master, maximumPixels: width * 2 - 1, maximumSide: width + 1)
        }
        let message = ImageInputError.rendersTooLarge(master.path, width: width, height: 2)
            .errorDescription!
        #expect(message.contains("renders at \(width)×2 pixels"))
    }

    /// The app checks a capture it loaded before the editor renders it: a crafted
    /// master whose cuts render it past the limits, and larger than its original, is refused.
    @Test func aLoadedCaptureIsCheckedForTheSizeItRendersAt() throws {
        let cuts = stride(from: 0, to: 4000, by: 2).map {
            Cut(axis: .vertical, lower: $0, upper: $0 + 1)
        }
        let edits = EditDocument(scale: 3, cuts: cuts)
        let width = 2000 + 2000 * 54
        #expect(throws: ImageInputError.rendersTooLarge("m.png", width: width, height: 2)) {
            try ImageInput.checkEditable("m.png", width: 4000, height: 2, edits: edits)
        }
        try ImageInput.checkEditable(
            "m.png", width: 4000, height: 2, edits: EditDocument(scale: 3))
    }

    /// An original past the limits — a crafted or huge PNG opened from Finder — is refused
    /// before the editor decodes it, edited or not.
    @Test func anOriginalPastTheLimitsFailsTheAppCheck() throws {
        let plain = EditDocument(scale: 1)
        #expect(throws: ImageInputError.tooManyPixels("p.png", width: 40_000, height: 40_000)) {
            try ImageInput.checkEditable("p.png", width: 40_000, height: 40_000, edits: plain)
        }
        let side = ImageInput.maximumSide + 1
        #expect(throws: ImageInputError.tooManyPixels("p.png", width: side, height: 1)) {
            try ImageInput.checkEditable("p.png", width: side, height: 1, edits: plain)
        }
    }

    /// A render no larger than an original within the limits is let through, even at the limit.
    @Test func aRenderNoLargerThanItsOriginalPassesTheAppCheck() throws {
        let (width, height) = (6_720, Stitcher.defaultMaximumHeight)
        try ImageInput.checkEditable(
            "p.png", width: width, height: height, edits: EditDocument(scale: 2))
        let cropped = EditDocument(
            scale: 2, crop: PixelRect(x: 0, y: 0, width: width, height: height - 10))
        try ImageInput.checkEditable("p.png", width: width, height: height, edits: cropped)
    }

    /// Excerpt's own largest capture: a full-width scroll capture of a 6K-class display at 2×,
    /// stopped at the stitcher's height cap. It reads with `excerpt read` and opens in the app.
    @Test func excerptsTallestCaptureIsWithinTheLimits() throws {
        let (width, height) = (3456, Stitcher.defaultMaximumHeight)
        #expect(ImageInput.maximumPixels >= 6_720 * Stitcher.defaultMaximumHeight)
        let context = PixelBuffer.makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let primary = try LibraryStore(folder: try Self.folder())
            .saveCapture(context.makeImage()!, scale: 2, at: Date())
        let input = try ImageInput.load(primary)
        #expect(input.original.width == width && input.original.height == height)
        try ImageInput.checkEditable(
            primary.path, width: width, height: height, edits: input.edits)
    }

    /// Review focus: the master beside a primary is checked like any input before it is read;
    /// one that fails leaves the primary to read as itself.
    @Test func aMasterOverTheLimitsLeavesThePrimaryFlat() throws {
        let (primary, _) = try Self.savedCapture(in: try Self.folder())
        // The primary is 100×(200 + 36); the master's original is 100×300.
        let flat = try ImageInput.load(primary, maximumPixels: 25_000)
        #expect(flat.edits.cuts.isEmpty)
        #expect(flat.original.height == 236)

        try FileManager.default.removeItem(at: Self.master(of: primary))
        try Self.sparse(Self.master(of: primary), bytes: UInt64(ImageInput.maximumBytes + 1))
        let beside = try ImageInput.load(primary)
        #expect(beside.edits.cuts.isEmpty)
        #expect(beside.original.height == 236)
    }

    @Test func damagedEditsFailNamingTheMaster() throws {
        let folder = try Self.folder()
        let master = folder.appendingPathComponent("Excerpt x original.png")
        let png = try PNGCodec.encode(Fixtures.sheet(width: 20, height: 20), scale: 1)
        try PNGChunks.settingText("{nonsense", keyword: PNGChunks.editsKeyword, in: png)
            .write(to: master)
        let reason = EditDocumentError.damaged.errorDescription!
        #expect(throws: ImageInputError.damagedEdits(master.path, reason)) {
            try ImageInput.load(master)
        }
        let message = ImageInputError.damagedEdits(master.path, reason).errorDescription!
        #expect(message.contains("Excerpt x original.png"))
        #expect(message.contains(reason))
    }

    /// Review focus (privacy): an edits chunk excerpt can't parse is damaged edits, never a
    /// reason to read the master flat and show its unedited original.
    @Test func anUnreadableEditsChunkIsDamagedEdits() throws {
        let folder = try Self.folder()
        let png = try PNGCodec.encode(Fixtures.sheet(width: 20, height: 20), scale: 1)
        let keyword = Array(PNGChunks.editsKeyword.utf8)
        let payloads: [String: [UInt8]] = [
            "compressed": keyword + [0, 1, 0, 0, 0] + Array("x".utf8),
            "short": keyword + [0],
            "unterminated": keyword,
        ]
        for (name, payload) in payloads {
            let master = folder.appendingPathComponent("Excerpt \(name) original.png")
            try Self.inserting([Self.chunk("iTXt", payload)], into: png).write(to: master)
            #expect(
                throws: ImageInputError.damagedEdits(
                    master.path, EditDocumentError.damaged.errorDescription!), "\(name)"
            ) { try ImageInput.load(master) }
        }
    }

    /// Review focus: chunks are scanned in place, so a PNG of hundreds of thousands of them reads
    /// in bounded time and memory.
    @Test(.timeLimit(.minutes(1))) func aPNGOfManyChunksLoadsQuickly() throws {
        let master = try Self.folder().appendingPathComponent("Excerpt many original.png")
        let edits = EditDocument(scale: 1, cuts: [Cut(axis: .horizontal, lower: 5, upper: 10)])
        let png = try MasterFile.encode(
            original: Fixtures.sheet(width: 20, height: 20), edits: edits)
        let empty = Self.chunk("teXt", [])
        try Self.inserting(Array(repeating: empty, count: 300_000), into: png).write(to: master)
        let start = ContinuousClock.now
        let input = try ImageInput.load(master)
        #expect(input.edits == edits)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    /// Review focus: odd encodings and containers read or fail with a typed error, never a trap.
    @Test func unusualFormatsNeverTrap() throws {
        let folder = try Self.folder()
        let sheet = Fixtures.sheet(width: 40, height: 30)
        var images: [(String, CGImage, UTType)] = []
        for (name, space, bits, info) in [
            (
                "cmyk", CGColorSpace(name: CGColorSpace.genericCMYK)!, 8,
                CGImageAlphaInfo.none.rawValue
            ),
            (
                "sixteen", CGColorSpace(name: CGColorSpace.sRGB)!, 16,
                CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            ),
            ("gray", CGColorSpaceCreateDeviceGray(), 8, CGImageAlphaInfo.none.rawValue),
        ] as [(String, CGColorSpace, Int, UInt32)] {
            let context = CGContext(
                data: nil, width: 40, height: 30, bitsPerComponent: bits, bytesPerRow: 0,
                space: space, bitmapInfo: info)!
            context.draw(sheet, in: CGRect(x: 0, y: 0, width: 40, height: 30))
            images.append((name, context.makeImage()!, name == "cmyk" ? .jpeg : .png))
            images.append((name + "-tiff", context.makeImage()!, .tiff))
        }
        images.append(("indexed", sheet, .gif))
        for (name, image, type) in images {
            let url = folder.appendingPathComponent(name)
                .appendingPathExtension(for: type)
            try Self.write(image, as: type, dpi: nil, to: url)
            let input = try ImageInput.load(url)
            #expect(input.original.width == 40, "\(name)")
            #expect(input.original.height == 30, "\(name)")
        }

        let animated = folder.appendingPathComponent("animated.gif")
        let destination = CGImageDestinationCreateWithURL(
            animated as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, sheet, nil)
        CGImageDestinationAddImage(destination, Fixtures.sheet(width: 40, height: 30), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try ImageInput.load(animated).original.width == 40)

        let pdf = folder.appendingPathComponent("page.pdf")
        var box = CGRect(x: 0, y: 0, width: 40, height: 30)
        let document = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        document.beginPDFPage(nil)
        document.draw(sheet, in: box)
        document.endPDFPage()
        document.closePDF()
        #expect(throws: ImageInputError.notAnImage(pdf.path)) { try ImageInput.load(pdf) }
    }
}

@Suite struct ImageInputMarginTests {
    @Test func aHugeMarginIsRefusedBeforeDrawing() {
        let far = Annotation(
            id: 1,
            shape: .text(
                origin: CGPoint(x: -EditDocument.coordinateLimit, y: 10), string: "x"))
        let edits = EditDocument(
            scale: 1, annotations: [far], marginColor: RGBA(r: 1, g: 2, b: 3, a: 255), salt: 1)
        #expect(throws: ImageInputError.self) {
            try ImageInput.checkEditable("m.png", width: 100, height: 100, edits: edits)
        }
    }
}
