// SPDX-License-Identifier: GPL-3.0-or-later
//
// A Cloudflare tunnel is one identity, and its credentials travel with the
// config file. A second Mac that starts the same tunnel becomes a second
// connector: Cloudflare spreads requests across both, and every request that
// lands on the Mac without Apple Core fails. These are the rules that keep a
// tunnel on exactly one Mac. They have no dependencies so the test target can
// compile them without the rest of the app.

import Foundation
#if os(macOS)
    import IOKit
#endif

/// Which Mac a tunnel belongs to, relative to the one asking.
public enum CloudflareTunnelOwnership: Equatable, Sendable {
    /// No owner recorded: a config written before ownership existed.
    case unowned
    case thisMac
    case otherMac(name: String)
}

/// What `cloudflared tunnel info` reports about who is connected to a tunnel.
/// Each connector is one running cloudflared process, normally one per Mac.
public struct CloudflareConnectorReport: Equatable, Sendable {
    public var connectorCount: Int
    public var originIPs: [String]

    public init(connectorCount: Int, originIPs: [String]) {
        self.connectorCount = connectorCount
        self.originIPs = originIPs
    }
}

public enum CloudflareTunnelOwnershipRules {
    public static func ownership(
        ownerMachineID: String,
        ownerMachineName: String,
        currentMachineID: String
    ) -> CloudflareTunnelOwnership {
        let owner = ownerMachineID.trimmingCharacters(in: .whitespacesAndNewlines)
        if owner.isEmpty {
            return .unowned
        }
        if owner == currentMachineID {
            return .thisMac
        }
        let name = ownerMachineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .otherMac(name: name.isEmpty ? "another Mac" : name)
    }

    /// Parses `cloudflared tunnel info --output json`. Nil when the output is
    /// not that document, so a cloudflared error never reads as zero connectors.
    public static func parseTunnelInfo(_ data: Data) -> CloudflareConnectorReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let connectors = object["conns"] as? [[String: Any]]
        else {
            return nil
        }
        var ips: [String] = []
        for connector in connectors {
            for edge in connector["conns"] as? [[String: Any]] ?? [] {
                if let ip = edge["origin_ip"] as? String, !ip.isEmpty, !ips.contains(ip) {
                    ips.append(ip)
                }
            }
        }
        return CloudflareConnectorReport(connectorCount: connectors.count, originIPs: ips)
    }

    public static func ownedElsewhereMessage(owner: String, hostname: String) -> String {
        let address = hostname.isEmpty ? "this tunnel" : hostname
        return
            "\(owner) runs remote access for \(address). Starting it here too would make the public address fail. Turn it off there first, or take it over on this Mac."
    }

    public static func duplicateConnectorMessage(count: Int, tunnelName: String) -> String {
        "\(count) Macs are connected to tunnel \(tunnelName). Cloudflare spreads requests across all of them, so the public address fails whenever a request lands on a Mac that is not running Apple Core. Turn off remote access on the other Mac."
    }
}

/// A stable identity for the Mac this process runs on.
public enum MachineIdentity {
    /// The hardware platform UUID, which survives renames and OS reinstalls.
    /// Falls back to the host name only when IOKit will not answer.
    public static func currentID() -> String {
        #if os(macOS)
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
            defer { IOObjectRelease(service) }
            if service != 0,
                let value = IORegistryEntryCreateCFProperty(
                    service,
                    "IOPlatformUUID" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? String,
                !value.isEmpty
            {
                return value
            }
        #endif
        return ProcessInfo.processInfo.hostName
    }

    public static func currentName() -> String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? ProcessInfo.processInfo.hostName : name
    }
}
