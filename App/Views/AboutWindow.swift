// SPDX-License-Identifier: GPL-3.0-or-later
//
// About window, rebuilt with Apple Core branding and the card-based design
// language ported from Bridgeport's SettingsView (ProductHeader treatment).

import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        window.styleMask = [.titled, .closable]
        window.title = "About Apple Core"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        self.init(window: window)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Core")
                        .font(.title.weight(.semibold))

                    if let shortVersionString = Bundle.main.shortVersionString {
                        Text("Version \(shortVersionString)")
                            .foregroundStyle(.secondary)
                    }

                    Text("Personal MCP server for Apple system services.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/oliverames/apple-core/issues/new")!
                    )
                } label: {
                    Label("Report an Issue…", systemImage: "ladybug")
                }

                Text("Licensed under GPL-3.0-or-later. Based on mattt/iMCP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let copyright = Bundle.main.copyright {
                    Text(copyright)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
