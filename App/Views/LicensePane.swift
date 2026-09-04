// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct LicensePane: View {
    @ObservedObject var model: ServingSettingsModel
    @State private var isImportingLicense = false
    @State private var showsVerificationDetails = false
    @State private var showsDeactivationConfirmation = false
    @FocusState private var keyIsFocused: Bool

    private let purchaseURL = URL(string: "https://amesconsulting.gumroad.com/l/applecore")!

    private var canActivate: Bool {
        !model.licensePasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isActivatingLicense
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if case .active(let document) = model.licenseState {
                    activatedLicense(document)
                } else {
                    activationForm
                }

                DisclosureGroup("How license verification works", isExpanded: $showsVerificationDetails) {
                    Text(
                        "Apple Core sends only your license key and the product ID to Gumroad, "
                            + "at activation and about once a day. Your license keeps working offline "
                            + "for up to 14 days after a successful check. Imported license files "
                            + "are verified on this Mac without a network request."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("License")
        .task { model.refreshLicenseState() }
        .confirmationDialog("Deactivate Apple Core on this Mac?", isPresented: $showsDeactivationConfirmation) {
            Button("Deactivate This Mac", role: .destructive) { model.deactivateLicense() }
        } message: {
            Text("Connected clients will lose access. You can activate this Mac again with your license.")
        }
        .fileImporter(isPresented: $isImportingLicense, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): model.importLicense(from: url)
            case .failure:
                model.licenseActivationError = "Could not open the license file. Please try again."
            }
        }
    }

    private var activationForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Activate Apple Core")
                    .font(.title2.weight(.semibold))
                Text("Enter the license key from your Gumroad receipt to connect your AI apps.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("License key")
                        .font(.callout.weight(.medium))
                    TextField(
                        "Paste your license key",
                        text: Binding(
                            get: { model.licensePasteText },
                            set: {
                                model.licensePasteText = $0
                                model.licenseActivationError = nil
                            }
                        )
                    )
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .autocorrectionDisabled()
                    .focused($keyIsFocused)
                    .accessibilityLabel("License key")
                    .disabled(model.isActivatingLicense)
                    .onSubmit { if canActivate { model.activateLicense() } }
                }

                if let error = model.licenseActivationError {
                    errorMessage(error)
                } else if case .rejected(let reason) = model.licenseState {
                    errorMessage(reason)
                }

                Button {
                    model.activateLicense()
                } label: {
                    HStack(spacing: 8) {
                        if model.isActivatingLicense {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isActivatingLicense ? "Checking license…" : "Activate")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canActivate)
            }

            HStack(spacing: 4) {
                Text("Don't have a license?")
                    .foregroundStyle(.secondary)
                Link("Buy Apple Core", destination: purchaseURL)
            }
            .font(.callout)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Have a license file?")
                        .font(.callout.weight(.medium))
                    Text("Import the file issued to you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Import File…") { isImportingLicense = true }
                    .disabled(model.isActivatingLicense)
            }
        }
        .padding(24)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { keyIsFocused = true }
    }

    private func activatedLicense(_ document: LicenseDocument) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Apple Core is activated", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            Text("This Mac is ready to connect to your AI apps.")
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 12) {
                if let name = document.licensedTo {
                    LabeledContent("Licensed to", value: name)
                }
                if let expiresAt = document.expiresAt {
                    LabeledContent("Expires") { Text(expiresAt, style: .date) }
                }
                LabeledContent("License ID", value: document.licenseID)
            }
            .font(.callout)
            .textSelection(.enabled)

            Button("Deactivate This Mac…", role: .destructive) { showsDeactivationConfirmation = true }
                .disabled(model.isActivatingLicense)
        }
        .padding(24)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
