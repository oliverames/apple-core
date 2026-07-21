import Foundation
import Testing

@Suite("Attachment save directory validation")
struct AttachmentSaveDirectoryTests {
    @Test("Defaults to Downloads inside the supplied home")
    func defaultDirectory() throws {
        let home = URL(fileURLWithPath: "/tmp/apple-core-home", isDirectory: true)
        let result = try AttachmentSaveDirectory.resolve(nil, homeDirectory: home)
        #expect(result == home.appendingPathComponent("Downloads", isDirectory: true))
    }

    @Test("Accepts an existing directory inside the home")
    func acceptsDirectoryInsideHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try AttachmentSaveDirectory.resolve(
            fixture.destination.path,
            homeDirectory: fixture.home
        )
        #expect(result == fixture.destination.resolvingSymlinksInPath())
    }

    @Test("Rejects a nonexistent directory")
    func rejectsMissingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: NSError.self) {
            try AttachmentSaveDirectory.resolve(
                fixture.home.appendingPathComponent("missing").path,
                homeDirectory: fixture.home
            )
        }
    }

    @Test("Rejects a directory outside the home")
    func rejectsDirectoryOutsideHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: NSError.self) {
            try AttachmentSaveDirectory.resolve(
                fixture.outside.path,
                homeDirectory: fixture.home
            )
        }
    }

    @Test("Rejects a symlink that escapes the home")
    func rejectsEscapingSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.home.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)

        #expect(throws: NSError.self) {
            try AttachmentSaveDirectory.resolve(link.path, homeDirectory: fixture.home)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let destination: URL
        let outside: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-core-path-tests-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            destination = home.appendingPathComponent("Downloads", isDirectory: true)
            outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
