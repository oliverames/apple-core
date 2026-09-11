// SPDX-License-Identifier: GPL-3.0-or-later
//
// One read-only answer to "what is this connector actually able to do right
// now?".
//
// Establishing that used to take a run of tool calls that each proved one
// thing by trying it, which is both slow and the opposite of read-only: a
// probe that works by calling a surface can trip a consent prompt. The
// shaping lives here, apart from the tool closure, so the state mapping can
// be tested against fabricated inventories instead of whatever this Mac
// happens to have granted today.

import Foundation

/// What macOS records for one requirement, reduced to the distinctions that
/// change what a caller should do next. `ServicePermissionStatus` produces the
/// live values; this mirror exists because that probe is app-target code and
/// the shaping has to compile into the test target too.
public enum ConnectorPermissionState: String, Codable, Equatable, Sendable {
    case granted
    /// Granted, but narrower than the surface needs.
    case limited
    case denied
    /// Never asked for, so the first call will raise a prompt.
    case notRequested
    /// macOS refused to show the prompt, so nothing is recorded and System
    /// Settings has no row to switch on.
    case promptBlocked
    /// The answer cannot be read at the moment, which is not a refusal.
    case unreadable
}

/// One surface's standing, in the four failure shapes that call for four
/// different responses: switch it on, upgrade macOS or the build, open System
/// Settings, or try again later.
public enum ConnectorSurfaceState: String, Codable, Equatable, Sendable {
    case ready
    case disabled
    case unsupported
    case denied
    case unavailable
}

/// One requirement's live reading, as the caller probed it.
public struct ConnectorPermissionInput: Equatable, Sendable {
    public let requirement: String
    public let state: ConnectorPermissionState
    public let detail: String
    /// True when the surface declared this grant as enabling one named
    /// capability rather than as a condition of working at all. An absent
    /// optional grant is reported, but it does not put the surface into a
    /// refused state: the difference between "four tools need this" and
    /// "nothing answers".
    public let isOptional: Bool
    /// What the optional grant unlocks, in the surface's own words.
    public let capability: String?

    public init(
        requirement: String,
        state: ConnectorPermissionState,
        detail: String,
        isOptional: Bool = false,
        capability: String? = nil
    ) {
        self.requirement = requirement
        self.state = state
        self.detail = detail
        self.isOptional = isOptional
        self.capability = capability
    }
}

/// Live input for one surface, gathered by the caller.
public struct ConnectorSurfaceInput: Equatable, Sendable {
    public let serviceTypeName: String
    /// False when this build does not contain the surface at all, which is how
    /// a framework missing from the running OS shows up.
    public let isBuilt: Bool
    public let isEnabled: Bool
    public let toolCount: Int
    public let permissions: [ConnectorPermissionInput]

    public init(
        serviceTypeName: String,
        isBuilt: Bool,
        isEnabled: Bool,
        toolCount: Int,
        permissions: [ConnectorPermissionInput]
    ) {
        self.serviceTypeName = serviceTypeName
        self.isBuilt = isBuilt
        self.isEnabled = isEnabled
        self.toolCount = toolCount
        self.permissions = permissions
    }
}

public struct ConnectorHealthReport: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public let name: String
        public let version: String
        public let build: String
        public let macOSVersion: String
    }

    public struct Permission: Codable, Equatable, Sendable {
        public let requirement: String
        public let state: ConnectorPermissionState
        public let detail: String
        /// True when the grant enables a named capability instead of gating
        /// the surface, so a client can tell an unused extra from a fault.
        public let isOptional: Bool
        /// What this grant unlocks, present only when it is optional.
        public let capability: String?
    }

    public struct Surface: Codable, Equatable, Sendable {
        public let service: String
        public let state: ConnectorSurfaceState
        public let toolCount: Int
        public let permissions: [Permission]
    }

    public struct SharedFolder: Codable, Equatable, Sendable {
        public let path: String
        public let writable: Bool
    }

    public let application: Application
    /// The master switch in the menu bar. Off means every tool call is
    /// refused, whatever the individual surfaces say.
    public let isConnectorEnabled: Bool
    public let surfaces: [Surface]
    /// Surfaces per state, so a caller can see "four ready, one denied"
    /// without counting the list itself.
    public let stateCounts: [String: Int]
    /// The folders the Filesystem surface may touch. Present only when that
    /// surface is switched on, because paths it cannot reach are not this
    /// call's business.
    public let sharedFolders: [SharedFolder]
}

public enum ConnectorHealth {
    /// Environment variables whose values would be a leak if one ever reached
    /// a detail string. Nothing here reads them deliberately; the sweep is
    /// what keeps that true when a probe's wording changes upstream.
    public static let redactedEnvironmentKeys = [
        "TUNNEL_TOKEN",
        "TUNNEL_CRED_CONTENTS",
        "CLOUDFLARE_API_TOKEN",
        "GUMROAD_LICENSE_KEY",
    ]

    /// A refusal outranks a reading failure, and both outrank a working
    /// surface: the caller is told the most actionable thing that is true.
    /// Enablement and build presence come first because a surface nobody
    /// switched on says nothing about its permissions.
    public static func state(for surface: ConnectorSurfaceInput) -> ConnectorSurfaceState {
        guard surface.isBuilt else { return .unsupported }
        guard surface.isEnabled else { return .disabled }
        // Optional grants are left out of the verdict on purpose. Mail
        // without Full Disk Access is ready: every tool but the local index
        // works, and reporting it as denied would send a caller to System
        // Settings to fix a surface that is not broken. The row itself still
        // carries the missing grant, so a caller can see why one tool fails.
        let gating = surface.permissions.filter { !$0.isOptional }
        if gating.contains(where: { $0.state == .denied || $0.state == .promptBlocked }) {
            return .denied
        }
        if gating.contains(where: { $0.state == .unreadable || $0.state == .notRequested }) {
            return .unavailable
        }
        return .ready
    }

    /// "MessageService" reads as an implementation detail in a support
    /// conversation; "Message" is the surface people talk about. Derived
    /// rather than tabulated so a new service cannot be left out of a list.
    public static func surfaceName(forServiceTypeName name: String) -> String {
        name.hasSuffix("Service") ? String(name.dropLast("Service".count)) : name
    }

    /// The defaults key holding a surface's switch. `ServerController` binds
    /// the same keys through `@AppStorage`, so this reads the switch the user
    /// set rather than a second idea of what is on.
    public static func enablementDefaultsKey(forServiceTypeName name: String) -> String {
        // The store predates the type names and was written in the plural for
        // Messages, so the one mismatch is spelled out rather than papered
        // over with a rule that would be wrong for the next service.
        if name == "MessageService" { return "messagesEnabled" }
        let surface = surfaceName(forServiceTypeName: name)
        return surface.prefix(1).lowercased() + surface.dropFirst() + "Enabled"
    }

    /// Surfaces the user never switched, in the state a fresh install leaves
    /// them. `ServerController` seeds the same two on, so a report read before
    /// anyone opens Settings matches what the app will actually serve.
    public static func defaultEnabled(forServiceTypeName name: String) -> Bool {
        name == "MapsService" || name == "UtilitiesService"
    }

    public static func report(
        application: ConnectorHealthReport.Application,
        isConnectorEnabled: Bool,
        surfaces: [ConnectorSurfaceInput],
        sharedFolders: [ConnectorHealthReport.SharedFolder],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConnectorHealthReport {
        // The master switch is folded in here rather than reported beside the
        // surfaces: a row reading "ready" while nothing answers is the exact
        // confusion this call exists to end.
        let effective = surfaces.map { surface in
            ConnectorSurfaceInput(
                serviceTypeName: surface.serviceTypeName,
                isBuilt: surface.isBuilt,
                isEnabled: surface.isEnabled && isConnectorEnabled,
                toolCount: surface.toolCount,
                permissions: surface.permissions
            )
        }

        let described = effective.map { surface in
            ConnectorHealthReport.Surface(
                service: surfaceName(forServiceTypeName: surface.serviceTypeName),
                state: state(for: surface),
                toolCount: surface.toolCount,
                permissions: surface.permissions.map { permission in
                    ConnectorHealthReport.Permission(
                        requirement: permission.requirement,
                        state: permission.state,
                        detail: redacted(permission.detail, environment: environment),
                        isOptional: permission.isOptional,
                        capability: permission.capability.map {
                            redacted($0, environment: environment)
                        }
                    )
                }
            )
        }

        var counts: [String: Int] = [:]
        for surface in described {
            counts[surface.state.rawValue, default: 0] += 1
        }

        // A disabled Filesystem surface cannot read these folders, so listing
        // them would only hand out paths the call is not otherwise entitled
        // to name.
        let filesystemIsReady = effective.contains {
            $0.serviceTypeName == "FilesystemService" && state(for: $0) == .ready
        }

        return ConnectorHealthReport(
            application: ConnectorHealthReport.Application(
                name: application.name,
                version: redacted(application.version, environment: environment),
                build: redacted(application.build, environment: environment),
                macOSVersion: redacted(application.macOSVersion, environment: environment)
            ),
            isConnectorEnabled: isConnectorEnabled,
            surfaces: described,
            stateCounts: counts,
            sharedFolders: filesystemIsReady ? sharedFolders : []
        )
    }

    private static func redacted(_ text: String, environment: [String: String]) -> String {
        SensitiveTextSanitizer.redactAssignmentsAndValues(
            in: text,
            keys: redactedEnvironmentKeys,
            environment: environment
        )
    }
}
