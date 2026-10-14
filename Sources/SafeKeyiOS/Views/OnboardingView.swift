import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .welcome
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showingImporter = false

    private var strength: PasswordStrength.Level { PasswordStrength.evaluate(password) }

    private var canCreate: Bool {
        strength != .tooShort && password == confirmation && !isCreating
    }

    /// Welcome, then what the app is for, then the password. The notice is
    /// acknowledged before a vault can be created or a backup restored.
    enum Page { case welcome, scope, setPassword }

    var body: some View {
        switch page {
        case .welcome:
            WelcomeView { withAnimation(.smooth(duration: 0.3)) { page = .scope } }
                .transition(.opacity)
        case .scope:
            ScopeNoticeView { withAnimation(.smooth(duration: 0.3)) { page = .setPassword } }
                .transition(.opacity)
        case .setPassword:
            setPassword
        }
    }

    private var setPassword: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)

                Text("SafeKey")
                    .font(.largeTitle.bold())

                Text("An encrypted vault for the recovery phrases and private keys of your burner wallets. Everything stays on this device unless you later turn on iCloud sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    // No textContentType on purpose: `.newPassword` summons
                    // the system's strong-password overlay, which offers to
                    // put the master password into iCloud Keychain — the one
                    // place it must never live, being the key to a vault that
                    // may itself sync through iCloud. Apple's Passwords app
                    // does not autofill its own gate either.
                    SecureField("Master password", text: $password)
                        .accessibilityIdentifier("onboarding.password")
                    PasswordStrengthMeter(password: password)
                    SecureField("Confirm password", text: $confirmation)
                        .accessibilityIdentifier("onboarding.confirm")
                    if !confirmation.isEmpty, confirmation != password {
                        Text("Passwords don't match")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 8)

                Text("This password encrypts everything and is never stored. If you forget it, the vault cannot be recovered — by anyone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Create Vault").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canCreate)

                Button("Restore from a Backup…") { showingImporter = true }
                    .font(.callout)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                restore(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let chosen = password
        Task {
            do {
                try await model.createVault(password: chosen)
            } catch {
                errorMessage = "Could not create the vault: \(error.localizedDescription)"
                isCreating = false
            }
        }
    }

    private func restore(from url: URL) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try model.inspectBackup(data)   // reject non-containers before writing
                try await model.importVault(data)
            } catch {
                errorMessage = "That file is not a valid SafeKey backup."
            }
        }
    }
}

/// Local-only password strength estimate. Never leaves the device.
enum PasswordStrength {
    enum Level: Int {
        case tooShort, weak, fair, good, strong

        var label: String {
            switch self {
            case .tooShort: "Too short"
            case .weak: "Weak"
            case .fair: "Fair"
            case .good: "Good"
            case .strong: "Strong"
            }
        }

        var color: Color {
            switch self {
            case .tooShort, .weak: .red
            case .fair: .orange
            case .good: .yellow
            case .strong: .green
            }
        }
    }

    static func evaluate(_ password: String) -> Level {
        guard password.count >= 8 else { return .tooShort }
        var classes = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        switch password.count + classes * 4 {
        case ..<16: return .weak
        case ..<22: return .fair
        case ..<30: return .good
        default: return .strong
        }
    }
}

struct PasswordStrengthMeter: View {
    let password: String
    private var level: PasswordStrength.Level { PasswordStrength.evaluate(password) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(1..<5) { segment in
                    Capsule()
                        .fill(segment <= level.rawValue ? level.color : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text(level.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.15), value: level.rawValue)
    }
}
