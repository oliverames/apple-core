// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Distinguishes a real user refusal from a consent dialog that macOS never
/// displayed. When a permission request returns "denied" but the
/// authorization status is still not determined afterwards, no choice was
/// recorded: tccd refused to show the prompt (for example, `boot-args`
/// containing `amfi_get_out_of_my_way=1` mark every third-party process as a
/// platform binary, and Tahoe's prompt policy denies those outright).
enum ServicePermissionError {
    /// Builds the error for a failed permission request. Pass
    /// `promptCouldHaveAppeared: false` when the authorization status is
    /// still "not determined" after the request came back denied.
    static func requestFailed(
        domain: String,
        what: String,
        promptCouldHaveAppeared: Bool
    ) -> NSError {
        let message: String
        if promptCouldHaveAppeared {
            message = "\(what) access was denied"
        } else {
            message =
                "macOS refused to display the \(what) permission request, so no choice was recorded. This Mac's security configuration is blocking consent prompts for apps that are not Apple-signed (custom boot-args such as amfi_get_out_of_my_way have this effect). Restore the default security configuration, then try again."
        }
        return NSError(
            domain: domain,
            code: promptCouldHaveAppeared ? 1 : 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
