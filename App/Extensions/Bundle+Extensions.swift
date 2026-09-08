import Foundation

extension Bundle {
    var name: String? {
        infoDictionary?["CFBundleName"] as? String
    }

    var shortVersionString: String? {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        if let prerelease = infoDictionary?["AppleCorePrerelease"] as? String, !prerelease.isEmpty {
            return "\(version)-\(prerelease)"
        }
        return version
    }

    var isPrerelease: Bool { infoDictionary?["AppleCorePrerelease"] as? String != nil }

    var copyright: String? {
        infoDictionary?["NSHumanReadableCopyright"] as? String
    }
}
