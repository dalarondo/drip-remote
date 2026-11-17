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

/// What the top of command mode shows. Tapping it cycles through these.
enum CommandTopDisplay: String, CaseIterable {
    case time = "Time"
    case banner = "Banner"
    case nothing = "Nothing"

    static let defaultsKey = "commandModeTopDisplay"

    func next(hasBanner: Bool) -> CommandTopDisplay {
        switch self {
        case .time: hasBanner ? .banner : .nothing
        case .banner: .nothing
        case .nothing: .time
        }
    }
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

/// The visible region of command center, animated by `progress` (0 → 1) as a drip:
///
/// 1. **Swell** (0 – 0.35): a drop of black gathers under the island and hangs from it
///    by a thinning neck.
/// 2. **Fall** (0.35 – 0.55): the drop lets go and falls, speeding up, to the middle of
///    the screen while the neck snaps back into the island.
/// 3. **Splash and flood** (0.55 – 1): it lands squashed, throws up droplets, and spreads
///    outward with a rippling edge until it covers the screen.
///
/// Run backwards, the black gathers into a drop and is drawn back up into the island.
struct IslandReveal: Shape {
    let island: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let swellEnd: CGFloat = 0.32
    private static let fallEnd: CGFloat = 0.45

    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        if p >= 0.999 { return Path(rect) }

        var path = Path()
        // The island itself is always part of the shape (black on black – invisible).
        path.addRoundedRect(in: island, cornerSize: CGSize(width: island.height / 2, height: island.height / 2))
        guard p > 0 else { return path }

        let cx = island.midX
        let dropRadius = max(64, island.width * 1.2)
        let hangY = island.midY + dropRadius * 2.0          // where the drop hangs before letting go
        let landY = rect.height * 0.5                        // where it lands

        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func easeOut(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }
        func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

        if p < Self.swellEnd {
            // 1. Swell: the drop grows and sinks, joined to the island by a pinching neck.
            //    It wobbles as it hangs – breathing wide / tall and swaying slightly.
            let t = p / Self.swellEnd
            let e = easeOut(t)
            let wobble = sin(t * .pi * 5) * (1 - t * 0.4)
            let radius = lerp(island.height * 0.4, dropRadius, e)
            let rx = radius * (1 + 0.10 * wobble), ry = radius * (1 - 0.10 * wobble)
            let sway = sin(t * .pi * 3) * 2.5 * e
            let centreY = lerp(island.midY, hangY, e) + wobble * 3 * e
            let topHalf = lerp(island.width * 0.45, island.width * 0.2, e)   // neck width at the island
            let pinch = lerp(topHalf, 5, e)                                  // …and at its thinnest
            let midY = (island.midY + centreY) / 2
            path.move(to: CGPoint(x: cx - topHalf, y: island.midY))
            path.addQuadCurve(to: CGPoint(x: cx + sway - rx * 0.7, y: centreY), control: CGPoint(x: cx + sway * 0.5 - pinch, y: midY))
            path.addLine(to: CGPoint(x: cx + sway + rx * 0.7, y: centreY))
            path.addQuadCurve(to: CGPoint(x: cx + topHalf, y: island.midY), control: CGPoint(x: cx + sway * 0.5 + pinch, y: midY))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: cx + sway - rx, y: centreY - ry, width: rx * 2, height: ry * 2))
        } else if p < Self.fallEnd {
            // 2. Fall: gravity (t²), with the drop stretching a little as it speeds up.
            let t = (p - Self.swellEnd) / (Self.fallEnd - Self.swellEnd)
            let centreY = lerp(hangY, landY, t * t)
            let stretch = 1 + 0.5 * t
            let w = dropRadius / sqrt(stretch), h = dropRadius * stretch
            path.addEllipse(in: CGRect(x: cx - w, y: centreY - h, width: w * 2, height: h * 2))
            // What's left of the neck snaps back up into the island, with a little bounce.
            let snap = min(1, t * 2.2)
            let stub = lerp(dropRadius * 0.9, 0, snap) * (1 + 0.3 * sin(snap * .pi * 3))
            if stub > 0.5 {
                path.addEllipse(in: CGRect(x: cx - island.width * 0.2, y: island.midY,
                                           width: island.width * 0.4, height: stub))
            }
        } else {
            // 3. Splash and flood.
            let c = (p - Self.fallEnd) / (1 - Self.fallEnd)
            let e = easeInOut(c)
            let reach = hypot(max(cx, rect.width - cx), max(landY, rect.height - landY)) + 8
            let radius = lerp(dropRadius, reach, e)

            // The blob's edge ripples – big lobes right after impact, settling to a clean
            // circle as it spreads – and it lands squashed flat before rounding out.
            let ripple = 0.38 * pow(1 - c, 1.3)
            let squash = lerp(0.4, 1, min(1, c * 3))
            let spin = c * 2.2
            let steps = 96
            for i in 0...steps {
                let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let r = radius * (1 + ripple * sin(7 * angle + spin) + ripple * 0.5 * sin(11 * angle - spin * 1.7))
                let point = CGPoint(x: cx + cos(angle) * r, y: landY + sin(angle) * r * squash)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()

            // Droplets thrown up and out by the impact, falling back under gravity and
            // shrinking away (the flood overtakes most of them).
            let life = min(1, c / 0.7)
            if life < 1 {
                // A crown of droplets, in two rings: big slow ones and small fast ones.
                let count = 18
                for i in 0..<count {
                    let f = CGFloat(i) / CGFloat(count - 1)
                    let fast = i % 2 == 1
                    let angle = lerp(-.pi * 0.96, -.pi * 0.04, f)               // an upward fan
                    let speed = rect.height * (fast ? 0.95 : 0.6) * (0.8 + 0.3 * abs(sin(CGFloat(i) * 2.4)))
                    let x = cx + cos(angle) * speed * life
                    let y = landY + sin(angle) * speed * life + rect.height * 0.75 * life * life
                    let size = (fast ? 9 : 20) * (0.7 + 0.5 * abs(sin(CGFloat(i) * 1.7))) * (1 - life * life)
                    if size > 0.5 {
                        path.addEllipse(in: CGRect(x: x - size, y: y - size, width: size * 2, height: size * 2))
                    }
                }
                // The rebound: a column of liquid thrown straight back up from the impact,
                // rising and collapsing, with a bead pinching off its tip.
                let rise = sin(.pi * life)
                let columnH = dropRadius * 3.2 * rise
                let columnW = dropRadius * 0.55 * (1 - life * 0.5)
                if columnH > 1 {
                    path.addEllipse(in: CGRect(x: cx - columnW / 2, y: landY - columnH, width: columnW, height: columnH))
                    let bead = dropRadius * 0.3 * rise
                    path.addEllipse(in: CGRect(x: cx - bead, y: landY - columnH - bead * 1.6, width: bead * 2, height: bead * 2))
                }
            }
        }
        return path
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
    /// The panel has expanded out of the island (false = collapsed into it).
    var revealed = false
    /// The apps page is showing instead of the controls.
    var showingApps = false
    /// The full-screen playback page is showing.
    var showingPlayback = false
    /// Set when leaving, so the controls morph back to their round shapes first.
    var leaving = false
}

final class CommandModeController: NSObject, NSGestureRecognizerDelegate {
    private let manager: AppleTVManager
    private let iconLoader: AppIconLoader
    private(set) var window: NSWindow?
    /// The screen command center last opened on (the island widget lives there too).
    private(set) var lastScreen: NSScreen?
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

    private var swipeStart: (point: NSPoint, time: TimeInterval)?

    /// Double clap → play / pause, while command mode is open (opt-in setting).
    private let clapDetector = ClapDetector()
    /// Raised palm → pause, thumbs-up → play, seen by the camera (opt-in setting).
    private let gestureDetector = HandGestureDetector()

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
        super.init()
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
        // Transparent: the black panel is drawn by the view, so it can grow out of the island.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = Self.shieldLevel
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true

        let root = CommandModeView(state: state, topInset: screen.safeAreaInsets.top,
                                   island: Self.islandRect(on: screen)) { [weak self] in
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
        // Page swipes. Touches on a touch display reach gesture recognizers only – not
        // event monitors – so the long swipe needs a recognizer, not just the monitor below.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        pan.delegate = self
        pan.delaysPrimaryMouseButtonEvents = false
        hosting.addGestureRecognizer(pan)
        window.setFrame(screen.frame, display: true)

        // Pinch in (two fingers, or the trackpad) shrinks back to the small remote.
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        hosting.addGestureRecognizer(pinch)

        NSApp.activate(ignoringOtherApps: true)
        state.revealed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // The view starts the drip itself once it has drawn collapsed (see its onAppear),
        // so the animation plays every time rather than racing the first frame.
        lastScreen = screen

        state.dimmed = false
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown, .scrollWheel]
        ) { [weak self] event in
            if event.window === self?.window {
                self?.noteActivity()
                self?.updateCursor(for: event)
                self?.trackPageSwipe(event)
                if event.type == .keyDown { self?.noteKeyPress() }
            }
            return event
        }
        noteActivity()

        isLeaving = false
        state.leaving = false
        state.showingApps = false
        state.showingPlayback = false
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

        if UserDefaults.standard.bool(forKey: "commandModeClap") {
            clapDetector.onDoubleClap = { [weak self] in
                guard let self, self.window != nil, self.manager.connectionStatus == .connected else { return }
                self.manager.pressButton(.playPause)
                self.noteActivity()
            }
            clapDetector.start()
        }

        if UserDefaults.standard.bool(forKey: "commandModeGestures") {
            gestureDetector.onGesture = { [weak self] gesture in self?.handle(gesture) }
            gestureDetector.start()
        }
    }

    /// Palm only pauses and thumbs-up only plays when the Apple TV reports its state;
    /// if the state is unknown, either gesture is a plain play / pause toggle.
    private func handle(_ gesture: HandGestureDetector.Gesture) {
        guard window != nil, manager.connectionStatus == .connected else { return }
        noteActivity()
        if let playing = manager.mrpManager.nowPlaying?.isPlaying {
            guard playing != gesture.wantsPlaying else { return }
        }
        manager.pressButton(.playPause)
    }

    private func startsOnDPad(windowPoint: NSPoint) -> Bool {
        guard let hit = window?.contentView?.hitTest(windowPoint) else { return false }
        return String(describing: type(of: hit)).contains("DPadTouchSurface")
    }

    private func turnPage(dx: CGFloat, dy: CGFloat, width: CGFloat) {
        guard abs(dx) > width * 0.25, abs(dy) < abs(dx) * 0.5, !state.showingPlayback else { return }
        if dx < 0, !state.showingApps, !state.textEntryActive {
            state.showingApps = true
        } else if dx > 0, state.showingApps {
            state.showingApps = false
        }
    }

    @objc private func handlePagePan(_ pan: NSPanGestureRecognizer) {
        guard pan.state == .ended, let view = pan.view else { return }
        let t = pan.translation(in: view)
        turnPage(dx: t.x, dy: t.y, width: view.bounds.width)
    }

    // Swipes that begin on the D-pad belong to the Apple TV, not to paging.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        !startsOnDPad(windowPoint: touch.location(in: nil))
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        !startsOnDPad(windowPoint: event.locationInWindow)
    }

    // Never block the controls' own gestures.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        true
    }

    /// A long, mostly horizontal swipe turns the page: left shows the apps, right goes back.
    /// Swipes that start on the D-pad are left alone – those belong to the Apple TV.
    private func trackPageSwipe(_ event: NSEvent) {
        guard let window, let content = window.contentView else { return }
        switch event.type {
        case .leftMouseDown:
            swipeStart = startsOnDPad(windowPoint: event.locationInWindow) ? nil : (event.locationInWindow, event.timestamp)
        case .leftMouseUp:
            guard let start = swipeStart else { return }
            swipeStart = nil
            guard event.timestamp - start.time < 1.5 else { return }
            turnPage(dx: event.locationInWindow.x - start.point.x,
                     dy: event.locationInWindow.y - start.point.y,
                     width: content.bounds.width)
        default:
            break
        }
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
        _ = window
        // Controls morph back to round, then the panel retreats into the island.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.state.revealed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                self?.close()
                completion()
            }
        }
    }

    @objc private func handlePinch(_ pinch: NSMagnificationGestureRecognizer) {
        guard !isLeaving, pinch.state == .changed || pinch.state == .ended else { return }
        if pinch.magnification < -0.25 { onExit?() }
    }

    /// Where the camera island (or notch) sits, in top-left-origin screen coordinates:
    /// the gap between the two usable strips either side of it. On a screen without
    /// one, a small pill at the top centre stands in.
    static func islandRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX, screen.safeAreaInsets.top > 0 {
            let height = screen.safeAreaInsets.top
            return CGRect(x: left.maxX - frame.minX, y: 0, width: right.minX - left.maxX, height: height)
        }
        return CGRect(x: frame.width / 2 - 60, y: 6, width: 120, height: 30)
    }

    func close() {
        clapDetector.shutDown()
        gestureDetector.shutDown()
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
    @Environment(AppIconLoader.self) private var iconLoader
    let state: CommandModeState
    let topInset: CGFloat
    /// The camera island's rect in this view's coordinates; the panel grows out of it.
    let island: CGRect
    let onExit: () -> Void

    @State private var showingKeyboard = false
    @State private var keyboardText = ""
    @AppStorage(CommandTopDisplay.defaultsKey) private var topDisplayRaw = CommandTopDisplay.time.rawValue
    @AppStorage("commandModeBannerText") private var bannerText = ""

    private var topDisplay: CommandTopDisplay {
        let stored = CommandTopDisplay(rawValue: topDisplayRaw) ?? .time
        // A banner with no text shows nothing.
        if stored == .banner, bannerText.trimmingCharacters(in: .whitespaces).isEmpty { return .nothing }
        return stored
    }
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
                        // Tap cycles the top display: time → banner (if one is set) → nothing → time.
                        ZStack {
                            clock(unit: unit)
                                .opacity(topDisplay == .time ? 1 : 0)
                            Text(bannerText)
                                .font(.system(size: unit * 0.9, weight: .thin, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.3)
                                .padding(.horizontal, unit * 1.2)
                                .opacity(topDisplay == .banner ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let hasBanner = !bannerText.trimmingCharacters(in: .whitespaces).isEmpty
                            withAnimation(.easeInOut(duration: 0.25)) {
                                topDisplayRaw = topDisplay.next(hasBanner: hasBanner).rawValue
                            }
                        }
                        HStack(alignment: .top) {
                            if !isConnected {
                                Text("Connecting…")
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

                    // Two pages: the controls, and the apps a long left-swipe away.
                    GeometryReader { page in
                        ZStack {
                            VStack(spacing: unit * 0.5) {
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
                                // The dark space either side of the transport opens the playback page.
                                NowPlayingBar()
                                    .frame(width: min(geo.size.width * 0.6, unit * 8))
                                    .opacity(isConnected ? 1 : 0.35)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        Color.black
                                            .contentShape(Rectangle())
                                            .onTapGesture { state.showingPlayback = true }
                                    )
                            }
                            }
                            .offset(x: state.showingApps ? -page.size.width * 1.1 : 0)
                            .allowsHitTesting(!state.showingApps)

                            appsPage(unit: unit)
                                .offset(x: state.showingApps ? 0 : page.size.width * 1.1)
                                .allowsHitTesting(state.showingApps)
                        }
                        .frame(width: page.size.width, height: page.size.height)
                        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: state.showingApps)
                    }
                }
                .padding(.horizontal, unit * 0.4)
                .padding(.top, max(topInset, unit * 0.3))
                .padding(.bottom, unit * 0.2)
                .opacity(state.showingPlayback ? 0 : 1)
                .allowsHitTesting(!state.showingPlayback)

                if state.showingPlayback {
                    playbackPage(unit: unit, width: geo.size.width)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.88), value: state.showingPlayback)
            // Night colours: multiplying turns every white / grey pixel red and leaves black black.
            .colorMultiply(redOnBlack ? Color(red: 1, green: 0.12, blue: 0.08) : .white)
            .opacity(state.dimmed ? 0.3 : 1)
            .animation(.easeInOut(duration: state.dimmed ? 2 : 0.2), value: state.dimmed)
        }
        .clipShape(IslandReveal(island: island, progress: state.revealed ? 1 : 0))
        // Linear: the drip's own phases do the easing. Faster on the way back in.
        .animation(.linear(duration: state.revealed ? 2.4 : 1.0), value: state.revealed)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: manager.connectionStatus) { _, status in
            // Errors are shown by the small remote, so step back to it.
            switch status {
            case .error, .localNetworkDenied: onExit()
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startDictation)) { _ in
            showingKeyboard = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                beginDictation(in: NSApp.keyWindow)
            }
        }
        .onChange(of: manager.keyboardToggleCounter) { _, _ in toggleKeyboard() }
        .onAppear {
            // Start the drip only after the collapsed frame is on screen, so it always animates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { state.revealed = true }
            // Morph from the remote's round controls into the square pad and pills.
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(2.1)) { morphed = true }
        }
        .onChange(of: showingKeyboard) { _, showing in state.textEntryActive = showing }
        .onChange(of: state.leaving) { _, leaving in
            guard leaving else { return }
            showingKeyboard = false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { morphed = false }
        }
    }

    /// Full-screen playback: big transport, skip buttons and a wide scrubber.
    /// Tapping any dark space goes back to the controls.
    private func playbackPage(unit: CGFloat, width: CGFloat) -> some View {
        let mrp = manager.mrpManager
        let np = mrp.nowPlaying
        let duration = np?.duration ?? 0
        // Big targets, two rows. Row widths are in units; 13 units fit the screen.
        let rowGap = unit * 0.28
        let skipW = unit * 1.85
        let skipH = unit * 1.5
        let transportH = unit * 1.7
        func skip(_ seconds: Double) {
            guard let np, duration > 0 else { return }
            mrp.seekToPosition(min(duration, max(0, np.currentPosition + seconds)))
        }

        func skipButton(_ seconds: Double) -> some View {
            Button { skip(seconds) } label: {
                Text("\(seconds < 0 ? "−" : "+")\(Int(abs(seconds)))")
                    .font(.system(size: unit * 0.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: skipW, height: skipH)
                    .background(ControlBackground(shape: Capsule()))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(seconds < 0 ? "Back" : "Forward") \(Int(abs(seconds))) seconds")
        }

        func transport(_ symbol: String, width: CGFloat, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: transportH * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: width, height: transportH)
                    .background(ControlBackground(shape: Capsule()))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }

        return ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture { state.showingPlayback = false }

            VStack(spacing: unit * 0.45) {
                VStack(spacing: unit * 0.1) {
                    Text(np?.title ?? " ")
                        .font(.system(size: unit * 0.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(np.flatMap { [$0.artist, $0.album].compactMap { $0 }.joined(separator: " — ") } ?? " ")
                        .font(.system(size: unit * 0.28))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .allowsHitTesting(false)

                // Row 1: previous, play / pause, next
                HStack(spacing: rowGap) {
                    transport("backward.fill", width: unit * 3.2) { mrp.sendCommand(.previousTrack) }
                    transport(np?.isPlaying == true ? "pause.fill" : "play.fill", width: unit * 4.6) {
                        manager.pressButton(.playPause)
                    }
                    transport("forward.fill", width: unit * 3.2) { mrp.sendCommand(.nextTrack) }
                }

                // Row 2: skip back and forward
                HStack(spacing: rowGap) {
                    skipButton(-30)
                    skipButton(-20)
                    skipButton(-10)
                    skipButton(10)
                    skipButton(20)
                    skipButton(30)
                }

                NowPlayingProgress(
                    nowPlaying: np,
                    duration: duration,
                    onSeek: { mrp.seekToPosition($0) },
                    grabDiameter: unit * 1.1
                )
                .frame(width: width * 0.8)
                .opacity(duration > 0 ? 1 : 0.3)
            }
        }
    }

    /// Apps grid: tap an app to launch it and return to the controls.
    private func appsPage(unit: CGFloat) -> some View {
        let columns = [GridItem(.adaptive(minimum: unit * 2.3), spacing: unit * 0.4)]
        return VStack(spacing: unit * 0.3) {
            HStack {
                glyphButton("chevron.left", size: unit * 0.7) { state.showingApps = false }
                    .help("Back to the controls")
                Spacer()
            }
            if manager.installedApps.isEmpty {
                Text("Loading apps…")
                    .font(.system(size: unit * 0.25))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: unit * 0.4) {
                        ForEach(manager.orderedApps, id: \.bundleID) { app in
                            Button {
                                manager.launchApp(bundleID: app.bundleID)
                                state.showingApps = false
                            } label: {
                                appTile(app, unit: unit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, unit * 0.1)
                }
            }
        }
        .padding(.horizontal, unit * 0.4)
        .onAppear { iconLoader.loadIcons(for: manager.installedApps) }
        .onChange(of: manager.installedApps.map(\.bundleID)) { iconLoader.loadIcons(for: manager.installedApps) }
    }

    private func appTile(_ app: (bundleID: String, name: String), unit: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: unit * 0.22)
        return VStack(spacing: unit * 0.1) {
            Group {
                if let icon = iconLoader.icons[app.bundleID] {
                    Color.clear.overlay {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                    }
                    .clipShape(shape)
                } else {
                    Image(systemName: AppIconFetcher.builtInSymbols[app.bundleID] ?? "app")
                        .font(.system(size: unit * 0.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ControlBackground(shape: shape))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: unit * 1.3)
            Text(app.name)
                .font(.system(size: unit * 0.2))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
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
