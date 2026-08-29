// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keychain storage for the Cloudflare API token used to manage Access.
//
// Deliberately not in `config.json` next to the MCP token. That one is a
// credential for this app's own server and is shown in the Settings window on
// purpose. This is a Cloudflare account credential with permission to change
// Zero Trust policy, so a plaintext file in the config directory is the wrong
// place for it: a backup, a screen share, or a support paste of that file
// should not hand over the account.

import Foundation
import OSLog
import Security

private let log = Logger.service("access-token")

public enum AccessTokenStore {
    private static let service = "com.oliverames.applecore.cloudflare-access"
    private static let account = "api-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes, or clears when handed an empty string. Update-then-add rather
    /// than delete-then-add, so a failed add cannot leave the user with no
    /// token where they previously had a working one.
    @discardableResult
    public static func write(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear() }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            log.error("Could not store the Cloudflare Access token: \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static var hasToken: Bool {
        read()?.isEmpty == false
    }
}
