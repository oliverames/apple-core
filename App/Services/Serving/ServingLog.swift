// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bridgeport's ported files (OAuthSupport, CloudflareManager, etc.) call a
// free `logMessage(_:)` function rather than threading a Logger instance
// through every static helper. Bridgeport backed that with a stderr println;
// apple-core is a GUI app, so route it through the existing OSLog pipeline
// instead.

import OSLog

func logMessage(_ message: String) {
    Logger.server.notice("\(message, privacy: .public)")
}
