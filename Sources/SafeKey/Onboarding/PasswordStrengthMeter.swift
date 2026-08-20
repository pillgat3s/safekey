import SwiftUI

/// Local-only strength estimate (length + character classes). Never sends the
/// password anywhere.
struct PasswordStrength {
    enum Level: Int, CaseIterable {
        case tooShort, weak, fair, good, strong

        var label: String {
            switch self {
            case .tooShort: "Too Short"
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

        let score = password.count + classes * 4
        switch score {
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
                .frame(width: 64, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
