// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// Fixtures stand in for the real containers deliberately. These tests must
/// never touch CNContactStore: a stray write to Oliver's address book syncs to
/// every device he owns, and the interesting cases here, a Mac with no iCloud
/// account and a Mac with two CardDAV accounts, are exactly the ones a live
/// store will not produce on demand.
@Suite("Contact destinations")
struct ContactDestinationTests {
    // MARK: Fixtures

    static let iCloud = ContactContainerCandidate(
        identifier: "C-icloud",
        name: "iCloud",
        kind: .cardDAV
    )
    static let onMyMac = ContactContainerCandidate(
        identifier: "C-local",
        name: "On My Mac",
        kind: .local,
        isSystemDefault: true
    )
    static let fastmail = ContactContainerCandidate(
        identifier: "C-fastmail",
        name: "Fastmail",
        kind: .cardDAV
    )
    static let exchange = ContactContainerCandidate(
        identifier: "C-exchange",
        name: "Work",
        kind: .exchange
    )

    // MARK: Classification

    @Test("A local container never syncs off the device")
    func localDoesNotSync() {
        #expect(Self.onMyMac.syncsOffDevice == false)
        #expect(Self.onMyMac.isICloud == false)
    }

    @Test("Server-backed containers sync off the device")
    func serverContainersSync() {
        #expect(Self.iCloud.syncsOffDevice)
        #expect(Self.fastmail.syncsOffDevice)
        #expect(Self.exchange.syncsOffDevice)
    }

    @Test("A CardDAV account that is not iCloud is not read as iCloud")
    func otherCardDAVIsNotICloud() {
        #expect(Self.fastmail.isICloud == false)
        #expect(Self.exchange.isICloud == false)
    }

    @Test("The names macOS gives the iCloud container are all recognized")
    func iCloudNameVariants() {
        #expect(ContactContainerNaming.readsAsICloud("iCloud"))
        #expect(ContactContainerNaming.readsAsICloud("ICLOUD"))
        #expect(ContactContainerNaming.readsAsICloud(" Card "))
        #expect(ContactContainerNaming.readsAsICloud("Fastmail") == false)
        #expect(ContactContainerNaming.readsAsICloud("") == false)
    }

    @Test("A local container named iCloud is still local")
    func kindGatesTheNameHeuristic() {
        let impostor = ContactContainerCandidate(
            identifier: "C-x",
            name: "iCloud",
            kind: .local
        )
        #expect(impostor.isICloud == false)
    }

    // MARK: Default destination

    @Test("With iCloud present the default destination is iCloud, not the system default")
    func defaultPrefersICloudOverSystemDefault() throws {
        let resolved = try ContactDestinationTarget.defaultDestination(
            in: [Self.onMyMac, Self.iCloud]
        )
        #expect(resolved.identifier == Self.iCloud.identifier)
        // The system default on this fixture Mac is On My Mac, which is the
        // September 8 configuration that produced the invisible contact.
        #expect(Self.onMyMac.isSystemDefault)
    }

    @Test("With no iCloud container the write is refused rather than made local")
    func noICloudIsAnError() {
        #expect(throws: ContactDestinationError.self) {
            try ContactDestinationTarget.defaultDestination(in: [Self.onMyMac, Self.fastmail])
        }
    }

    @Test("The no-iCloud error names the containers that do exist")
    func noICloudErrorListsAlternatives() {
        do {
            _ = try ContactDestinationTarget.defaultDestination(in: [Self.onMyMac])
            Issue.record("expected a refusal")
        } catch let error as ContactDestinationError {
            guard case let .noICloudDestination(available) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(available.contains { $0.contains("On My Mac") })
            #expect(error.errorDescription?.contains("container") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Two containers that both look like iCloud are ambiguous, not a coin flip")
    func twoICloudContainersAreAmbiguous() {
        let second = ContactContainerCandidate(
            identifier: "C-icloud-2",
            name: "Card",
            kind: .cardDAV
        )
        do {
            _ = try ContactDestinationTarget.defaultDestination(in: [Self.iCloud, second])
            Issue.record("expected a refusal")
        } catch let error as ContactDestinationError {
            guard case let .ambiguousICloudDestination(candidates) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(candidates.count == 2)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("An empty container list is refused")
    func noContainersAtAll() {
        #expect(throws: ContactDestinationError.noContainers) {
            try ContactDestinationTarget.defaultDestination(in: [])
        }
    }

    // MARK: Explicit selection

    @Test("An identifier selects exactly that container")
    func resolveByIdentifier() throws {
        let resolved = try ContactDestinationTarget.resolve(
            requested: "C-local",
            in: [Self.iCloud, Self.onMyMac]
        )
        #expect(resolved.identifier == "C-local")
    }

    @Test("A name selects a container case-insensitively")
    func resolveByName() throws {
        let resolved = try ContactDestinationTarget.resolve(
            requested: "on my mac",
            in: [Self.iCloud, Self.onMyMac]
        )
        #expect(resolved.identifier == "C-local")
    }

    @Test("Naming a local container explicitly is allowed, since the caller asked")
    func explicitLocalIsHonoured() throws {
        let resolved = try ContactDestinationTarget.resolve(
            requested: "On My Mac",
            in: [Self.onMyMac, Self.fastmail]
        )
        #expect(resolved.syncsOffDevice == false)
    }

    @Test("Whitespace and an empty string fall back to the default destination")
    func blankRequestUsesDefault() throws {
        for blank in ["", "   "] {
            let resolved = try ContactDestinationTarget.resolve(
                requested: blank,
                in: [Self.onMyMac, Self.iCloud]
            )
            #expect(resolved.identifier == Self.iCloud.identifier)
        }
        let none = try ContactDestinationTarget.resolve(
            requested: nil,
            in: [Self.onMyMac, Self.iCloud]
        )
        #expect(none.identifier == Self.iCloud.identifier)
    }

    @Test("An unknown name is refused and the available containers are listed")
    func unknownNameIsRefused() {
        do {
            _ = try ContactDestinationTarget.resolve(
                requested: "Gmail",
                in: [Self.iCloud, Self.onMyMac]
            )
            Issue.record("expected a refusal")
        } catch let error as ContactDestinationError {
            guard case let .unknownName(requested, available) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(requested == "Gmail")
            #expect(available.count == 2)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("A stale UUID identifier is reported as an unknown identifier")
    func unknownIdentifierIsRefused() {
        do {
            _ = try ContactDestinationTarget.resolve(
                requested: "6F89C86D-5F0A-42A5-94EB-CE71C8B877E8",
                in: [Self.iCloud]
            )
            Issue.record("expected a refusal")
        } catch let error as ContactDestinationError {
            guard case .unknownIdentifier = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("A name shared by two containers is ambiguous, not resolved to the first")
    func duplicateNameIsAmbiguous() {
        let first = ContactContainerCandidate(identifier: "C-1", name: "Contacts", kind: .cardDAV)
        let second = ContactContainerCandidate(identifier: "C-2", name: "Contacts", kind: .exchange)
        do {
            _ = try ContactDestinationTarget.resolve(requested: "Contacts", in: [first, second])
            Issue.record("expected a refusal")
        } catch let error as ContactDestinationError {
            guard case let .ambiguousName(_, candidates) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(candidates.count == 2)
            #expect(error.errorDescription?.contains("identifier") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Reporting

    @Test("A contact that landed in iCloud reports no warning")
    func iCloudLandingIsClean() {
        let report = ContactDestinationReporting.report(
            landed: Self.iCloud,
            requested: Self.iCloud
        )
        #expect(report.warning == nil)
        #expect(report.isICloud)
        #expect(report.syncsOffDevice)
        #expect(ContactDestinationReporting.syncExpectation(report) == "expected-via-icloud")
    }

    @Test("A contact that landed on this Mac warns that it will not reach other devices")
    func localLandingWarns() {
        let report = ContactDestinationReporting.report(
            landed: Self.onMyMac,
            requested: Self.onMyMac
        )
        #expect(report.warning?.contains("this Mac only") == true)
        #expect(report.warning?.contains("other devices") == true)
        #expect(ContactDestinationReporting.syncExpectation(report) == "local-only")
    }

    @Test("Landing somewhere other than the requested container is called out")
    func mismatchIsReported() {
        let report = ContactDestinationReporting.report(
            landed: Self.onMyMac,
            requested: Self.iCloud
        )
        #expect(report.warning?.contains("requested in \"iCloud\"") == true)
        #expect(report.warning?.contains("landed in \"On My Mac\"") == true)
    }

    @Test("A non-iCloud server account reports its own sync expectation")
    func serverAccountExpectation() {
        let report = ContactDestinationReporting.report(landed: Self.fastmail, requested: nil)
        #expect(report.isICloud == false)
        #expect(report.warning == nil)
        #expect(
            ContactDestinationReporting.syncExpectation(report) == "expected-via-server-account"
        )
    }

    @Test("An unreadable destination is reported as unverified, not as success")
    func unknownLandingIsUnverified() {
        let report = ContactDestinationReporting.report(landed: nil, requested: Self.iCloud)
        #expect(report.warning?.contains("unverified") == true)
        #expect(report.syncsOffDevice == false)
        #expect(ContactDestinationReporting.syncExpectation(report) == "local-only")
    }
}
