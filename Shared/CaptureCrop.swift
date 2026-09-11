// SPDX-License-Identifier: GPL-3.0-or-later
//
// Crop geometry for `capture_take_screenshot`.
//
// A screenshot is the bluntest thing this app does: it returns whatever
// happened to be on screen, including the parts of it nobody asked about. A
// crop is the cheapest privacy control available here, so the rules around it
// are strict in one particular direction — a crop that cannot be honoured is
// an error, never a full-screen capture. Silently widening a request that was
// made specifically to narrow the result is the one failure mode worth
// engineering against.
//
// Coordinates are in points, relative to the origin of the capture target
// itself: the selected display's own top-left, or the window's own top-left.
// Never the global desktop space. On a Mac with a second display to the left
// of the built-in one, global coordinates are negative, and a caller that read
// a window's global frame and passed it here would otherwise get a confident
// answer about the wrong pixels.

import CoreGraphics
import Foundation

public enum CaptureCropError: LocalizedError, Equatable {
    case incomplete
    case notFinite
    case nonPositiveSize(width: Double, height: Double)
    case outsideTarget(requested: String, target: String)
    case targetHasNoSize

    public var errorDescription: String? {
        switch self {
        case .incomplete:
            return "crop needs all four of x, y, width and height."
        case .notFinite:
            return "crop values must be ordinary numbers."
        case let .nonPositiveSize(width, height):
            return "crop width and height must be greater than zero; got \(width) by \(height)."
        case let .outsideTarget(requested, target):
            return
                "The crop \(requested) does not fit inside the capture target, which is \(target) in points measured from its own top-left corner. "
                + "Nothing was captured: a crop that does not fit is an error rather than a full-screen screenshot. "
                + "Use capture_list_targets to read the target's size first."
        case .targetHasNoSize:
            return "The capture target reported no size, so a crop cannot be checked against it."
        }
    }
}

/// A validated crop, in both the coordinate spaces the capture needs.
public struct CaptureCropRegion: Equatable, Sendable {
    /// Points, relative to the target's own top-left. This is what
    /// `SCStreamConfiguration.sourceRect` wants.
    public let sourceRect: CGRect
    /// Pixels, after the quality scale factor. This is what the configuration's
    /// `width` and `height` want, and it is what the returned image measures.
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.sourceRect = sourceRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum CaptureCrop {
    /// Nothing smaller than this is worth returning, and a zero-pixel
    /// configuration is rejected by ScreenCaptureKit with a far less useful
    /// message than this one.
    public static let minimumPixelDimension = 1

    /// Validates a requested crop against the target's own size.
    ///
    /// `scale` is the quality scale factor already applied to uncropped
    /// screenshots. Applying the same factor to a crop keeps "medium quality"
    /// meaning one thing rather than two, and keeps a cropped capture visibly
    /// smaller than the whole screen at the same setting.
    public static func validate(
        x: Double?,
        y: Double?,
        width: Double?,
        height: Double?,
        targetWidth: Double,
        targetHeight: Double,
        scale: Double
    ) throws -> CaptureCropRegion {
        guard let x, let y, let width, let height else { throw CaptureCropError.incomplete }
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, scale.isFinite else {
            throw CaptureCropError.notFinite
        }
        guard targetWidth > 0, targetHeight > 0 else { throw CaptureCropError.targetHasNoSize }
        guard width > 0, height > 0 else {
            throw CaptureCropError.nonPositiveSize(width: width, height: height)
        }

        // Containment is checked before anything is captured, and the message
        // describes both rectangles: "does not fit" with no numbers sends the
        // caller straight back for another screenshot to measure against.
        guard x >= 0, y >= 0, x + width <= targetWidth, y + height <= targetHeight else {
            throw CaptureCropError.outsideTarget(
                requested: describe(x: x, y: y, width: width, height: height),
                target: "\(format(targetWidth)) by \(format(targetHeight))"
            )
        }

        let effectiveScale = scale > 0 ? scale : 1
        return CaptureCropRegion(
            sourceRect: CGRect(x: x, y: y, width: width, height: height),
            pixelWidth: max(minimumPixelDimension, Int((width * effectiveScale).rounded())),
            pixelHeight: max(minimumPixelDimension, Int((height * effectiveScale).rounded()))
        )
    }

    /// The pixel size an uncropped capture of a target should use.
    ///
    /// Separated out because the uncropped path had the same bug a crop would
    /// have inherited: it scaled every capture against the first display in
    /// the list, so a window on a second display, or any window at all on a
    /// Mac whose first display is the smaller one, was configured at the wrong
    /// size and came back letterboxed or cut.
    public static func scaledSize(
        targetWidth: Double,
        targetHeight: Double,
        scale: Double
    ) -> (width: Int, height: Int) {
        let effectiveScale = scale > 0 ? scale : 1
        return (
            max(minimumPixelDimension, Int((max(0, targetWidth) * effectiveScale).rounded())),
            max(minimumPixelDimension, Int((max(0, targetHeight) * effectiveScale).rounded()))
        )
    }

    private static func describe(x: Double, y: Double, width: Double, height: Double) -> String {
        "\(format(width)) by \(format(height)) at \(format(x)), \(format(y))"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
