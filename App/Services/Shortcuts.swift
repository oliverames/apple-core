import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("shortcuts")

final class ShortcutsService: Service {
    static let shared = ShortcutsService()

    private let shortcutsPath = "/usr/bin/shortcuts"
    private let executionTimeout: Duration = .seconds(300)

    /// Shared folders bound the file arguments below. A shortcut can be handed
    /// a file to work on, and can write its result to disk, but only inside a
    /// folder the user has already shared with Apple Core.
    private var filesystemRoots: [FilesystemRoot] {
        ServingConfigManager.load().filesystemRoots ?? []
    }

    var tools: [Tool] {
        Tool(
            name: "shortcuts_list",
            description:
                "List the shortcuts on this Mac, with the identifier of each one. "
                + "Prefer the identifier over the name when running a shortcut: names are not unique.",
            inputSchema: .object(
                properties: [
                    "folder": .string(
                        description:
                            "Only list shortcuts in this folder. Pass \"none\" for shortcuts that are in no folder."
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Shortcuts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var listArguments = ["list", "--show-identifiers"]
            if let folder = arguments["folder"]?.stringValue, !folder.isEmpty {
                listArguments.append(contentsOf: ["--folder-name", folder])
            }
            let named = try await self.namedEntries(arguments: listArguments, what: "shortcuts")
            log.info("Found \(named.count) shortcuts")
            return Value.array(named)
        }

        Tool(
            name: "shortcuts_folders",
            description:
                "List the folders shortcuts are organized into. Pass a folder name to shortcuts_list to see what is in it.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "List Shortcut Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let named = try await self.namedEntries(
                arguments: ["list", "--folders", "--show-identifiers"],
                what: "folders"
            )
            return Value.array(named)
        }

        Tool(
            name: "shortcuts_run",
            description:
                "Run a shortcut by name or identifier. Input can be text, or a file inside a shared folder. "
                + "The result is returned as text unless outputPath is given.",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "The name or identifier of the shortcut to run"
                    ),
                    "input": .string(
                        description: "Optional text input to pass to the shortcut"
                    ),
                    "inputPath": .string(
                        description:
                            "Optional file to pass to the shortcut, inside a shared folder. Cannot be combined with input."
                    ),
                    "outputPath": .string(
                        description:
                            "Optional file to write the shortcut's result to, inside a shared folder that allows writing. "
                            + "Use this for results that are not text, such as an image."
                    ),
                    "outputType": .string(
                        description:
                            "Optional Uniform Type Identifier for the result, such as public.png or public.plain-text."
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Run Shortcut",
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw ShortcutsError.missingArgument("name")
            }

            let text = arguments["input"]?.stringValue
            let inputPath = arguments["inputPath"]?.stringValue
            if text != nil, inputPath != nil {
                throw ShortcutsError.conflictingInput
            }

            return try await self.runShortcut(
                name: name,
                input: text,
                inputPath: inputPath,
                outputPath: arguments["outputPath"]?.stringValue,
                outputType: arguments["outputType"]?.stringValue
            )
        }

        Tool(
            name: "shortcuts_view",
            description:
                "Open a shortcut in the Shortcuts app so the user can see how it is built. Does not run it.",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "The name or identifier of the shortcut to open")
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "View Shortcut",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw ShortcutsError.missingArgument("name")
            }
            _ = try await self.capture(arguments: ["view", name], what: "shortcuts view")
            return Value.object(["opened": .bool(true), "shortcut": .string(name)])
        }
    }

    // MARK: - Private Implementation

    /// Generous ceiling for `shortcuts list` / `shortcuts view`, which are
    /// fast operations when healthy.
    private static let captureTimeout: Duration = .seconds(60)

    /// Runs the CLI and returns stdout, throwing with stderr on a non-zero exit.
    private func capture(arguments: [String], what: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        defer {
            outputHandle.closeFile()
            errorHandle.closeFile()
        }

        try process.run()

        // Drain both pipes concurrently with termination, matching
        // AppleScriptRunner: reading only after the child exited deadlocked
        // whenever output exceeded the pipe buffer, because the child blocks
        // writing before it can terminate. The timeout bounds a wedged CLI.
        let outputTask = Task.detached {
            (try? outputHandle.readToEnd()) ?? Data()
        }
        let errorTask = Task.detached {
            (try? errorHandle.readToEnd()) ?? Data()
        }

        do {
            if try await !ProcessCompletion.wait(for: process, timeout: Self.captureTimeout) {
                throw ShortcutsError.commandFailed(what, "timed out")
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            log.error("Failed to run \(what, privacy: .public): \(error.localizedDescription)")
            _ = await outputTask.value
            _ = await errorTask.value
            throw error
        }

        let outputData = await outputTask.value
        let errorData = await errorTask.value

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("\(what, privacy: .public) failed: \(message)")
            throw ShortcutsError.commandFailed(what, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    /// Parses the CLI's `Name (UUID)` lines. The identifier is optional in the
    /// parse rather than assumed: a name containing parentheses would otherwise
    /// silently lose its last word.
    private func namedEntries(arguments: [String], what: String) async throws -> [Value] {
        let output = try await capture(arguments: arguments, what: "shortcuts \(what)")
        return
            output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                guard
                    line.hasSuffix(")"),
                    let open = line.lastIndex(of: "("),
                    open > line.startIndex
                else {
                    return .object(["name": .string(line)])
                }
                let identifier = String(line[line.index(after: open) ..< line.index(before: line.endIndex)])
                let name = String(line[line.startIndex ..< open]).trimmingCharacters(in: .whitespaces)
                guard UUID(uuidString: identifier) != nil else {
                    return .object(["name": .string(line)])
                }
                return .object(["name": .string(name), "id": .string(identifier)])
            }
    }

    private func runShortcut(
        name: String,
        input: String?,
        inputPath: String?,
        outputPath: String?,
        outputType: String?
    ) async throws -> Value {
        log.info("Running shortcut: \(name, privacy: .public)")

        let tempDirectory = FileManager.default.temporaryDirectory

        // A caller-supplied output path is written directly, so the result of a
        // shortcut that produces an image or a PDF stays a file instead of being
        // forced through a text return value.
        let destination: URL
        let returnsText: Bool
        if let outputPath {
            destination = try FilesystemAccess.resolve(
                requested: outputPath,
                roots: filesystemRoots,
                requiringWrite: true
            )
            returnsText = false
        } else {
            destination = tempDirectory.appendingPathComponent("shortcut_output_\(UUID().uuidString)")
            returnsText = true
        }

        var arguments = ["run", name, "--output-path", destination.path]
        if let outputType, !outputType.isEmpty {
            arguments.append(contentsOf: ["--output-type", outputType])
        }

        var temporaryInput: URL?
        if let inputPath {
            let resolved = try FilesystemAccess.resolve(
                requested: inputPath,
                roots: filesystemRoots,
                requiringWrite: false
            )
            arguments.append(contentsOf: ["--input-path", resolved.path])
        } else if let input {
            let url = tempDirectory.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
            try input.write(to: url, atomically: true, encoding: .utf8)
            arguments.append(contentsOf: ["--input-path", url.path])
            temporaryInput = url
        }

        defer {
            if let temporaryInput {
                try? FileManager.default.removeItem(at: temporaryInput)
            }
            if returnsText {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let errorHandle = errorPipe.fileHandleForReading
        defer { errorHandle.closeFile() }

        try process.run()
        let errorTask = Task.detached {
            (try? errorHandle.readToEnd()) ?? Data()
        }

        do {
            let exitedBeforeTimeout = try await ProcessCompletion.wait(for: process, timeout: self.executionTimeout)
            if !exitedBeforeTimeout {
                throw ShortcutsError.timedOut(name)
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            let errorData = await errorTask.value
            if !errorData.isEmpty {
                let stderrMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                log.error("Shortcut '\(name, privacy: .public)' stderr: \(stderrMessage, privacy: .public)")
            }
            log.error("Failed to run shortcut '\(name, privacy: .public)': \(error.localizedDescription)")
            throw error
        }

        let errorData = await errorTask.value

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            log.error("Shortcut '\(name, privacy: .public)' failed: \(message)")
            throw ShortcutsError.shortcutFailed(
                name,
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        log.info("Shortcut '\(name, privacy: .public)' completed successfully")

        var result: [String: Value] = [
            "success": .bool(true),
            "shortcut": .string(name),
        ]

        let exists = FileManager.default.fileExists(atPath: destination.path)
        if returnsText {
            if exists, let output = try? String(contentsOf: destination, encoding: .utf8),
                !output.isEmpty
            {
                result["output"] = .string(output)
            }
        } else if exists {
            result["outputPath"] = .string(destination.path)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let size { result["sizeBytes"] = .int(size) }
        } else {
            result["note"] = .string("The shortcut produced no output, so no file was written.")
        }

        return Value.object(result)
    }
}

enum ShortcutsError: LocalizedError {
    case missingArgument(String)
    case conflictingInput
    case commandFailed(String, String)
    case shortcutFailed(String, String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case .conflictingInput:
            return "Pass either input or inputPath, not both."
        case let .commandFailed(what, message):
            return message.isEmpty ? "\(what) failed." : "\(what) failed: \(message)"
        case let .shortcutFailed(name, message):
            return message.isEmpty
                ? "The shortcut \(name) failed." : "The shortcut \(name) failed: \(message)"
        case let .timedOut(name):
            return "The shortcut \(name) did not finish within five minutes."
        }
    }
}
