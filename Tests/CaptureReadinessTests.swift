import Testing

@Suite("Capture readiness")
struct CaptureReadinessTests {
    @Test("Each capture permission is reported on its own")
    func permissionsAreIndependent() {
        // The gap this closes: the surface activates when any one capture
        // permission is available, so activation alone never said which of the
        // three a caller could actually use.
        #expect(CaptureReadiness.deviceStatus(permission: .authorized, hasDevice: true) == .ready)
        #expect(CaptureReadiness.deviceStatus(permission: .denied, hasDevice: true) == .denied)
        #expect(
            CaptureReadiness.deviceStatus(permission: .restricted, hasDevice: true) == .restricted
        )
        #expect(
            CaptureReadiness.deviceStatus(permission: .notDetermined, hasDevice: true)
                == .notDetermined
        )
    }

    @Test("A denied microphone and an absent one are not the same answer")
    func deniedIsDistinctFromMissingHardware() {
        #expect(CaptureReadiness.deviceStatus(permission: .authorized, hasDevice: false) == .noHardware)
        #expect(CaptureReadiness.deviceStatus(permission: .denied, hasDevice: false) == .denied)
    }

    @Test("Missing hardware is only claimed once the modality is authorized")
    func hardwareIsNotJudgedWithoutPermission() {
        // An unauthorized process can see an empty device list for reasons that
        // have nothing to do with what is plugged in, so an empty list under
        // any other permission state must not be reported as absent hardware.
        for permission in CapturePermissionState.allCases where permission != .authorized {
            #expect(
                CaptureReadiness.deviceStatus(permission: permission, hasDevice: false) != .noHardware
            )
        }
    }

    @Test("A locked screen reports a locked session, not an empty display list")
    func lockedSessionBeatsTheDisplayCount() {
        // ScreenCaptureKit reports zero displays while the Mac is locked. That
        // is the failure this distinguishes: identical numbers, different
        // causes, and only one of them is worth acting on.
        #expect(
            CaptureReadiness.screenStatus(
                isAuthorized: true,
                isGUISessionActive: false,
                displayCount: 0
            ) == .lockedSession
        )
        #expect(
            CaptureReadiness.screenStatus(
                isAuthorized: true,
                isGUISessionActive: true,
                displayCount: 0
            ) == .noHardware
        )
    }

    @Test("Screen readiness needs permission, a session and a display together")
    func screenStatusCombinations() {
        #expect(
            CaptureReadiness.screenStatus(
                isAuthorized: true,
                isGUISessionActive: true,
                displayCount: 2
            ) == .ready
        )
        #expect(
            CaptureReadiness.screenStatus(
                isAuthorized: false,
                isGUISessionActive: true,
                displayCount: 2
            ) == .denied
        )
        // A denied permission outranks the lock: granting access is the next
        // step either way, and it can be done from another Mac.
        #expect(
            CaptureReadiness.screenStatus(
                isAuthorized: false,
                isGUISessionActive: false,
                displayCount: 0
            ) == .denied
        )
    }

    @Test("Every status and modality pair explains itself")
    func detailsAreWrittenForEveryCombination() {
        for status in CaptureModalityStatus.allCases {
            for modality in CaptureModality.allCases {
                let detail = CaptureReadiness.detail(for: status, modality: modality)
                #expect(!detail.isEmpty)
            }
        }
        let locked = CaptureReadiness.detail(for: .lockedSession, modality: .screen)
        #expect(locked.contains("locked"))
    }
}
