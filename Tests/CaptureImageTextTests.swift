import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers

@Suite("Recognised text from a file")
struct CaptureImageTextTests {
    @Test("Rasters and PDFs are worth trying; other types are refused up front")
    func supportedTypes() {
        #expect(CaptureImageText.isSupported(.png))
        #expect(CaptureImageText.isSupported(.jpeg))
        #expect(CaptureImageText.isSupported(.heic))
        #expect(CaptureImageText.isSupported(.tiff))
        #expect(CaptureImageText.isSupported(.pdf))
        #expect(!CaptureImageText.isSupported(.plainText))
        #expect(!CaptureImageText.isSupported(.zip))
        #expect(!CaptureImageText.isSupported(nil))
    }

    @Test("A vector image is refused rather than returning an empty result")
    func refusesVectors() {
        #expect(UTType.svg.conforms(to: .image))
        #expect(!CaptureImageText.isSupported(.svg))
    }

    @Test("PDFs are told apart from images")
    func detectsPDF() {
        #expect(CaptureImageText.isPDF(.pdf))
        #expect(!CaptureImageText.isPDF(.png))
        #expect(!CaptureImageText.isPDF(nil))
    }

    @Test("A page range starts where asked and stops at the page budget")
    func pagesRange() {
        #expect(CaptureImageText.pageRange(pageCount: 10, startingAt: nil, maxPages: 3) == 0 ..< 3)
        #expect(CaptureImageText.pageRange(pageCount: 10, startingAt: 4, maxPages: 3) == 3 ..< 6)
        // The last page of a document is included, not stepped over.
        #expect(CaptureImageText.pageRange(pageCount: 10, startingAt: 9, maxPages: 5) == 8 ..< 10)
        // Past the end is a finished document, not an error.
        #expect(CaptureImageText.pageRange(pageCount: 10, startingAt: 11, maxPages: 5) == 0 ..< 0)
        #expect(CaptureImageText.pageRange(pageCount: 0, startingAt: 1, maxPages: 5) == 0 ..< 0)
        // A zero or negative start is the first page, not a crash.
        #expect(CaptureImageText.pageRange(pageCount: 3, startingAt: 0, maxPages: 2) == 0 ..< 2)
        #expect(CaptureImageText.pageRange(pageCount: 3, startingAt: -4, maxPages: 2) == 0 ..< 2)
    }

    @Test("The character budget keeps the beginning intact")
    func budgetStopsAtTheFirstOverflow() {
        let result = CaptureImageText.budgeted(
            lines: ["12345", "67890", "x"],
            maxCharacters: 8
        )
        #expect(result.lines == ["12345"])
        #expect(result.characters == 5)
        #expect(result.truncated)
    }

    @Test("Everything that fits comes back untruncated")
    func budgetFits() {
        let result = CaptureImageText.budgeted(lines: ["ab", "cd"], maxCharacters: 10)
        #expect(result.lines == ["ab", "cd"])
        #expect(result.characters == 4)
        #expect(!result.truncated)
    }

    @Test("Bounds clamp to their documented limits")
    func clamps() {
        #expect(CaptureImageText.clampedPages(nil) == CaptureImageText.defaultMaxPages)
        #expect(CaptureImageText.clampedPages(2) == 2)
        #expect(CaptureImageText.clampedPages(9999) == CaptureImageText.maximumMaxPages)
        #expect(CaptureImageText.clampedCharacters(0) == CaptureImageText.defaultMaxCharacters)
        #expect(
            CaptureImageText.clampedCharacters(10_000_000) == CaptureImageText.maximumMaxCharacters
        )
    }
}

@Suite("Reading text out of real files")
struct CaptureImageTextReaderTests {
    /// A bitmap with one line of large text drawn on white, which is what a
    /// screenshot or a scan looks like to the recogniser.
    private static func rasterisedText(_ text: String) throws -> CGImage {
        let width = 900
        let height = 220
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, size: 96, at: CGPoint(x: 40, y: 70), in: context)
        return try #require(context.makeImage())
    }

    private static func draw(_ text: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 0, alpha: 1),
            ]
        )
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    /// A one-page PDF. `embeddingText` decides whether the page carries real
    /// characters or only a picture of them.
    private static func makePDF(_ text: String, embeddingText: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-ocr-\(UUID().uuidString).pdf")
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        if embeddingText {
            draw(text, size: 48, at: CGPoint(x: 60, y: 600), in: context)
        } else {
            let raster = try rasterisedText(text)
            context.draw(raster, in: CGRect(x: 60, y: 520, width: 480, height: 117))
        }
        context.endPDFPage()
        context.closePDF()
        try data.write(to: url)
        return url
    }

    @Test("A PDF page with real characters is read, not recognised")
    func readsTheTextLayer() throws {
        let url = try Self.makePDF("INVOICE 42", embeddingText: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let read = try CaptureImageTextReader.readPage(page, number: 1)
        #expect(read.source == "text")
        #expect(read.page == 1)
        #expect(read.lines.joined(separator: " ").contains("INVOICE 42"))
    }

    @Test("A PDF page that is only a picture of text is recognised")
    func recognisesAScannedPage() throws {
        let url = try Self.makePDF("INVOICE 42", embeddingText: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let read = try CaptureImageTextReader.readPage(page, number: 1)
        #expect(read.source == "ocr")
        #expect(read.lines.joined(separator: " ").contains("INVOICE"))
    }

    @Test("A page renders onto white, so dark text is not recognised against black")
    func rendersOntoWhite() throws {
        let url = try Self.makePDF("INVOICE 42", embeddingText: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let image = try CaptureImageTextReader.render(page)
        // Twice the page's own size, and no larger than the clamp.
        #expect(image.width == 1224)
        #expect(image.height == 1584)
        // The rendered page still reads, which it would not against a
        // transparent-turned-black background.
        #expect(try CaptureImageTextReader.recognize(image).joined().contains("INVOICE"))
    }

    @Test("An image file is recognised and reports its own size")
    func readsAnImageFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try Self.rasterisedText("INVOICE 42")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let read = try CaptureImageTextReader.readImage(at: url)
        #expect(read.pixelWidth == 900)
        #expect(read.pixelHeight == 220)
        #expect(read.lines.joined(separator: " ").contains("INVOICE"))
    }

    @Test("A file that is not an image is refused rather than read as empty")
    func refusesNonImages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try "not an image".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: CaptureImageTextError.unreadableImage(url.path)) {
            try CaptureImageTextReader.readImage(at: url)
        }
    }
}
