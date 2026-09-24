import SwiftUI

/// A window to type text into; Speak sends it to the talking head.
struct InputWindow: View {
    static let id = "input"

    @Environment(SpeechEngine.self) private var speech
    @Environment(\.openWindow) private var openWindow
    @State private var text: String

    init(initialText: String) {
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 12) {
            TextEditor(text: $text)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 12))

            HStack {
                Spacer()
                Button("Speak", systemImage: "play.fill") {
                    openWindow(id: FaceWindow.id)
                    speech.speak(text)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 220)
        .background(WindowAccessor(onWindow: bringToFront))
    }
}
