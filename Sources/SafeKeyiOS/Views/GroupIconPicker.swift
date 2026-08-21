import SwiftUI
import SafeKeyCore

/// Picking a group's icon: an emoji you type, or one of a curated set of
/// symbols. Deliberately not the whole SF Symbols catalogue — thousands of
/// glyphs in a grid is a worse experience than eighteen good ones.
struct GroupIconPicker: View {
    @Binding var icon: String?
    @Binding var colorHex: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    private var emojiBinding: Binding<String> {
        Binding(
            get: { (icon?.isSingleEmoji == true) ? icon! : "" },
            set: { newValue in
                // Keep only the last character typed, so the field holds one
                // emoji rather than accumulating a string.
                icon = newValue.isEmpty ? nil : String(newValue.suffix(1))
            }
        )
    }

    var body: some View {
        Section {
            TextField("Emoji", text: emojiBinding, prompt: Text("Type an emoji"))
                .accessibilityIdentifier("group.emoji")
        } header: {
            Text("Emoji")
        }

        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(WalletGroup.symbolChoices, id: \.self) { symbol in
                    Button {
                        icon = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 17))
                            .frame(width: 38, height: 38)
                            .foregroundStyle(icon == symbol ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                            .background {
                                if icon == symbol {
                                    Circle().fill(.tint)
                                } else {
                                    Circle().fill(.quaternary.opacity(0.5))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Symbol")
        }

        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(WalletGroup.palette, id: \.self) { hex in
                    Button {
                        colorHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if colorHex == hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Colour")
        } footer: {
            Text("The colour applies to a symbol. An emoji keeps its own colours.")
        }
    }
}
