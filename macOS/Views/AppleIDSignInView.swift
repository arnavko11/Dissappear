import SwiftUI

/// Apple ID sign-in, used only to let Apple issue a development certificate and
/// provisioning profile for this Mac — the same thing Xcode's Accounts pane does.
struct AppleIDSignInView: View {
    @EnvironmentObject private var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case appleID, password, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Sign In with Apple ID",
                          subtitle: "Apple issues the certificate and profile. This app never stores your password.")

            if model.needsVerificationCode {
                verificationStep
            } else {
                credentialsStep
            }

            if let error = model.error {
                ErrorCard(error: error)
            }

            HStack {
                Link("Apple's developer account terms", destination: URL(string: "https://developer.apple.com/terms/")!)
                    .font(.footnote)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(model.needsVerificationCode ? "Verify" : "Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || model.isSigningIn)
            }
        }
        .padding(20)
        .frame(width: 460)
        .overlay {
            if model.isSigningIn {
                ProgressView().controlSize(.small)
            }
        }
        .onChange(of: model.isSignedInWithAppleID) { _, signedIn in
            if signedIn {
                password = ""
                dismiss()
            }
        }
        .onDisappear { password = "" }
    }

    private var credentialsStep: some View {
        Form {
            TextField("Apple ID", text: $appleID)
                .textContentType(.username)
                .focused($focus, equals: .appleID)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(submit)
        }
        .formStyle(.grouped)
        .overlay(alignment: .bottomLeading) {
            EmptyView()
        }
        .safeAreaInset(edge: .bottom) {
            Text("Your password is used once, on this Mac, to complete Apple's secure remote password exchange. It is never written to disk and never sent to Apple in readable form. Only the resulting session token is kept, in your Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var verificationStep: some View {
        Form {
            LabeledContent("Verification Code") {
                TextField("123456", text: $verificationCode)
                    .focused($focus, equals: .code)
                    .onSubmit(submit)
            }
            Button("Send a new code") {
                Task { await model.signInWithAppleID(appleID: appleID, password: password) }
            }
            .buttonStyle(.link)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Text("Enter the six-digit code shown on your trusted Apple device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var canSubmit: Bool {
        model.needsVerificationCode
            ? verificationCode.count >= 6
            : !appleID.isEmpty && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            if model.needsVerificationCode {
                await model.submitVerificationCode(verificationCode, password: password)
            } else {
                await model.signInWithAppleID(appleID: appleID, password: password)
            }
        }
    }
}
