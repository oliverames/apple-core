// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading the text out of a picture or a PDF that is already on disk.
//
// `capture_read_text` recognises what is on screen right now. The far more
// common question is about a file: a screenshot somebody dropped in a shared
// folder, a scanned invoice, a PDF whose pages are images of pages. Vision
// does that recognition on this Mac, for free, with no provider key and
// nothing leaving the machine — which is what separates this from the donor
// servers, where reading an image means shipping it to a hosted model.
//
// The bounds live here rather than in the service so they can be tested:
// which files are worth trying at all, how many pages of a long PDF one call
// may rasterise, and how a character budget cuts a result off.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

public enum CaptureImageTextError: LocalizedError, Equatable {
    case unsupportedType(path: String, type: String?)
    case fileTooLarge(path: String, bytes: Int, limit: Int)
    case unreadableImage(String)
    case emptyDocument(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedType(path, type):
            let described = type.map { " It is \($0)." } ?? ""
            return
                "\(path) is not an image or a PDF, so there is nothing to recognise text in.\(described) "
                + "Use filesystem_read for a text file."
        case let .fileTooLarge(path, bytes, limit):
            return
                "\(path) is \(bytes) bytes, over the \(limit)-byte limit for text recognition. "
                + "Recognition rasterises the whole file in memory."
        case let .unreadableImage(path):
            return
                "\(path) could not be decoded as an image. It may be truncated, or its contents may not match its extension."
        case let .emptyDocument(path):
            return "\(path) has no pages to recognise."
        }
    }
}

public enum CaptureImageText {
    public static let defaultMaxPages = 5
    public static let maximumMaxPages = 25
    public static let defaultMaxCharacters = 20_000
    public static let maximumMaxCharacters = 200_000
    /// Recognition decompresses the whole image, so the limit is about memory
    /// on the Mac doing the work rather than about the response size.
    public static let maximumFileBytes = 64 * 1024 * 1024

    public static func clampedPages(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxPages }
        return min(requested, maximumMaxPages)
    }

    public static func clampedCharacters(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxCharacters }
        return min(requested, maximumMaxCharacters)
    }

    /// True for the file types Vision can be pointed at: raster images and
    /// PDFs. Asked of the uniform type rather than the extension, so a JPEG
    /// named `.dat` is recognised and a `.png` that is really a spreadsheet is
    /// refused before anything tries to decode it.
    public static func isSupported(_ type: UTType?) -> Bool {
        guard let type else { return false }
        if type.conforms(to: .pdf) { return true }
        // Vision reads rasters. A vector type conforms to .image but has no
        // pixels to recognise until something renders it, so it is refused
        // with the same message as a spreadsheet rather than returning an
        // empty result that reads as "no text in this file".
        if type.conforms(to: .svg) { return false }
        return type.conforms(to: .image)
    }

    public static func isPDF(_ type: UTType?) -> Bool {
        type?.conforms(to: .pdf) ?? false
    }

    /// Which pages of a document one call covers, given a 1-based starting
    /// page a caller may have taken from a previous call's `nextPage`.
    ///
    /// Returns an empty range when the start is past the end, which is a
    /// finished document rather than an error.
    public static func pageRange(
        pageCount: Int,
        startingAt requestedStart: Int?,
        maxPages: Int
    ) -> Range<Int> {
        guard pageCount > 0 else { return 0 ..< 0 }
        let start = max(1, requestedStart ?? 1) - 1
        guard start < pageCount else { return 0 ..< 0 }
        let end = min(pageCount, start + max(1, maxPages))
        return start ..< end
    }

    public struct Budgeted: Equatable, Sendable {
        public let lines: [String]
        public let characters: Int
        public let truncated: Bool

        public init(lines: [String], characters: Int, truncated: Bool) {
            self.lines = lines
            self.characters = characters
            self.truncated = truncated
        }
    }

    /// Fills a character budget with recognised lines, in order.
    ///
    /// It stops at the first line that would overflow rather than skipping it
    /// and taking a later, shorter one: recognised text is a document, and a
    /// caller reading a receipt should get its beginning intact rather than
    /// its beginning with a hole in it.
    public static func budgeted(lines: [String], maxCharacters: Int) -> Budgeted {
        var kept: [String] = []
        var characters = 0
        for line in lines {
            if characters + line.count > maxCharacters {
                return Budgeted(lines: kept, characters: characters, truncated: true)
            }
            characters += line.count
            kept.append(line)
        }
        return Budgeted(lines: kept, characters: characters, truncated: false)
    }
}

/// One page's worth of read text, and how it was obtained.
public struct CaptureImageTextPage: Equatable, Sendable {
    /// 1-based, as a person counts pages.
    public let page: Int
    /// "text" when the page carried real characters, "ocr" when they had to be
    /// recognised from pixels. Worth reporting: one is exact and the other is
    /// a guess with a good hit rate.
    public let source: String
    public let lines: [String]

    public init(page: Int, source: String, lines: [String]) {
        self.page = page
        self.source = source
        self.lines = lines
    }
}

/// The part of reading a file that touches Vision and PDFKit, kept out of the
/// service so it can be run against real fixtures in a test rather than only
/// against a live Mac with a connector attached.
public enum CaptureImageTextReader {
    /// Recognises the text in one image.
    public static func recognize(_ image: CGImage, languages: [String] = []) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Recognises the text in an image file.
    public static func readImage(at url: URL, languages: [String] = []) throws -> (
        lines: [String], pixelWidth: Int, pixelHeight: Int
    ) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CaptureImageTextError.unreadableImage(url.path)
        }
        return (try recognize(image, languages: languages), image.width, image.height)
    }

    /// Reads one PDF page, preferring the characters the page already carries.
    ///
    /// Recognising a page whose text is right there is strictly worse than
    /// reading it: recognition invents mistakes the file does not contain.
    public static func readPage(_ page: PDFPage, number: Int, languages: [String] = []) throws
        -> CaptureImageTextPage
    {
        let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !embedded.isEmpty {
            return CaptureImageTextPage(
                page: number,
                source: "text",
                lines: embedded.components(separatedBy: .newlines)
            )
        }
        return CaptureImageTextPage(
            page: number,
            source: "ocr",
            lines: try recognize(render(page), languages: languages)
        )
    }

    /// Rasterises one PDF page for recognition.
    ///
    /// Drawn at twice its natural size, because recognition of small print at
    /// one-to-one is noticeably worse, and clamped so a poster-sized page does
    /// not become a hundred-megapixel bitmap.
    public static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let identifier = page.document?.documentURL?.path ?? "PDF"
        guard bounds.width > 0, bounds.height > 0 else {
            throw CaptureImageTextError.unreadableImage(identifier)
        }
        let maximumDimension: CGFloat = 4000
        let scale = min(2, maximumDimension / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw CaptureImageTextError.unreadableImage(identifier) }

        // A PDF page is transparent where nothing is drawn, and recognising
        // dark text on a transparent background reads as dark text on black.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)

        guard let image = context.makeImage() else {
            throw CaptureImageTextError.unreadableImage(identifier)
        }
        return image
    }
}
