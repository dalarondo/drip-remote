import SwiftUI
import ServiceManagement
import ItsytvCore
#if APPSTORE
import StoreKit
#endif

enum RemoteTab: String, CaseIterable {
    case remote = "Remote"
    case apps = "Apps"
}

struct RemoteControlView: View {
    @Environment(AppleTVManager.self) private var manager
    @State private var selectedTab: RemoteTab = .remote
    @State private var showingKeyboard = false
    @State private var keyboardText = ""
    @State private var appSearchText = ""
    @State private var showUnpairHint = false
    @AppStorage("showAppsSearch") private var showAppsSearch = false
    #if APPSTORE
    @Environment(\.requestReview) private var requestReview
    #endif

    private var isConnected: Bool {
        manager.connectionStatus == .connected
    }

    private var touch: Bool { TouchMode.shared.isTouch }

    var body: some View {
        VStack(spacing: touch ? 14 : 10) {
            // Header — always interactive
            HStack(spacing: 8) {
                Text(manager.connectedDeviceName ?? "Apple TV")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if TouchMode.shared.islandStyle {
                    PowerButton {
                        manager.pressButton(.pageDown)
                    } onLongPress: {
                        manager.pressButton(.pageDown, action: .hold)
                    }
                }
                // Expand into command center (same as pinching out on the remote).
                Button {
                    NotificationCenter.default.post(name: .toggleCommandMode, object: nil)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: touch ? 14 : 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: touch ? 36 : 20, height: touch ? 36 : 20)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Command center")
                PanelMenuButton(deviceID: manager.connectedDeviceID ?? "") {
                    if let deviceID = manager.connectedDeviceID {
                        KeychainStorage.delete(for: deviceID)
                    }
                    manager.disconnect()
                }
                PanelCloseButton {
                    // Island style: ✕ only puts the remote away. Disconnect is in the ⋯ menu.
                    if TouchMode.shared.islandStyle {
                        NotificationCenter.default.post(name: .putAwayIslandRemote, object: nil)
                    } else {
                        manager.disconnect()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // "Taking too long?" unpair hint
            if showUnpairHint && !isConnected {
                VStack(spacing: 4) {
                    Text("Taking too long?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Unpair this Apple TV") {
                        if let deviceID = manager.connectedDeviceID {
                            KeychainStorage.delete(for: deviceID)
                        }
                        manager.disconnect()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
                .padding(.bottom, 4)
            }

            // Controls — dimmed while connecting
            VStack(spacing: touch ? 14 : 10) {
                // Tab picker
                CapsuleSegmentPicker(
                    selection: $selectedTab,
                    options: RemoteTab.allCases.map { ($0, $0.rawValue) },
                    large: touch
                )
                .padding(.horizontal, 8)

                // Keyboard text input (pushes content down when visible)
                if showingKeyboard && selectedTab == .remote {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ComposeAwareTextField(
                            text: $keyboardText,
                            placeholder: "Type or dictate...",
                            onCommittedTextChange: { committed in
                                manager.updateRemoteText(committed)
                            },
                            onSubmit: {
                                keyboardText = ""
                                showingKeyboard = false
                                manager.resetTextInputState()
                            }
                        )
                        .font(.caption)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Color(nsColor: DS.Colors.muted)))
                    .padding(.horizontal, 8)
                }

                // Content — remote is always rendered to maintain size
                ZStack(alignment: .top) {
                    ZStack {
                        // Remote always rendered (hidden when on apps to keep size)
                        VStack(spacing: touch ? 14 : 10) {
                            RemoteTabContent(swipeEnabled: selectedTab == .remote)
                            NowPlayingBar()
                        }
                        .opacity(selectedTab == .remote ? 1 : 0)
                        .allowsHitTesting(selectedTab == .remote)

                        // Apps overlaid on top when selected
                        if selectedTab == .apps {
                            AppGridView(searchText: $appSearchText)
                                .transition(.identity)
                        }
                    }
                    .animation(nil, value: selectedTab)

                    // Floating buttons over remote content (island style puts them elsewhere)
                    if selectedTab == .remote && !TouchMode.shared.islandStyle {
                        HStack {
                            // Keyboard button
                            Button {
                                showingKeyboard.toggle()
                                if !showingKeyboard {
                                    keyboardText = ""
                                    manager.resetTextInputState()
                                }
                            } label: {
                                Image(systemName: "keyboard")
                                    .font(.system(size: touch ? 18 : 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: touch ? 44 : 32, height: touch ? 44 : 32)
                                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .shortcutHint(.keyboard, alignment: .leading, offset: CGSize(width: 28, height: 0))

                            Spacer()

                            // Power button (Control Center)
                            PowerButton {
                                manager.pressButton(.pageDown)
                            } onLongPress: {
                                manager.pressButton(.pageDown, action: .hold)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
            .opacity(isConnected ? 1 : 0.4)
            .allowsHitTesting(isConnected)
        }
        .onReceive(NotificationCenter.default.publisher(for: .startDictation)) { _ in
            // Command mode has its own text field.
            guard !TouchMode.shared.commandModeActive else { return }
            selectedTab = .remote
            showingKeyboard = true
            // Give the field a moment to appear and take focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                beginDictation(in: NSApp.keyWindow)
            }
        }
        .onChange(of: manager.keyboardToggleCounter) { _, _ in
            guard !TouchMode.shared.commandModeActive else { return }
            showingKeyboard.toggle()
            if !showingKeyboard {
                keyboardText = ""
                manager.resetTextInputState()
            }
        }
        .onChange(of: showAppsSearch) { _, show in
            if show {
                selectedTab = .apps
            }
        }
        .onChange(of: manager.connectionStatus) { _, status in
            if status == .connected {
                withAnimation { showUnpairHint = false }
            } else if case .connecting = status {
                scheduleUnpairHint()
            }
        }
        .onAppear {
            // The panel is created while the status is already `.connecting`, so
            // `onChange` never sees that initial value — arm the hint here too so
            // a stuck connection reliably surfaces the unpair option.
            if !isConnected { scheduleUnpairHint() }
        }
        #if APPSTORE
        .task(id: isConnected) { await askForReviewAfterUse() }
        #endif
    }

    #if APPSTORE
    /// Records a day of use and, after `ReviewPromptRule.sustainedUse` seconds of a connected remote,
    /// asks for a rating when the rule allows. The task restarts – and so is cancelled – when the
    /// connection changes or the panel closes.
    private func askForReviewAfterUse() async {
        guard isConnected else { return }
        let rule = ReviewPromptRule(defaults: .standard)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        rule.recordUse(on: Date(), version: version)
        try? await Task.sleep(for: .seconds(ReviewPromptRule.sustainedUse))
        guard !Task.isCancelled, isConnected, rule.shouldPrompt(now: Date()) else { return }
        rule.recordPrompt(now: Date())
        requestReview()
    }
    #endif

    /// Reset and (re)arm the 5-second "Taking too long?" unpair hint.
    private func scheduleUnpairHint() {
        showUnpairHint = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if !isConnected {
                withAnimation { showUnpairHint = true }
            }
        }
    }
}

struct NowPlayingBar: View {
    @Environment(AppleTVManager.self) private var manager
    @AppStorage("showArtwork") private var showArtwork = true
    private var touch: Bool { TouchMode.shared.isTouch }

    var body: some View {
        let mrp = manager.mrpManager
        let np = mrp.nowPlaying
        let hasContent = np != nil

        VStack(spacing: 6) {
            // Artwork – full width, square (can be turned off in the … menu)
            // Touch layout drops the artwork: the taller controls need the room.
            if !showArtwork || touch {
                EmptyView()
            } else if let data = np?.artworkData, let image = NSImage(data: data) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
            }

            // Island style puts the title and transport side by side to save height.
            let row = TouchMode.shared.islandStyle ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 6))
            row {
            // Title + artist
            VStack(spacing: 2) {
                Text(np?.title ?? " ")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(np.flatMap { [$0.artist, $0.album].compactMap { $0 }.joined(separator: " — ") } ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(hasContent ? 1 : 0)

            // Controls — use HID button presses (not MRP commands) for play/pause
            // because apps like YouTube ignore MRP SendCommandMessage.
            HStack(spacing: touch ? 20 : 12) {
                Button {
                    mrp.sendCommand(.previousTrack)
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: touch ? 24 : 18))
                        .frame(width: touch ? 64 : 44, height: touch ? 52 : 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasContent || !mrp.supportedCommands.contains(.previousTrack))

                Button {
                    manager.pressButton(.playPause)
                } label: {
                    Image(systemName: np?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: touch ? 30 : 22))
                        .frame(width: touch ? 64 : 44, height: touch ? 52 : 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasContent)

                Button {
                    mrp.sendCommand(.nextTrack)
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: touch ? 24 : 18))
                        .frame(width: touch ? 64 : 44, height: touch ? 52 : 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasContent || !mrp.supportedCommands.contains(.nextTrack))
            }
            .foregroundStyle(.secondary)
            .fixedSize()
            } // row

            // Progress bar
            NowPlayingProgress(
                nowPlaying: np,
                duration: np?.duration ?? 0,
                onSeek: { position in mrp.seekToPosition(position) }
            )
            .opacity(hasContent && (np?.duration ?? 0) > 0 ? 1 : 0.3)
        }
        .padding(.horizontal, touch ? 24 : 16)
        .padding(.bottom, touch ? 24 : 16)
    }
}

/// Touch-friendly, Apple Music–style scrubber.
///
/// - Tall (40pt) hit area; the track grows and a thumb appears while scrubbing.
/// - Progress advances smoothly (per frame) instead of once a second.
/// - Dragging away from the bar vertically slows the scrub (Hi-Speed → Half →
///   Quarter → Fine), like the iOS scrubber, for precise seeking on a long video.
/// - The seek is sent once, on release; nothing is sent while dragging.
/// - A tap jumps straight to that position.
struct NowPlayingProgress: View {
    let nowPlaying: NowPlayingState?
    let duration: TimeInterval
    var onSeek: ((Double) -> Void)?

    @AppStorage("showRemainingTime") private var showRemainingTime = false
    @State private var isSeeking = false
    /// Position being scrubbed to, in seconds.
    @State private var scrubTime: TimeInterval = 0
    @State private var lastDragX: CGFloat?
    @State private var scrubSpeed: ScrubSpeed = .highSpeed
    /// After seeking, hold the seeked position until the server catches up.
    @State private var pendingSeekTarget: TimeInterval?
    @State private var pendingSeekSince = Date.distantPast

    /// A large, always-visible grab circle of this diameter (full-screen playback page).
    var grabDiameter: CGFloat? = nil

    private var touch: Bool { TouchMode.shared.isTouch }
    private var trackHeight: CGFloat { grabDiameter.map { $0 * 0.16 } ?? (touch ? 8 : 4) }
    private var activeTrackHeight: CGFloat { grabDiameter.map { $0 * 0.26 } ?? (touch ? 18 : 12) }
    private var thumbSize: CGFloat { grabDiameter ?? (touch ? 30 : 18) }
    private var hitHeight: CGFloat { grabDiameter.map { $0 + 28 } ?? (touch ? 64 : 40) }
    private var thumbAlwaysVisible: Bool { grabDiameter != nil }

    enum ScrubSpeed: Equatable {
        case highSpeed, half, quarter, fine

        init(verticalDistance d: CGFloat) {
            switch d {
            case ..<40: self = .highSpeed
            case ..<90: self = .half
            case ..<150: self = .quarter
            default: self = .fine
            }
        }

        var factor: CGFloat {
            switch self {
            case .highSpeed: 1
            case .half: 0.5
            case .quarter: 0.25
            case .fine: 0.1
            }
        }

        var label: String {
            switch self {
            case .highSpeed: "Hi-Speed scrubbing"
            case .half: "Half-speed scrubbing"
            case .quarter: "Quarter-speed scrubbing"
            case .fine: "Fine scrubbing"
            }
        }
    }

    /// Where the bar should currently sit, given the latest server state.
    private func displayTime(at date: Date) -> TimeInterval {
        if isSeeking { return scrubTime }
        if let target = pendingSeekTarget { return target }
        return min(duration, max(0, nowPlaying?.currentPosition ?? 0))
    }

    var body: some View {
        let isPlaying = (nowPlaying?.playbackRate ?? 0) > 0
        // Redraw every frame while playing or scrubbing; idle otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !(isPlaying || isSeeking || pendingSeekTarget != nil))) { context in
            let time = displayTime(at: context.date)
            let progress = duration > 0 ? min(1, max(0, time / duration)) : 0

            VStack(spacing: 0) {
                GeometryReader { geo in
                    let height = isSeeking ? activeTrackHeight : trackHeight
                    let fillWidth = geo.size.width * progress

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: height)

                        Capsule()
                            .fill(isSeeking ? Color.primary : Color.secondary)
                            .frame(width: max(height, fillWidth), height: height)

                        Circle()
                            .fill(Color.primary)
                            .frame(width: thumbSize, height: thumbSize)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .offset(x: min(max(0, fillWidth - thumbSize / 2), geo.size.width - thumbSize))
                            .opacity(isSeeking || thumbAlwaysVisible ? 1 : 0)
                            .scaleEffect(isSeeking ? (thumbAlwaysVisible ? 1.12 : 1) : (thumbAlwaysVisible ? 1 : 0.4))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .background(WindowDragBlocker())
                    .gesture(scrubGesture(width: geo.size.width))
                    .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSeeking)
                }
                .frame(height: hitHeight)

                ZStack {
                    HStack {
                        Text(formatTime(time))
                        Spacer()
                        Text(showRemainingTime ? "-\(formatTime(duration - time))" : formatTime(duration))
                            .onTapGesture { showRemainingTime.toggle() }
                    }
                    .font(.system(size: (isSeeking ? 12 : 10) * (touch ? 1.3 : 1), weight: isSeeking ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isSeeking ? .secondary : .tertiary)

                    if isSeeking {
                        Text(scrubSpeed.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isSeeking)
                .animation(.easeOut(duration: 0.15), value: scrubSpeed)
            }
            // Clear the "hold until server catches up" state once it has.
            .onChange(of: nowPlaying?.currentPosition ?? 0) { _, serverTime in
                guard let target = pendingSeekTarget, !isSeeking else { return }
                let expected = target + (isPlaying ? Date().timeIntervalSince(pendingSeekSince) : 0)
                if abs(serverTime - expected) < 3 || Date().timeIntervalSince(pendingSeekSince) > 6 {
                    pendingSeekTarget = nil
                }
            }
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                if !isSeeking {
                    // Touch-down: jump to the touched point, then scrub relatively from there.
                    isSeeking = true
                    scrubSpeed = .highSpeed
                    scrubTime = clampTime(value.location.x / width * duration)
                    lastDragX = value.location.x
                    haptic(.alignment)
                    return
                }
                // Distance from the bar picks the scrub speed (the bar is 40pt tall).
                let verticalDistance = max(0, abs(value.location.y - hitHeight / 2) - hitHeight / 2)
                let speed = ScrubSpeed(verticalDistance: verticalDistance)
                if speed != scrubSpeed {
                    scrubSpeed = speed
                    haptic(.levelChange)
                }
                let dx = value.location.x - (lastDragX ?? value.location.x)
                lastDragX = value.location.x
                let before = scrubTime
                scrubTime = clampTime(scrubTime + dx / width * duration * scrubSpeed.factor)
                if (before > 0 && scrubTime == 0) || (before < duration && scrubTime == duration) {
                    haptic(.alignment)
                }
            }
            .onEnded { _ in
                guard isSeeking else { return }
                let position = scrubTime
                lastDragX = nil
                if duration > 0 {
                    onSeek?(position)
                    pendingSeekTarget = position
                    pendingSeekSince = Date()
                }
                isSeeking = false
                haptic(.generic)
            }
    }

    private func clampTime(_ t: TimeInterval) -> TimeInterval {
        min(duration, max(0, t))
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct RemoteTabContent: View {
    @Environment(AppleTVManager.self) private var manager
    let swipeEnabled: Bool

    private var touch: Bool { TouchMode.shared.isTouch }
    private var padding: CGFloat { touch ? 16 : 8 }
    private var island: Bool { TouchMode.shared.islandStyle }
    private var buttonSize: CGFloat { island ? 80 : (touch ? 78 : 60) }
    private var buttonGap: CGFloat { island ? 14 : (touch ? 18 : 12) }

    private func back(_ action: InputAction) {
        if action == .hold {
            manager.pressButton(.home)
        } else {
            manager.pressButton(.menu, action: action)
        }
    }

    var body: some View {
        if island { islandBody } else { stackedBody }
    }

    /// Island style: wide and short – D-pad on the left, buttons on the right.
    private var islandBody: some View {
        let side = buttonSize * 3 + buttonGap * 2        // the buttons block is this wide
        return HStack(alignment: .center, spacing: 20) {
            DPadView(
                onPress: { button, action in manager.pressButton(button, action: action) },
                size: side,
                swipeEnabled: swipeEnabled,
                height: side
            )
            touchButtons
        }
        .padding(.horizontal, padding)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var stackedBody: some View {
        let dpadSize: CGFloat = touch ? 232 : 150

        return VStack(spacing: touch ? 20 : 4) {
            // D-pad
            DPadView(
                onPress: { button, action in manager.pressButton(button, action: action) },
                size: dpadSize,
                swipeEnabled: swipeEnabled
            )
                .padding(.top, 15)

            // Buttons matching Apple TV remote layout
            if touch {
                touchButtons
            } else {
                compactButtons
            }
        }
        .padding(.horizontal, padding)
        .padding(.bottom, touch ? 16 : 12)
    }

    /// Wide layout: Back / TV / Dictate, then Play-Pause / Mute, then a full-width volume bar.
    private var touchButtons: some View {
        VStack(spacing: buttonGap) {
            HStack(spacing: buttonGap) {
                RemoteCircleButton(imageName: "btnBack", button: .menu, shortcut: .back, size: buttonSize, onInput: back)
                RemoteCircleButton(imageName: "btnHome", button: .home, shortcut: .home, size: buttonSize) { action in
                    manager.pressButton(.home, action: action)
                }
                DictateButton(size: buttonSize)
            }
            HStack(spacing: buttonGap) {
                RemoteCircleButton(imageName: "btnPlayPause", button: .playPause, shortcut: .playPause, size: buttonSize) { action in
                    manager.pressButton(.playPause, action: action)
                }
                RemoteCircleButton(imageName: "btnMute", button: .siri, shortcut: .mute, size: buttonSize) { action in
                    guard action == .click else { return }
                    manager.toggleMute()
                }
                if island {
                    // The floating keyboard button would sit on the pad here, so it joins the grid.
                    Image(systemName: "keyboard")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.medium)
                        .frame(width: buttonSize * 0.36, height: buttonSize * 0.36)
                        .foregroundStyle(Color(nsColor: DS.Colors.remoteButtonForeground))
                        .frame(width: buttonSize, height: buttonSize)
                        .background(ControlBackground(shape: Circle()))
                        .overlay(RemoteButtonGesture { action in
                            guard action == .click else { return }
                            manager.keyboardToggleCounter &+= 1
                        })
                        .help("Type on Apple TV")
                }
            }
            VolumePill(
                width: buttonSize * 3 + buttonGap * 2,
                height: buttonSize * 0.85,
                horizontal: true,
                onUp: { manager.pressButton(.volumeUp) },
                onDown: { manager.pressButton(.volumeDown) }
            )
        }
    }

    private var compactButtons: some View {
        VStack(spacing: buttonGap) {
            // Row 1: Back + TV/Home
            HStack(spacing: buttonGap) {
                RemoteCircleButton(imageName: "btnBack", button: .menu, shortcut: .back, size: buttonSize, onInput: back)
                RemoteCircleButton(imageName: "btnHome", button: .home, shortcut: .home, size: buttonSize) { action in
                    manager.pressButton(.home, action: action)
                }
            }

            // Rows 2-4: Dictate + Play/Pause + Mute left, Volume pill right
            HStack(alignment: .top, spacing: buttonGap) {
                VStack(spacing: buttonGap) {
                    DictateButton(size: buttonSize)
                    RemoteCircleButton(imageName: "btnPlayPause", button: .playPause, shortcut: .playPause, size: buttonSize) { action in
                        manager.pressButton(.playPause, action: action)
                    }
                    RemoteCircleButton(imageName: "btnMute", button: .siri, shortcut: .mute, size: buttonSize) { action in
                        guard action == .click else { return }
                        manager.toggleMute()
                    }
                }

                VolumePill(
                    width: buttonSize,
                    height: buttonSize * 3 + buttonGap * 2,
                    onUp: { manager.pressButton(.volumeUp) },
                    onDown: { manager.pressButton(.volumeDown) }
                )
            }
        }
    }
}


struct AppGridView: View {
    @Binding var searchText: String
    @AppStorage("showAppsSearch") private var showAppsSearch = false
    @Environment(AppleTVManager.self) private var manager
    @Environment(AppIconLoader.self) private var iconLoader
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var draggingBundleID: String?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: TouchMode.shared.isTouch ? 3 : 2)
    }

    private var filteredApps: [(bundleID: String, name: String)] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        if manager.installedApps.isEmpty {
            if manager.osVersion?.hasPrefix("26.5") == true {
                VStack(spacing: 8) {
                    Text("Apps unavailable in tvOS 26.5")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    Text("We are working on the fix for tvOS 26.5")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading apps...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 8) {
                if showAppsSearch {
                    // Search bar
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ComposeAwareTextField(
                            text: $searchText,
                            placeholder: "Search apps...",
                            onCommittedTextChange: { _ in },
                            onSubmit: { }
                        )
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Color(nsColor: DS.Colors.muted)))
                    .padding(.horizontal, 16)
                }

            ScrollView {
                LazyVGrid(columns: columns, spacing: TouchMode.shared.isTouch ? 16 : 8) {
                    ForEach(filteredApps, id: \.bundleID) { app in
                        appView(for: app)
                            .opacity(draggingBundleID == app.bundleID ? 0.5 : 1)
                            .onDrag {
                                draggingBundleID = app.bundleID
                                return NSItemProvider(object: app.bundleID as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: AppReorderDropDelegate(
                                    targetBundleID: app.bundleID,
                                    apps: $apps,
                                    draggingBundleID: $draggingBundleID,
                                    onReorder: { manager.saveAppOrder($0.map(\.bundleID)) }
                                )
                            )
                            .background(WindowDragBlocker())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .onAppear {
                apps = manager.orderedApps
                iconLoader.loadIcons(for: manager.installedApps)
            }
            .onChange(of: manager.installedApps.map(\.bundleID)) {
                apps = manager.orderedApps
                iconLoader.loadIcons(for: manager.installedApps)
            }
            .onChange(of: showAppsSearch) { _, show in
                if !show { searchText = "" }
            }
            } // VStack
        }
    }

    @ViewBuilder
    private func appView(for app: (bundleID: String, name: String)) -> some View {
        if let symbolName = AppIconFetcher.builtInSymbols[app.bundleID] {
            AppleAppButton(name: app.name, symbolName: symbolName) {
                manager.launchApp(bundleID: app.bundleID)
            }
        } else {
            AppButton(name: app.name, icon: iconLoader.icons[app.bundleID]) {
                manager.launchApp(bundleID: app.bundleID)
            }
        }
    }
}

private struct AppReorderDropDelegate: DropDelegate {
    let targetBundleID: String
    @Binding var apps: [(bundleID: String, name: String)]
    @Binding var draggingBundleID: String?
    let onReorder: ([(bundleID: String, name: String)]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingBundleID,
              dragging != targetBundleID,
              let fromIndex = apps.firstIndex(where: { $0.bundleID == dragging }),
              let toIndex = apps.firstIndex(where: { $0.bundleID == targetBundleID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            apps.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        onReorder(apps)
        draggingBundleID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}
}

struct AppButton: View {
    let name: String
    let icon: NSImage?
    let action: () -> Void

    private var iconHeight: CGFloat { TouchMode.shared.isTouch ? 64 : 42 }
    private let cornerRadius: CGFloat = 10

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let icon {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: iconHeight)
                        .overlay {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.quaternary)
                        .frame(maxWidth: .infinity)
                        .frame(height: iconHeight)
                        .overlay {
                            Image(systemName: "app.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                }
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
    }
}

struct AppleAppButton: View {
    let name: String
    let symbolName: String?
    let action: () -> Void

    private var iconHeight: CGFloat { TouchMode.shared.isTouch ? 64 : 42 }
    private let cornerRadius: CGFloat = 10

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                    .frame(maxWidth: .infinity)
                    .frame(height: iconHeight)
                    .overlay {
                        Image(systemName: symbolName ?? "app.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Native gesture handler (no 300ms SwiftUI tap disambiguation delay)

private struct RemoteButtonGesture: NSViewRepresentable {
    let onInput: (InputAction) -> Void

    func makeNSView(context: Context) -> RemoteButtonGestureNSView {
        let view = RemoteButtonGestureNSView()
        view.onInput = onInput
        return view
    }

    func updateNSView(_ nsView: RemoteButtonGestureNSView, context: Context) {
        nsView.onInput = onInput
    }
}

private class RemoteButtonGestureNSView: NSView {
    var onInput: ((InputAction) -> Void)?
    private var holdTimer: Timer?
    private var holdFired = false
    private var downLocation: NSPoint = .zero
    private var dragCancelled = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Sliding off a button (e.g. a page swipe that starts on it) cancels the press.
    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        if hypot(p.x - downLocation.x, p.y - downLocation.y) > 24 {
            dragCancelled = true
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        downLocation = event.locationInWindow
        dragCancelled = false
        holdFired = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.holdFired = true
            self.onInput?(.hold)
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard !holdFired, !dragCancelled else { return }
        onInput?(.click)
    }
}

/// Transparent layer over the D-pad that turns a precise trackpad / Magic Mouse
/// swipe into the core's real-time touch stream — the macOS analogue of the
/// iOS pan-over-dpad gesture. It listens via a local `.scrollWheel` monitor
/// rather than the responder chain, so it never intercepts the button clicks
/// layered beneath it; a swipe is only claimed while the cursor is over the pad.
private struct DPadSwipeCapture: NSViewRepresentable {
    let isEnabled: Bool
    let onBegan: () -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> DPadSwipeCaptureView {
        let view = DPadSwipeCaptureView()
        view.isEnabled = isEnabled
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: DPadSwipeCaptureView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }

    static func dismantleNSView(_ nsView: DPadSwipeCaptureView, coordinator: ()) {
        nsView.teardown()
    }
}

private final class DPadSwipeCaptureView: NSView {
    var isEnabled = true {
        didSet {
            if !isEnabled { end() }
        }
    }
    var onBegan: (() -> Void)?
    var onChanged: ((CGPoint) -> Void)?
    var onEnded: ((CGPoint, CGPoint) -> Void)?

    // Apple TV touch surface is direct-manipulation: a swipe up should move the
    // highlight up. macOS reports a swipe-up as a positive `scrollingDeltaY`,
    // but the core treats positive translation.y as downward, so vertical is
    // inverted. Flip either constant if a swipe navigates the wrong way.
    private let invertVertical = false
    private let invertHorizontal = false

    // Scales raw scroll deltas before they drive the touch stream. Lower = less
    // sensitive; tune to taste. Applied to both translation and release velocity
    // so the inertia after a flick stays proportional.
    private let sensitivity: CGFloat = 0.25

    private var monitor: Any?
    private var active = false
    private var translation: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var lastMoveTime: TimeInterval = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installMonitor() } else { teardown() }
    }

    deinit { teardown() }

    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func cursorIsOverDPad(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        return convert(bounds, to: nil).contains(event.locationInWindow)
    }

    /// Returns `nil` to swallow the event (so it never scrolls anything beneath
    /// the pad), or the event to let it propagate normally.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Only precise gestures (trackpad / Magic Mouse) act as swipes; a
        // classic notched wheel keeps its normal behaviour.
        guard isEnabled else { return event }
        guard event.hasPreciseScrollingDeltas else { return event }
        guard active || cursorIsOverDPad(event) else { return event }

        // `scrollingDelta*` is pre-inverted to match the system "Natural scrolling"
        // setting; `isDirectionInvertedFromDevice` is true exactly when that has
        // been applied. Normalize so the swipe always tracks the finger
        // (content-following, like the Apple TV touch surface) regardless of it.
        let naturalize: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = event.scrollingDeltaX * naturalize * (invertHorizontal ? -1 : 1) * sensitivity
        let dy = event.scrollingDeltaY * naturalize * (invertVertical ? -1 : 1) * sensitivity

        switch event.phase {
        case .began:
            begin()
            apply(dx: dx, dy: dy, timestamp: event.timestamp)
        case .changed:
            if !active { begin() }
            apply(dx: dx, dy: dy, timestamp: event.timestamp)
        case .ended, .cancelled:
            end()
        default:
            // Momentum (phase == []) arrives after the fingers lift; the core
            // runs its own inertia from the release velocity, so drop it.
            return cursorIsOverDPad(event) ? nil : event
        }
        return nil
    }

    private func begin() {
        active = true
        translation = .zero
        velocity = .zero
        lastMoveTime = 0
        onBegan?()
    }

    private func apply(dx: CGFloat, dy: CGFloat, timestamp: TimeInterval) {
        guard active else { return }
        translation.x += dx
        translation.y += dy
        if lastMoveTime > 0 {
            let dt = max(timestamp - lastMoveTime, 1.0 / 1000)
            velocity = CGPoint(x: dx / dt, y: dy / dt)
        }
        lastMoveTime = timestamp
        onChanged?(translation)
    }

    private func end() {
        guard active else { return }
        active = false
        onEnded?(translation, velocity)
    }
}

// MARK: - Touch surface for the D-pad

/// One gesture surface over the whole D-pad, so a finger doesn't have to hit a
/// 5pt dot: a tap anywhere clicks the nearest direction (centre = Select), a
/// press-and-hold sends a hold, and a drag becomes the Apple TV's real-time
/// touch stream (like swiping the Siri Remote's touch surface).
private struct DPadTouchSurface: NSViewRepresentable {
    let onInput: (CompanionButton, InputAction) -> Void
    let onSwipeBegan: () -> Void
    let onSwipeChanged: (CGPoint) -> Void
    let onSwipeEnded: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> DPadTouchSurfaceView {
        let view = DPadTouchSurfaceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DPadTouchSurfaceView, context: Context) { update(nsView) }

    private func update(_ view: DPadTouchSurfaceView) {
        view.onInput = onInput
        view.onSwipeBegan = onSwipeBegan
        view.onSwipeChanged = onSwipeChanged
        view.onSwipeEnded = onSwipeEnded
    }
}

private final class DPadTouchSurfaceView: NSView {
    var onInput: ((CompanionButton, InputAction) -> Void)?
    var onSwipeBegan: (() -> Void)?
    var onSwipeChanged: ((CGPoint) -> Void)?
    var onSwipeEnded: ((CGPoint, CGPoint) -> Void)?

    /// Movement (pt) before a press turns into a swipe. Generous, because a
    /// fingertip wobbles more than a mouse.
    private let dragThreshold: CGFloat = 10
    private let holdDelay: TimeInterval = 0.5

    private var start: CGPoint = .zero
    private var pressedButton: CompanionButton = .select
    private var holdTimer: Timer?
    private var holdFired = false
    private var swiping = false
    private var translation: CGPoint = .zero
    private var velocity: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lastTime: TimeInterval = 0

    // Top-left origin, so a drag down is positive y — what the core expects.
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func button(at point: CGPoint) -> CompanionButton {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        if hypot(dx, dy) < min(bounds.width, bounds.height) * 0.25 { return .select }
        // Compare as fractions of each half-extent, so a wide pad still splits on its diagonals.
        if abs(dx) / max(bounds.width, 1) > abs(dy) / max(bounds.height, 1) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        lastPoint = start
        lastTime = event.timestamp
        translation = .zero
        velocity = .zero
        swiping = false
        holdFired = false
        pressedButton = button(at: start)

        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] _ in
            guard let self, !self.swiping else { return }
            self.holdFired = true
            self.onInput?(self.pressedButton, .hold)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !holdFired else { return }
        let point = convert(event.locationInWindow, from: nil)
        translation = CGPoint(x: point.x - start.x, y: point.y - start.y)

        if !swiping {
            guard hypot(translation.x, translation.y) > dragThreshold else { return }
            swiping = true
            holdTimer?.invalidate()
            holdTimer = nil
            onSwipeBegan?()
        }

        let dt = max(event.timestamp - lastTime, 1.0 / 1000)
        let instant = CGPoint(x: (point.x - lastPoint.x) / dt, y: (point.y - lastPoint.y) / dt)
        // Light smoothing so a single jittery sample doesn't fling the focus.
        velocity = CGPoint(x: velocity.x * 0.4 + instant.x * 0.6, y: velocity.y * 0.4 + instant.y * 0.6)
        lastPoint = point
        lastTime = event.timestamp
        onSwipeChanged?(translation)
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        if swiping {
            swiping = false
            // A finger that paused before lifting shouldn't fling.
            if event.timestamp - lastTime > 0.1 { velocity = .zero }
            onSwipeEnded?(translation, velocity)
        } else if !holdFired {
            onInput?(pressedButton, .click)
        }
    }

    deinit { holdTimer?.invalidate() }
}

// MARK: - Dictation

extension Notification.Name {
    /// Posted by the mic button: open the "type on Apple TV" field and start macOS dictation.
    static let startDictation = Notification.Name("itsytv.startDictation")
}

/// Speak instead of typing: opens the text field and starts macOS dictation, and the
/// dictated words are sent to the Apple TV's on-screen keyboard (search boxes etc.).
/// This is dictation, not Siri – the Apple TV only gets text.
struct DictateButton: View {
    let size: CGFloat
    var width: CGFloat? = nil
    @State private var blinkOpacity: Double = 0

    var body: some View {
        // Sized by frame, not font size: a frame animates smoothly while the button morphs,
        // a font size snaps.
        Image(systemName: "mic.fill")
            .resizable()
            .scaledToFit()
            .fontWeight(.medium)
            .frame(width: size * 0.36, height: size * 0.36)
            .foregroundStyle(Color(nsColor: DS.Colors.remoteButtonForeground))
            .frame(width: width ?? size, height: size)
            .background(ControlBackground(shape: Capsule()))
            .overlay(Capsule().fill(.white.opacity(blinkOpacity)).allowsHitTesting(false))
            .overlay(RemoteButtonGesture { action in
                guard action == .click else { return }
                blinkOpacity = 0.25
                withAnimation(.easeOut(duration: 0.2)) { blinkOpacity = 0 }
                NotificationCenter.default.post(name: .startDictation, object: nil)
            })
            .help("Dictate to the Apple TV")
            .accessibilityLabel("Dictate")
    }
}

/// Focus the remote's text field (if it isn't already) and ask AppKit to start dictation.
func beginDictation(in window: NSWindow?) {
    guard let window else { return }
    func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let f = firstEditableField(in: sub) { return f } }
        return nil
    }
    if !(window.firstResponder is NSTextView), let content = window.contentView,
       let field = firstEditableField(in: content) {
        window.makeFirstResponder(field)
    }
    NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
}

struct DPadView: View {
    @Environment(AppleTVManager.self) private var manager
    let onPress: (CompanionButton, InputAction) -> Void
    let size: CGFloat
    let swipeEnabled: Bool
    /// Command mode: a rounded rectangle `size` wide and this tall, for more touch area.
    var height: CGFloat? = nil
    /// Command mode corner radius; animating it from half the size morphs a circle into the square.
    var cornerRadius: CGFloat? = nil
    @Environment(\.oledControls) private var oled
    @State private var blinkOpacity: Double = 0

    private static let dpadButtons: Set<CompanionButton> = [.up, .down, .left, .right, .select]

    private func press(_ button: CompanionButton, _ action: InputAction) {
        blink()
        onPress(button, action)
    }

    private func blink() {
        blinkOpacity = 0.25
        withAnimation(.easeOut(duration: 0.2)) { blinkOpacity = 0 }
    }

    private var padHeight: CGFloat { height ?? size }

    /// A circle normally; a rounded rectangle in command mode.
    private var padRadius: CGFloat { cornerRadius ?? min(size, padHeight) * 0.12 }

    private var padShape: AnyShape {
        oled ? AnyShape(RoundedRectangle(cornerRadius: padRadius)) : AnyShape(Circle())
    }

    var body: some View {
        let selectSize = min(size, padHeight) * (oled ? 0.42 : 0.5)

        ZStack {
            // Concrete shapes (not AnyShape) so the corner radius animates.
            Group {
                if oled {
                    ControlBackground(shape: RoundedRectangle(cornerRadius: padRadius))
                } else {
                    ControlBackground(shape: Circle())
                }
            }
                .frame(width: size, height: padHeight)

            // Center select button — larger, subtly distinct from outer ring
            Group {
                if oled {
                    Circle().stroke(Color.white.opacity(0.28), lineWidth: 1.5)
                } else {
                    Circle().fill(Color(nsColor: DS.Colors.remoteButtonForeground).opacity(0.08))
                }
            }
                .frame(width: selectSize, height: selectSize)
                .contentShape(Circle())
                .overlay(Circle().fill(.white.opacity(manager.heldButton == .select ? 0.22 : 0)).allowsHitTesting(false))
                .shortcutHint(.select)
                .help("Return")

            // Direction dots
            VStack {
                DPadDot(shortcut: .up)
                Spacer()
                DPadDot(shortcut: .down)
            }
            .frame(height: padHeight)
            .padding(.vertical, 12)

            HStack {
                DPadDot(shortcut: .left)
                Spacer()
                DPadDot(shortcut: .right)
            }
            .frame(width: size)
            .padding(.horizontal, 12)

            padShape
                .fill(.white.opacity(blinkOpacity))
                .frame(width: size, height: padHeight)
                .allowsHitTesting(false)
        }
        // Tap / hold / drag anywhere on the pad (touch screen, mouse, trackpad click).
        .overlay(
            DPadTouchSurface(
                onInput: { button, action in press(button, action) },
                onSwipeBegan: { manager.touchBegan(referenceSize: CGSize(width: size * 1.5, height: size * 1.5)) },
                onSwipeChanged: { manager.touchMoved(translation: $0) },
                onSwipeEnded: { manager.touchEnded(translation: $0, velocity: $1) }
            )
            .clipShape(padShape)
        )
        // Swipe over the pad (trackpad / Magic Mouse) streams as a touch,
        // matching iOS. Hit testing stays off so button clicks pass through.
        .overlay(
            DPadSwipeCapture(
                isEnabled: swipeEnabled,
                onBegan: { manager.touchBegan(referenceSize: CGSize(width: size * 1.5, height: size * 1.5)) },
                onChanged: { manager.touchMoved(translation: $0) },
                onEnded: { manager.touchEnded(translation: $0, velocity: $1) }
            )
            .allowsHitTesting(false)
        )
        .onChange(of: manager.keyboardBlinkCounter) { _, _ in
            if Self.dpadButtons.contains(manager.keyboardBlinkButton) { blink() }
        }
    }
}

struct DPadDot: View {
    let shortcut: RemoteShortcut

    var body: some View {
        // Visual only — DPadTouchSurface handles input over the whole pad.
        Circle()
            .fill(Color(nsColor: DS.Colors.remoteButtonForeground))
            .frame(width: 5, height: 5)
            .frame(width: 30, height: 30)
            .shortcutHint(shortcut)
            .help(shortcut.label)
    }
}

struct RemoteCircleButton: View {
    @Environment(AppleTVManager.self) private var manager
    let imageName: String
    let button: CompanionButton
    let shortcut: RemoteShortcut
    let size: CGFloat
    /// Wider than `size` turns the circle into a pill (command mode).
    let width: CGFloat?
    let action: (InputAction) -> Void
    @State private var blinkOpacity: Double = 0

    init(imageName: String, button: CompanionButton, shortcut: RemoteShortcut, size: CGFloat, width: CGFloat? = nil,
         onInput action: @escaping (InputAction) -> Void) {
        self.width = width
        self.imageName = imageName
        self.button = button
        self.shortcut = shortcut
        self.size = size
        self.action = action
    }

    /// Its key is being held down on the keyboard.
    private var isHeld: Bool { manager.heldButton == button }

    private func press(_ input: InputAction) {
        blink()
        action(input)
    }

    private func blink() {
        blinkOpacity = 0.25
        withAnimation(.easeOut(duration: 0.2)) { blinkOpacity = 0 }
    }

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.33, height: size * 0.33)
            .frame(width: width ?? size, height: size)
            .background(ControlBackground(shape: Capsule()))
            .overlay(Capsule().fill(.white.opacity(blinkOpacity)).allowsHitTesting(false))
            .overlay(Capsule().fill(.white.opacity(isHeld ? 0.22 : 0)).allowsHitTesting(false))
            .scaleEffect(isHeld ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: isHeld)
            .overlay(RemoteButtonGesture { input in press(input) })
            .shortcutHint(shortcut, alignment: .bottom, offset: CGSize(width: 0, height: -7))
            .help(shortcut.label)
            .onChange(of: manager.keyboardBlinkCounter) { _, _ in
                if manager.keyboardBlinkButton == button { blink() }
            }
    }
}

struct VolumePill: View {
    @Environment(AppleTVManager.self) private var manager
    let width: CGFloat
    let height: CGFloat
    var horizontal = false
    let onUp: () -> Void
    let onDown: () -> Void
    @State private var blinkOpacity: Double = 0

    private func blink() {
        blinkOpacity = 0.25
        withAnimation(.easeOut(duration: 0.2)) { blinkOpacity = 0 }
    }

    private var minusButton: some View {
        Button(action: { blink(); onDown() }) {
            Image(systemName: "minus")
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .frame(width: min(width, height) * 0.3, height: min(width, height) * 0.3)
                .foregroundStyle(Color(nsColor: DS.Colors.remoteButtonForeground))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("−")
    }

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            // Horizontal puts − on the left, + on the right.
            if horizontal { minusButton }
            Button(action: { blink(); onUp() }) {
                Image(systemName: "plus")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .frame(width: min(width, height) * 0.3, height: min(width, height) * 0.3)
                    .foregroundStyle(Color(nsColor: DS.Colors.remoteButtonForeground))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("+")

            if !horizontal { minusButton }
        }
        .frame(width: width, height: height)
        .background(ControlBackground(shape: Capsule()))
        .overlay(Capsule().fill(.white.opacity(blinkOpacity)).allowsHitTesting(false))
        .clipShape(Capsule())
        .shortcutHint(.volumeUp, alignment: .top, offset: CGSize(width: 0, height: 7))
        .shortcutHint(.volumeDown, alignment: .bottom, offset: CGSize(width: 0, height: -7))
        .onChange(of: manager.keyboardBlinkCounter) { _, _ in
            if manager.keyboardBlinkButton == .volumeUp || manager.keyboardBlinkButton == .volumeDown {
                blink()
            }
        }
    }
}

private struct PowerButton: View {
    let onTap: () -> Void
    let onLongPress: () -> Void
    @State private var didLongPress = false

    init(onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        Image(systemName: "power")
            .font(.system(size: TouchMode.shared.isTouch ? 18 : 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: TouchMode.shared.isTouch ? 44 : 32, height: TouchMode.shared.isTouch ? 44 : 32)
            .background(Circle().fill(Color.secondary.opacity(0.12)))
            .onTapGesture {
                guard !didLongPress else {
                    didLongPress = false
                    return
                }
                onTap()
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                didLongPress = true
                onLongPress()
            }
    }
}

struct ErrorView: View {
    @Environment(AppleTVManager.self) private var manager
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Dismiss") {
                manager.disconnect()
            }
            .buttonStyle(.borderedProminent)

            // A pair-verify failure means the Apple TV no longer recognizes our
            // credentials (e.g. it was reset). Offer the unpair the message asks
            // for — Dismiss alone would leave the dead pairing in place.
            Button("Unpair this Apple TV") {
                if let deviceID = manager.connectedDeviceID {
                    KeychainStorage.delete(for: deviceID)
                }
                manager.disconnect()
            }
            .font(.caption)
            .foregroundStyle(.red)
            .buttonStyle(.plain)
        }
        .padding(24)
    }
}

/// macOS blocks Itsytv's connection. The manager keeps it waiting and goes on by itself once the
/// user turns Itsytv on under Local Network.
struct LocalNetworkDeniedView: View {
    @Environment(AppleTVManager.self) private var manager

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Local network access is off")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text("Turn on Itsytv in System Settings → Privacy & Security → Local Network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Privacy & Security") {
                SystemSettingsPane.privacySecurity.open()
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") {
                manager.disconnect()
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .padding(24)
    }
}

struct SettingsView: View {
    @Environment(AppleTVManager.self) private var manager
    @AppStorage(DockIcon.key) private var showInDock = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var pairedIDs = KeychainStorage.allPairedDeviceIDs()

    var body: some View {
        Form {
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
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                // Reachable from the app menu once Itsytv is in the Dock.
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockIcon.apply() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 300)
    }
}

/// Prevents `isMovableByWindowBackground` from intercepting drags on this view.
/// Place as a `.background()` on any interactive area that needs to handle its own drag gestures.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NonDraggableView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class NonDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
