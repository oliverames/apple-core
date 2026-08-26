// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared building blocks for the grouped-settings layout, adapted from
// skylight-bridge's Sources/SkylightBridge/Views/Components.swift so the two
// apps read as the same family: same grouped forms, same section header and
// tip footer grammar, same status vocabulary, same page margins.
//
// The content areas use standard macOS grouped forms; Liquid Glass appears
// only in system chrome such as the toolbar and sidebar, which is what the
// system does on its own when building against the macOS 26+ SDK.

import AppKit
import SwiftUI

/// Row status the macOS way: a small colored SF symbol plus secondary text
/// (like System Settings), never a capsule chip that mimics a button. The
/// neutral tone stays a quiet tag capsule for counts and mode labels only.
struct StatusBadge: View {
    enum Tone {
        case neutral
        case positive
        case warning
    }

    let title: String
    var tone: Tone = .neutral

    var body: some View {
        switch tone {
        case .neutral:
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
        case .positive:
            statusLabel(systemImage: "checkmark.circle.fill", color: .green)
        case .warning:
            statusLabel(systemImage: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private func statusLabel(systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .imageScale(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Section header with a bold title and a plain-language subtitle.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

/// "Tip" capsule with explanatory text, used as a section footer.
struct TipFooter: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Tip")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

/// Standard layout for grouped-settings detail pages: cards stretch with the
/// window and keep a fixed, modest gutter on each side — no centered
/// max-width column, whose side margins would grow with the window.
struct GroupedPageLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, 24, for: .scrollContent)
    }
}

extension View {
    func groupedPageLayout() -> some View {
        modifier(GroupedPageLayout())
    }
}

/// Sheet footer with a cancel affordance and a prominent confirm action,
/// separated from the form by a divider.
struct EditorFooter: View {
    let confirmTitle: String
    var cancelTitle: String = "Cancel"
    var showsCancel: Bool = true
    var canConfirm: Bool = true
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if showsCancel {
                    Button(cancelTitle, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding(12)
        }
        .background(.bar)
    }
}

/// Copy-to-pasteboard button with transient confirmation, so the user can see
/// that the click did something.
struct SettingsCopyButton: View {
    let title: String
    let systemImage: String
    let value: () -> String?

    @State private var isConfirmingCopy = false

    var body: some View {
        Button {
            guard let value = value(), !value.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation { isConfirmingCopy = true }
            Task {
                try? await Task.sleep(for: .milliseconds(1400))
                withAnimation { isConfirmingCopy = false }
            }
        } label: {
            Label(
                isConfirmingCopy ? "Copied" : title,
                systemImage: isConfirmingCopy ? "checkmark.circle.fill" : systemImage
            )
        }
    }
}
