import Foundation
import Testing

@Suite("Connector health report")
struct ConnectorHealthTests {
    private static func surface(
        _ name: String = "CalendarService",
        isBuilt: Bool = true,
        isEnabled: Bool = true,
        toolCount: Int = 3,
        permissions: [ConnectorPermissionInput] = []
    ) -> ConnectorSurfaceInput {
        ConnectorSurfaceInput(
            serviceTypeName: name,
            isBuilt: isBuilt,
            isEnabled: isEnabled,
            toolCount: toolCount,
            permissions: permissions
        )
    }

    private static func permission(
        _ state: ConnectorPermissionState,
        detail: String = "detail"
    ) -> ConnectorPermissionInput {
        ConnectorPermissionInput(requirement: "Calendar", state: state, detail: detail)
    }

    private static let application = ConnectorHealthReport.Application(
        name: "Apple Core",
        version: "1.7.3",
        build: "34",
        macOSVersion: "Version 27.0 (Build 27A1)"
    )

    // MARK: - The four states a caller has to tell apart

    @Test("A surface missing from this build reads as unsupported, not off")
    func unsupportedOutranksEverything() {
        let state = ConnectorHealth.state(
            for: Self.surface(
                "WeatherService",
                isBuilt: false,
                permissions: [Self.permission(.denied)]
            )
        )
        #expect(state == .unsupported)
    }

    @Test("A switched-off surface reads as disabled whatever its permissions say")
    func disabledOutranksPermissions() {
        let state = ConnectorHealth.state(
            for: Self.surface(isEnabled: false, permissions: [Self.permission(.denied)])
        )
        #expect(state == .disabled)
    }

    @Test(
        "A refusal reads as denied",
        arguments: [ConnectorPermissionState.denied, .promptBlocked]
    )
    func refusalsAreDenied(state: ConnectorPermissionState) {
        #expect(
            ConnectorHealth.state(
                for: Self.surface(permissions: [Self.permission(.granted), Self.permission(state)])
            ) == .denied
        )
    }

    @Test(
        "A reading that cannot be taken now reads as temporarily unavailable",
        arguments: [ConnectorPermissionState.unreadable, .notRequested]
    )
    func unreadableIsTemporary(state: ConnectorPermissionState) {
        #expect(
            ConnectorHealth.state(
                for: Self.surface(permissions: [Self.permission(.granted), Self.permission(state)])
            ) == .unavailable
        )
    }

    @Test("A refusal outranks a reading that could not be taken")
    func denialOutranksUnreadable() {
        #expect(
            ConnectorHealth.state(
                for: Self.surface(
                    permissions: [Self.permission(.unreadable), Self.permission(.denied)]
                )
            ) == .denied
        )
    }

    @Test("Granted and narrowed permissions both leave the surface ready")
    func grantedAndLimitedAreReady() {
        #expect(
            ConnectorHealth.state(
                for: Self.surface(
                    permissions: [Self.permission(.granted), Self.permission(.limited)]
                )
            ) == .ready
        )
        #expect(ConnectorHealth.state(for: Self.surface(permissions: [])) == .ready)
    }

    @Test("The master switch disables every surface it could have served")
    func masterSwitchDisablesSurfaces() {
        let report = ConnectorHealth.report(
            application: Self.application,
            isConnectorEnabled: false,
            surfaces: [
                Self.surface("CalendarService"),
                Self.surface("WeatherService", isBuilt: false),
            ],
            sharedFolders: []
        )

        #expect(report.isConnectorEnabled == false)
        #expect(report.stateCounts == ["disabled": 1, "unsupported": 1])
    }

    @Test("State counts tally the surfaces reported")
    func stateCountsMatchSurfaces() {
        let report = ConnectorHealth.report(
            application: Self.application,
            isConnectorEnabled: true,
            surfaces: [
                Self.surface("CalendarService"),
                Self.surface("MailService", permissions: [Self.permission(.denied)]),
                Self.surface("NotesService", permissions: [Self.permission(.unreadable)]),
                Self.surface("RemindersService", isEnabled: false),
                Self.surface("WeatherService", isBuilt: false),
            ],
            sharedFolders: []
        )

        #expect(
            report.stateCounts == [
                "ready": 1, "denied": 1, "unavailable": 1, "disabled": 1, "unsupported": 1,
            ]
        )
        #expect(report.surfaces.map(\.service) == ["Calendar", "Mail", "Notes", "Reminders", "Weather"])
    }

    // MARK: - Paths

    @Test("Shared folders appear only while the Filesystem surface can read them")
    func sharedFoldersFollowTheFilesystemSurface() {
        let folders = [ConnectorHealthReport.SharedFolder(path: "/Users/test/Notes", writable: true)]

        let ready = ConnectorHealth.report(
            application: Self.application,
            isConnectorEnabled: true,
            surfaces: [Self.surface("FilesystemService")],
            sharedFolders: folders
        )
        #expect(ready.sharedFolders == folders)

        let off = ConnectorHealth.report(
            application: Self.application,
            isConnectorEnabled: true,
            surfaces: [Self.surface("FilesystemService", isEnabled: false)],
            sharedFolders: folders
        )
        #expect(off.sharedFolders.isEmpty)
    }

    // MARK: - Secrets

    @Test("No secret-shaped value survives into the encoded report")
    func secretsAreRedacted() throws {
        let environment = [
            "TUNNEL_TOKEN": "token-sentinel",
            "CLOUDFLARE_API_TOKEN": "api-sentinel",
        ]
        let report = ConnectorHealth.report(
            application: ConnectorHealthReport.Application(
                name: "Apple Core",
                version: "1.7.3 api-sentinel",
                build: "34",
                macOSVersion: "Version 27.0"
            ),
            isConnectorEnabled: true,
            surfaces: [
                Self.surface(
                    permissions: [
                        Self.permission(.denied, detail: "TUNNEL_TOKEN=token-sentinel"),
                        Self.permission(.unreadable, detail: "context api-sentinel context"),
                    ]
                )
            ],
            sharedFolders: [],
            environment: environment
        )

        let encoded = String(
            decoding: try JSONEncoder().encode(report),
            as: UTF8.self
        )
        #expect(!encoded.contains("token-sentinel"))
        #expect(!encoded.contains("api-sentinel"))
        #expect(encoded.contains("[redacted]"))
    }

    @Test("The report carries no field that could hold a credential")
    func reportFieldsAreBounded() throws {
        let report = ConnectorHealth.report(
            application: Self.application,
            isConnectorEnabled: true,
            surfaces: [Self.surface()],
            sharedFolders: [],
            environment: [:]
        )
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(report)
        )
        let top = try #require(encoded as? [String: Any])

        // Growing the report is fine; growing it with a token, a connection
        // identifier or an account name is what this guards against.
        #expect(
            Set(top.keys) == ["application", "isConnectorEnabled", "surfaces", "stateCounts", "sharedFolders"]
        )
        let application = try #require(top["application"] as? [String: Any])
        #expect(Set(application.keys) == ["name", "version", "build", "macOSVersion"])
    }

    // MARK: - Reading the switches the app actually wrote

    @Test("Every inventoried service maps to the defaults key the app binds")
    func enablementKeysMatchTheApp() {
        let expected = [
            "CalendarService": "calendarEnabled",
            "CaptureService": "captureEnabled",
            "ContactsService": "contactsEnabled",
            "FilesystemService": "filesystemEnabled",
            "LocationService": "locationEnabled",
            "MailService": "mailEnabled",
            "MapsService": "mapsEnabled",
            "MessageService": "messagesEnabled",
            "NotesService": "notesEnabled",
            "RemindersService": "remindersEnabled",
            "ShortcutsService": "shortcutsEnabled",
            "UtilitiesService": "utilitiesEnabled",
            "WeatherService": "weatherEnabled",
        ]

        #expect(Set(expected.keys) == Set(ServicePermissionInventory.standard.keys))
        for (serviceTypeName, key) in expected {
            #expect(ConnectorHealth.enablementDefaultsKey(forServiceTypeName: serviceTypeName) == key)
        }
    }

    @Test("Only the two surfaces a fresh install serves default to on")
    func defaultEnablement() {
        let onByDefault = ServicePermissionInventory.standard.keys.filter {
            ConnectorHealth.defaultEnabled(forServiceTypeName: $0)
        }
        #expect(Set(onByDefault) == ["MapsService", "UtilitiesService"])
    }
}
