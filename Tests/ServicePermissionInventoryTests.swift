import Testing

@Suite("Service permission inventory")
struct ServicePermissionInventoryTests {
    @Test("Every standard service declares its complete permission flow")
    func standardServicePermissionCoverage() {
        let expected: [String: [ServicePermissionRequirement]] = [
            "CalendarService": [.calendar],
            "CaptureService": [.camera, .microphone, .screenRecording],
            "ContactsService": [.contacts],
            "LocationService": [.location],
            "MailService": [.mailAutomation],
            "MapsService": [.location],
            "MessageService": [.messagesAutomation, .messagesDatabase],
            "NotesService": [.notesAutomation],
            "RemindersService": [.reminders],
            "ShortcutsService": [],
            "UtilitiesService": [],
            "WeatherService": [],
        ]

        #expect(ServicePermissionInventory.standard == expected)
    }
}
