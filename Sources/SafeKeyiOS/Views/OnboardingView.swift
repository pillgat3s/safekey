import SwiftUI
import UniformTypeIdentifiers
import SafeKeyCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var hasSeenWelcome = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showingImporter = false

    private var strength: PasswordStrength.Level { PasswordStrength.evaluate(password) }

    private var canCreate: Bool {
        strength != .tooShort && password == confirmation && !isCreating
    }

    var body: some View {
        if hasSeenWelcome {
            setPassword
        } else {
            WelcomeView { withAnimation(.smooth(duration: 0.3)) { hasSeenWelcome = true } }
                .transition(.opacity)
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

                Text("An encrypted vault for your wallet recovery phrases and private keys. Everything stays on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    SecureField("Master password", text: $password)
                        .accessibilityIdentifier("onboarding.password")
                        .textContentType(.newPassword)
                    PasswordStrengthMeter(password: password)
                    SecureField("Confirm password", text: $confirmation)
                        .accessibilityIdentifier("onboarding.confirm")
                        .textContentType(.newPassword)
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
