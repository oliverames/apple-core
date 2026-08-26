// SPDX-License-Identifier: GPL-3.0-or-later
//
// The clients Apple Core knows how to connect to.
//
// The Clients pane offered exactly one button, "Configure Claude Desktop",
// which is one of many things people actually connect. This describes the
// rest, and is honest about the difference between the ones Apple Core can
// configure for you and the ones where it can only hand you the details.
//
// Deliberately not invented: a client is only listed with an automatic or
// command setup when its configuration format is known. For anything else the
// entry says so and offers the address and token, rather than writing a guess
// into somebody's config file.

import Foundation

struct MCPClient: Identifiable, Sendable {
    /// How Apple Core can connect this client.
    enum Setup: Sendable {
        /// Apple Core edits the client's config file itself.
        case automatic
        /// The client is configured from a terminal; Apple Core supplies the
        /// command, with the live address and token already substituted.
        case command(String)
        /// The client is configured in its own interface by pasting the
        /// address. Cloud clients are all of these.
        case paste(String)
    }

    let id: String
    let name: String
    let iconName: String
    let setup: Setup
    /// Paths that indicate the client is installed on this Mac. Empty for
    /// cloud clients, which are not installed at all.
    let detectionPaths: [String]

    var isInstalled: Bool {
        guard !detectionPaths.isEmpty else { return true }
        let fileManager = FileManager.default
        return detectionPaths.contains { fileManager.fileExists(atPath: $0) }
    }
}

enum MCPClientCatalog {
    private static var home: String { NSHomeDirectory() }

    /// Clients that run on this Mac and talk to the local address.
    static func local(address: String, token: String) -> [MCPClient] {
        [
            MCPClient(
                id: "claude-desktop",
                name: "Claude Desktop",
                iconName: "desktopcomputer",
                setup: .automatic,
                detectionPaths: [
                    "/Applications/Claude.app",
                    "\(home)/Library/Application Support/Claude",
                ]
            ),
            MCPClient(
                id: "claude-code",
                name: "Claude Code",
                iconName: "terminal",
                setup: .command(
                    "claude mcp add --transport http apple-core \(address) --header \"Authorization: Bearer \(token)\""
                ),
                detectionPaths: ["\(home)/.claude.json", "\(home)/.claude"]
            ),
            MCPClient(
                id: "codex",
                name: "Codex",
                iconName: "chevron.left.forwardslash.chevron.right",
                setup: .command("codex mcp add apple-core --url \(address) --bearer-token \(token)"),
                detectionPaths: ["\(home)/.codex/config.toml", "\(home)/.codex"]
            ),
            MCPClient(
                id: "cursor",
                name: "Cursor",
                iconName: "cursorarrow.rays",
                setup: .paste("Settings › MCP › Add Server, then paste the address and token."),
                detectionPaths: ["/Applications/Cursor.app", "\(home)/.cursor"]
            ),
            MCPClient(
                id: "antigravity",
                name: "Antigravity",
                iconName: "sparkles",
                setup: .paste("Add an MCP server in Antigravity's settings, then paste the address and token."),
                detectionPaths: [
                    "/Applications/Antigravity.app",
                    "\(home)/.gemini/settings.json",
                ]
            ),
            MCPClient(
                id: "hermes",
                name: "Hermes",
                iconName: "bolt.horizontal",
                setup: .paste("Add an MCP server in Hermes's settings, then paste the address and token."),
                detectionPaths: [
                    "/Applications/Hermes.app",
                    "\(home)/Library/Application Support/Hermes",
                ]
            ),
            MCPClient(
                id: "openclaw",
                name: "OpenClaw",
                iconName: "pawprint",
                setup: .paste("Add an MCP server in OpenClaw's configuration, then paste the address and token."),
                detectionPaths: ["/Applications/OpenClaw.app", "\(home)/.config/openclaw"]
            ),
        ]
    }

    /// Clients that reach this Mac over the internet. All of them are
    /// configured by pasting the remote address into a web interface, and none
    /// of them can work until remote access is on.
    static var cloud: [MCPClient] {
        [
            MCPClient(
                id: "claude-web",
                name: "Claude (web and mobile)",
                iconName: "cloud",
                setup: .paste("Settings › Connectors › Add custom connector, then paste the address."),
                detectionPaths: []
            ),
            MCPClient(
                id: "claude-cowork",
                name: "Claude Cowork",
                iconName: "person.2",
                setup: .paste("Add Apple Core as a connector, then paste the address."),
                detectionPaths: []
            ),
            MCPClient(
                id: "chatgpt",
                name: "ChatGPT",
                iconName: "bubble.left.and.bubble.right",
                setup: .paste("Settings › Apps & Connectors › Advanced › Developer mode, then paste the address."),
                detectionPaths: []
            ),
            MCPClient(
                id: "chatgpt-work",
                name: "ChatGPT Work",
                iconName: "briefcase",
                setup: .paste("Ask your workspace admin to add Apple Core as a connector using the address."),
                detectionPaths: []
            ),
        ]
    }
}
