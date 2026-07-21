import Foundation

public enum AttachmentSaveDirectory {
    public static func resolve(
        _ requested: String?,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) throws -> URL {
        let home = (homeDirectory ?? fileManager.homeDirectoryForCurrentUser)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard let requested, !requested.isEmpty else {
            return home.appendingPathComponent("Downloads", isDirectory: true)
        }

        let expanded = (requested as NSString).expandingTildeInPath
        let directory = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw validationError("destination must be an existing directory: \(requested)")
        }

        let homePrefix = home.path + "/"
        guard directory == home || (directory.path + "/").hasPrefix(homePrefix) else {
            throw validationError("destination must be inside the user's home directory")
        }

        return directory
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(
            domain: "AttachmentSaveDirectoryError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
