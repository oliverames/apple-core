// SPDX-License-Identifier: GPL-3.0-or-later
//
// Obtains cloudflared without asking the user to install it themselves.
//
// Apple Core previously required `brew install cloudflared` and only printed
// that command in the Cloudflare pane, which stopped anyone who does not use
// Homebrew. This finds an already-installed copy first, and otherwise
// downloads the official signed binary from Cloudflare's own GitHub release
// into Apple Core's config directory.
//
// The download is verified against the SHA-256 digest GitHub publishes for
// the release asset, so a corrupted or substituted archive is rejected rather
// than executed.

import CryptoKit
import Darwin
import Foundation

public enum CloudflaredInstallProgress: Sendable, Equatable {
    case locatingRelease
    case downloading
    case verifying
    case extracting
    case finished(path: String)

    /// What to show while this step runs.
    public var message: String {
        switch self {
        case .locatingRelease: "Finding the latest cloudflared release…"
        case .downloading: "Downloading cloudflared from Cloudflare…"
        case .verifying: "Verifying the download…"
        case .extracting: "Installing…"
        case .finished: "cloudflared installed."
        }
    }
}

public enum CloudflaredInstallError: LocalizedError, Equatable {
    case unsupportedArchitecture
    case releaseLookupFailed(String)
    case noAssetForArchitecture(String)
    case downloadFailed(String)
    case digestUnavailable
    case digestMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case binaryMissingAfterExtraction
    case untrustedPublisher(String)
    case quarantineRemovalFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "This Mac's processor architecture is not one cloudflared publishes a build for."
        case let .releaseLookupFailed(detail):
            return "Could not reach Cloudflare's release listing on GitHub: \(detail)"
        case let .noAssetForArchitecture(arch):
            return "Cloudflare's latest release has no macOS \(arch) download."
        case let .downloadFailed(detail):
            return "The cloudflared download did not finish: \(detail)"
        case .digestUnavailable:
            return "GitHub did not publish a checksum for this download, so Apple Core cannot verify it."
        case let .digestMismatch(expected, actual):
            return
                "The downloaded cloudflared did not match its published checksum and was discarded "
                + "(expected \(expected.prefix(16))…, got \(actual.prefix(16))…)."
        case let .extractionFailed(detail):
            return "The cloudflared archive could not be unpacked: \(detail)"
        case .binaryMissingAfterExtraction:
            return "The cloudflared archive unpacked without producing a cloudflared binary."
        case let .untrustedPublisher(detail):
            return "The downloaded cloudflared was not signed by Cloudflare and was discarded: \(detail)"
        case let .quarantineRemovalFailed(detail):
            return "Apple Core verified cloudflared but could not prepare it to run: \(detail)"
        }
    }
}

public actor CloudflaredInstaller {
    /// Release metadata for the current platform, resolved from GitHub.
    private struct ReleaseAsset {
        let version: String
        let downloadURL: URL
        /// GitHub reports this as "sha256:<hex>". Stored as the bare hex.
        let sha256: String?
    }

    private static let releaseAPI = URL(
        string: "https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
    )!

    private let fileManager: FileManager
    private let session: URLSession

    public init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    // MARK: - Discovery

    /// Where Apple Core keeps a cloudflared it downloaded itself.
    public static func managedBinaryPath() -> String {
        AppleCoreServingPaths.configDirectory()
            .appendingPathComponent("bin/cloudflared")
            .path
    }

    /// The cloudflared this Mac should use: a system or Homebrew copy when one
    /// exists, otherwise Apple Core's own. Returns nil when there is none, so
    /// the caller can offer to install rather than showing a path that is not
    /// there.
    public static func locateInstalled(fileManager: FileManager = .default) -> String? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared",
            managedBinaryPath(),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// The version string of the cloudflared at `path`, for display.
    public static func installedVersion(at path: String) -> String? {
        let result = runShell(path, ["--version"])
        guard result.status == 0 else { return nil }
        // `cloudflared version 2026.8.2 (built ...)` — keep the number only.
        let words = result.stdout.split(separator: " ")
        guard let index = words.firstIndex(of: "version"), words.indices.contains(index + 1) else {
            return result.stdout.isEmpty ? nil : result.stdout
        }
        return String(words[index + 1])
    }

    // MARK: - Install

    /// Downloads the official cloudflared for this Mac and installs it under
    /// Apple Core's config directory. Reports progress so the pane can show
    /// something during a ~20MB download. Returns the installed path.
    public func install(
        progress: @Sendable @escaping (CloudflaredInstallProgress) -> Void = { _ in }
    ) async throws -> String {
        progress(.locatingRelease)
        let asset = try await latestReleaseAsset()

        progress(.downloading)
        let archiveData = try await download(asset.downloadURL)

        progress(.verifying)
        guard let expected = asset.sha256 else {
            throw CloudflaredInstallError.digestUnavailable
        }
        let actual = Self.sha256Hex(archiveData)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw CloudflaredInstallError.digestMismatch(expected: expected, actual: actual)
        }

        progress(.extracting)
        let installedPath = try extract(archiveData)

        logMessage("CloudflaredInstaller: installed cloudflared \(asset.version) at \(installedPath)")
        progress(.finished(path: installedPath))
        return installedPath
    }

    // MARK: - Steps

    private func latestReleaseAsset() async throws -> ReleaseAsset {
        guard let assetName = Self.assetNameForCurrentArchitecture() else {
            throw CloudflaredInstallError.unsupportedArchitecture
        }

        var request = URLRequest(url: Self.releaseAPI)
        // GitHub rejects unidentified clients more aggressively, and the
        // versioned Accept header keeps the `digest` field stable.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("apple-core", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudflaredInstallError.releaseLookupFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw CloudflaredInstallError.releaseLookupFailed("HTTP \(http.statusCode)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let assets = root["assets"] as? [[String: Any]]
        else {
            throw CloudflaredInstallError.releaseLookupFailed("the response was not the expected JSON")
        }
        let version = (root["tag_name"] as? String) ?? "unknown"

        guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
            let urlString = asset["browser_download_url"] as? String,
            let url = URL(string: urlString)
        else {
            throw CloudflaredInstallError.noAssetForArchitecture(Self.currentArchitecture ?? "unknown")
        }

        // GitHub reports "sha256:<hex>"; anything else is treated as absent
        // rather than trusted, because an unverified binary is not installed.
        var digest: String?
        if let raw = asset["digest"] as? String, raw.lowercased().hasPrefix("sha256:") {
            digest = String(raw.dropFirst("sha256:".count))
        }

        return ReleaseAsset(version: version, downloadURL: url, sha256: digest)
    }

    /// Fetches the archive in one shot. `URLSession.bytes` would allow a
    /// percentage, but iterating ~20 million elements of `AsyncBytes` costs
    /// noticeably more than the transfer it is reporting on, so the UI shows an
    /// indeterminate indicator instead and this stays a single buffered read.
    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("apple-core", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw CloudflaredInstallError.downloadFailed("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as CloudflaredInstallError {
            throw error
        } catch {
            throw CloudflaredInstallError.downloadFailed(error.localizedDescription)
        }
    }

    /// Unpacks the .tgz in a scratch directory and moves the binary into place.
    private func extract(_ archiveData: Data) throws -> String {
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("apple-core-cloudflared-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: scratch) }

        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw CloudflaredInstallError.extractionFailed(error.localizedDescription)
        }

        let archiveURL = scratch.appendingPathComponent("cloudflared.tgz")
        do {
            try archiveData.write(to: archiveURL, options: .atomic)
        } catch {
            throw CloudflaredInstallError.extractionFailed(error.localizedDescription)
        }

        let untar = runShell("/usr/bin/tar", ["-xzf", archiveURL.path, "-C", scratch.path])
        guard untar.status == 0 else {
            throw CloudflaredInstallError.extractionFailed(
                untar.stderr.isEmpty ? "tar exited with status \(untar.status)" : untar.stderr
            )
        }

        let unpacked = scratch.appendingPathComponent("cloudflared")
        guard fileManager.fileExists(atPath: unpacked.path) else {
            throw CloudflaredInstallError.binaryMissingAfterExtraction
        }

        do {
            try CloudflaredPublisherVerifier.verify(at: unpacked)
        } catch {
            throw CloudflaredInstallError.untrustedPublisher(error.localizedDescription)
        }

        let destination = URL(fileURLWithPath: Self.managedBinaryPath())
        let destinationDirectory = destination.deletingLastPathComponent()
        let candidate = destinationDirectory.appendingPathComponent(".cloudflared-install-\(UUID().uuidString)")
        defer {
            if fileManager.fileExists(atPath: candidate.path) {
                try? fileManager.removeItem(at: candidate)
            }
        }
        do {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: unpacked, to: candidate)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
            try Self.clearQuarantine(at: candidate)

            try CloudflaredBinaryReplacement.install(candidate, at: destination)
        } catch let error as CloudflaredInstallError {
            throw error
        } catch {
            throw CloudflaredInstallError.extractionFailed(error.localizedDescription)
        }

        return destination.path
    }

    // MARK: - Platform

    private static var currentArchitecture: String? {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "amd64"
        #else
            return nil
        #endif
    }

    static func assetNameForCurrentArchitecture() -> String? {
        guard let arch = currentArchitecture else { return nil }
        return "cloudflared-darwin-\(arch).tgz"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Clear only quarantine, and only after both digest and publisher checks.
    /// ENOATTR means the file was never quarantined and is already ready.
    private static func clearQuarantine(at url: URL) throws {
        let result = removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard result == 0 || errno == ENOATTR else {
            let detail = String(cString: strerror(errno))
            throw CloudflaredInstallError.quarantineRemovalFailed(detail)
        }
    }
}
