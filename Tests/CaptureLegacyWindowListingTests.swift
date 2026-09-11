// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// `capture_list_windows` is on its way out. These tests hold the two promises
/// the deprecation makes: the description names the replacement, and a window
/// entry says only whether a title exists, never what it says.
@Suite("Capture legacy window listing")
struct CaptureLegacyWindowListingTests {
    @Test("The description marks the tool deprecated and names the replacement")
    func descriptionPointsAtReplacement() {
        let description = CaptureLegacyWindowListing.toolDescription
        #expect(description.hasPrefix("Deprecated:"))
        #expect(description.contains("capture_list_targets"))
        #expect(description.contains("No longer returns window titles."))
    }

    @Test("A titled window reports that it has a title, not the title itself")
    func reportsPresenceOnly() {
        #expect(CaptureLegacyWindowListing.hasTitle("Quarterly review.pages"))
        #expect(CaptureLegacyWindowListing.hasTitle("Re: severance terms"))
    }

    @Test("An untitled or empty-titled window reports no title")
    func emptyTitleIsNoTitle() {
        #expect(CaptureLegacyWindowListing.hasTitle(nil) == false)
        #expect(CaptureLegacyWindowListing.hasTitle("") == false)
    }
}
