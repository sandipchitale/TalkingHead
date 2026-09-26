import AppKit
import ServiceManagement
import SwiftUI

/// A menu bar applet (no Dock icon or app menu, see `LSUIElement`). The menu bar item opens
/// the talking head and the typing window, plays and pauses, and picks the voice.
@main
struct TalkingHeadApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let options = LaunchOptions.launch
    /// Shared by the menu, the face window, its speech bubble and the typing window.
    @State private var speech: SpeechEngine
    @State private var faceSettings = FaceWindowSettings(options: LaunchOptions.launch)
    /// Only the applet started from Finder (or at login) shows the menu bar item; `th` runs
    /// don't add a second one.
    @State private var showsMenuBarItem = !LaunchOptions.launch.isCommandLine

    init() {
        let speech = SpeechEngine()
        speech.portraitID = LaunchOptions.launch.portrait.id
        _speech = State(initialValue: speech)
        ExternalRequests.shared = ExternalRequests(speech: speech)
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
                NSApp.activate()
            }
    }
}

/// The menu shown from the menu bar item.
struct MenuBarMenu: View {
    @Environment(SpeechEngine.self) private var speech
    @Environment(FaceWindowSettings.self) private var faceSettings
    @Environment(\.openWindow) private var openWindow
    @State private var launchesAtLogin = MenuBarMenu.isLoginItem

    var body: some View {
        @Bindable var speech = speech
        @Bindable var faceSettings = faceSettings

        Button("Show Talking Head") { show(FaceWindow.id) }
        Button("Type Text to Speak…") { show(InputWindow.id) }

        Divider()

        Button(speech.state == .speaking ? "Pause" : "Play") { speech.togglePlayback() }
            .disabled(speech.state == .idle && speech.spokenText.isEmpty)
        Button("Stop") { speech.stop() }
            .disabled(speech.state == .idle)

        Divider()

        Picker("Voice", selection: $speech.portraitID) {
            Text("Male (Daniel)").tag(Portrait.man.id)
            Text("Female (Samantha)").tag(Portrait.woman.id)
        }
        .pickerStyle(.inline)
        .disabled(speech.state != .idle)

        Picker("Speed", selection: $speech.rate) {
            ForEach(SpeechEngine.rates, id: \.rate) { option in
                Text(option.name).tag(option.rate)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Toggle("Always on Top", isOn: $faceSettings.isAlwaysOnTop)
        Toggle("Launch at Login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))

        Button("Quit Talking Head") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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
        }
    }

    /// A `th` run ends when its windows are closed, returning the terminal; started from
    /// Finder, the applet stays in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        LaunchOptions.launch.isCommandLine
    }
}
