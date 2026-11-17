import AppKit
import SwiftUI
import ItsytvCore

// The island widget: what command center becomes when it retracts. It sits around the
// camera island like a Live Activity – a small black pill showing playback state – and
// expands on tap into playback controls plus a "drip" button that sends command center
// pouring back out over the screen.
//
// macOS has no app-facing API for drawing in the island, so this is an ordinary
// borderless, transparent panel positioned over it; black on the island's black makes
// the two read as one shape.

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    // The panel never becomes key, so the first click has to act.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandWidgetController {
    private let manager: AppleTVManager
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private let state = IslandWidgetState()

    /// Drip button: open command center.
    var onDrip: (() -> Void)?
    /// Remote button: show the small touch remote.
    var onRemote: (() -> Void)?

    var isVisible: Bool { panel != nil }

    /// The small remote is currently out (the remote button shows as active).
    var remoteIsOpen: Bool {
        get { state.remoteIsOpen }
        set { state.remoteIsOpen = newValue }
    }

    func collapse() { state.expanded = false }

    var isExpanded: Bool { state.expanded }

    init(manager: AppleTVManager) {
        self.manager = manager
    }

    func show(on screen: NSScreen?) {
        guard panel == nil, let screen = screen ?? NSScreen.main else { return }
        let island = CommandModeController.islandRect(on: screen)

        // Big enough for the expanded widget; everything outside the black shape is
        // transparent and lets clicks through to the menu bar and apps beneath.
        let size = NSSize(width: 460, height: 290)
        let origin = NSPoint(
            x: screen.frame.minX + island.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false

        state.expanded = false
        let root = IslandWidgetView(
            state: state,
            islandSize: island.size,
            onDrip: { [weak self] in self?.onDrip?() },
            onRemote: { [weak self] in self?.onRemote?() }
        )
        .environment(manager)

        let hosting = IslandHostingView(rootView: root)
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        // A click anywhere else collapses the expanded widget.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.state.expanded = false
        }
    }

    func hide() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel?.close()
        panel = nil
    }
}

@Observable
final class IslandWidgetState {
    var expanded = false
    var remoteIsOpen = false
}

struct IslandWidgetView: View {
    @Environment(AppleTVManager.self) private var manager
    let state: IslandWidgetState
    let islandSize: CGSize
    let onDrip: () -> Void
    let onRemote: () -> Void

    @AppStorage("commandModeRed") private var redOnBlack = false

    /// Width of each "ear" either side of the camera in the compact pill.
    static let ear: CGFloat = 64
    private var ear: CGFloat { Self.ear }
    static let expandedSize = CGSize(width: 420, height: 262)
    private var expandedSize: CGSize { Self.expandedSize }

    private var isPlaying: Bool { manager.mrpManager.nowPlaying?.isPlaying == true }

    var body: some View {
        let expanded = state.expanded
        let width = expanded ? expandedSize.width : islandSize.width + ear * 2
        let height = expanded ? expandedSize.height : islandSize.height

        ZStack(alignment: .top) {
            // Flat on top so it runs into the screen edge; rounded below, like the island.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: expanded ? 36 : islandSize.height / 2,
                bottomTrailingRadius: expanded ? 36 : islandSize.height / 2,
                topTrailingRadius: 0
            )
            .fill(.black)

            if expanded {
                expandedContent
                    .padding(.top, islandSize.height + 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else {
                compactContent
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { state.expanded = true } }
        // Interacting with the island takes over: the remote shrinks back in as it expands.
        .onChange(of: state.expanded) { _, isExpanded in
            if isExpanded, state.remoteIsOpen { onRemote() }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: expanded)
        .colorMultiply(redOnBlack ? Color(red: 1, green: 0.12, blue: 0.08) : .white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // Compact: a glyph left of the camera, playback state right of it.
    private var compactContent: some View {
        HStack(spacing: 0) {
            // While the remote is out, the left ear is a shortcut to put it away.
            Image(systemName: state.remoteIsOpen ? "appletvremote.gen4.fill" : "appletv.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: ear, height: islandSize.height)
                .contentShape(Rectangle())
                .onTapGesture {
                    if state.remoteIsOpen { onRemote() } else { state.expanded = true }
                }
            Spacer().frame(width: islandSize.width)
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                .frame(width: ear)
        }
        .frame(height: islandSize.height)
    }

    // Expanded: what's playing, transport, and the way out to command center or the remote.
    private var expandedContent: some View {
        let mrp = manager.mrpManager
        let np = mrp.nowPlaying

        return VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(np?.title ?? manager.connectedDeviceName ?? "Apple TV")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(np.flatMap { [$0.artist, $0.album].compactMap { $0 }.joined(separator: " — ") } ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { state.expanded = false }   // tap the title to collapse

            HStack(spacing: 14) {
                control("appletvremote.gen4.fill", size: 44,
                        help: state.remoteIsOpen ? "Put the remote away" : "Show the remote",
                        active: state.remoteIsOpen, action: onRemote)
                control("backward.fill", size: 48, help: "Previous") { mrp.sendCommand(.previousTrack) }
                control(isPlaying ? "pause.fill" : "play.fill", size: 60, help: "Play / pause") {
                    manager.pressButton(.playPause)
                }
                control("forward.fill", size: 48, help: "Next") { mrp.sendCommand(.nextTrack) }
                // The drip: command center pours back out of the island.
                control("drop.fill", size: 44, help: "Command center", action: onDrip)
            }

            NowPlayingProgress(
                nowPlaying: np,
                duration: np?.duration ?? 0,
                onSeek: { mrp.seekToPosition($0) }
            )
            .padding(.horizontal, 28)
            .opacity((np?.duration ?? 0) > 0 ? 1 : 0.3)
        }
    }

    private func control(_ symbol: String, size: CGFloat, help: String, active: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(active ? 0.22 : 0)))
                .background(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
