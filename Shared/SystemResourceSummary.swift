// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded totals about the Mac, and a firm line around what "resources" means.
//
// "How much space is left" is a real question a client cannot otherwise
// answer, and it is one number per volume. "What is running on this Mac" is a
// different question wearing the same word, and it is not answered here: no
// process list, no command lines, no environment variables. A process
// argument vector routinely contains an API token, and an environment dump
// always does; neither belongs on a connector that a remote client can call.
//
// So this file shapes totals and nothing else, and the shaping is separated
// from the reading so the arithmetic can be tested without depending on how
// full the disk happens to be today.

import Foundation

public struct StorageVolumeSummary: Equatable, Sendable {
    public let name: String
    public let path: String
    public let totalBytes: Int64
    /// What the filesystem will hand out now.
    public let availableBytes: Int64
    /// What it would hand out after purging caches and local snapshots, which
    /// on an APFS volume is usually much larger and is the number Finder shows.
    public let availableForImportantUsageBytes: Int64?

    public init(
        name: String,
        path: String,
        totalBytes: Int64,
        availableBytes: Int64,
        availableForImportantUsageBytes: Int64?
    ) {
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    /// Whole percent used, or nil for a volume that reports no size.
    public var percentUsed: Int? {
        guard totalBytes > 0 else { return nil }
        return Int((Double(usedBytes) / Double(totalBytes) * 100).rounded())
    }
}

public struct SystemResourceSummary: Equatable, Sendable {
    public let volumes: [StorageVolumeSummary]
    public let physicalMemoryBytes: Int64
    public let processorCount: Int
    public let uptimeSeconds: Int
    /// `ProcessInfo.ThermalState` described in words, because the raw enum
    /// value means nothing to a reader.
    public let thermalState: String
    public let lowPowerModeEnabled: Bool

    public init(
        volumes: [StorageVolumeSummary],
        physicalMemoryBytes: Int64,
        processorCount: Int,
        uptimeSeconds: Int,
        thermalState: String,
        lowPowerModeEnabled: Bool
    ) {
        self.volumes = volumes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.uptimeSeconds = uptimeSeconds
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }

    /// The volume a client should look at first when someone says "the disk".
    public var bootVolume: StorageVolumeSummary? {
        volumes.first { $0.path == "/" } ?? volumes.first
    }
}

public enum SystemResourceFormatting {
    /// Decimal gigabytes, the way Finder and Apple's own storage pane count
    /// them. Using binary units here would report a "500GB" SSD as 465GB and
    /// send someone looking for the missing 35.
    public static func describeBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var index = 0
        var scaled = value
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(scaled)) bytes" }
        return String(format: "%.1f%@", scaled, units[index])
    }

    public static func describeUptime(seconds: Int) -> String {
        let seconds = max(0, seconds)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func describeThermalState(_ rawValue: Int) -> String {
        switch rawValue {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious"
        case 3: return "critical"
        default: return "unknown"
        }
    }
}
