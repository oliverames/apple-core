import Testing

@Suite("Capture target discovery")
struct CaptureTargetInventoryTests {
    /// A two-display Mac running two applications, one of which has a window
    /// that has been minimized out of sight.
    private static func fixture() -> CaptureTargetSnapshot {
        CaptureTargetSnapshot(
            displays: [
                .init(id: 1, width: 3456, height: 2234),
                .init(id: 2, width: 2560, height: 1440),
            ],
            applications: [
                .init(bundleIdentifier: "com.apple.Safari", name: "Safari", processIdentifier: 501),
                .init(bundleIdentifier: "com.apple.Notes", name: "Notes", processIdentifier: 502),
            ],
            windows: [
                .init(
                    id: 10,
                    ownerBundleIdentifier: "com.apple.Safari",
                    ownerName: "Safari",
                    x: 0,
                    y: 0,
                    width: 1440,
                    height: 900,
                    isOnScreen: true,
                    isActive: true,
                    hasTitle: true
                ),
                .init(
                    id: 11,
                    ownerBundleIdentifier: "com.apple.Safari",
                    ownerName: "Safari",
                    x: 40,
                    y: 60,
                    width: 800,
                    height: 600,
                    isOnScreen: false,
                    isActive: false,
                    hasTitle: true
                ),
                .init(
                    id: 12,
                    ownerBundleIdentifier: "com.apple.Notes",
                    ownerName: "Notes",
                    x: 2560,
                    y: 0,
                    width: 1024,
                    height: 768,
                    isOnScreen: true,
                    isActive: false,
                    hasTitle: false
                ),
            ]
        )
    }

    @Test("Both displays survive discovery")
    func multipleDisplaysAreListed() {
        let snapshot = Self.fixture()
        let targets = CaptureTargetInventory.filtered(snapshot)
        #expect(targets.displays.map(\.id) == [1, 2])
        #expect(targets.displays[1].width == 2560)
    }

    @Test("Hidden windows are left out unless they are asked for")
    func offscreenWindowsAreOptional() {
        let snapshot = Self.fixture()
        #expect(CaptureTargetInventory.filtered(snapshot).windows.map(\.id) == [10, 12])
        #expect(
            CaptureTargetInventory.filtered(snapshot, includeOffscreenWindows: true)
                .windows.map(\.id) == [10, 11, 12]
        )
    }

    @Test("A bundle identifier narrows both the applications and the windows")
    func filteringByApplication() {
        let targets = CaptureTargetInventory.filtered(
            Self.fixture(),
            bundleIdentifier: "com.apple.Safari",
            includeOffscreenWindows: true
        )
        #expect(targets.applications.map(\.bundleIdentifier) == ["com.apple.Safari"])
        #expect(targets.windows.map(\.id) == [10, 11])
        // Displays belong to the Mac rather than to an application, so an
        // application filter must not hide the place to point a display capture.
        #expect(targets.displays.count == 2)
    }

    @Test("An empty bundle identifier filters nothing")
    func emptyFilterIsNoFilter() {
        let targets = CaptureTargetInventory.filtered(Self.fixture(), bundleIdentifier: "")
        #expect(targets.applications.count == 2)
    }

    @Test("A window identifier that has closed reads as stale, not as an error")
    func staleWindowIdentifiers() {
        let snapshot = Self.fixture()
        #expect(CaptureTargetInventory.lookup(windowID: nil, in: snapshot) == .notRequested)
        #expect(CaptureTargetInventory.lookup(windowID: 10, in: snapshot) == .live(10))
        #expect(CaptureTargetInventory.lookup(windowID: 999, in: snapshot) == .stale(999))
        // A minimized window is still a live target, so it must not be confused
        // with one that has gone away.
        #expect(CaptureTargetInventory.lookup(windowID: 11, in: snapshot) == .live(11))
        #expect(CaptureTargetInventory.staleWindowAdvice(for: 999).contains("999"))
    }

    @Test("Every window on a locked Mac is gone along with the displays")
    func lockedSessionSnapshot() {
        // What ScreenCaptureKit actually returns behind a lock screen, kept as
        // a fixture so the discovery result for it stays deliberate.
        let locked = CaptureTargetSnapshot()
        let targets = CaptureTargetInventory.filtered(locked)
        #expect(targets.displays.isEmpty)
        #expect(targets.windows.isEmpty)
        #expect(CaptureTargetInventory.lookup(windowID: 10, in: locked) == .stale(10))
        #expect(
            CaptureReadiness.screenStatus(
                isAuthorized: true,
                isGUISessionActive: false,
                displayCount: locked.displays.count
            ) == .lockedSession
        )
    }

    @Test("A window carries no title, only whether it has one")
    func discoveryReturnsNoWindowContents() {
        // The privacy line for this surface: a title routinely names the open
        // document, which is content rather than a target. The check is a
        // structural one, because a field that does not exist cannot leak.
        let window = Self.fixture().windows[0]
        let mirrored = Mirror(reflecting: window).children.compactMap(\.label)
        #expect(!mirrored.contains("title"))
        #expect(mirrored.contains("hasTitle"))
    }
}
