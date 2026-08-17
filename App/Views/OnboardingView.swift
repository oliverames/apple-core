// SPDX-License-Identifier: GPL-3.0-or-later
//
// First-run flow: welcome, one choice, services, done.
//
// Two things shaped this. The choice comes before anything else, because
// "this Mac only" and "reachable from anywhere" are genuinely different
// products and every later screen means something different depending on the
// answer — asking it at the end, as an optional extra step, made the whole
// flow read as setup for a thing you had not agreed to yet.
//
// And there is no step rail. The first draft had a dot-and-line progress
// indicator, which is a web wizard pattern that no Apple setup flow uses.
// Containers are `Form` sections rather than hand-rolled cards, so they get
// the system's own treatment — including Liquid Glass on macOS 26 and later,
// since the app builds against the macOS 27 SDK — while still degrading
// correctly at the 15.1 deployment target.

import AppKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case access
    case services
    case done
}

struct OnboardingView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var model: ServingSettingsModel
    let onFinish: () -> Void

    @State private var step: OnboardingStep = .welcome
    /// Lifted out of the access step so the footer can own the primary action.
    /// Defaults to the safe answer, so Continue always means something.
    @State private var wantsRemote = false

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:
                OnboardingWelcomeStep()
            case .access:
                OnboardingAccessStep(model: model, wantsRemote: $wantsRemote)
            case .services:
                OnboardingServicesStep(serverController: serverController)
            case .done:
                OnboardingDoneStep(
                    address: model.publicBaseURL.isEmpty
                        ? "\(model.localBaseURL)/mcp" : "\(model.clientBaseURL)/mcp",
                    token: model.token
                )
            }
        }
        .frame(width: 560, height: 540)
        .safeAreaInset(edge: .bottom) {
            OnboardingFooter(
                showsBack: step != .welcome && step != .done,
                isBusy: model.isConfiguringRemoteAccess,
                primaryTitle: primaryTitle,
                onBack: { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome },
                onPrimary: performPrimaryAction
            )
        }
        .task { await model.refreshCloudflareStatus() }
    }

    /// There is exactly one primary button, and on the access step it changes
    /// what it does rather than sitting next to a second button that competes
    /// with it.
    private var primaryTitle: String {
        switch step {
        case .done:
            return "Done"
        case .access where wantsRemote && !isRemoteConfigured:
            return "Set Up Remote Access"
        default:
            return "Continue"
        }
    }

    private var isRemoteConfigured: Bool {
        model.cloudflareStatus?.state == .running
    }

    private func performPrimaryAction() {
        switch step {
        case .done:
            onFinish()
        case .access where wantsRemote && !isRemoteConfigured:
            Task { await model.setUpRemoteAccess() }
        default:
            step = OnboardingStep(rawValue: step.rawValue + 1) ?? .done
        }
    }
}

// MARK: - Footer

/// At most two buttons, which is as many as an Apple setup panel ever shows.
private struct OnboardingFooter: View {
    let showsBack: Bool
    let isBusy: Bool
    let primaryTitle: String
    let onBack: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        HStack {
            if showsBack {
                Button("Back", action: onBack)
                    .disabled(isBusy)
            }

            Spacer()

            Button(primaryTitle, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - Shared layout

/// The centered hero Apple uses for a welcome or a single-proposition screen.
private struct OnboardingHero<Content: View>: View {
    var systemImage: String?
    var usesAppIcon = false
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            if usesAppIcon {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 52))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
            }

            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

private struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }
}

// MARK: - Welcome

private struct OnboardingWelcomeStep: View {
    var body: some View {
        OnboardingHero(
            usesAppIcon: true,
            title: "Welcome to Apple Core",
            subtitle: "Your Mac's Calendar, Mail, Notes and more, available to AI clients you trust."
        ) {
            Text("Every client has to be approved before it can connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }
}

// MARK: - Access

/// The one real choice in setup, asked first.
///
/// The choice rows carry the whole explanation, so there is no paragraph
/// restating them, and the action lives in the footer rather than as a second
/// button competing with Continue.
private struct OnboardingAccessStep: View {
    @ObservedObject var model: ServingSettingsModel
    @Binding var wantsRemote: Bool

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepHeader(
                title: "Where can Apple Core be reached?",
                subtitle: "You can change this later."
            )

            Form {
                Section {
                    OnboardingChoiceRow(
                        icon: "laptopcomputer",
                        title: "This Mac only",
                        detail: "Claude Desktop, Claude Code and other apps running here.",
                        isSelected: !wantsRemote
                    ) {
                        wantsRemote = false
                    }

                    OnboardingChoiceRow(
                        icon: "globe",
                        title: "Reachable from anywhere",
                        detail: "Also Claude's web and mobile clients. Signs you in to Cloudflare once.",
                        isSelected: wantsRemote
                    ) {
                        wantsRemote = true
                    }
                }

                if wantsRemote {
                    Section {
                        RemoteAccessProgress(model: model)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Status only. The button that starts this lives in the footer.
private struct RemoteAccessProgress: View {
    @ObservedObject var model: ServingSettingsModel

    var body: some View {
        if model.cloudflareStatus?.state == .running {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote access is on")
                    Text(model.cloudflare.hostname)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else if model.isConfiguringRemoteAccess {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.remoteSetupStage ?? model.cloudflaredInstallProgress?.message ?? "Setting up…")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = model.cloudflareSetupError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if model.needsManualHostname {
            RemoteAccessSetup(model: model)
        } else {
            Text("Apple Core publishes one web address for this Mac using your own Cloudflare account.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingChoiceRow: View {
    let icon: String
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Radio on the leading edge, which is where macOS puts it.
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Services

private struct OnboardingServicesStep: View {
    @ObservedObject var serverController: ServerController

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepHeader(
                title: "Choose Services",
                subtitle: "macOS asks your permission as each one is switched on."
            )

            Form {
                Section {
                    ForEach(serverController.computedServiceConfigs) { config in
                        OnboardingServiceToggle(serverController: serverController, config: config)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct OnboardingServiceToggle: View {
    @ObservedObject var serverController: ServerController
    let config: ServiceConfig

    @State private var isActivating = false
    @State private var activationError: String?

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 10) {
                Image(systemName: config.iconName)
                    .foregroundStyle(config.color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name)
                    if let activationError {
                        Text(activationError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isActivating {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isActivating)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { config.binding.wrappedValue },
            set: { newValue in
                config.binding.wrappedValue = newValue
                activationError = nil
                Task { @MainActor in
                    if newValue {
                        isActivating = true
                        defer { isActivating = false }
                        do {
                            try await ServicePermissionCoordinator.activate(
                                config.service,
                                requirements: config.permissionRequirements
                            )
                        } catch {
                            config.binding.wrappedValue = false
                            activationError = error.localizedDescription
                        }
                    }
                    await serverController.updateServiceBindings(
                        Dictionary(
                            uniqueKeysWithValues: serverController.computedServiceConfigs.map { ($0.id, $0.binding) }
                        )
                    )
                }
            }
        )
    }
}

// MARK: - Done

/// Connecting a client used to be its own step. It is one button and one
/// copyable string, so it belongs on the screen that says you are finished.
private struct OnboardingDoneStep: View {
    let address: String
    let token: String

    var body: some View {
        OnboardingHero(
            systemImage: "checkmark.circle.fill",
            title: "Apple Core is ready",
            subtitle: "It lives in your menu bar and keeps running in the background."
        ) {
            VStack(spacing: 10) {
                Text(address)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        ClaudeDesktop.showConfigurationPanel()
                    } label: {
                        Label("Configure Claude Desktop…", systemImage: "desktopcomputer")
                    }

                    SettingsCopyButton(title: "Copy Connection Details", systemImage: "doc.on.doc") {
                        "\(address)\n\(token)"
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let completionDefaultsKey = "hasCompletedOnboarding"

    private var window: NSWindow?
    private var shouldRestoreAccessoryPolicy = false

    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: completionDefaultsKey)
    }

    func show(serverController: ServerController, model: ServingSettingsModel) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(
            serverController: serverController,
            model: model,
            onFinish: { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.completionDefaultsKey)
                self?.closeWindow()
            }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // A setup panel, not a document window: the chrome is the content.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.delegate = self
        self.window = window

        // Onboarding is the one moment a menu-bar app has to be in front, and
        // an accessory app cannot reliably take focus.
        shouldRestoreAccessoryPolicy = NSApp.activationPolicy() == .accessory && NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.close()
        window = nil
        restorePolicy()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing with the titlebar button counts as finishing: re-showing the
        // flow on every launch until someone reaches the last step would be
        // worse than letting them out.
        UserDefaults.standard.set(true, forKey: Self.completionDefaultsKey)
        window = nil
        restorePolicy()
    }

    private func restorePolicy() {
        guard shouldRestoreAccessoryPolicy else { return }
        shouldRestoreAccessoryPolicy = false

        let dockIconRequested = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
        let settingsWindowVisible = NSApp.windows.contains {
            $0.identifier?.rawValue == "AppleCoreSettingsWindow" && $0.isVisible
        }
        if !dockIconRequested && !settingsWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
