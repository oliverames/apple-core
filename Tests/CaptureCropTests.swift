import CoreGraphics
import Foundation
import Testing

@Suite("Screenshot crop geometry")
struct CaptureCropTests {
    @Test("A crop inside the target is scaled with the quality factor")
    func validCrop() throws {
        let region = try CaptureCrop.validate(
            x: 100,
            y: 50,
            width: 400,
            height: 200,
            targetWidth: 1920,
            targetHeight: 1080,
            scale: 0.5
        )
        #expect(region.sourceRect == CGRect(x: 100, y: 50, width: 400, height: 200))
        #expect(region.pixelWidth == 200)
        #expect(region.pixelHeight == 100)
    }

    @Test("A crop that runs off the target is refused, never widened")
    func outsideTarget() {
        #expect(throws: CaptureCropError.self) {
            try CaptureCrop.validate(
                x: 1800,
                y: 0,
                width: 400,
                height: 200,
                targetWidth: 1920,
                targetHeight: 1080,
                scale: 1
            )
        }
        #expect(throws: CaptureCropError.self) {
            try CaptureCrop.validate(
                x: -10,
                y: 0,
                width: 100,
                height: 100,
                targetWidth: 1920,
                targetHeight: 1080,
                scale: 1
            )
        }
    }

    @Test("The refusal names both rectangles, so the caller can fix it in one step")
    func refusalMessage() {
        do {
            _ = try CaptureCrop.validate(
                x: 0,
                y: 0,
                width: 4000,
                height: 100,
                targetWidth: 1920,
                targetHeight: 1080,
                scale: 1
            )
            Issue.record("expected a refusal")
        } catch let error as CaptureCropError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("4000"))
            #expect(message.contains("1920"))
            #expect(message.contains("rather than a full-screen screenshot"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("An incomplete or non-positive crop is an error")
    func malformed() {
        #expect(throws: CaptureCropError.incomplete) {
            try CaptureCrop.validate(
                x: 0,
                y: 0,
                width: nil,
                height: 10,
                targetWidth: 100,
                targetHeight: 100,
                scale: 1
            )
        }
        #expect(throws: CaptureCropError.nonPositiveSize(width: 0, height: 10)) {
            try CaptureCrop.validate(
                x: 0,
                y: 0,
                width: 0,
                height: 10,
                targetWidth: 100,
                targetHeight: 100,
                scale: 1
            )
        }
        #expect(throws: CaptureCropError.notFinite) {
            try CaptureCrop.validate(
                x: .nan,
                y: 0,
                width: 10,
                height: 10,
                targetWidth: 100,
                targetHeight: 100,
                scale: 1
            )
        }
    }

    @Test("A target with no size cannot be cropped against")
    func unsizedTarget() {
        #expect(throws: CaptureCropError.targetHasNoSize) {
            try CaptureCrop.validate(
                x: 0,
                y: 0,
                width: 10,
                height: 10,
                targetWidth: 0,
                targetHeight: 0,
                scale: 1
            )
        }
    }

    @Test("A crop never scales down to zero pixels")
    func minimumPixels() throws {
        let region = try CaptureCrop.validate(
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            targetWidth: 100,
            targetHeight: 100,
            scale: 0.1
        )
        #expect(region.pixelWidth == 1)
        #expect(region.pixelHeight == 1)
    }

    @Test("Uncropped captures scale the target's own size, not the first display's")
    func uncroppedScaling() {
        // The window is smaller than the display the old code measured, which
        // is exactly the case that came back letterboxed.
        let size = CaptureCrop.scaledSize(targetWidth: 800, targetHeight: 600, scale: 0.5)
        #expect(size.width == 400)
        #expect(size.height == 300)
        let unscaled = CaptureCrop.scaledSize(targetWidth: 800, targetHeight: 600, scale: 0)
        #expect(unscaled.width == 800)
    }
}
