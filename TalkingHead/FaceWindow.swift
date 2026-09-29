import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The talking head in its own resizable window, titled with the voice name. Clicking the
/// head shows or hides the speech bubble; the buttons below it play/pause, open the window
/// for typing text, pick a text file to speak, and pin the window above other windows.
///
/// The applet opens one window per face (`portraitID`), so two voices can each have theirs, as
/// the two seats of a debate do. A window with no face of its own (a `th` run's) shows whichever
/// face speaks.
struct FaceWindow: View {
    static let id = "face"

    let options: LaunchOptions
    /// This window's face, or nil to follow the one speaking.
    var portraitID: Portrait.ID?
    @Environment(SpeechEngine.self) private var speech
    @Environment(FaceWindowSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var bubble = SpeechBubble()
    @State private var window: NSWindow?
    /// Set once the typing window or file picker has been used, so the app no longer quits
    /// after speaking.
    @State private var isInteractive = false
    @State private var isPickingFile = false
    @State private var hasReportedStart = false

    /// The face shown: this window's own, else the one speaking (or chosen).
    private var portrait: Portrait {
        portraitID.flatMap { id in speech.portraits.first { $0.id == id } } ?? speech.portrait
    }

    /// Whether the live speech's mouth, brows and mood belong on this face: a following window
    /// always shows them; a face's own window only when that face spoke last.
    private var isLive: Bool {
        portraitID == nil || speech.livePortrait == portraitID
    }

    var body: some View {
        VStack(spacing: 0) {
            FaceView(mouth: isLive ? speech.mouth : .rest, portrait: portrait,
                     brows: isLive ? speech.brows : 0,
                     expression: isLive ? speech.expression : .neutral,
                     presence: speech.presence(for: portrait.id),
                     pose: speech.presencePose(for: portrait.id), nodStarted: speech.nodStarted(for: portrait.id))
                .padding([.horizontal, .top], 12)
                .overlay {
                    ClickCatcher(toolTip: "Click to show or hide the speech bubble") { bubble.toggle() }
                }

            toolbar
        }
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 330, maxHeight: .infinity)
        // The face, with the voice speaking for it (none when macOS's default voice speaks).
        .navigationTitle(portrait.faceName)
        .navigationSubtitle(speech.voiceName(for: portrait) ?? "")
        .background(WindowAccessor { window in
            self.window = window
            FaceWindows.register(window, for: portrait.id, placing: portraitID != nil)
            if speech.faceRequestActivates {
                bringToFront(window)
            } else {
                window.orderFrontRegardless()
            }
            bubble.attach(to: window, content: SpeechBubbleView(bubble: bubble, portraitID: portraitID).environment(speech))
            applyAlwaysOnTop()
        })
        // A following window is found under the face it shows.
        .onChange(of: portrait.id) { _, id in
            if let window { FaceWindows.register(window, for: id, placing: false) }
        }
        .onChange(of: settings.floats) { applyAlwaysOnTop() }
        .task {
            switch options.mode {
            case .speak(let text):
                SpeechSpooler.shared.submit(SpeechRequest(source: .text(text), mood: options.mood?.rawValue))
            case .speakURL(let url):
                do {
                    let text = try await WebPage.speakableText(for: url)
                    SpeechSpooler.shared.submit(SpeechRequest(source: .text(text), mood: options.mood?.rawValue))
                } catch {
                    FileHandle.standardError.write(Data("th: can't read \(url.absoluteString): \(error.localizedDescription)\n".utf8))
                    exit(2)
                }
            case .menuBar, .face:
                break
            }
        }
        .onChange(of: speech.state) { old, new in
            // `th --report-start` (run by th-mcp) says when the voice starts.
            if options.reportsStart, !hasReportedStart, new == .speaking {
                hasReportedStart = true
                print("started")
                fflush(stdout)
            }
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
                SpeechSpooler.shared.togglePlayback(speech)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(speech.state == .idle && speech.replay == nil)
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
        window.level = settings.floats ? .floating : .normal
        bubble.matchParentLevel()
    }

    /// Speaks a text file (see `TextFile`).
    private func speak(fileAt url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            SpeechSpooler.shared.submit(SpeechRequest(source: .text(try TextFile.read(url))))
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The face windows, by face, so code outside SwiftUI (the spooler, the typing window) can find
/// the window a face is shown in.
enum FaceWindows {
    private final class Entry {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private static var entries: [Portrait.ID: Entry] = [:]
    /// Faces whose windows have been asked for but haven't appeared yet, and when.
    private static var opening: [Portrait.ID: Date] = [:]

    /// Whether to open `portrait`'s window: not when it is showing, or already on its way (asked
    /// for in the last couple of seconds). Two quick requests for one face (a link, then the
    /// speech it queues) would otherwise open two windows before the first appeared.
    static func shouldOpen(_ portrait: Portrait.ID) -> Bool {
        if window(for: portrait) != nil { return false }
        if let asked = opening[portrait], Date().timeIntervalSince(asked) < 2 { return false }
        opening[portrait] = Date()
        return true
    }

    /// Records `window` as `portrait`'s. With `placing`, the window gets back where that face was
    /// last left or, the first time, goes beside a face window already showing, with room between
    /// them for the left one's speech bubble.
    static func register(_ window: NSWindow, for portrait: Portrait.ID, placing: Bool) {
        // A window shown under another face (a `th` run's, following the voice) leaves its old one.
        entries = entries.filter { $0.value.window != nil && $0.value.window !== window }
        entries[portrait] = Entry(window)
        opening[portrait] = nil
        guard placing else { return }
        let name = "TalkingHeadFace.\(portrait)"
        let restored = window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
        if !restored, let other = visible.first(where: { $0 !== window }) {
            placeBeside(window, other)
        }
    }

    /// `portrait`'s window, if it is showing.
    static func window(for portrait: Portrait.ID) -> NSWindow? {
        entries[portrait]?.window.flatMap { $0.isVisible ? $0 : nil }
    }

    /// Every face window showing.
    static var visible: [NSWindow] {
        entries.values.compactMap(\.window).filter(\.isVisible)
    }

    /// Puts `window` level with `other`, to its right or else its left, leaving a speech bubble's
    /// width between them.
    private static func placeBeside(_ window: NSWindow, _ other: NSWindow) {
        let screen = (other.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let gap = SpeechBubble.size.width + 24
        var frame = window.frame
        frame.origin.y = other.frame.maxY - frame.height
        frame.origin.x = other.frame.maxX + gap
        if frame.maxX > screen.maxX {
            frame.origin.x = other.frame.minX - gap - frame.width
        }
        guard frame.minX >= screen.minX else { return }
        window.setFrame(frame, display: true)
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
