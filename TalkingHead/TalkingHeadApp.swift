import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// A menu bar applet (no Dock icon or app menu, see `LSUIElement`). The menu bar item opens
/// the talking head and the typing window, plays and pauses, and picks the voice. (Started by
/// `Entry`, which first lets a `th` run hand its speech to a running applet.)
struct TalkingHeadApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let options = LaunchOptions.launch
    /// Shared by the menu, the face window, its speech bubble and the typing window.
    @State private var speech: SpeechEngine
    @State private var faceSettings: FaceWindowSettings
    /// Only the applet started from Finder (or at login) shows the menu bar item; `th` runs
    /// don't add a second one.
    @State private var showsMenuBarItem = !LaunchOptions.launch.isCommandLine

    init() {
        let speech = SpeechEngine()
        if LaunchOptions.launch.isCommandLine {
            speech.portraitID = LaunchOptions.launch.portrait.id
        } else {
            // The applet remembers the voice chosen in its menu (`th-mcp` reads it too).
            if let saved = UserDefaults.standard.string(forKey: SavedVoice.key) {
                speech.portraitID = SpeechEngine.portraitID(forVoice: saved)
            }
            speech.savesVoice = true
        }
        let faceSettings = FaceWindowSettings(options: LaunchOptions.launch)
        _speech = State(initialValue: speech)
        _faceSettings = State(initialValue: faceSettings)
        let spooler = SpeechSpooler(performer: FacePerformer(speech: speech, settings: faceSettings))
        SpeechSpooler.shared = spooler
        ExternalRequests.shared = ExternalRequests(speech: speech, spooler: spooler)
        // Only the menu bar applet serves MCP over HTTP and the spooler's socket; a `th` run
        // never opens either.
        if !LaunchOptions.launch.isCommandLine {
            MCPServerController.shared = MCPServerController(spooler: spooler)
            AppDelegate.spoolerServer = SpoolerServer(spooler: spooler)
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuBarMenu()
                .environment(speech)
                .environment(faceSettings)
        } label: {
            MenuBarLabel()
                .environment(speech)
        }

        Window("Talking Head", id: FaceWindow.id) {
            FaceWindow(options: options)
                .environment(speech)
                .environment(faceSettings)
        }
        .defaultSize(width: 420, height: 500)
        .defaultLaunchBehavior(options.isCommandLine ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            // ⌘Q with a window in front closes that window instead of quitting: the applet
            // stays in the menu bar, and only its menu's Quit Talking Head ends it. (A `th` run
            // still ends when its last window closes.)
            CommandGroup(replacing: .appTermination) {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("q")
            }
        }

        Window("Type to Speak", id: InputWindow.id) {
            InputWindow()
                .environment(speech)
        }
        .defaultSize(width: 520, height: 280)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
    }
}

/// The menu bar icon. It stays alive while the applet runs, so it also opens the face window
/// when other apps send text to speak (`SpeechEngine.requestFace()`).
struct MenuBarLabel: View {
    @Environment(SpeechEngine.self) private var speech
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: speech.state == .speaking ? "person.wave.2.fill" : "person.wave.2")
            // `initial` covers a request made while launching (e.g. by a talkinghead:// URL),
            // before this view existed.
            .onChange(of: speech.faceRequests, initial: true) {
                guard speech.faceRequests > 0 else { return }
                openWindow(id: FaceWindow.id)
                // Presence opens the face quietly, leaving the keyboard where it is.
                if speech.faceRequestActivates { NSApp.activate() }
            }
    }
}

/// The menu shown from the menu bar item.
struct MenuBarMenu: View {
    @Environment(SpeechEngine.self) private var speech
    @Environment(FaceWindowSettings.self) private var faceSettings
    @Environment(\.openWindow) private var openWindow
    @State private var launchesAtLogin = MenuBarMenu.isLoginItem

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        @Bindable var speech = speech
        @Bindable var faceSettings = faceSettings

        // The app's name and version, as a heading.
        Text("Talking Head \(Self.version)")
        Divider()

        Button("Show Talking Head") { show(FaceWindow.id) }
        Button("Type Text to Speak…") { show(InputWindow.id) }

        Divider()

        Button(speech.state == .speaking ? "Pause" : "Play") { SpeechSpooler.shared.togglePlayback(speech) }
            .disabled(speech.state == .idle && speech.replay == nil)
        // Silence: ends the speech and clears the queue, whoever queued it.
        Button("Stop") { SpeechSpooler.shared.stopAll() }
            .disabled(speech.state == .idle)

        Divider()

        Picker("Voice", selection: $speech.portraitID) {
            Text(faceLabel(.man)).tag(Portrait.man.id)
            Text(faceLabel(.woman)).tag(Portrait.woman.id)
        }
        .pickerStyle(.inline)
        .disabled(speech.state != .idle)
        voiceMenu("Man's Voice", for: .man)
        voiceMenu("Woman's Voice", for: .woman)

        Picker("Speed", selection: $speech.rate) {
            ForEach(SpeechEngine.rates, id: \.rate) { option in
                Text(option.name).tag(option.rate)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Toggle("Always on Top", isOn: $faceSettings.isAlwaysOnTop)
        Toggle("Launch at Login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))
        if let mcp = MCPServerController.shared {
            Toggle("MCP Server (port \(String(mcp.port)))", isOn: Binding(get: { mcp.isRunning }, set: mcp.setEnabled))
            Button("MCP Server Config…") { MCPConfigWindowController.show() }
        }

        Button("Quit Talking Head") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Woman (Ava)": the face, and the voice it speaks with.
    private func faceLabel(_ portrait: Portrait) -> String {
        speech.voiceName(for: portrait).map { "\(portrait.faceName) (\($0))" } ?? portrait.faceName
    }

    /// Chooses the voice a face speaks with: its own (Daniel or Samantha, at the best installed
    /// quality) or an installed English voice of its gender, best quality first. Better voices are downloaded
    /// in System Settings → Accessibility → Read & Speak.
    private func voiceMenu(_ title: String, for portrait: Portrait) -> some View {
        let choice = Binding<String?>(
            get: { speech.chosenVoices[portrait.id] },
            set: { speech.choose(voice: $0, for: portrait.id) })
        return Menu(title) {
            Picker(title, selection: choice) {
                Text("\(portrait.voiceName) (the face's own voice)").tag(String?.none)
                Divider()
                ForEach(SpeechEngine.choosableVoices(for: portrait), id: \.identifier) { voice in
                    Text(voice.name).tag(String?.some(voice.identifier))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// Registered as a login item, including when macOS is still waiting for the user to
    /// approve it in System Settings.
    private static var isLoginItem: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    /// Registers or unregisters the app as a login item, so it is in the menu bar after every
    /// login. If macOS needs the user's approval, it opens the Login Items settings.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at Login: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        launchesAtLogin = Self.isLoginItem
    }

    /// Opens a window and brings it to the front: an applet isn't active by default, and
    /// clicks on an inactive app's window would only activate it.
    private func show(_ id: String) {
        openWindow(id: id)
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }?.makeKeyAndOrderFront(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The applet's spooler socket, for `th` and `th-mcp`.
    static var spoolerServer: SpoolerServer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so a talkinghead:// URL that launched the app is received.
        ExternalRequests.shared?.registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchOptions.launch.isCommandLine {
            // When started from a terminal, bring the talking head to the front.
            NSApp.activate()
        } else {
            // The "Speak with Talking Head" service (see NSServices in Info.plist).
            NSApp.servicesProvider = ExternalRequests.shared
            NSUpdateDynamicServices()
            MCPServerController.shared?.startAtLaunch()
            do {
                try Self.spoolerServer?.start()
            } catch {
                // Another applet already serves it; this one speaks only its own requests.
                NSLog("Talking Head speech spooler not started: \(error)")
                Self.spoolerServer = nil
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPServerController.shared?.stop()
        Self.spoolerServer?.stop()
    }

    /// A `th` run ends when its windows are closed, returning the terminal; started from
    /// Finder, the applet stays in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        LaunchOptions.launch.isCommandLine
    }
}
