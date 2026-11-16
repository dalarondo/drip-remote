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
    /// Set when leaving, so the controls morph back to their round shapes first.
    var leaving = false
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

    private let cursorHideDelay: TimeInterval = 3
    private var cursorTimer: Timer?

    /// Above everything, including notification banners, so no alert shows over the panel.
    private static let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    /// Just above the menu bar and Dock; used while typing so the dictation / input UI can show.
    private static let typingLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    /// Keeps the display (and so the Mac) awake while command mode is up.
    private var awakeActivity: NSObjectProtocol?
    private var isLeaving = false

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
        window.level = Self.shieldLevel
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
        // Lets us tell a finger from the pointer, to keep the cursor hidden for touch.
        TouchMode.shared.attachSniffer(to: hosting)
        window.setFrame(screen.frame, display: true)

        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
        self.window = window

        state.dimmed = false
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown, .scrollWheel]
        ) { [weak self] event in
            if event.window === self?.window {
                self?.noteActivity()
                self?.updateCursor(for: event)
                if event.type == .keyDown { self?.noteKeyPress() }
            }
            return event
        }
        noteActivity()

        isLeaving = false
        state.leaving = false
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Command mode control panel is on screen"
        )

        state.textEntryActive = false
        state.onTextEntryChange = { [weak self] in
            guard let self else { return }
            self.updateKeyboardBacklight()
            // Drop below system input UI while typing; back to the shield level afterwards.
            self.window?.level = self.state.textEntryActive ? Self.typingLevel : Self.shieldLevel
        }
        keyRecentlyPressed = false
        updateKeyboardBacklight()

        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// The cursor is hidden in command mode. Moving a real mouse / trackpad shows it,
    /// and it hides again after a few seconds still. Touches never show it.
    private func updateCursor(for event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            cursorTimer?.invalidate()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: cursorHideDelay, repeats: false) { _ in
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if TouchMode.shared.touchDetected { NSCursor.setHiddenUntilMouseMoves(true) }
        default:
            break
        }
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

    /// Leave with the reverse morph: controls shrink back to round, then the black fades out.
    func animateOut(completion: @escaping () -> Void) {
        guard let window, !isLeaving else { return }
        isLeaving = true
        state.dimmed = false
        state.leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                self?.close()
                completion()
            })
        }
    }

    func close() {
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        isLeaving = false
        cursorTimer?.invalidate()
        cursorTimer = nil
        NSCursor.setHiddenUntilMouseMoves(false)
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
    @State private var morphed = false
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
                            if !isConnected {
                                Text("Reconnecting…")
                                    .font(.system(size: unit * 0.22, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
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
                            // Starts as the remote's round pad, then grows into the square.
                            let round = min(half.size.width, half.size.height) * 0.62
                            let full = min(half.size.width, half.size.height)
                            DPadView(
                                onPress: { b, action in manager.pressButton(b, action: action) },
                                size: morphed ? half.size.width : round,
                                swipeEnabled: true,
                                height: morphed ? half.size.height : round,
                                cornerRadius: morphed ? full * 0.12 : round / 2
                            )
                            .frame(width: half.size.width, height: half.size.height)
                        }

                        GeometryReader { half in
                            // Three columns, three rows, sized to fill the half.
                            // Starts as round buttons, then stretches into pills.
                            let fullW = (half.size.width - gap * 2) / 3
                            let fullH = (half.size.height - gap * 2) / 3
                            let round = min(fullW, fullH) * 0.7
                            let pillW = morphed ? fullW : round
                            let pillH = morphed ? fullH : round

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
                                    width: morphed ? half.size.width : round * 3 + gap * 2,
                                    height: pillH,
                                    horizontal: true,
                                    onUp: { manager.pressButton(.volumeUp) },
                                    onDown: { manager.pressButton(.volumeDown) }
                                )
                            }
                            .frame(width: half.size.width, height: half.size.height)
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
        .onAppear {
            // Morph from the remote's round controls into the square pad and pills.
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.25)) { morphed = true }
        }
        .onChange(of: showingKeyboard) { _, showing in state.textEntryActive = showing }
        .onChange(of: state.leaving) { _, leaving in
            guard leaving else { return }
            showingKeyboard = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { morphed = false }
        }
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
