// SPDX-License-Identifier: GPL-3.0-or-later
//
// Adapted from Bridgeport's LaunchAgentPlist.swift. Bridgeport runs a
// separate CLI daemon binary invoked with a `--server` flag; Apple Core has
// no such split -- the app's own executable *is* the server, so the
// LaunchAgent simply relaunches the app bundle's main executable.

import Foundation

public enum LaunchAgentPlist {
    public static func makeData(
        label: String,
        appBundlePath: String,
        stdoutPath: String,
        stderrPath: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                "-W",
                "-a",
                appBundlePath,
            ],
            "KeepAlive": true,
            "RunAtLoad": true,
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
