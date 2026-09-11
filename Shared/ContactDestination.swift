// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure destination logic for Contacts writes: which container a new contact
// or group should land in, and what the caller is told about where it
// actually landed.
//
// None of this touches CNContactStore. The service layer converts live
// `CNContainer` values into `ContactContainerCandidate` and hands them here.
//
// One rule shapes the file. A contact created into a local-only container
// looks exactly like a contact created into iCloud until someone notices it
// never reached their phone, so the default is never "whatever the system
// default container happens to be". Either an off-device destination is
// identified, or the write is refused and the caller is told what the
// available destinations are.

import Foundation

// MARK: - Containers

/// What kind of account backs a container. Contacts has no account-level API
/// separate from containers: a container *is* the account as far as
/// CNContactStore is concerned, which is why destination selection is
/// expressed in containers throughout.
public enum ContactContainerKind: String, Sendable, CaseIterable {
    case local
    case exchange
    case cardDAV
    case unassigned
    case unknown

    /// Whether a contact written here can leave this Mac at all. `local` is
    /// the On My Mac store; everything else is backed by a server.
    public var syncsOffDevice: Bool {
        switch self {
        case .local, .unknown: return false
        case .exchange, .cardDAV, .unassigned: return true
        }
    }
}

/// One place a contact or group can be created.
public struct ContactContainerCandidate: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let kind: ContactContainerKind
    /// True for the container CNContactStore reports as its default. Recorded
    /// for diagnosis only; it is deliberately not used to pick a destination.
    public let isSystemDefault: Bool

    public init(
        identifier: String,
        name: String,
        kind: ContactContainerKind,
        isSystemDefault: Bool = false
    ) {
        self.identifier = identifier
        self.name = name
        self.kind = kind
        self.isSystemDefault = isSystemDefault
    }

    public var syncsOffDevice: Bool { kind.syncsOffDevice }

    /// Whether this looks like the iCloud container.
    ///
    /// This is a name heuristic, and it is the weakest link in the file.
    /// Contacts exposes no account identity on `CNContainer`: iCloud, Google
    /// and Fastmail are all `cardDAV`, distinguished only by a display name
    /// macOS chooses. iCloud is named "iCloud" in some builds and "Card", the
    /// CardDAV principal, in others. A caller that needs certainty should
    /// pass a container identifier from `contacts_containers` instead of
    /// relying on this.
    public var isICloud: Bool {
        guard kind == .cardDAV else { return false }
        return ContactContainerNaming.readsAsICloud(name)
    }

    /// How a container is named back to a caller choosing between several.
    public var disambiguation: String {
        "\"\(name)\" (\(kind.rawValue), identifier \(identifier))"
    }
}

public enum ContactContainerNaming {
    /// Display names macOS is known to give the iCloud contacts container.
    public static let iCloudNames: Set<String> = ["icloud", "card", "icloud contacts"]

    public static func readsAsICloud(_ name: String) -> Bool {
        let normalized =
            name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return iCloudNames.contains(normalized)
    }
}

// MARK: - Errors

public enum ContactDestinationError: LocalizedError, Equatable {
    case noContainers
    case unknownIdentifier(String)
    case unknownName(requested: String, available: [String])
    case ambiguousName(requested: String, candidates: [String])
    case noICloudDestination(available: [String])
    case ambiguousICloudDestination(candidates: [String])

    public var errorDescription: String? {
        switch self {
        case .noContainers:
            return "This Mac reports no Contacts containers, so there is nowhere to save a contact."
        case let .unknownIdentifier(identifier):
            return
                "No Contacts container has the identifier \(identifier). Call contacts_containers to list them."
        case let .unknownName(requested, available):
            return
                "No Contacts container matches \"\(requested)\". Available containers: "
                + "\(available.joined(separator: ", "))."
        case let .ambiguousName(requested, candidates):
            return
                "\"\(requested)\" names \(candidates.count) Contacts containers: "
                + "\(candidates.joined(separator: "; ")). Pass the identifier instead."
        case let .noICloudDestination(available):
            return
                "No iCloud container was found on this Mac, and writing to the default container "
                + "would create a contact that never leaves this machine. Available containers: "
                + "\(available.joined(separator: "; ")). Either sign in to iCloud Contacts, or pass "
                + "container explicitly to accept a local-only contact."
        case let .ambiguousICloudDestination(candidates):
            return
                "\(candidates.count) containers look like iCloud: \(candidates.joined(separator: "; ")). "
                + "Pass container explicitly to say which one."
        }
    }
}

// MARK: - Resolution

public enum ContactDestinationTarget {
    /// Exact identifier first, then an exact, case-insensitive name.
    ///
    /// With nothing requested the destination is the iCloud container, not
    /// the system default container. The system default is On My Mac on a Mac
    /// that has never had iCloud Contacts turned on, and a caller asking to
    /// "create a contact" has not asked for a card that stays on one machine.
    /// When no iCloud container exists the write is refused rather than
    /// redirected, so the absence is reported at creation time.
    public static func resolve(
        requested: String?,
        in containers: [ContactContainerCandidate]
    ) throws -> ContactContainerCandidate {
        guard !containers.isEmpty else { throw ContactDestinationError.noContainers }

        guard let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try defaultDestination(in: containers)
        }
        let wanted = requested.trimmingCharacters(in: .whitespaces)

        if let byIdentifier = containers.first(where: { $0.identifier == wanted }) {
            return byIdentifier
        }
        let byName = containers.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        switch byName.count {
        case 0:
            // An identifier-shaped request that matched nothing is a stale or
            // wrong identifier, which is worth saying plainly.
            if wanted.contains(":ABPerson") || UUID(uuidString: wanted) != nil {
                throw ContactDestinationError.unknownIdentifier(wanted)
            }
            throw ContactDestinationError.unknownName(
                requested: wanted,
                available: containers.map(\.disambiguation)
            )
        case 1:
            return byName[0]
        default:
            throw ContactDestinationError.ambiguousName(
                requested: wanted,
                candidates: byName.map(\.disambiguation)
            )
        }
    }

    /// The destination used when the caller names none: exactly one iCloud
    /// container, or an error naming what is actually available.
    public static func defaultDestination(
        in containers: [ContactContainerCandidate]
    ) throws -> ContactContainerCandidate {
        guard !containers.isEmpty else { throw ContactDestinationError.noContainers }
        let iCloud = containers.filter(\.isICloud)
        switch iCloud.count {
        case 1:
            return iCloud[0]
        case 0:
            throw ContactDestinationError.noICloudDestination(
                available: containers.map(\.disambiguation)
            )
        default:
            throw ContactDestinationError.ambiguousICloudDestination(
                candidates: iCloud.map(\.disambiguation)
            )
        }
    }
}

// MARK: - Reporting

/// What a caller is told about where a contact actually landed.
///
/// `landed` is read back from the store after the save, not assumed from the
/// request, because that gap is the whole bug: the September 8 card was
/// created with a nil container, went to On My Mac, and read back perfectly
/// on the machine that wrote it.
public struct ContactDestinationReport: Sendable, Equatable {
    public let container: ContactContainerCandidate
    public let syncsOffDevice: Bool
    public let isICloud: Bool
    public let warning: String?

    public init(
        container: ContactContainerCandidate,
        syncsOffDevice: Bool,
        isICloud: Bool,
        warning: String?
    ) {
        self.container = container
        self.syncsOffDevice = syncsOffDevice
        self.isICloud = isICloud
        self.warning = warning
    }
}

public enum ContactDestinationReporting {
    /// `landed` is where the store says the record now lives; `requested` is
    /// the container resolution asked for, when one was resolved.
    public static func report(
        landed: ContactContainerCandidate?,
        requested: ContactContainerCandidate?
    ) -> ContactDestinationReport {
        guard let landed else {
            // The save succeeded but the container could not be read back.
            // Saying so beats implying the requested destination was honoured.
            let fallback =
                requested
                ?? ContactContainerCandidate(identifier: "", name: "unknown", kind: .unknown)
            return ContactDestinationReport(
                container: fallback,
                syncsOffDevice: false,
                isICloud: false,
                warning:
                    "Saved, but this Mac did not report which container the record landed in, so "
                    + "whether it will sync to your other devices is unverified."
            )
        }

        var warnings: [String] = []
        if !landed.syncsOffDevice {
            warnings.append(
                "This record was created in \"\(landed.name)\", which is stored on this Mac only. "
                    + "It will not appear on your other devices."
            )
        }
        if let requested, requested.identifier != landed.identifier {
            warnings.append(
                "It was requested in \"\(requested.name)\" but landed in \"\(landed.name)\"."
            )
        }

        return ContactDestinationReport(
            container: landed,
            syncsOffDevice: landed.syncsOffDevice,
            isICloud: landed.isICloud,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " ")
        )
    }

    /// Saved on this Mac and delivered to other devices are separate
    /// outcomes, and only the first is observable from here. CloudKit gives
    /// no per-record delivery receipt through CNContactStore, so the honest
    /// report is the destination plus what that destination implies.
    public static func syncExpectation(_ report: ContactDestinationReport) -> String {
        if !report.syncsOffDevice {
            return "local-only"
        }
        return report.isICloud ? "expected-via-icloud" : "expected-via-server-account"
    }
}
