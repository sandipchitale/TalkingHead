import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The talking head in its own resizable window, titled with the voice name. Clicking the
/// head shows or hides the speech bubble; the buttons below it play/pause, open the window
/// for typing text, and pick a text file to speak.
struct FaceWindow: View {
    static let id = "face"

    let options: LaunchOptions
    @Environment(SpeechEngine.self) private var speech
    @Environment(\.openWindow) private var openWindow
    @State private var bubble = SpeechBubble()
    /// Set once the typing window or file picker has been used, so the app no longer quits
    /// after speaking.
    @State private var isInteractive = false
    @State private var isPickingFile = false

    var body: some View {
        VStack(spacing: 0) {
            FaceView(mouth: speech.mouth, portrait: speech.portrait)
                .padding([.horizontal, .top], 12)
                .contentShape(.rect)
                .onTapGesture { bubble.toggle() }
                .help("Click to show or hide the speech bubble")

            toolbar
        }
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 330, maxHeight: .infinity)
        .navigationTitle(speech.portrait.voiceName)
        .background(WindowAccessor { window in
            bubble.attach(to: window, content: SpeechBubbleView(bubble: bubble).environment(speech))
        })
        .task {
            if case .speak(let text) = options.mode {
                speech.speak(text)
            }
        }
        .onChange(of: speech.state) { old, new in
            // From the command line, quit once the text has been spoken (unless the user has
            // opened the typing window to carry on).
            if case .speak = options.mode, !isInteractive, old != .idle, new == .idle {
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private var toolbar: some View {
        let isSpeaking = speech.state == .speaking
        return HStack(spacing: 10) {
            Button(isSpeaking ? "Pause" : "Play", systemImage: isSpeaking ? "pause.fill" : "play.fill") {
                speech.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(speech.state == .idle && speech.spokenText.isEmpty)
            .help(isSpeaking ? "Pause (Space)" : "Play (Space)")

            Button("Type Text", systemImage: "macwindow") {
                isInteractive = true
                openWindow(id: InputWindow.id)
            }
            .help("Type text to speak")

            Button("Speak File", systemImage: "doc.text") {
                isInteractive = true
                isPickingFile = true
            }
            .help("Select a file to speak")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.text]) { result in
            if case .success(let url) = result {
                speak(fileAt: url)
            }
        }
    }

    /// Speaks a text file: plain text, or the text of RTF, HTML and other formats AppKit reads.
    private func speak(fileAt url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            speech.speak(text)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}
