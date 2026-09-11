import Testing

@Suite("Service permission inventory")
struct ServicePermissionInventoryTests {
    @Test("Every standard service declares its complete permission flow")
    func standardServicePermissionCoverage() {
        let expected: [String: [ServicePermissionNeed]] = [
            "CalendarService": [.required(.calendar)],
            "CaptureService": [
                .required(.camera), .required(.microphone), .required(.screenRecording),
            ],
            "ContactsService": [.required(.contacts)],
            // Bounded by the user's shared-folder allowlist, not by TCC.
            "FilesystemService": [],
            "LocationService": [.required(.location)],
            "MailService": [
                .required(.mailAutomation),
                .optional(.fullDiskAccess, enables: "the local mail index"),
            ],
            "MapsService": [.required(.location)],
            "MessageService": [.required(.messagesAutomation), .required(.messagesDatabase)],
            "NotesService": [
                .required(.notesAutomation),
                .optional(
                    .fullDiskAccess,
                    enables: "note links, metadata, checklist state and sync status"
                ),
            ],
            "RemindersService": [.required(.reminders)],
            "ShortcutsService": [],
            "UtilitiesService": [],
            "WeatherService": [],
        ]

        #expect(ServicePermissionInventory.standard == expected)
    }

    @Test("Full Disk Access gates no surface it is declared on")
    func fullDiskAccessIsOptionalEverywhereItIsDeclared() {
        let declaring = ServicePermissionInventory.standard.filter { _, needs in
            needs.contains { $0.requirement == .fullDiskAccess }
        }

        #expect(Set(declaring.keys) == ["MailService", "NotesService"])
        for (service, needs) in declaring {
            let need = needs.first { $0.requirement == .fullDiskAccess }
            #expect(need?.isRequired == false, "\(service) must not require Full Disk Access")
            // An optional grant that names nothing cannot be offered as a
            // capability, only as an unexplained demand.
            #expect(need?.capability?.isEmpty == false)
            // The surface still has to work on its own, so it must declare at
            // least one requirement that is genuinely required.
            #expect(!needs.requiredRequirements.isEmpty)
        }
    }

    @Test("Required and optional grants separate cleanly")
    func requiredAndOptionalSplit() {
        let mail = ServicePermissionInventory.needs(forServiceTypeName: "MailService")

        #expect(mail?.requiredRequirements == [.mailAutomation])
        #expect(mail?.optionalNeeds.map(\.requirement) == [.fullDiskAccess])
        // Onboarding and activation ask only for the required list, which is
        // what keeps enabling Mail from demanding a blanket disk grant.
        #expect(mail?.requiredRequirements.contains(.fullDiskAccess) == false)
    }

    @Test("Every service's required grants are what a caller would ask for")
    func everyServiceHasRequiredOnlyActivation() {
        for (service, needs) in ServicePermissionInventory.standard {
            let required = needs.requiredRequirements
            #expect(
                required.allSatisfy { requirement in
                    needs.contains { $0.requirement == requirement && $0.isRequired }
                },
                "\(service) required list disagrees with its needs"
            )
            #expect(needs.optionalNeeds.allSatisfy { $0.capability != nil })
        }
    }

    @Test("The Full Disk Access probe is not keyed to any one app's data")
    func fullDiskAccessProbePathIsGeneric() {
        let path = ServicePermissionRequirement.fullDiskAccessProbePath

        #expect(path == "/Library/Application Support/com.apple.TCC/TCC.db")
        // Present on every Mac rather than only on one that has opened the
        // app in question, and not inside a home directory that some macOS
        // versions do not give a consent store at all.
        #expect(path.hasPrefix("/Library/"))
        for appPath in ["Messages", "Mail", "notes", "Notes", "chat.db", "NoteStore"] {
            #expect(!path.contains(appPath))
        }
    }

    @Test("The Messages database grant stays separate from the generic one")
    func messagesDatabaseIsNotMergedAway() {
        // Messages accepts a security-scoped bookmark for the single file,
        // picked by hand. Folding it into `fullDiskAccess` would lose that
        // narrower grant, which is a real alternative to a blanket one.
        let messages = ServicePermissionInventory.needs(forServiceTypeName: "MessageService")

        #expect(messages?.map(\.requirement) == [.messagesAutomation, .messagesDatabase])
    }

    @Test("The shared grant instruction names Full Disk Access once")
    func grantInstructionIsShared() {
        let instruction = ServicePermissionRequirement.fullDiskAccess.grantInstruction

        #expect(instruction.contains("Full Disk Access"))
        #expect(instruction.contains("System Settings"))
        // Messages points at the same pane, so it says the same thing.
        #expect(ServicePermissionRequirement.messagesDatabase.grantInstruction == instruction)
    }
}
