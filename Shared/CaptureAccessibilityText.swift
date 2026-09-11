// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading an interface as text instead of as a picture.
//
// A screenshot of a window is a megabyte of pixels a model then has to guess
// at. The same window's accessibility tree is a few kilobytes of labelled
// text, it costs the user's context window almost nothing, and — the part that
// matters here — it returns far less of what was never asked for. A screenshot
// of Mail shows every message in the list. The accessibility text of one
// message window is that message.
//
// Three rules are load-bearing, and they are in this file rather than in the
// tool closure so they can be tested without a live Mac:
//
//   1. Secure fields never contribute text. Not their value, not their
//      placeholder, and their children are not walked either. A password field
//      that reports its contents through the accessibility API is a thing that
//      happens, and this is the one place that can refuse to pass it on.
//   2. The traversal is bounded in depth, in node count and in total
//      characters, and says which bound it hit. An unbounded walk of a
//      document window can be tens of thousands of nodes.
//   3. Nothing here clicks, types, focuses or raises anything. This reads.
//      Apple Core is not remote control of a Mac, and an accessibility surface
//      is exactly where that line would be easiest to cross by accident.

import Foundation

/// One element, reduced to what a reader needs. Modelled as a protocol so the
/// traversal can be exercised against a constructed tree; the app conforms a
/// thin wrapper over `AXUIElement` to it.
public protocol CaptureAccessibleElement {
    var axRole: String? { get }
    var axSubrole: String? { get }
    var axTitle: String? { get }
    var axValueText: String? { get }
    var axDescriptionText: String? { get }
    var axChildren: [Self] { get }
}

public struct CaptureTextNode: Equatable, Sendable {
    public let role: String
    public let text: String
    public let depth: Int

    public init(role: String, text: String, depth: Int) {
        self.role = role
        self.text = text
        self.depth = depth
    }
}

public struct CaptureAccessibilityTextResult: Equatable, Sendable {
    public let nodes: [CaptureTextNode]
    public let visitedCount: Int
    /// How many elements were skipped for holding secure content. Counted and
    /// reported, so a caller can see that something was withheld rather than
    /// wonder why a login window read as empty.
    public let secureElementsExcluded: Int
    public let reachedNodeLimit: Bool
    public let reachedDepthLimit: Bool
    public let reachedCharacterLimit: Bool

    public var text: String { nodes.map(\.text).joined(separator: "\n") }

    public var isBounded: Bool { reachedNodeLimit || reachedDepthLimit || reachedCharacterLimit }

    public init(
        nodes: [CaptureTextNode],
        visitedCount: Int,
        secureElementsExcluded: Int,
        reachedNodeLimit: Bool,
        reachedDepthLimit: Bool,
        reachedCharacterLimit: Bool
    ) {
        self.nodes = nodes
        self.visitedCount = visitedCount
        self.secureElementsExcluded = secureElementsExcluded
        self.reachedNodeLimit = reachedNodeLimit
        self.reachedDepthLimit = reachedDepthLimit
        self.reachedCharacterLimit = reachedCharacterLimit
    }
}

public enum CaptureAccessibilityText {
    public static let defaultMaxDepth = 12
    public static let maximumMaxDepth = 30
    public static let defaultMaxNodes = 1500
    public static let maximumMaxNodes = 5000
    public static let defaultMaxCharacters = 20_000
    public static let maximumMaxCharacters = 60_000
    /// One element's own text, before the whole-read budget applies. A text
    /// view's value can be an entire document.
    public static let maximumNodeCharacters = 2000

    /// Roles and subroles whose contents are never read. Matched on both,
    /// because AppKit reports a secure field as role `AXTextField` with
    /// subrole `AXSecureTextField` in some hosts and as role
    /// `AXSecureTextField` in others.
    public static let secureRoles: Set<String> = [
        "AXSecureTextField",
        "AXSecureTextArea",
    ]

    public static func isSecure(role: String?, subrole: String?) -> Bool {
        if let role, secureRoles.contains(role) { return true }
        if let subrole, secureRoles.contains(subrole) { return true }
        return false
    }

    public static func clampedDepth(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxDepth }
        return min(requested, maximumMaxDepth)
    }

    public static func clampedNodes(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxNodes }
        return min(requested, maximumMaxNodes)
    }

    public static func clampedCharacters(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxCharacters }
        return min(requested, maximumMaxCharacters)
    }

    /// The text one element contributes: its value if it has one, otherwise
    /// its title, otherwise its accessibility description. Whitespace-only and
    /// duplicate-of-parent text is dropped by the caller, not here.
    public static func text(of element: some CaptureAccessibleElement) -> String? {
        let candidates = [element.axValueText, element.axTitle, element.axDescriptionText]
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                !trimmed.isEmpty
            else { continue }
            return String(trimmed.prefix(maximumNodeCharacters))
        }
        return nil
    }

    /// Breadth-first, bounded walk. Breadth-first rather than depth-first so a
    /// node budget spent early returns the window's headings and labels rather
    /// than the first paragraph of one text view.
    public static func read<Element: CaptureAccessibleElement>(
        root: Element,
        maxDepth: Int = defaultMaxDepth,
        maxNodes: Int = defaultMaxNodes,
        maxCharacters: Int = defaultMaxCharacters
    ) -> CaptureAccessibilityTextResult {
        var nodes: [CaptureTextNode] = []
        var visited = 0
        var secureExcluded = 0
        var characters = 0
        var reachedNodeLimit = false
        var reachedDepthLimit = false
        var reachedCharacterLimit = false
        var seen = Set<String>()

        var queue: [(element: Element, depth: Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()

            if isSecure(role: element.axRole, subrole: element.axSubrole) {
                secureExcluded += 1
                continue
            }

            visited += 1
            if visited > maxNodes {
                reachedNodeLimit = true
                break
            }

            if let text = text(of: element) {
                // A container and its label routinely report the same string.
                // Repeating it wastes the character budget the caller is
                // paying for and reads as if the interface said it twice.
                if seen.insert(text).inserted {
                    if characters + text.count > maxCharacters {
                        reachedCharacterLimit = true
                        break
                    }
                    characters += text.count
                    nodes.append(
                        CaptureTextNode(
                            role: element.axRole ?? "AXUnknown",
                            text: text,
                            depth: depth
                        )
                    )
                }
            }

            guard depth < maxDepth else {
                if !element.axChildren.isEmpty { reachedDepthLimit = true }
                continue
            }
            for child in element.axChildren {
                queue.append((child, depth + 1))
            }
        }

        return CaptureAccessibilityTextResult(
            nodes: nodes,
            visitedCount: min(visited, maxNodes),
            secureElementsExcluded: secureExcluded,
            reachedNodeLimit: reachedNodeLimit,
            reachedDepthLimit: reachedDepthLimit,
            reachedCharacterLimit: reachedCharacterLimit
        )
    }
}
