// SPDX-License-Identifier: GPL-3.0-or-later
//
// Remote access as one decision.
//
// What this replaces, in two rounds. First a pane that asked for Profile,
// Domain, Hostname and Tunnel Name up front, hid six more fields behind a
// disclosure, and offered four tunnel verbs in an ellipsis menu. Then a
// three-step checklist that still made the person read the mechanics —
// install a connector, sign in, pick an address — and work out the order.
//
// None of those steps is a decision. They are all consequences of the single
// decision of whether to have remote access at all. So the view states the
// proposition, offers one button, and reports progress on one line while the
// sequence runs behind it.
//
// Shared by onboarding and the Settings pane so the two cannot disagree.

import SwiftUI

struct RemoteAccessSetup: View {
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        if model.cloudflareStatus?.state == .running {
            RemoteAccessActive(
                address: "\(model.clientBaseURL)/mcp",
                token: model.token,
                onTurnOff: { Task { await model.stopCloudflareTunnel() } }
            )
        } else {
            RemoteAccessOffer(model: model)
        }
    }
}

// MARK: - Off

/// The proposition and the one button. Everything the setup sequence does is
/// deliberately absent until it is running, and then it is one line.
private struct RemoteAccessOffer: View {
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "Apple Core can publish one web address for this Mac using your own Cloudflare account, so cloud "
                    + "clients can reach it. You will sign in to Cloudflare once in your browser."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.needsManualHostname {
                RemoteAccessAddressField(model: model)
            }

            if model.isConfiguringRemoteAccess {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.remoteSetupStage ?? model.cloudflaredInstallProgress?.message ?? "Setting up…")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    Task { await model.setUpRemoteAccess() }
                } label: {
                    Text("Set Up Remote Access")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let error = model.cloudflareSetupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Only shown when the domain could not be read from the Cloudflare sign-in.
private struct RemoteAccessAddressField: View {
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "mcp.example.com",
                text: Binding(
                    get: { model.cloudflare.hostname },
                    set: { model.cloudflare.hostname = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
            .onSubmit {
                model.normalizeCloudflareHostFields()
                model.save(restartServer: false)
            }

            Text("A subdomain of a domain in your Cloudflare account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - On

private struct RemoteAccessActive: View {
    let address: String
    let token: String
    let onTurnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote access is on")
                        .font(.headline)
                    Text(address)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack(spacing: 10) {
                RemoteCopyButton(title: "Copy Address", systemImage: "link") { address }
                RemoteCopyButton(title: "Copy Token", systemImage: "key") { token }
                Spacer()
                Button("Turn Off", role: .destructive, action: onTurnOff)
            }
        }
    }
}

private struct RemoteCopyButton: View {
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
