import AppKit
import SwiftUI

/// A window to type text into; Speak sends it to the talking head.
struct InputWindow: View {
    static let id = "input"

    @Environment(SpeechEngine.self) private var speech
    @Environment(\.openWindow) private var openWindow
    /// Starts as the current voice's greeting (see `LaunchOptions.defaultText`).
    @State private var text = ""
    @State private var window: NSWindow?

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
                    speak()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 220)
        .background(WindowAccessor { window in
            self.window = window
            bringToFront(window)
        })
        .onAppear {
            if text.isEmpty { text = LaunchOptions.defaultText(voiceName: greetingName) }
        }
        // An untouched greeting follows the voice: the face, or the voice chosen for it.
        .onChange(of: greetingName) { old, new in
            if text == LaunchOptions.defaultText(voiceName: old) {
                text = LaunchOptions.defaultText(voiceName: new)
            }
        }
    }

    /// Who the greeting says is speaking: the voice, else the face.
    private var greetingName: String {
        speech.voiceName(for: speech.portrait) ?? speech.portrait.faceName
    }

    /// Speaks the text, opening the talking head if it isn't showing, and keeps the keyboard
    /// focus here so you can keep typing.
    private func speak() {
        if FaceWindows.window(for: speech.portrait.id) == nil {
            openWindow(id: FaceWindow.id, value: speech.portraitID)
            // The face window makes itself key when it appears; take the focus back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [window] in
                window?.makeKeyAndOrderFront(nil)
            }
        }
        SpeechSpooler.shared.submit(SpeechRequest(source: .text(text)))
    }
}
