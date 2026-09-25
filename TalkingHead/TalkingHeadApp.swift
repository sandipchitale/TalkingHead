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
    /// Only the applet started from Finder (or at login) shows the menu bar item; `th` runs
    /// don't add a second one.
    @State private var showsMenuBarItem = !LaunchOptions.launch.isCommandLine

    init() {
        let speech = SpeechEngine()
        speech.portraitID = LaunchOptions.launch.portrait.id
        _speech = State(initialValue: speech)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuBarMenu()
                .environment(speech)
        } label: {
            Image(systemName: speech.state == .speaking ? "person.wave.2.fill" : "person.wave.2")
        }

        Window("Talking Head", id: FaceWindow.id) {
            FaceWindow(options: options)
                .environment(speech)
        }
        .defaultSize(width: 420, height: 500)
        .defaultLaunchBehavior(options.isCommandLine ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)

        Window("Type to Speak", id: InputWindow.id) {
            InputWindow(initialText: LaunchOptions.defaultText)
                .environment(speech)
        }
        .defaultSize(width: 520, height: 280)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
    }
}

/// The menu shown from the menu bar item.
struct MenuBarMenu: View {
    @Environment(SpeechEngine.self) private var speech
    @Environment(\.openWindow) private var openWindow
    @State private var launchesAtLogin = MenuBarMenu.isLoginItem

    var body: some View {
        @Bindable var speech = speech

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When started from a terminal, bring the talking head to the front.
        if LaunchOptions.launch.isCommandLine {
            NSApp.activate()
        }
    }

    /// A `th` run ends when its windows are closed, returning the terminal; started from
    /// Finder, the applet stays in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        LaunchOptions.launch.isCommandLine
    }
}
