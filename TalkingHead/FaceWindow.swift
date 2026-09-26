import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The talking head in its own resizable window, titled with the voice name. Clicking the
/// head shows or hides the speech bubble; the buttons below it play/pause, open the window
/// for typing text, pick a text file to speak, and pin the window above other windows.
struct FaceWindow: View {
    static let id = "face"

    let options: LaunchOptions
    @Environment(SpeechEngine.self) private var speech
    @Environment(FaceWindowSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var bubble = SpeechBubble()
    @State private var window: NSWindow?
    /// Set once the typing window or file picker has been used, so the app no longer quits
    /// after speaking.
    @State private var isInteractive = false
    @State private var isPickingFile = false

    var body: some View {
        VStack(spacing: 0) {
            FaceView(mouth: speech.mouth, portrait: speech.portrait, brows: speech.brows)
                .padding([.horizontal, .top], 12)
                .overlay {
                    ClickCatcher(toolTip: "Click to show or hide the speech bubble") { bubble.toggle() }
                }

            toolbar
        }
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 330, maxHeight: .infinity)
        .navigationTitle(speech.portrait.voiceName)
        .background(WindowAccessor { window in
            self.window = window
            bringToFront(window)
            bubble.attach(to: window, content: SpeechBubbleView(bubble: bubble).environment(speech))
            applyAlwaysOnTop()
        })
        .onChange(of: settings.isAlwaysOnTop) { applyAlwaysOnTop() }
        .task {
            switch options.mode {
            case .speak(let text):
                speech.speak(text)
            case .speakURL(let url):
                do {
                    speech.speak(try await WebPage.speakableText(for: url))
                } catch {
                    FileHandle.standardError.write(Data("th: can't read \(url.absoluteString): \(error.localizedDescription)\n".utf8))
                    exit(2)
                }
            case .menuBar, .face:
                break
            }
        }
        .onChange(of: speech.state) { old, new in
            // From the command line, quit once the text has been spoken (unless the user has
            // opened the typing window to carry on).
            if options.speaksAndQuits, !isInteractive, old != .idle, new == .idle {
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

            Button(settings.isAlwaysOnTop ? "Unpin" : "Pin",
                   systemImage: settings.isAlwaysOnTop ? "pin.fill" : "pin") {
                settings.isAlwaysOnTop.toggle()
            }
            .help(settings.isAlwaysOnTop ? "Stop keeping on top of other windows" : "Keep on top of other windows")
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

    /// Floats the window (and its bubble) above other apps' windows, or returns it to normal.
    private func applyAlwaysOnTop() {
        guard let window else { return }
        window.level = settings.isAlwaysOnTop ? .floating : .normal
        bubble.matchParentLevel()
    }

    /// Speaks a text file (see `TextFile`).
    private func speak(fileAt url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            speech.speak(try TextFile.read(url))
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Activates the app and makes `window` key once it is on screen. A menu bar applet isn't
/// active when it opens a window from its menu, and clicks on an inactive app's window only
/// activate it, so without this the first clicks on the head or buttons would be lost.
@MainActor
func bringToFront(_ window: NSWindow) {
    DispatchQueue.main.async {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// A transparent view that reports clicks, including the first click on a window of an
/// inactive app (which SwiftUI's tap gesture would only use to activate the app).
struct ClickCatcher: NSViewRepresentable {
    var toolTip: String
    var onClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.toolTip = toolTip
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                onClick?()
            }
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
