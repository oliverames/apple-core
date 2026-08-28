// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin stdio <-> local Streamable HTTP bridge for MCP clients that can only
// launch a subprocess. The app itself owns the MCP server and HTTP endpoint.

import Foundation

struct CLIServingConfig: Decodable {
    var token: String?
    var port: UInt16?
    var bindHost: String?
}

func loadServingConfig() -> CLIServingConfig {
    let environment = ProcessInfo.processInfo.environment
    let configDirectory: URL
    if let override = environment["APPLECORE_CONFIG_HOME"],
        !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        configDirectory = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
    } else {
        configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/apple-core")
    }

    let configURL = configDirectory.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
        let config = try? JSONDecoder().decode(CLIServingConfig.self, from: data)
    else {
        return CLIServingConfig()
    }
    return config
}

let servingConfig = loadServingConfig()
guard let token = servingConfig.token, !token.isEmpty else {
    FileHandle.standardError.write(
        Data(
            "apple-core-cli: no serving token found in ~/.config/apple-core/config.json. Launch the Apple Core app once so it can generate one.\n"
                .utf8
        )
    )
    exit(1)
}

let port = servingConfig.port ?? 8756
let bindHost = servingConfig.bindHost ?? "127.0.0.1"
// IPv6 literals need brackets in a URL authority.
let urlHost = bindHost.contains(":") && !bindHost.hasPrefix("[") ? "[\(bindHost)]" : bindHost
guard let baseURL = URL(string: "http://\(urlHost):\(port)/") else {
    FileHandle.standardError.write(Data("apple-core-cli: invalid bind host/port\n".utf8))
    exit(1)
}

let bridge = StdioHTTPBridge(baseURL: baseURL, token: token)
do {
    try await bridge.connect()
} catch {
    FileHandle.standardError.write(Data("apple-core-cli: could not connect transport: \(error)\n".utf8))
    exit(1)
}

// submit starts an independent send task and returns immediately. The loop
// therefore keeps reading while earlier requests are in flight, which lets an
// MCP cancellation notification reach the server without waiting for the
// request it cancels.
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    await bridge.submit(trimmed)
}

await bridge.close()
