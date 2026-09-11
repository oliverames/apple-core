import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import ImageIO
import OSLog
import PDFKit
import ObjectiveC
import Ontology
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

private let log = Logger.service("capture")

final class CaptureService: NSObject, Service {
    static let shared = CaptureService()

    private var captureSession: AVCaptureSession?
    private var audioRecorder: AVAudioRecorder?
    private var photoOutput: AVCapturePhotoOutput?
    private let photoDelegateLock = NSLock()
    private var photoDelegates: [UUID: PhotoCaptureDelegate] = [:]

    private func retainPhotoDelegate(_ delegate: PhotoCaptureDelegate, for requestID: UUID) {
        photoDelegateLock.withLock { photoDelegates[requestID] = delegate }
    }

    private func releasePhotoDelegate(for requestID: UUID) {
        photoDelegateLock.withLock { _ = photoDelegates.removeValue(forKey: requestID) }
    }

    private static func captureIdentifier(_ value: Value?, named name: String) throws -> UInt32? {
        guard let value else { return nil }
        guard let rawValue = Int(value, strict: false), let identifier = NumericArgument.uint32(rawValue) else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 22,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(name) must be a whole number between 0 and 4294967295"
                ]
            )
        }
        return identifier
    }

    override init() {
        super.init()
        log.debug("Initializing capture service")
    }

    deinit {
        log.info("Deinitializing capture service")
        captureSession?.stopRunning()
        audioRecorder?.stop()
    }

    var isActivated: Bool {
        get async {
            let cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            let microphoneAuthorized =
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
            return cameraAuthorized || microphoneAuthorized || screenRecordingAuthorized
        }
    }

    func activate() async throws {
        var failures: [String] = []

        do {
            try await requestPermission(for: .video)
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try await requestPermission(for: .audio)
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try await requestScreenRecordingPermission()
        } catch {
            failures.append(error.localizedDescription)
        }

        guard failures.isEmpty else {
            throw NSError(
                domain: "CaptureServiceError",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]
            )
        }
    }

    private func requestPermission(for mediaType: AVMediaType) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        let mediaName = mediaType == .video ? "Camera" : "Microphone"

        switch status {
        case .authorized:
            log.debug("\(mediaName) access already authorized")
            return
        case .denied, .restricted:
            log.error("\(mediaName) access denied")
            throw NSError(
                domain: "CaptureServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(mediaName) access denied"]
            )
        case .notDetermined:
            log.debug("Requesting \(mediaName) access")
            let granted = await AVCaptureDevice.requestAccess(for: mediaType)
            if !granted {
                let statusAfterRequest = AVCaptureDevice.authorizationStatus(for: mediaType)
                throw ServicePermissionError.requestFailed(
                    domain: "CaptureServiceError",
                    what: mediaName,
                    promptCouldHaveAppeared: statusAfterRequest != .notDetermined
                )
            }
        @unknown default:
            log.error("Unknown \(mediaName) authorization status")
            throw NSError(
                domain: "CaptureServiceError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown authorization status"]
            )
        }
    }

    private func requestScreenRecordingPermission() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            // Request screen recording access
            guard CGRequestScreenCaptureAccess() else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Screen recording access denied"]
                )
            }
            return
        }
    }

    var tools: [Tool] {
        Tool(
            name: "capture_take_picture",
            description: "Take a picture with the device camera",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        default: .string(ImageFormat.default.rawValue),
                        enum: ImageFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "quality": .number(
                        description: "JPEG quality",
                        default: 0.8,
                        minimum: 0.0,
                        maximum: 1.0
                    ),
                    "preset": .string(
                        description: "Camera quality preset",
                        default: .string(SessionPreset.default.rawValue),
                        enum: SessionPreset.allCases.map { .string($0.rawValue) }
                    ),
                    "device": .string(
                        description: "Camera device type",
                        default: .string(CaptureDeviceType.default.rawValue),
                        enum: CaptureDeviceType.allCases.map { .string($0.rawValue) }
                    ),
                    "position": .string(
                        description: "Camera position",
                        default: .string(CaptureDevicePosition.default.rawValue),
                        enum: CaptureDevicePosition.allCases.map { .string($0.rawValue) }
                    ),
                    "flash": .string(
                        description: "Flash mode",
                        default: .string(FlashMode.default.rawValue),
                        enum: FlashMode.allCases.map { .string($0.rawValue) }
                    ),
                    "autoExposure": .boolean(
                        description: "Enable automatic exposure and light balancing",
                        default: true
                    ),
                    "autoFocus": .boolean(
                        description: "Enable automatic focus",
                        default: true
                    ),
                    "autoWhiteBalance": .boolean(
                        description: "Enable automatic white balance",
                        default: true
                    ),
                    "delay": .number(
                        description: "Delay before taking photo, in seconds",
                        default: 1,
                        minimum: 0,
                        maximum: 60
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Take Picture",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard await self.isActivated else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Camera access not authorized"]
                )
            }

            let format =
                ImageFormat(
                    rawValue: arguments["format"]?.stringValue ?? ImageFormat.default.rawValue
                )
                ?? .jpeg
            let requestedQuality = arguments["quality"]?.doubleCoerced ?? 0.8
            guard let quality = NumericArgument.clampedDouble(requestedQuality, to: 0 ... 1) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "JPEG quality must be a finite number"]
                )
            }
            let preset =
                SessionPreset(
                    rawValue: arguments["preset"]?.stringValue ?? SessionPreset.default.rawValue
                )
                ?? .photo
            let device =
                CaptureDeviceType(
                    rawValue: arguments["device"]?.stringValue ?? CaptureDeviceType.default.rawValue
                )
                ?? .builtInWideAngle
            let position =
                CaptureDevicePosition(
                    rawValue: arguments["position"]?.stringValue
                        ?? CaptureDevicePosition.default.rawValue
                ) ?? .unspecified
            let flash =
                FlashMode(rawValue: arguments["flash"]?.stringValue ?? FlashMode.default.rawValue)
                ?? .auto
            let autoExposure = arguments["autoExposure"]?.boolValue ?? true
            let autoFocus = arguments["autoFocus"]?.boolValue ?? true
            let autoWhiteBalance = arguments["autoWhiteBalance"]?.boolValue ?? true
            let requestedDelay = arguments["delay"]?.doubleCoerced ?? 1.0
            guard requestedDelay.isFinite else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Camera delay must be a finite number"]
                )
            }
            let delay = min(max(requestedDelay, 0), 60)

            let captureSession = AVCaptureSession()
            captureSession.sessionPreset = preset.avPreset

            guard
                let camera = AVCaptureDevice.device(
                    for: device,
                    position: position,
                    mediaType: .video
                )
            else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No camera device found"]
                )
            }

            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if autoExposure && camera.isExposureModeSupported(.autoExpose) {
                camera.exposureMode = .autoExpose
            }

            if autoFocus && camera.isFocusModeSupported(.autoFocus) {
                camera.focusMode = .autoFocus
            }

            if autoWhiteBalance && camera.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                camera.whiteBalanceMode = .autoWhiteBalance
            }

            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(videoInput) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"]
                )
            }
            captureSession.addInput(videoInput)

            let photoOutput = AVCapturePhotoOutput()
            guard captureSession.canAddOutput(photoOutput) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add photo output"]
                )
            }
            captureSession.addOutput(photoOutput)

            return try await withCheckedThrowingContinuation { continuation in
                let resumeGate = ResumeGate()
                let requestID = UUID()
                let resumeOnce: (Result<Value, Error>, (() async -> Void)?) async -> Void = {
                    result,
                    cleanup in
                    guard await resumeGate.shouldResume() else { return }
                    if let cleanup = cleanup {
                        await cleanup()
                    }
                    continuation.resume(with: result)
                }

                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(delay + 10))
                    await resumeOnce(
                        .failure(
                            NSError(
                                domain: "CaptureServiceError",
                                code: 9,
                                userInfo: [NSLocalizedDescriptionKey: "Camera capture timeout"]
                            )
                        ),
                        {
                            await MainActor.run {
                                captureSession.stopRunning()
                                self.releasePhotoDelegate(for: requestID)
                            }
                        }
                    )
                }

                captureSession.startRunning()

                Task { @MainActor in
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }

                    let settings = AVCapturePhotoSettings()
                    if photoOutput.supportedFlashModes.contains(flash.avFlashMode) {
                        settings.flashMode = flash.avFlashMode
                    }

                    let delegate = PhotoCaptureDelegate(
                        format: format,
                        quality: quality,
                        completion: { result in
                            Task { @MainActor in
                                timeoutTask.cancel()
                                captureSession.stopRunning()
                                self.releasePhotoDelegate(for: requestID)
                                await resumeOnce(result, nil)
                            }
                        }
                    )

                    self.retainPhotoDelegate(delegate, for: requestID)
                    photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
        }

        Tool(
            name: "capture_record_audio",
            description: "Record audio with the device microphone",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        default: .string(AudioFormat.default.rawValue),
                        enum: AudioFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "duration": .number(
                        description: "Recording duration in seconds",
                        default: 10,
                        minimum: 1,
                        maximum: 300
                    ),
                    "quality": .string(
                        description: "Audio quality",
                        default: "medium",
                        enum: ["low", "medium", "high"]
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Record Audio",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                // Try to request permission if not authorized
                try await self.requestPermission(for: .audio)
            }

            let format =
                AudioFormat(
                    rawValue: arguments["format"]?.stringValue ?? AudioFormat.default.rawValue
                )
                ?? .mp4
            let requestedDuration = arguments["duration"]?.doubleCoerced ?? 10.0
            guard let duration = NumericArgument.clampedDouble(requestedDuration, to: 1 ... 300) else {
                throw NSError(
                    domain: "CaptureServiceError",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "Recording duration must be a finite number"]
                )
            }
            let quality = arguments["quality"]?.stringValue ?? "medium"

            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(format.fileExtension)

            let settings: [String: Any] = {
                switch quality {
                case "low":
                    return [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 22050,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
                    ]
                case "high":
                    return [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]
                default:  // medium
                    return [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                    ]
                }
            }()

            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.record(forDuration: duration)

            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    try? await Task.sleep(for: .seconds(duration + 0.5))
                    recorder.stop()

                    do {
                        let audioData = try Data(contentsOf: tempURL)
                        try FileManager.default.removeItem(at: tempURL)
                        let audioValue = Value.data(mimeType: format.mimeType, audioData)
                        continuation.resume(returning: audioValue)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        Tool(
            name: "capture_take_screenshot",
            description: "Take a screenshot of the screen, window, or application",
            inputSchema: .object(
                properties: [
                    "contentType": .string(
                        description: "Type of content to capture",
                        default: .string(ScreenCaptureContentType.default.rawValue),
                        enum: ScreenCaptureContentType.allCases.map { .string($0.rawValue) }
                    ),
                    "format": .string(
                        default: .string(ScreenshotFormat.default.rawValue),
                        enum: ScreenshotFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "quality": .string(
                        description: "Screenshot quality and resolution",
                        default: .string(ScreenCaptureQuality.default.rawValue),
                        enum: ScreenCaptureQuality.allCases.map { .string($0.rawValue) }
                    ),
                    "displayId": .integer(
                        description: "Display ID for display capture (optional)",
                        minimum: 0,
                        maximum: Int(UInt32.max)
                    ),
                    "windowId": .integer(
                        description: "Window ID for window capture (optional)",
                        minimum: 0,
                        maximum: Int(UInt32.max)
                    ),
                    "bundleId": .string(
                        description: "Bundle ID for application capture (optional)"
                    ),
                    "includesCursor": .boolean(
                        description: "Include cursor in screenshot",
                        default: true
                    ),
                    "crop": .object(
                        description:
                            "Capture only part of the target. Points, measured from the target's own top-left corner: "
                            + "the selected display's, or the selected window's, never the desktop's. "
                            + "A crop that does not fit inside the target is an error, not a full-screen screenshot. "
                            + "capture_list_targets reports each target's size.",
                        properties: [
                            "x": .number(description: "Points from the target's left edge"),
                            "y": .number(description: "Points from the target's top edge"),
                            "width": .number(description: "Width in points"),
                            "height": .number(description: "Height in points"),
                        ],
                        required: ["x", "y", "width", "height"],
                        additionalProperties: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Take Screenshot",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            if !CGPreflightScreenCaptureAccess() {
                // Try to request permission if not authorized
                try await self.requestScreenRecordingPermission()
            }

            let contentType =
                ScreenCaptureContentType(
                    rawValue: arguments["contentType"]?.stringValue
                        ?? ScreenCaptureContentType.default.rawValue
                ) ?? .display
            let format =
                ScreenshotFormat(
                    rawValue: arguments["format"]?.stringValue ?? ScreenshotFormat.default.rawValue
                ) ?? .png
            let quality =
                ScreenCaptureQuality(
                    rawValue: arguments["quality"]?.stringValue
                        ?? ScreenCaptureQuality.default.rawValue
                ) ?? .medium
            let includesCursor = arguments["includesCursor"]?.boolValue ?? true

            let displayId = try Self.captureIdentifier(arguments["displayId"], named: "displayId")
            let windowId = try Self.captureIdentifier(arguments["windowId"], named: "windowId")
            let bundleId = arguments["bundleId"]?.stringValue

            // Get available content
            let availableContent = try await SCShareableContent.getAvailableContent()

            // Create content filter based on content type, and remember the
            // target's own size. The configuration used to be scaled against
            // whichever display happened to be first in the list, which is the
            // wrong size for a window, and the wrong size for anything at all
            // on a Mac whose first display is not the one being captured.
            let contentFilter: SCContentFilter
            var targetWidth = 0.0
            var targetHeight = 0.0
            switch contentType {
            case .display:
                let display: SCDisplay
                if let displayId = displayId {
                    guard
                        let selectedDisplay = availableContent.displays.first(where: {
                            $0.displayID == displayId
                        })
                    else {
                        throw NSError(
                            domain: "CaptureServiceError",
                            code: 20,
                            userInfo: [NSLocalizedDescriptionKey: "Display not found"]
                        )
                    }
                    display = selectedDisplay
                } else {
                    guard let mainDisplay = availableContent.displays.first else {
                        // ScreenCaptureKit reports no displays while the screen
                        // is locked, which reads as a broken capture rather
                        // than the ordinary situation it is.
                        throw NSError(
                            domain: "CaptureServiceError",
                            code: 21,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "No display is available to capture. The Mac's screen is probably locked."
                            ]
                        )
                    }
                    display = mainDisplay
                }
                contentFilter = SCContentFilter(display: display, excludingWindows: [])
                targetWidth = Double(display.width)
                targetHeight = Double(display.height)

            case .window:
                guard let windowId = windowId else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 22,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Window ID required for window capture"
                        ]
                    )
                }
                guard
                    let window = availableContent.windows.first(where: { $0.windowID == windowId })
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 23,
                        userInfo: [NSLocalizedDescriptionKey: "Window not found"]
                    )
                }
                contentFilter = SCContentFilter(desktopIndependentWindow: window)
                targetWidth = window.frame.width
                targetHeight = window.frame.height

            case .application:
                guard let bundleId = bundleId else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 24,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Bundle ID required for application capture"
                        ]
                    )
                }
                guard
                    let application = availableContent.applications.first(where: {
                        $0.bundleIdentifier == bundleId
                    })
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 25,
                        userInfo: [NSLocalizedDescriptionKey: "Application not found"]
                    )
                }
                let appWindows = availableContent.windows.filter {
                    $0.owningApplication == application
                }
                guard let firstDisplay = availableContent.displays.first else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 26,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No displays available for application capture"
                        ]
                    )
                }
                contentFilter = SCContentFilter(
                    display: firstDisplay,
                    including: appWindows
                )
                // An application capture is framed by the display it is drawn
                // on, not by the windows, so the display is the crop's target.
                targetWidth = Double(firstDisplay.width)
                targetHeight = Double(firstDisplay.height)
            }

            // Create stream configuration
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.capturesAudio = false
            streamConfiguration.showsCursor = includesCursor
            streamConfiguration.scalesToFit = true
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA

            // Quality scales the target's own size, and a crop replaces that
            // size with the requested region. A crop that cannot be honoured
            // throws here, before anything is captured: falling back to the
            // whole screen would widen a request whose entire purpose was to
            // narrow what is returned.
            if let crop = arguments["crop"]?.objectValue {
                let region = try CaptureCrop.validate(
                    x: crop["x"]?.doubleCoerced,
                    y: crop["y"]?.doubleCoerced,
                    width: crop["width"]?.doubleCoerced,
                    height: crop["height"]?.doubleCoerced,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    scale: Double(quality.scaleFactor)
                )
                streamConfiguration.sourceRect = region.sourceRect
                streamConfiguration.width = region.pixelWidth
                streamConfiguration.height = region.pixelHeight
            } else if targetWidth > 0, targetHeight > 0 {
                let size = CaptureCrop.scaledSize(
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    scale: Double(quality.scaleFactor)
                )
                streamConfiguration.width = size.width
                streamConfiguration.height = size.height
            }

            return try await withCheckedThrowingContinuation { continuation in
                let resumeGate = ResumeGate()
                let resumeOnce: (Result<Value, Error>, (() async -> Void)?) async -> Void = {
                    result,
                    _ in
                    guard await resumeGate.shouldResume() else { return }
                    continuation.resume(with: result)
                }

                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(10))
                    await resumeOnce(
                        .failure(
                            NSError(
                                domain: "CaptureServiceError",
                                code: 26,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Screenshot capture timeout"
                                ]
                            )
                        ),
                        nil
                    )
                }

                Task {
                    do {
                        // Use SCScreenshotManager for taking screenshots
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: contentFilter,
                            configuration: streamConfiguration
                        )

                        // Convert CGImage to Data
                        let imageData: Data
                        switch format {
                        case .png:
                            guard let pngData = image.pngData() else {
                                throw NSError(
                                    domain: "CaptureServiceError",
                                    code: 28,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: "Failed to create PNG data"
                                    ]
                                )
                            }
                            imageData = pngData
                        case .jpeg:
                            guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
                                throw NSError(
                                    domain: "CaptureServiceError",
                                    code: 29,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: "Failed to create JPEG data"
                                    ]
                                )
                            }
                            imageData = jpegData
                        }

                        timeoutTask.cancel()
                        let screenshotValue = Value.data(mimeType: format.mimeType, imageData)
                        await resumeOnce(.success(screenshotValue), nil)
                    } catch {
                        timeoutTask.cancel()
                        await resumeOnce(.failure(error), nil)
                    }
                }
            }
        }

        Tool(
            name: "capture_list_windows",
            description: CaptureLegacyWindowListing.toolDescription,
            inputSchema: .object(
                properties: [
                    "bundleId": .string(
                        description: "Only list windows belonging to this application"
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Capturable Windows (Deprecated)",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            if !CGPreflightScreenCaptureAccess() {
                try await self.requestScreenRecordingPermission()
            }

            // Desktop windows and off-screen windows are excluded: neither is
            // something a caller can meaningfully ask for a picture of, and
            // including them buries the real windows in noise.
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )

            let wantedBundle = arguments["bundleId"]?.stringValue
            let windows = content.windows.filter { window in
                guard let wantedBundle, !wantedBundle.isEmpty else { return true }
                return window.owningApplication?.bundleIdentifier == wantedBundle
            }

            let displays: [Value] = content.displays.map { display in
                .object([
                    "displayId": .int(Int(display.displayID)),
                    "width": .int(display.width),
                    "height": .int(display.height),
                ])
            }

            let applications: [Value] = content.applications
                .filter { application in
                    guard let wantedBundle, !wantedBundle.isEmpty else { return true }
                    return application.bundleIdentifier == wantedBundle
                }
                .map { application in
                    .object([
                        "bundleId": .string(application.bundleIdentifier),
                        "name": .string(application.applicationName),
                        "processId": .int(Int(application.processID)),
                    ])
                }

            let windowValues: [Value] = windows.map { window in
                var entry: [String: Value] = [
                    "windowId": .int(Int(window.windowID)),
                    "width": .int(Int(window.frame.width)),
                    "height": .int(Int(window.frame.height)),
                    "isActive": .bool(window.isActive),
                ]
                // Deliberately no title. A window title routinely carries a
                // document name or a message subject, which is content the
                // caller has not been granted; hasTitle still separates a
                // document window from an untitled panel.
                entry["hasTitle"] = .bool(CaptureLegacyWindowListing.hasTitle(window.title))
                if let owner = window.owningApplication {
                    entry["bundleId"] = .string(owner.bundleIdentifier)
                    entry["application"] = .string(owner.applicationName)
                }
                return .object(entry)
            }

            var result: [String: Value] = [
                "displays": .array(displays),
                "applications": .array(applications),
                "windows": .array(windowValues),
            ]
            if displays.isEmpty {
                result["note"] = .string(
                    "No display is available to capture. The Mac's screen is probably locked. "
                        + "Individual windows can still be listed, but not captured."
                )
            }
            return Value.object(result)
        }

        Tool(
            name: "capture_list_targets",
            description:
                "List the displays, applications and windows a capture can be aimed at, with only the "
                + "identifiers and geometry capture_take_screenshot needs. Returns no window contents and no "
                + "window titles, and never asks for Screen Recording access.",
            inputSchema: .object(
                properties: [
                    "bundleId": .string(
                        description: "Only list the application and windows belonging to this bundle identifier"
                    ),
                    "windowId": .integer(
                        description:
                            "Check whether a window identifier from an earlier listing is still valid. One that "
                            + "has since closed is reported as stale rather than as an error.",
                        minimum: 0,
                        maximum: Int(UInt32.max)
                    ),
                    "includeOffscreenWindows": .boolean(
                        description: "Include minimized and other off-screen windows",
                        default: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Capture Targets",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Preflight rather than request: a client sizing up the machine
            // should not be the thing that puts a consent dialog in front of
            // whoever is sitting at it.
            guard CGPreflightScreenCaptureAccess() else {
                throw CaptureTargetError.screenRecordingNotAuthorized
            }

            let bundleIdentifier = arguments["bundleId"]?.stringValue
            let windowIdentifier = try Self.captureIdentifier(arguments["windowId"], named: "windowId")
            let includeOffscreen = arguments["includeOffscreenWindows"]?.boolValue ?? false

            let snapshot = try await Self.currentTargetSnapshot()
            // The lookup runs against the whole snapshot on purpose: a window
            // the caller filtered out is still a live window, and calling it
            // stale would send them chasing an identifier that never changed.
            let lookup = CaptureTargetInventory.lookup(windowID: windowIdentifier, in: snapshot)
            let targets = CaptureTargetInventory.filtered(
                snapshot,
                bundleIdentifier: bundleIdentifier,
                includeOffscreenWindows: includeOffscreen
            )
            let screenStatus = CaptureReadiness.screenStatus(
                isAuthorized: true,
                isGUISessionActive: GUISession.isActive,
                displayCount: snapshot.displays.count
            )

            return Self.value(for: targets, screenStatus: screenStatus, lookup: lookup)
        }

        Tool(
            name: "capture_read_text",
            description:
                "Read an application's on-screen text through the macOS accessibility API, instead of screenshotting it. "
                + "Far smaller than a screenshot and far more accurate than reading pixels, and it returns only the named "
                + "application's interface rather than everything on screen. Password and other secure fields are never read. "
                + "Needs Accessibility permission, which is separate from Screen Recording. "
                + "This reads only: it cannot click, type or focus anything.",
            inputSchema: .object(
                properties: [
                    "bundleId": .string(
                        description:
                            "Bundle identifier of the running application to read, from capture_list_targets"
                    ),
                    "scope": .string(
                        description:
                            "Which of the application's windows to read. \"focused\" is its frontmost window; \"all\" is every window it has open.",
                        default: .string("focused"),
                        enum: [.string("focused"), .string("all")]
                    ),
                    "source": .string(
                        description:
                            "\"accessibility\" reads the interface's own labels and needs Accessibility permission. "
                            + "\"ocr\" recognises text from a picture of the application's windows on this Mac, needs Screen Recording permission instead, "
                            + "and is the fallback for an application that exposes nothing to accessibility, such as a remote desktop or a scanned document. "
                            + "OCR runs on this Mac; nothing is sent anywhere.",
                        default: .string("accessibility"),
                        enum: [.string("accessibility"), .string("ocr")]
                    ),
                    "maxDepth": .integer(
                        description:
                            "How deep to walk the interface, up to \(CaptureAccessibilityText.maximumMaxDepth)",
                        default: .int(CaptureAccessibilityText.defaultMaxDepth)
                    ),
                    "maxNodes": .integer(
                        description:
                            "Maximum interface elements to visit, up to \(CaptureAccessibilityText.maximumMaxNodes)",
                        default: .int(CaptureAccessibilityText.defaultMaxNodes)
                    ),
                    "maxCharacters": .integer(
                        description:
                            "Maximum characters of text to return, up to \(CaptureAccessibilityText.maximumMaxCharacters)",
                        default: .int(CaptureAccessibilityText.defaultMaxCharacters)
                    ),
                ],
                required: ["bundleId"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read On-Screen Text",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let bundleId = arguments["bundleId"]?.stringValue, !bundleId.isEmpty else {
                throw CaptureAccessibilityError.missingBundleIdentifier
            }
            guard GUISession.isActive else {
                throw CaptureAccessibilityError.noGUISession
            }
            let maxCharactersRequested = CaptureAccessibilityText.clampedCharacters(
                arguments["maxCharacters"]?.intValue
            )
            // The two sources need different permissions and read different
            // things, so they are separate paths rather than one path with a
            // fallback. A silent fallback from accessibility to OCR would turn
            // a refused Accessibility grant into a screen capture the user
            // never agreed to.
            if arguments["source"]?.stringValue == "ocr" {
                return try await CaptureService.recognizeText(
                    bundleId: bundleId,
                    maxCharacters: maxCharactersRequested
                )
            }
            // Checked without prompting. A tool call arriving over a connector
            // is the wrong moment to throw a system dialog at whoever is
            // sitting at the Mac; the error says exactly what to switch on.
            guard AXIsProcessTrusted() else {
                throw CaptureAccessibilityError.accessibilityNotAuthorized
            }
            guard
                let application = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleId
                ).first
            else {
                throw CaptureAccessibilityError.applicationNotRunning(bundleId)
            }

            let readAllWindows = arguments["scope"]?.stringValue == "all"
            let root = AXElement(element: AXUIElementCreateApplication(application.processIdentifier))
            let windows: [AXElement]
            if readAllWindows {
                windows = root.windows
            } else if let focused = root.focusedWindow {
                windows = [focused]
            } else {
                // An application with no focused window is ordinary — it may be
                // in the background — so read its windows rather than failing.
                windows = root.windows
            }
            guard !windows.isEmpty else {
                throw CaptureAccessibilityError.noWindows(bundleId)
            }

            let maxCharacters = maxCharactersRequested
            let maxNodes = CaptureAccessibilityText.clampedNodes(arguments["maxNodes"]?.intValue)
            let maxDepth = CaptureAccessibilityText.clampedDepth(arguments["maxDepth"]?.intValue)

            var described: [Value] = []
            var remainingCharacters = maxCharacters
            var remainingNodes = maxNodes
            var secureExcluded = 0
            var bounded = false
            for window in windows {
                guard remainingCharacters > 0, remainingNodes > 0 else {
                    bounded = true
                    break
                }
                let result = CaptureAccessibilityText.read(
                    root: window,
                    maxDepth: maxDepth,
                    maxNodes: remainingNodes,
                    maxCharacters: remainingCharacters
                )
                remainingCharacters -= result.text.count
                remainingNodes -= result.visitedCount
                secureExcluded += result.secureElementsExcluded
                bounded = bounded || result.isBounded
                described.append(
                    .object([
                        "title": .string(window.axTitle ?? ""),
                        "text": .string(result.text),
                        "elementCount": .int(result.nodes.count),
                    ])
                )
            }

            var response: [String: Value] = [
                "bundleId": .string(bundleId),
                "applicationName": .string(application.localizedName ?? bundleId),
                "scope": .string(readAllWindows ? "all" : "focused"),
                "source": .string("accessibility"),
                "windows": .array(described),
                "charactersReturned": .int(maxCharacters - max(0, remainingCharacters)),
                "truncated": .bool(bounded),
            ]
            if secureExcluded > 0 {
                response["secureFieldsExcluded"] = .int(secureExcluded)
                response["secureFieldsNote"] = .string(
                    "\(secureExcluded) secure field\(secureExcluded == 1 ? " was" : "s were") skipped. Apple Core never reads the contents of a password field, whatever the accessibility API offers."
                )
            }
            if bounded {
                response["note"] = .string(
                    "The read stopped at one of its bounds. Raise maxNodes, maxDepth or maxCharacters, or read one window at a time with scope: focused."
                )
            }
            return Value.object(response)
        }

        Tool(
            name: "capture_readiness",
            description:
                "Report whether the camera, microphone and screen are each usable on this Mac, telling missing "
                + "hardware, denied permission and a locked screen apart. Captures nothing and never triggers a "
                + "permission prompt.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Capture Readiness",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            let guiSessionActive = GUISession.isActive
            let cameraPermission = CapturePermissionState(
                AVCaptureDevice.authorizationStatus(for: .video)
            )
            let microphonePermission = CapturePermissionState(
                AVCaptureDevice.authorizationStatus(for: .audio)
            )
            let cameraCount = Self.deviceCount(for: .video)
            let microphoneCount = Self.deviceCount(for: .audio)
            let screenAuthorized = CGPreflightScreenCaptureAccess()

            // The display list is only asked for when there is a session to ask
            // about. On a locked Mac it comes back empty, and a zero here would
            // read as "no screens attached" rather than "nobody is looking".
            var displayCount = 0
            if screenAuthorized && guiSessionActive {
                displayCount = (try? await Self.currentTargetSnapshot().displays.count) ?? 0
            }

            let camera = CaptureReadiness.deviceStatus(
                permission: cameraPermission,
                hasDevice: cameraCount > 0
            )
            let microphone = CaptureReadiness.deviceStatus(
                permission: microphonePermission,
                hasDevice: microphoneCount > 0
            )
            let screen = CaptureReadiness.screenStatus(
                isAuthorized: screenAuthorized,
                isGUISessionActive: guiSessionActive,
                displayCount: displayCount
            )

            return Value.object([
                "camera": .object([
                    "status": .string(camera.rawValue),
                    "detail": .string(CaptureReadiness.detail(for: camera, modality: .camera)),
                    "permission": .string(cameraPermission.rawValue),
                    "deviceCount": .int(cameraCount),
                ]),
                "microphone": .object([
                    "status": .string(microphone.rawValue),
                    "detail": .string(
                        CaptureReadiness.detail(for: microphone, modality: .microphone)
                    ),
                    "permission": .string(microphonePermission.rawValue),
                    "deviceCount": .int(microphoneCount),
                ]),
                "screen": .object([
                    "status": .string(screen.rawValue),
                    "detail": .string(CaptureReadiness.detail(for: screen, modality: .screen)),
                    "permission": .string(screenAuthorized ? "authorized" : "notAuthorized"),
                    "displayCount": .int(displayCount),
                ]),
                "accessibility": .object([
                    "status": .string(
                        CaptureAccessibilityReadiness.status(isTrusted: AXIsProcessTrusted())
                    ),
                    "detail": .string(
                        CaptureAccessibilityReadiness.detail(isTrusted: AXIsProcessTrusted())
                    ),
                    "permission": .string(
                        AXIsProcessTrusted() ? "authorized" : "notAuthorized"
                    ),
                ]),
                "guiSessionActive": .bool(guiSessionActive),
            ])
        }

        Tool(
            name: "capture_read_image_text",
            description: CaptureService.readImageTextDescription,
            inputSchema: .object(
                properties: [
                    "path": .string(
                        description: "Image or PDF inside a folder shared with Apple Core"
                    ),
                    "page": .integer(
                        description: CaptureService.readImageTextPageDescription,
                        default: .int(1),
                        minimum: 1
                    ),
                    "maxPages": .integer(
                        description: CaptureService.readImageTextMaxPagesDescription,
                        default: .int(CaptureImageText.defaultMaxPages),
                        minimum: 1,
                        maximum: CaptureImageText.maximumMaxPages
                    ),
                    "maxCharacters": .integer(
                        description: CaptureService.readImageTextMaxCharactersDescription,
                        default: .int(CaptureImageText.defaultMaxCharacters),
                        minimum: 1,
                        maximum: CaptureImageText.maximumMaxCharacters
                    ),
                    "languages": .array(
                        description: CaptureService.readImageTextLanguagesDescription,
                        items: .string()
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Text in a File",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try CaptureService.readImageText(arguments)
        }
    }
}

// MARK: - Capture Target Discovery Support

extension CaptureService {
    /// Live capture targets, flattened into the snapshot the discovery and
    /// readiness rules work on.
    ///
    /// Off-screen windows are collected rather than filtered out at the source
    /// so the caller's own argument, not this call, decides whether minimized
    /// windows appear. Desktop windows are always excluded: nobody asks for a
    /// picture of the wallpaper, and they bury the real windows.
    static func currentTargetSnapshot() async throws -> CaptureTargetSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        return CaptureTargetSnapshot(
            displays: content.displays.map {
                .init(id: $0.displayID, width: $0.width, height: $0.height)
            },
            applications: content.applications.map {
                .init(
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.applicationName,
                    processIdentifier: Int($0.processID)
                )
            },
            windows: content.windows.map { window in
                .init(
                    id: window.windowID,
                    ownerBundleIdentifier: window.owningApplication?.bundleIdentifier,
                    ownerName: window.owningApplication?.applicationName,
                    x: Int(window.frame.origin.x),
                    y: Int(window.frame.origin.y),
                    width: Int(window.frame.width),
                    height: Int(window.frame.height),
                    isOnScreen: window.isOnScreen,
                    isActive: window.isActive,
                    hasTitle: !(window.title ?? "").isEmpty
                )
            }
        )
    }

    /// Prompt-free count of the capture devices for one media type. Device
    /// discovery is not gated by consent, which is what makes it safe for a
    /// readiness check that must not put a dialog on screen.
    static func deviceCount(for mediaType: AVMediaType) -> Int {
        let deviceTypes: [AVCaptureDevice.DeviceType] =
            mediaType == .video
            ? [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
            : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: .unspecified
        ).devices.count
    }

    static func value(
        for snapshot: CaptureTargetSnapshot,
        screenStatus: CaptureModalityStatus,
        lookup: CaptureTargetInventory.WindowLookup
    ) -> Value {
        let displays: [Value] = snapshot.displays.map { display in
            .object([
                "displayId": .int(Int(display.id)),
                "width": .int(display.width),
                "height": .int(display.height),
            ])
        }

        let applications: [Value] = snapshot.applications.map { application in
            .object([
                "bundleId": .string(application.bundleIdentifier),
                "name": .string(application.name),
                "processId": .int(application.processIdentifier),
            ])
        }

        let windows: [Value] = snapshot.windows.map { window in
            var entry: [String: Value] = [
                "windowId": .int(Int(window.id)),
                "x": .int(window.x),
                "y": .int(window.y),
                "width": .int(window.width),
                "height": .int(window.height),
                "isOnScreen": .bool(window.isOnScreen),
                "isActive": .bool(window.isActive),
                "hasTitle": .bool(window.hasTitle),
            ]
            if let bundleIdentifier = window.ownerBundleIdentifier {
                entry["bundleId"] = .string(bundleIdentifier)
            }
            if let name = window.ownerName {
                entry["application"] = .string(name)
            }
            return .object(entry)
        }

        var result: [String: Value] = [
            "displays": .array(displays),
            "applications": .array(applications),
            "windows": .array(windows),
            "screenStatus": .string(screenStatus.rawValue),
        ]
        if screenStatus != .ready {
            result["note"] = .string(CaptureReadiness.detail(for: screenStatus, modality: .screen))
        }
        switch lookup {
        case .notRequested:
            break
        case let .live(windowID):
            result["requestedWindow"] = .object([
                "windowId": .int(Int(windowID)),
                "status": .string("live"),
            ])
        case let .stale(windowID):
            result["requestedWindow"] = .object([
                "windowId": .int(Int(windowID)),
                "status": .string("stale"),
                "detail": .string(CaptureTargetInventory.staleWindowAdvice(for: windowID)),
            ])
        }
        return .object(result)
    }
}

enum CaptureTargetError: LocalizedError {
    case screenRecordingNotAuthorized

    var errorDescription: String? {
        switch self {
        case .screenRecordingNotAuthorized:
            return "Screen Recording access is not granted for Apple Core, so there is nothing to list. "
                + "Grant it in System Settings, or call capture_take_screenshot to be asked for it."
        }
    }
}

// MARK: - Photo Capture Delegate

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let format: ImageFormat
    private let quality: Double
    private let completion: (Result<Value, Swift.Error>) -> Void
    private var hasCompleted = false

    init(
        format: ImageFormat,
        quality: Double,
        completion: @escaping (Result<Value, Swift.Error>) -> Void
    ) {
        self.format = format
        self.quality = quality
        self.completion = completion
        super.init()
    }

    private func complete(with result: Result<Value, Error>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            complete(with: .failure(error))
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            complete(
                with: .failure(
                    NSError(
                        domain: "CaptureServiceError",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get image data"]
                    )
                )
            )
            return
        }

        do {
            let processedData: Data
            let mimeType: String

            if format == .png {
                guard let image = NSImage(data: imageData),
                    let pngData = image.pngData()
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert to PNG"]
                    )
                }
                processedData = pngData
                mimeType = format.mimeType
            } else {
                guard let image = NSImage(data: imageData),
                    let jpegData = image.jpegData(compressionQuality: quality)
                else {
                    throw NSError(
                        domain: "CaptureServiceError",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert to JPEG"]
                    )
                }
                processedData = jpegData
                mimeType = format.mimeType
            }

            let imageValue = Value.data(mimeType: mimeType, processedData)
            complete(with: .success(imageValue))
        } catch {
            complete(with: .failure(error))
        }
    }
}

// MARK: - Reading an interface as text

/// A thin wrapper over `AXUIElement` that conforms it to the traversal rules
/// in `CaptureAccessibilityText`.
///
/// The rules live in Shared so they can be tested against a constructed tree;
/// this type is the part that cannot be, because an `AXUIElement` only exists
/// against a live application. Keeping it this thin is the point: every
/// decision about what is read and what is withheld is made in the tested
/// file, not here.
struct AXElement: CaptureAccessibleElement {
    let element: AXUIElement

    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        if let text = value as? String { return text }
        // A value can be a number, a boolean or a URL. Numbers and booleans
        // are interface state rather than text, and are left out; a URL is
        // worth reading, since it is what a browser's address field holds.
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    var axRole: String? { string(kAXRoleAttribute) }
    var axSubrole: String? { string(kAXSubroleAttribute) }
    var axTitle: String? { string(kAXTitleAttribute) }
    var axValueText: String? { string(kAXValueAttribute) }
    var axDescriptionText: String? { string(kAXDescriptionAttribute) }

    var axChildren: [AXElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        return children.map { AXElement(element: $0) }
    }

    var windows: [AXElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { AXElement(element: $0) }
    }

    var focusedWindow: AXElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
                == .success,
            let window = value
        else { return nil }
        // CFTypeRef carries no static type, and an attribute that should be a
        // window is not always one. Checked rather than force cast.
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        // swift-format-ignore: NeverForceUnwrap
        return AXElement(element: window as! AXUIElement)
    }
}

extension CaptureService {
    /// Recognises text in a picture of one application's windows, on this Mac.
    ///
    /// Vision's text recogniser runs locally. That is the only reason this is
    /// acceptable on a connector at all: the alternative shape of this feature
    /// ships a screenshot of someone's Mail window to a server.
    static func recognizeText(bundleId: String, maxCharacters: Int) async throws -> Value {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureAccessibilityError.screenRecordingNotAuthorized
        }
        let content = try await SCShareableContent.getAvailableContent()
        guard
            let application = content.applications.first(where: { $0.bundleIdentifier == bundleId })
        else {
            throw CaptureAccessibilityError.applicationNotRunning(bundleId)
        }
        let windows = content.windows.filter { $0.owningApplication == application }
        guard !windows.isEmpty else { throw CaptureAccessibilityError.noWindows(bundleId) }
        // The display the application is actually on, not the first one in
        // the list. Recognising against display one while the application sits
        // on display two produced an empty read reported as "no text found",
        // which is the same mistake the screenshot scaling made.
        guard let display = CaptureService.display(showing: windows, among: content.displays) else {
            throw CaptureAccessibilityError.noGUISession
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, including: windows),
            configuration: configuration
        )

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        var lines: [String] = []
        var characters = 0
        var truncated = false
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            if characters + text.count > maxCharacters {
                truncated = true
                break
            }
            characters += text.count
            lines.append(text)
        }

        var response: [String: Value] = [
            "bundleId": .string(bundleId),
            "applicationName": .string(application.applicationName),
            "source": .string("ocr"),
            "text": .string(lines.joined(separator: "\n")),
            "lineCount": .int(lines.count),
            "charactersReturned": .int(characters),
            "truncated": .bool(truncated),
            "note": .string(
                "Recognised from a picture of the application's windows, on this Mac. Recognition makes mistakes: check anything exact, such as a number or an address, against the interface itself."
            ),
        ]
        if truncated {
            response["note"] = .string(
                "Recognition stopped at maxCharacters. Raise it, or narrow what is on screen."
            )
        }
        return Value.object(response)
    }

    /// The whole handler, off the tool list.
    ///
    /// Not a style preference: the list of tools is one expression, and a
    /// handler body inlined into it is type-checked as part of that
    /// expression, which is how the surface reached "unable to type-check this
    /// expression in reasonable time".
    static func readImageText(_ arguments: [String: Value]) throws -> Value {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            throw FilesystemServiceError.missingArgument("path")
        }
        // The allowlist decides, exactly as it does for every filesystem
        // tool. Recognition is a read of the file's contents, and a
        // connector must not reach a file through this tool that
        // filesystem_read would refuse.
        let url = try FilesystemAccess.resolve(
            requested: path,
            roots: FilesystemService.shared.roots,
            requiringWrite: false
        )
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values?.contentType
        guard CaptureImageText.isSupported(type) else {
            throw CaptureImageTextError.unsupportedType(
                path: url.path,
                type: type?.localizedDescription ?? type?.identifier
            )
        }
        let size = values?.fileSize ?? 0
        guard size <= CaptureImageText.maximumFileBytes else {
            throw CaptureImageTextError.fileTooLarge(
                path: url.path,
                bytes: size,
                limit: CaptureImageText.maximumFileBytes
            )
        }

        let languages = arguments["languages"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let maxCharacters = CaptureImageText.clampedCharacters(
            arguments["maxCharacters"]?.intValue
        )

        if CaptureImageText.isPDF(type) {
            return try CaptureService.readPDF(
                at: url,
                startingAt: arguments["page"]?.intValue,
                maxPages: CaptureImageText.clampedPages(arguments["maxPages"]?.intValue),
                maxCharacters: maxCharacters,
                languages: languages
            )
        }
        return try CaptureService.readImage(
            at: url,
            maxCharacters: maxCharacters,
            languages: languages
        )
    }

    /// Written out here rather than inline: the tool list is one expression,
    /// and every interpolated description added to it costs the type checker
    /// real time.
    static let readImageTextDescription =
        "Read the text in a picture or a PDF that is already in a shared folder: a screenshot, a scan, "
        + "a photographed receipt, a PDF whose pages are images of pages. Recognition runs on this Mac "
        + "through the macOS Vision framework; nothing is uploaded and no model key is needed. A PDF page "
        + "that already carries real text is read rather than recognised, which is both exact and faster. "
        + "Needs no Screen Recording or Accessibility permission: the file is read from disk."
    static let readImageTextPageDescription =
        "First page of a PDF to read, counting from 1. Pass a previous call's nextPage to carry on."
    static let readImageTextMaxPagesDescription =
        "How many PDF pages this call may read, up to \(CaptureImageText.maximumMaxPages)"
    static let readImageTextMaxCharactersDescription =
        "Maximum characters to return, up to \(CaptureImageText.maximumMaxCharacters)"
    static let readImageTextLanguagesDescription =
        "Language codes to recognise, best first, such as [\"en-US\", \"fr-FR\"]. Left out, macOS picks."

    /// The display an application's windows are on.
    ///
    /// Picked by overlap area rather than by position in the list: a window
    /// straddling two displays belongs to the one showing most of it, and a
    /// list order is not a fact about where anything is.
    static func display(showing windows: [SCWindow], among displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        let target = windows.reduce(CGRect.null) { $0.union($1.frame) }
        guard !target.isNull, !target.isEmpty else { return displays.first }
        let ranked = displays.max { left, right in
            area(of: left.frame.intersection(target)) < area(of: right.frame.intersection(target))
        }
        guard let ranked, area(of: ranked.frame.intersection(target)) > 0 else {
            return displays.first
        }
        return ranked
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    /// Recognises one image file.
    static func readImage(at url: URL, maxCharacters: Int, languages: [String]) throws -> Value {
        let read = try CaptureImageTextReader.readImage(at: url, languages: languages)
        let budget = CaptureImageText.budgeted(lines: read.lines, maxCharacters: maxCharacters)
        var response: [String: Value] = [
            "path": .string(url.path),
            "kind": .string("image"),
            "source": .string("ocr"),
            "text": .string(budget.lines.joined(separator: "\n")),
            "lineCount": .int(budget.lines.count),
            "charactersReturned": .int(budget.characters),
            "truncated": .bool(budget.truncated),
            "pixelWidth": .int(read.pixelWidth),
            "pixelHeight": .int(read.pixelHeight),
            "note": .string(
                "Recognised on this Mac. Recognition makes mistakes: check anything exact, such as a figure or an account number, against the file itself."
            ),
        ]
        if budget.truncated {
            response["note"] = .string(
                "Recognition stopped at maxCharacters. Raise it to read the rest."
            )
        }
        return .object(response)
    }

    /// Reads a range of a PDF's pages.
    static func readPDF(
        at url: URL,
        startingAt requestedPage: Int?,
        maxPages: Int,
        maxCharacters: Int,
        languages: [String]
    ) throws -> Value {
        guard let document = PDFDocument(url: url) else {
            throw CaptureImageTextError.unreadableImage(url.path)
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw CaptureImageTextError.emptyDocument(url.path) }

        let range = CaptureImageText.pageRange(
            pageCount: pageCount,
            startingAt: requestedPage,
            maxPages: maxPages
        )
        var pages: [Value] = []
        var remaining = maxCharacters
        var truncated = false
        var recognisedAny = false
        var lastReadIndex = range.lowerBound - 1
        var combined: [String] = []

        for index in range {
            guard remaining > 0 else {
                truncated = true
                break
            }
            guard let page = document.page(at: index) else { continue }
            let read = try CaptureImageTextReader.readPage(
                page,
                number: index + 1,
                languages: languages
            )
            recognisedAny = recognisedAny || read.source == "ocr"
            let budget = CaptureImageText.budgeted(lines: read.lines, maxCharacters: remaining)
            remaining -= budget.characters
            truncated = truncated || budget.truncated
            lastReadIndex = index
            combined.append(contentsOf: budget.lines)
            pages.append(
                .object([
                    "page": .int(read.page),
                    "source": .string(read.source),
                    "text": .string(budget.lines.joined(separator: "\n")),
                    "lineCount": .int(budget.lines.count),
                    "truncated": .bool(budget.truncated),
                ])
            )
            if budget.truncated { break }
        }

        var response: [String: Value] = [
            "path": .string(url.path),
            "kind": .string("pdf"),
            "pageCount": .int(pageCount),
            "pages": .array(pages),
            "text": .string(combined.joined(separator: "\n")),
            "charactersReturned": .int(maxCharacters - max(0, remaining)),
            "truncated": .bool(truncated),
        ]
        // The next page to ask for is the one after the last page actually
        // read, which is not the end of the requested range when the character
        // budget cut the call short.
        let nextPage = lastReadIndex + 2
        if nextPage <= pageCount {
            response["nextPage"] = .int(nextPage)
            response["note"] = .string(
                "Stopped after page \(lastReadIndex + 1) of \(pageCount). Call again with page: \(nextPage) for the rest."
            )
        } else if recognisedAny {
            response["note"] = .string(
                "Pages with no text layer were recognised from their images on this Mac. Recognition makes mistakes: check anything exact against the file itself."
            )
        }
        return .object(response)
    }
}

enum CaptureAccessibilityError: LocalizedError {
    case missingBundleIdentifier
    case accessibilityNotAuthorized
    case screenRecordingNotAuthorized
    case noGUISession
    case applicationNotRunning(String)
    case noWindows(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return
                "bundleId is required. Call capture_list_targets for the bundle identifiers of the applications running on this Mac."
        case .accessibilityNotAuthorized:
            return
                "Apple Core does not have Accessibility permission, which is what reading an interface as text needs. "
                + "It is a separate permission from Screen Recording: System Settings › Privacy & Security › Accessibility, then switch Apple Core on. "
                + "Until then, capture_take_screenshot still works, and source: \"ocr\" reads text from a picture instead."
        case .screenRecordingNotAuthorized:
            return
                "Recognising text from the screen needs Screen Recording permission: System Settings › Privacy & Security › Screen & System Audio Recording."
        case .noGUISession:
            return
                "No one is logged in at this Mac's screen, or it is locked, so there is no interface to read."
        case let .applicationNotRunning(bundleId):
            return
                "\(bundleId) is not running on this Mac. Call capture_list_targets to see what is."
        case let .noWindows(bundleId):
            return "\(bundleId) is running but has no open windows to read."
        }
    }
}
