import AppKit
import Foundation
import IOKit.ps
import JSONSchema
import OSLog
import UserNotifications

private let log = Logger.service("utilities")

final class UtilitiesService: Service {
    static let shared = UtilitiesService()

    var tools: [Tool] {
        Tool(
            name: "utilities_beep",
            description: "Play a system sound",
            inputSchema: .object(
                properties: [
                    "sound": .string(
                        default: .string(Sound.default.rawValue),
                        enum: Sound.allCases.map { .string($0.rawValue) }
                    )
                ],
                required: ["sound"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Play System Sound",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { input in
            let rawValue = input["sound"]?.stringValue ?? Sound.default.rawValue
            guard let sound = Sound(rawValue: rawValue) else {
                log.error("Invalid sound: \(rawValue)")
                throw NSError(
                    domain: "SoundError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid sound"
                    ]
                )
            }

            return NSSound.play(sound)
        }

        Tool(
            name: "utilities_notify",
            description:
                "Post a macOS notification. Use this to get the user's attention when they are not looking at the conversation.",
            inputSchema: .object(
                properties: [
                    "title": .string(description: "Notification title"),
                    "body": .string(description: "Notification body text"),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Post Notification",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw UtilitiesError.missingArgument("title")
            }
            let body = arguments["body"]?.stringValue ?? ""

            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            // Notification authorization is requested lazily here rather than
            // when the service is enabled: most sessions never post one, and a
            // prompt on enable would be a prompt for nothing.
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else {
                throw UtilitiesError.notificationsNotAuthorized
            }
            try await center.add(request)
            return Value.object(["posted": .bool(true), "title": .string(title)])
        }

        Tool(
            name: "utilities_clipboard_formats",
            description:
                "List what is on the clipboard and in which formats, with sizes, without fetching any of it. "
                + "Call this before utilities_clipboard_read when the clipboard might hold something other than plain text, "
                + "such as a styled document, a web selection or an image.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "List Clipboard Formats",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let pasteboard = NSPasteboard.general
            let types = pasteboard.types ?? []
            let described: [Value] = types.compactMap { type in
                // Only the formats a client can actually ask for by name are
                // advertised. A pasteboard carries a dozen private types per
                // application, and listing them invites a request this tool
                // cannot serve.
                guard let format = ClipboardFormat.matching(pasteboardType: type.rawValue) else {
                    return nil
                }
                var entry: [String: Value] = [
                    "format": .string(format.rawValue),
                    "uti": .string(type.rawValue),
                    "textual": .bool(format.isTextual),
                ]
                if let data = pasteboard.data(forType: type) {
                    entry["sizeBytes"] = .int(data.count)
                    entry["fitsInline"] = .bool(data.count <= ClipboardPayload.maximumInlineBytes)
                }
                return .object(entry)
            }
            var result: [String: Value] = [
                "formats": .array(described),
                "changeCount": .int(pasteboard.changeCount),
                "isEmpty": .bool(types.isEmpty),
                "inlineLimitBytes": .int(ClipboardPayload.maximumInlineBytes),
            ]
            if described.isEmpty && !types.isEmpty {
                result["note"] = .string(
                    "The clipboard holds only formats private to the application that wrote it, so there is nothing here to read."
                )
            }
            return Value.object(result)
        }

        Tool(
            name: "utilities_clipboard_read",
            description:
                "Read what is on the clipboard. Plain text by default; pass format for rtf, html, url, fileURL, png, tiff or pdf. "
                + "Call utilities_clipboard_formats first to see what is actually there. "
                + "Anything too large to return inline can be written to a file with savePath, inside a shared folder that allows writing.",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        description: "Which format to read",
                        default: .string(ClipboardFormat.text.rawValue),
                        enum: ClipboardFormat.allCases.map { .string($0.rawValue) }
                    ),
                    "savePath": .string(
                        description:
                            "Write the clipboard contents to this file instead of returning them. Must sit inside a shared folder that allows writing."
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Clipboard",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let pasteboard = NSPasteboard.general
            let format = try ClipboardPayload.resolveFormat(arguments["format"]?.stringValue)
            let available = (pasteboard.types ?? []).compactMap {
                ClipboardFormat.matching(pasteboardType: $0.rawValue)?.rawValue
            }
            guard
                let data = pasteboard.data(
                    forType: NSPasteboard.PasteboardType(format.pasteboardType)
                )
            else {
                // The plain-text case keeps the shape it always returned, so a
                // client that only ever asked for text sees no change at all.
                if format == .text {
                    return Value.object([
                        "hasText": .bool(false),
                        "format": .string(format.rawValue),
                        "availableFormats": .array(available.map { .string($0) }),
                    ])
                }
                throw ClipboardError.formatUnavailable(
                    requested: format.rawValue,
                    available: available
                )
            }

            // A file is the only way large binary leaves this surface, and it
            // goes through the same allowlist every other write does. There is
            // no path here that writes outside a shared folder.
            if let savePath = arguments["savePath"]?.stringValue {
                let url = try FilesystemAccess.resolve(
                    requested: savePath,
                    roots: ServingConfigManager.load().filesystemRoots ?? [],
                    requiringWrite: true
                )
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw UtilitiesError.savePathExists(url.path)
                }
                try data.write(to: url, options: .atomic)
                log.info("Wrote clipboard \(format.rawValue, privacy: .public) to a shared folder")
                return Value.object([
                    "format": .string(format.rawValue),
                    "savedTo": .string(url.path),
                    "sizeBytes": .int(data.count),
                    "changeCount": .int(pasteboard.changeCount),
                ])
            }

            try ClipboardPayload.checkInlineSize(format: format, sizeBytes: data.count)
            var result: [String: Value] = [
                "format": .string(format.rawValue),
                "sizeBytes": .int(data.count),
                "changeCount": .int(pasteboard.changeCount),
                "availableFormats": .array(available.map { .string($0) }),
            ]
            if format.isTextual, let text = String(data: data, encoding: .utf8) {
                result["text"] = .string(text)
                result["characters"] = .int(text.count)
                if format == .text { result["hasText"] = .bool(true) }
            } else {
                result["base64"] = .string(data.base64EncodedString())
            }
            return Value.object(result)
        }

        Tool(
            name: "utilities_clipboard_write",
            description:
                "Replace the clipboard contents. Plain text by default; pass format for rtf, html or url. "
                + "This overwrites whatever the user had copied, so take a utilities_clipboard_snapshot first if you mean to put it back.",
            inputSchema: .object(
                properties: [
                    "text": .string(description: "Content to put on the clipboard"),
                    "format": .string(
                        description:
                            "How to label the content on the clipboard. rtf and html must already be in that format.",
                        default: .string(ClipboardFormat.text.rawValue),
                        enum: ClipboardFormat.allCases.filter(\.isWritable).map {
                            .string($0.rawValue)
                        }
                    ),
                ],
                required: ["text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write Clipboard",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let text = arguments["text"]?.stringValue else {
                throw UtilitiesError.missingArgument("text")
            }
            let format = try ClipboardPayload.resolveFormat(arguments["format"]?.stringValue)
            guard format.isWritable else {
                throw ClipboardError.formatNotWritable(format.rawValue)
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(
                Data(text.utf8),
                forType: NSPasteboard.PasteboardType(format.pasteboardType)
            )
            // A snapshot taken a moment ago must survive Apple Core's own
            // write, or the snapshot-write-restore sequence would invalidate
            // itself on the middle step.
            ClipboardSnapshotStore.shared.recordOwnWrite(changeCount: pasteboard.changeCount)
            return Value.object([
                "written": .bool(true),
                "format": .string(format.rawValue),
                "characters": .int(text.count),
                "changeCount": .int(pasteboard.changeCount),
            ])
        }

        Tool(
            name: "utilities_clipboard_snapshot",
            description:
                "Remember what is on the clipboard so it can be put back later with utilities_clipboard_restore. "
                + "Held in memory on this Mac for \(Int(ClipboardSnapshotStore.defaultLifetime / 60)) minutes and never written to disk, "
                + "because a clipboard routinely holds a password.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Snapshot Clipboard",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let pasteboard = NSPasteboard.general
            var items: [ClipboardFormat: Data] = [:]
            var skipped: [String] = []
            for type in pasteboard.types ?? [] {
                guard let format = ClipboardFormat.matching(pasteboardType: type.rawValue),
                    let data = pasteboard.data(forType: type)
                else { continue }
                // Bounded: a snapshot of a 40MB image held in memory for ten
                // minutes is a cost the user never asked for.
                guard data.count <= ClipboardPayload.maximumInlineBytes else {
                    skipped.append(format.rawValue)
                    continue
                }
                items[format] = data
            }
            let snapshot = ClipboardSnapshotStore.shared.store(
                items: items,
                changeCount: pasteboard.changeCount
            )
            var result: [String: Value] = [
                "token": .string(snapshot.token),
                "changeCount": .int(snapshot.expectedChangeCount),
                "formats": .array(items.keys.map(\.rawValue).sorted().map { .string($0) }),
                "expiresInSeconds": .int(Int(ClipboardSnapshotStore.defaultLifetime)),
            ]
            if !skipped.isEmpty {
                result["skippedFormats"] = .array(skipped.map { .string($0) })
                result["note"] = .string(
                    "\(skipped.joined(separator: ", ")) was too large to snapshot and will not come back on restore."
                )
            }
            return Value.object(result)
        }

        Tool(
            name: "utilities_clipboard_restore",
            description:
                "Put a snapshotted clipboard back. Refused when anything has copied to the clipboard since the snapshot was taken, "
                + "so this can never discard something the user copied while you were working.",
            inputSchema: .object(
                properties: [
                    "token": .string(description: "The token utilities_clipboard_snapshot returned")
                ],
                required: ["token"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Restore Clipboard",
                readOnlyHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let token = arguments["token"]?.stringValue else {
                throw UtilitiesError.missingArgument("token")
            }
            let pasteboard = NSPasteboard.general
            let decision = ClipboardSnapshotStore.shared.decide(
                token: token,
                currentChangeCount: pasteboard.changeCount
            )
            guard decision == .restore, let snapshot = ClipboardSnapshotStore.shared.snapshot(token: token)
            else {
                var refusal: [String: Value] = [
                    "restored": .bool(false),
                    "reason": .string(
                        {
                            switch decision {
                            case .restore: return "unavailable"
                            case .refusedNewerCopy: return "newer_copy"
                            case .expired: return "expired"
                            case .unknownToken: return "unknown_token"
                            }
                        }()
                    ),
                ]
                if let message = decision.message { refusal["note"] = .string(message) }
                if case let .refusedNewerCopy(current, expected) = decision {
                    refusal["changeCount"] = .int(current)
                    refusal["expectedChangeCount"] = .int(expected)
                }
                return Value.object(refusal)
            }

            pasteboard.clearContents()
            for (format, data) in snapshot.items {
                pasteboard.setData(
                    data,
                    forType: NSPasteboard.PasteboardType(format.pasteboardType)
                )
            }
            ClipboardSnapshotStore.shared.consume(token: token)
            return Value.object([
                "restored": .bool(true),
                "formats": .array(snapshot.items.keys.map(\.rawValue).sorted().map { .string($0) }),
                "changeCount": .int(pasteboard.changeCount),
            ])
        }

        Tool(
            name: "utilities_open_url",
            description:
                "Open a URL in the user's default application. Use this to show the user a web page or open a document.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "The URL to open")
                ],
                required: ["url"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Open URL",
                readOnlyHint: false,
                openWorldHint: true
            )
        ) { arguments in
            guard let raw = arguments["url"]?.stringValue, let url = URL(string: raw) else {
                throw UtilitiesError.missingArgument("url")
            }
            // Only schemes that open something the user can see. Without this,
            // a tool call could reach any registered URL handler on the Mac,
            // which is a much larger surface than "show me a page".
            let allowedSchemes = ["http", "https", "mailto", "facetime", "sms", "tel"]
            guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
                throw UtilitiesError.unsupportedScheme(url.scheme ?? "none")
            }
            let opened = NSWorkspace.shared.open(url)
            return Value.object(["opened": .bool(opened), "url": .string(url.absoluteString)])
        }

        Tool(
            name: "utilities_system_info",
            description: "Get basic information about this Mac: name, macOS version, and uptime",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "System Information",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let info = ProcessInfo.processInfo
            return Value.object([
                "computerName": .string(Host.current().localizedName ?? "Mac"),
                "systemVersion": .string(info.operatingSystemVersionString),
                "uptimeSeconds": .int(Int(info.systemUptime)),
                "processorCount": .int(info.processorCount),
            ])
        }

        Tool(
            name: "utilities_storage_summary",
            description:
                "How much disk space is free on this Mac, plus memory size, processor count, uptime and thermal state. "
                + "Totals only: this reports nothing about what is running, no process list, no command lines and no environment variables.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Storage and Resources",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            let summary = UtilitiesService.resourceSummary()
            let volumes: [Value] = summary.volumes.map { volume in
                var entry: [String: Value] = [
                    "name": .string(volume.name),
                    "path": .string(volume.path),
                    "totalBytes": .int(Int(volume.totalBytes)),
                    "availableBytes": .int(Int(volume.availableBytes)),
                    "total": .string(SystemResourceFormatting.describeBytes(volume.totalBytes)),
                    "available": .string(
                        SystemResourceFormatting.describeBytes(volume.availableBytes)
                    ),
                ]
                if let percent = volume.percentUsed { entry["percentUsed"] = .int(percent) }
                if let important = volume.availableForImportantUsageBytes {
                    entry["availableForImportantUsageBytes"] = .int(Int(important))
                    entry["availableAfterPurging"] = .string(
                        SystemResourceFormatting.describeBytes(important)
                    )
                }
                return .object(entry)
            }
            return Value.object([
                "volumes": .array(volumes),
                "physicalMemoryBytes": .int(Int(summary.physicalMemoryBytes)),
                "physicalMemory": .string(
                    SystemResourceFormatting.describeBytes(summary.physicalMemoryBytes)
                ),
                "processorCount": .int(summary.processorCount),
                "uptimeSeconds": .int(summary.uptimeSeconds),
                "uptime": .string(
                    SystemResourceFormatting.describeUptime(seconds: summary.uptimeSeconds)
                ),
                "thermalState": .string(summary.thermalState),
                "lowPowerModeEnabled": .bool(summary.lowPowerModeEnabled),
            ])
        }

        Tool(
            name: "utilities_power",
            description:
                "Report this Mac's power: whether it is on mains or battery, how much charge is left, whether "
                + "it is charging, and how long macOS thinks that leaves. Worth asking before starting anything "
                + "long on a laptop serving this connector. Reads only; changes no power setting.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Power and Battery",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            let summary = UtilitiesService.powerSummary()
            let info = ProcessInfo.processInfo
            var response: [String: Value] = [
                "hasBattery": .bool(summary.hasBattery),
                "powerSource": .string(summary.source.rawValue),
                "isCharging": .bool(summary.isCharging),
                "isFullyCharged": .bool(summary.isFullyCharged),
                "lowPowerModeEnabled": .bool(info.isLowPowerModeEnabled),
                "thermalState": .string(
                    SystemResourceFormatting.describeThermalState(info.thermalState.rawValue)
                ),
                "summary": .string(summary.summaryLine()),
            ]
            if let percent = summary.percentRemaining {
                response["percentRemaining"] = .int(percent)
            }
            if let minutes = summary.minutesRemaining {
                response["minutesRemaining"] = .int(minutes)
            }
            if let minutes = summary.minutesToFullCharge {
                response["minutesToFullCharge"] = .int(minutes)
            }
            if summary.timeEstimateIsCalculating {
                response["timeEstimateIsCalculating"] = .bool(true)
                response["timeEstimateNote"] = .string(
                    "macOS has not settled on a time estimate yet, which it does for several minutes after a charger is plugged in or unplugged. The percentage is still accurate."
                )
            }
            if let condition = summary.condition {
                response["batteryCondition"] = .string(condition)
            }
            return Value.object(response)
        }

        Tool(
            name: "utilities_connector_health",
            description:
                "Report which Apple Core surfaces are live on this Mac, what each one is waiting on, "
                + "which folders are shared, and the version information a support conversation needs. "
                + "Read-only, and raises no permission prompts. Call this first when a tool is missing or failing.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Connector Health",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { _ in
            await connectorHealthReport()
        }
    }
}

extension UtilitiesService {
    /// Reads the totals the summary reports.
    ///
    /// Volumes are the boot volume plus the volume each shared folder lives
    /// on, deduplicated. Not every mounted volume: a connected client asking
    /// about disk space has no business being handed an inventory of the
    /// external drives and network shares attached to someone's Mac.
    /// Reads the Mac's own power source.
    ///
    /// The internal battery is picked by name rather than by position: a Mac
    /// with a UPS attached lists the UPS as a power source too, and reporting
    /// its charge as the Mac's battery would be a confident wrong answer.
    static func powerSummary() -> PowerSummary {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return .noBattery }

        let descriptions = sources.compactMap { source in
            IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        }
        guard !descriptions.isEmpty else { return .noBattery }
        let internalBattery = descriptions.first { description in
            (description[PowerSummary.Key.type] as? String) == kIOPSInternalBatteryType
        }
        return PowerSummary.from(description: internalBattery ?? descriptions[0])
    }

    static func resourceSummary() -> SystemResourceSummary {
        let info = ProcessInfo.processInfo
        var paths = ["/"]
        for root in ServingConfigManager.load().filesystemRoots ?? [] {
            paths.append(root.path)
        }

        var volumes: [StorageVolumeSummary] = []
        var seen = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard
                let values = try? url.resourceValues(forKeys: [
                    .volumeURLKey, .volumeNameKey, .volumeTotalCapacityKey,
                    .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                ]),
                let volumeURL = values.volume,
                seen.insert(volumeURL.path).inserted
            else { continue }
            volumes.append(
                StorageVolumeSummary(
                    name: values.volumeName ?? volumeURL.lastPathComponent,
                    path: volumeURL.path,
                    totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                    availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                    availableForImportantUsageBytes: values
                        .volumeAvailableCapacityForImportantUsage
                )
            )
        }

        return SystemResourceSummary(
            volumes: volumes,
            physicalMemoryBytes: Int64(info.physicalMemory),
            processorCount: info.processorCount,
            uptimeSeconds: Int(info.systemUptime),
            thermalState: SystemResourceFormatting.describeThermalState(
                info.thermalState.rawValue
            ),
            lowPowerModeEnabled: info.isLowPowerModeEnabled
        )
    }
}

/// Gathers the live values `ConnectorHealth` shapes into a report. Every probe
/// here reads recorded state: nothing calls a surface, so nothing prompts.
private func connectorHealthReport() async -> ConnectorHealthReport {
    let built = Dictionary(
        uniqueKeysWithValues: ServiceRegistry.services.map {
            (String(describing: type(of: $0)), $0.tools.count)
        }
    )
    let defaults = UserDefaults.standard
    let info = Bundle.main.infoDictionary ?? [:]

    var surfaces: [ConnectorSurfaceInput] = []
    // The inventory, not the registry, decides which surfaces exist: a service
    // compiled out of this build has to appear as unsupported rather than
    // vanish, or a client cannot tell "not on this Mac" from "never existed".
    for serviceTypeName in ServicePermissionInventory.standard.keys.sorted() {
        let needs = ServicePermissionInventory.standard[serviceTypeName] ?? []
        let isBuilt = built[serviceTypeName] != nil
        let isEnabled =
            defaults.object(
                forKey: ConnectorHealth.enablementDefaultsKey(forServiceTypeName: serviceTypeName)
            ) as? Bool ?? ConnectorHealth.defaultEnabled(forServiceTypeName: serviceTypeName)

        // A surface nobody switched on is reported as switched off, full stop.
        // Reading its permissions anyway would list refusals for things the
        // user has not agreed to use yet, and spend a TCC round trip each.
        var permissions: [ConnectorPermissionInput] = []
        if isBuilt && isEnabled {
            for need in needs {
                let state = await ServicePermissionStatus.state(of: need.requirement)
                permissions.append(
                    ConnectorPermissionInput(
                        requirement: need.requirement.settingsTitle,
                        state: state.connectorState,
                        detail: state.label,
                        isOptional: !need.isRequired,
                        capability: need.capability
                    )
                )
            }
        }

        surfaces.append(
            ConnectorSurfaceInput(
                serviceTypeName: serviceTypeName,
                isBuilt: isBuilt,
                isEnabled: isEnabled,
                toolCount: built[serviceTypeName] ?? 0,
                permissions: permissions
            )
        )
    }

    let sharedFolders = (ServingConfigManager.load().filesystemRoots ?? []).map {
        ConnectorHealthReport.SharedFolder(path: $0.path, writable: $0.writable)
    }

    return ConnectorHealth.report(
        application: ConnectorHealthReport.Application(
            name: info["CFBundleName"] as? String ?? "Apple Core",
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        ),
        // The menu bar switch, read from the same default `App.swift` binds.
        isConnectorEnabled: defaults.object(forKey: "isEnabled") as? Bool ?? true,
        surfaces: surfaces,
        sharedFolders: sharedFolders
    )
}

extension ServicePermissionState {
    /// The recorded answer, reduced to what a client can act on. `limited`
    /// keeps its wording in the detail, which is where the narrowing is
    /// described.
    var connectorState: ConnectorPermissionState {
        switch self {
        case .granted: .granted
        case .limited: .limited
        case .denied: .denied
        case .notDetermined: .notRequested
        case .promptBlocked: .promptBlocked
        case .unknown: .unreadable
        }
    }
}

enum UtilitiesError: LocalizedError {
    case missingArgument(String)
    case unsupportedScheme(String)
    case notificationsNotAuthorized
    case savePathExists(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .unsupportedScheme(scheme):
            return "Apple Core will not open \(scheme): URLs."
        case .notificationsNotAuthorized:
            return "Notifications are not allowed for Apple Core in System Settings."
        case let .savePathExists(path):
            return
                "\(path) already exists. Nothing was written: replacing a file here would discard it without sending anything to the Trash. Choose another name."
        }
    }
}
