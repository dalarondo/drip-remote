import AppKit
import SwiftUI
import Observation
import ItsytvCore

// Command mode: a full-screen, pure-black control panel for an OLED display – a bit
// like StandBy. Only the controls are lit (thin outlines and glyphs); every other
// pixel is black, i.e. off. The controls dim further after a spell of inactivity.

extension Notification.Name {
    static let toggleCommandMode = Notification.Name("itsytv.toggleCommandMode")
}

// MARK: - OLED control style

private struct OLEDControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draw remote controls as outlines on black instead of filled shapes.
    var oledControls: Bool {
        get { self[OLEDControlsKey.self] }
        set { self[OLEDControlsKey.self] = newValue }
    }
}

/// The body of a remote control: a filled shape normally, an outline in command mode.
struct ControlBackground<S: Shape>: View {
    @Environment(\.oledControls) private var oled
    let shape: S

    var body: some View {
        if oled {
            shape.stroke(Color.white.opacity(0.28), lineWidth: 1.5)
        } else {
            shape.fill(Color(nsColor: DS.Colors.remoteButton))
        }
    }
}

// MARK: - Window

private final class CommandModeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@Observable
final class CommandModeState {
    /// Controls are dimmed after a while without input.
    var dimmed = false
}

final class CommandModeController {
    private let manager: AppleTVManager
    private let iconLoader: AppIconLoader
    private(set) var window: NSWindow?
    private let state = CommandModeState()
    private var activityMonitor: Any?
    private var idleTimer: Timer?

    /// Seconds without input before the controls dim.
    private let idleDelay: TimeInterval = 30

    /// Called when the user leaves command mode from inside it.
    var onExit: (() -> Void)?

    var isActive: Bool { window != nil }

    init(manager: AppleTVManager, iconLoader: AppIconLoader) {
        self.manager = manager
        self.iconLoader = iconLoader
    }

    /// The screen to take over: a touch display if there is one, else `preferred`.
    private func targetScreen(preferred: NSScreen?) -> NSScreen? {
        if #available(macOS 27.0, *),
           let touch = NSScreen.screens.first(where: { $0.touchCapabilities.contains(.multiTouch) }) {
            return touch
        }
        return preferred ?? NSScreen.main
    }

    func show(preferredScreen: NSScreen?) {
        guard window == nil, let screen = targetScreen(preferred: preferredScreen) else { return }

        let window = CommandModeWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Above the menu bar and Dock, so nothing but black surrounds the controls.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true

        let root = CommandModeView(state: state, topInset: screen.safeAreaInsets.top) { [weak self] in
            self?.onExit?()
        }
        .environment(manager)
        .environment(iconLoader)
        .environment(\.oledControls, true)

        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setFrame(screen.frame, display: true)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        state.dimmed = false
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .mouseMoved, .keyDown, .scrollWheel]
        ) { [weak self] event in
            if event.window === self?.window { self?.noteActivity() }
            return event
        }
        noteActivity()
    }

    func close() {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        window?.close()
        window = nil
    }

    private func noteActivity() {
        if state.dimmed { state.dimmed = false }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleDelay, repeats: false) { [weak self] _ in
            self?.state.dimmed = true
        }
    }
}

// MARK: - View

struct CommandModeView: View {
    @Environment(AppleTVManager.self) private var manager
    let state: CommandModeState
    let topInset: CGFloat
    let onExit: () -> Void

    @State private var showingKeyboard = false
    @State private var keyboardText = ""

    private var isConnected: Bool { manager.connectionStatus == .connected }

    var body: some View {
        GeometryReader { geo in
            // One unit drives every size, so the panel scales with the display.
            let unit = min(geo.size.height / 9.5, geo.size.width / 15)
            let button = unit * 1.3
            let gap = unit * 0.32

            ZStack {
                Color.black

                HStack(spacing: unit) {
                    // Left: clock and now playing
                    VStack(spacing: unit * 0.5) {
                        clock(unit: unit)
                        NowPlayingBar()
                    }
                    .frame(width: unit * 4.4)

                    // Centre: D-pad / touch surface
                    DPadView(
                        onPress: { b, action in manager.pressButton(b, action: action) },
                        size: unit * 4.8,
                        swipeEnabled: true
                    )

                    // Right: buttons
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            RemoteCircleButton(imageName: "btnBack", button: .menu, shortcut: .back, size: button) { action in
                                if action == .hold {
                                    manager.pressButton(.home)
                                } else {
                                    manager.pressButton(.menu, action: action)
                                }
                            }
                            RemoteCircleButton(imageName: "btnHome", button: .home, shortcut: .home, size: button) { action in
                                manager.pressButton(.home, action: action)
                            }
                            DictateButton(size: button)
                        }
                        HStack(spacing: gap) {
                            RemoteCircleButton(imageName: "btnPlayPause", button: .playPause, shortcut: .playPause, size: button) { action in
                                manager.pressButton(.playPause, action: action)
                            }
                            RemoteCircleButton(imageName: "btnMute", button: .siri, shortcut: .mute, size: button) { action in
                                guard action == .click else { return }
                                manager.toggleMute()
                            }
                            glyphButton("keyboard", size: button) { toggleKeyboard() }
                        }
                        VolumePill(
                            width: button * 3 + gap * 2,
                            height: button * 0.8,
                            horizontal: true,
                            onUp: { manager.pressButton(.volumeUp) },
                            onDown: { manager.pressButton(.volumeDown) }
                        )
                    }
                    .frame(width: unit * 4.4)
                }
                .opacity(isConnected ? 1 : 0.35)
                .allowsHitTesting(isConnected)

                // Corners: device name, exit
                VStack {
                    HStack {
                        Text(isConnected ? (manager.connectedDeviceName ?? "Apple TV") : "Reconnecting…")
                            .font(.system(size: unit * 0.22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        glyphButton("xmark", size: unit * 0.7, action: onExit)
                            .help("Leave command mode (⌘W)")
                    }
                    Spacer()
                    if showingKeyboard {
                        keyboardField(unit: unit)
                    }
                }
                .padding(.horizontal, unit * 0.4)
                .padding(.top, max(topInset, unit * 0.3))
                .padding(.bottom, unit * 0.5)
            }
            .opacity(state.dimmed ? 0.3 : 1)
            .animation(.easeInOut(duration: state.dimmed ? 2 : 0.2), value: state.dimmed)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .startDictation)) { _ in
            showingKeyboard = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                beginDictation(in: NSApp.keyWindow)
            }
        }
        .onChange(of: manager.keyboardToggleCounter) { _, _ in toggleKeyboard() }
    }

    private func toggleKeyboard() {
        showingKeyboard.toggle()
        if !showingKeyboard {
            keyboardText = ""
            manager.resetTextInputState()
        }
    }

    private func clock(unit: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: unit * 0.05) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: unit * 1.25, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                Text(context.date, format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: unit * 0.24, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func glyphButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.33, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(ControlBackground(shape: Circle()))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func keyboardField(unit: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.5))
            ComposeAwareTextField(
                text: $keyboardText,
                placeholder: "Type or dictate...",
                onCommittedTextChange: { manager.updateRemoteText($0) },
                onSubmit: {
                    keyboardText = ""
                    showingKeyboard = false
                    manager.resetTextInputState()
                }
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .frame(width: unit * 6)
        .background(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1.5))
    }
}
