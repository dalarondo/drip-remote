import AppKit
import SwiftUI
import ServiceManagement
import ItsytvCore

extension Notification.Name {
    /// Ask the app to open Settings (it steps out of command center first if needed).
    static let openSettings = Notification.Name("dripremote.openSettings")
}

/// The Settings window. One place for every preference, reachable from the menu bar
/// menu, the island widget, command center and the remote's ⋯ menu.
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        guard let manager = AppDelegate.shared?.manager else { return }
        let window = self.window ?? makeWindow(manager: manager)
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(manager: AppleTVManager) -> NSWindow {
        let hostingView = NSHostingView(rootView: SettingsView().environment(manager))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        // The remote and the island widget float at status-bar level; stay above them.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        return window
    }
}

struct SettingsView: View {
    @Environment(AppleTVManager.self) private var manager

    // Interface
    @AppStorage("openInCommandCenter") private var openInCommandCenter = true

    // Command center
    @AppStorage("commandModeRed") private var redOnBlack = false
    @AppStorage(CommandTopDisplay.defaultsKey) private var topDisplay = CommandTopDisplay.time.rawValue
    @AppStorage("commandModeBannerText") private var bannerText = ""
    @AppStorage("commandModeDimKeyboard") private var dimKeyboard = true
    @AppStorage("commandModeClap") private var clap = false
    @AppStorage("commandModeGestures") private var gestures = false

    // Remote
    @AppStorage("showShortcutHints") private var showShortcutHints = false
    @AppStorage("showAppsSearch") private var showAppsSearch = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("showArtwork") private var showArtwork = true
    @AppStorage(TouchLayoutPreference.defaultsKey) private var touchLayout = TouchLayoutPreference.auto.rawValue

    // General
    @AppStorage(DockIcon.key) private var showInDock = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pairedIDs = KeychainStorage.allPairedDeviceIDs()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open in command center", isOn: $openInCommandCenter)
            } header: {
                Text("Interface")
            } footer: {
                Text("On: connecting opens the full-screen command center, which retracts into the island. Off: the classic small remote under the menu bar icon. Applies the next time you connect.")
            }

            Section {
                Toggle("Red on black", isOn: $redOnBlack)
                Picker("Top of the screen shows", selection: $topDisplay) {
                    ForEach(CommandTopDisplay.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                TextField("Banner text", text: $bannerText, prompt: Text("Shown when you tap the time away"))
                Toggle("Dim the keyboard backlight", isOn: $dimKeyboard)
                Toggle("Double clap to play or pause", isOn: $clap)
                Toggle("Hand gestures", isOn: $gestures)
            } header: {
                Text("Command center")
            } footer: {
                Text("Double clap uses the microphone. Hand gestures use the camera: a raised palm or a wave to the left pauses, a thumbs-up or a wave to the right plays. Both only run while command center is open, are analysed on this Mac, and are never recorded.")
            }

            Section {
                Toggle("Show shortcut hints on the buttons", isOn: $showShortcutHints)
                Toggle("Show app search", isOn: $showAppsSearch)
                Button("Keyboard shortcuts…") {
                    ShortcutsWindow.show(beside: NSApp.keyWindow)
                }
            } header: {
                Text("Remote")
            }

            Section {
                Toggle("Always on top", isOn: $alwaysOnTop)
                Toggle("Show artwork", isOn: $showArtwork)
                Picker("Touch layout", selection: $touchLayout) {
                    ForEach(TouchLayoutPreference.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            } header: {
                Text("Classic remote")
            } footer: {
                Text("These apply to the classic small remote only (\"Open in command center\" off).")
            }
            .disabled(openInCommandCenter)

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockIcon.apply() }
            }

            Section("Paired devices") {
                if pairedIDs.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pairedIDs, id: \.self) { id in
                        HStack {
                            Image(systemName: "appletv.fill")
                            if let name = manager.discoveredDevices.first(where: { $0.id == id })?.name {
                                Text(name)
                            } else {
                                Text("Apple TV")
                                Text("not on the network")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // As the remote's own Unpair: forget the pairing, drop the connection.
                            Button("Unpair") {
                                KeychainStorage.delete(for: id)
                                if manager.connectedDeviceID == id { manager.disconnect() }
                                pairedIDs = KeychainStorage.allPairedDeviceIDs()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: version)
                Text("Based on Itsytv by Nick Ustinov, used under the MIT licence. Apple TV protocol work informed by pyatv.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onAppear { pairedIDs = KeychainStorage.allPairedDeviceIDs() }
    }
}
