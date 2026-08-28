// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import Security

public struct CloudflaredPublisherVerificationError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "cloudflared was not signed by Cloudflare Inc. (68WVV388M8): \(detail)"
    }
}

/// Requires Cloudflare's current Developer ID identity and hardened-runtime
/// certificate chain before Apple Core removes quarantine or installs a
/// downloaded binary.
public enum CloudflaredPublisherVerifier {
    public static let teamID = "68WVV388M8"

    private static let requirementText = """
        identifier "cloudflared" and anchor apple generic and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "68WVV388M8"
        """

    public static func verify(at url: URL) throws {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?

        var status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw CloudflaredPublisherVerificationError(status: status)
        }

        status = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw CloudflaredPublisherVerificationError(status: status)
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            throw CloudflaredPublisherVerificationError(status: status)
        }
    }
}

/// Atomically installs a verified candidate from the destination directory.
/// POSIX rename carries the candidate's 0755 mode and leaves the old binary
/// untouched if the replacement fails.
enum CloudflaredBinaryReplacement {
    static func install(_ candidate: URL, at destination: URL) throws {
        let result = candidate.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard result == 0 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
