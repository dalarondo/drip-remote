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
    /// The text field is open, so the physical keyboard is needed.
    var textEntryActive = false {
        didSet { if textEntryActive != oldValue { onTextEntryChange?() } }
    }
    @ObservationIgnored var onTextEntryChange: (() -> Void)?
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

    /// Keyboard backlight: off in command mode, back on while the keyboard is in use –
    /// the text field is open, or a key was pressed in the last few seconds.
    private let keyLightDuration: TimeInterval = 8
    private var keyLightTimer: Timer?
    private var keyRecentlyPressed = false

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
            if event.window === self?.window {
                self?.noteActivity()
                if event.type == .keyDown { self?.noteKeyPress() }
            }
            return event
        }
        noteActivity()

        state.textEntryActive = false
        state.onTextEntryChange = { [weak self] in self?.updateKeyboardBacklight() }
        keyRecentlyPressed = false
        updateKeyboardBacklight()
    }

    private func noteKeyPress() {
        keyRecentlyPressed = true
        keyLightTimer?.invalidate()
        keyLightTimer = Timer.scheduledTimer(withTimeInterval: keyLightDuration, repeats: false) { [weak self] _ in
            self?.keyRecentlyPressed = false
            self?.updateKeyboardBacklight()
        }
        updateKeyboardBacklight()
    }

    private func updateKeyboardBacklight() {
        guard window != nil, UserDefaults.standard.object(forKey: "commandModeDimKeyboard") as? Bool ?? true else {
            KeyboardBacklight.shared.restore()
            return
        }
        if state.textEntryActive || keyRecentlyPressed {
            KeyboardBacklight.shared.restore()
        } else {
            KeyboardBacklight.shared.dim()
        }
    }

    func close() {
        keyLightTimer?.invalidate()
        keyLightTimer = nil
        state.onTextEntryChange = nil
        KeyboardBacklight.shared.restore()
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
    @AppStorage("commandModeShowClock") private var showClock = true
    @AppStorage("commandModeRed") private var redOnBlack = false

    private var isConnected: Bool { manager.connectionStatus == .connected }

    var body: some View {
        GeometryReader { geo in
            // One unit drives every size, so the panel scales with the display.
            let unit = min(geo.size.height / 10.5, geo.size.width / 13)
            let gap = unit * 0.32

            ZStack {
                Color.black

                VStack(spacing: unit * 0.5) {
                    // Top: time, with the device name and exit in the corners
                    ZStack {
                        // Tap the time to hide it (more pixels off); tap the same spot to bring it back.
                        ZStack {
                            clock(unit: unit)
                                .opacity(showClock ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { showClock.toggle() }
                        }
                        HStack(alignment: .top) {
                            Text(isConnected ? (manager.connectedDeviceName ?? "Apple TV") : "Reconnecting…")
                                .font(.system(size: unit * 0.22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                            Spacer()
                            glyphButton("xmark", size: unit * 0.7, action: onExit)
                                .help("Leave command mode (⌘W)")
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    // Middle: square D-pad fills the left half, pill buttons fill the right half
                    HStack(spacing: unit * 0.6) {
                        GeometryReader { half in
                            DPadView(
                                onPress: { b, action in manager.pressButton(b, action: action) },
                                size: half.size.width,
                                swipeEnabled: true,
                                height: half.size.height
                            )
                        }

                        GeometryReader { half in
                            // Three columns, three rows, sized to fill the half.
                            let pillW = (half.size.width - gap * 2) / 3
                            let pillH = (half.size.height - gap * 2) / 3

                            VStack(spacing: gap) {
                                HStack(spacing: gap) {
                                    RemoteCircleButton(imageName: "btnBack", button: .menu, shortcut: .back, size: pillH, width: pillW) { action in
                                        if action == .hold {
                                            manager.pressButton(.home)
                                        } else {
                                            manager.pressButton(.menu, action: action)
                                        }
                                    }
                                    RemoteCircleButton(imageName: "btnHome", button: .home, shortcut: .home, size: pillH, width: pillW) { action in
                                        manager.pressButton(.home, action: action)
                                    }
                                    DictateButton(size: pillH, width: pillW)
                                }
                                HStack(spacing: gap) {
                                    RemoteCircleButton(imageName: "btnPlayPause", button: .playPause, shortcut: .playPause, size: pillH, width: pillW) { action in
                                        manager.pressButton(.playPause, action: action)
                                    }
                                    RemoteCircleButton(imageName: "btnMute", button: .siri, shortcut: .mute, size: pillH, width: pillW) { action in
                                        guard action == .click else { return }
                                        manager.toggleMute()
                                    }
                                    glyphButton("keyboard", size: pillH, width: pillW) { toggleKeyboard() }
                                }
                                VolumePill(
                                    width: half.size.width,
                                    height: pillH,
                                    horizontal: true,
                                    onUp: { manager.pressButton(.volumeUp) },
                                    onDown: { manager.pressButton(.volumeDown) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, unit * 0.4)
                    .frame(maxHeight: .infinity)
                    .opacity(isConnected ? 1 : 0.35)
                    .allowsHitTesting(isConnected)

                    // Bottom: now playing, or the text field while typing / dictating
                    if showingKeyboard {
                        keyboardField(unit: unit)
                            .padding(.bottom, unit * 0.5)
                    } else {
                        NowPlayingBar()
                            .frame(width: min(geo.size.width * 0.6, unit * 8))
                            .opacity(isConnected ? 1 : 0.35)
                    }
                }
                .padding(.horizontal, unit * 0.4)
                .padding(.top, max(topInset, unit * 0.3))
                .padding(.bottom, unit * 0.2)
            }
            // Night colours: multiplying turns every white / grey pixel red and leaves black black.
            .colorMultiply(redOnBlack ? Color(red: 1, green: 0.12, blue: 0.08) : .white)
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
        .onChange(of: showingKeyboard) { _, showing in state.textEntryActive = showing }
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

    private func glyphButton(_ symbol: String, size: CGFloat, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.33, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: width ?? size, height: size)
                .background(ControlBackground(shape: Capsule()))
                .contentShape(Capsule())
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
