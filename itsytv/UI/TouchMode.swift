import AppKit
import Observation

/// "Touch layout" setting, stored under `touchLayout` in UserDefaults.
enum TouchLayoutPreference: String, CaseIterable {
    case auto = "Automatic"
    case always = "Always"
    case never = "Never"

    static let defaultsKey = "touchLayout"
}

/// Tracks whether the remote is being driven by a finger (a Mac with a touch display,
/// or a Sidecar iPad) or by a pointer, so the panel can switch to a larger,
/// right-edge-docked layout.
///
/// Detection follows Apple's "Adopting gesture recognizers in your app": AppKit does
/// not deliver direct touches through the responder chain or event monitors, and it
/// emulates mouse events from a single finger – so mouse events can't tell a finger
/// from a cursor. Only a gesture recognizer sees the difference: its delegate gets
/// `shouldReceive touch:` for a direct touch and `shouldAttemptToRecognizeWith event:`
/// for pointer input (which direct touches never call). `attachSniffer(to:)` installs
/// a recognizer that only observes those callbacks and never recognizes anything.
///
/// The "Touch layout" menu item (Automatic / Always / Never) overrides detection.
@Observable
final class TouchMode: NSObject, NSGestureRecognizerDelegate {
    static let shared = TouchMode()

    /// Panel width in each layout.
    static let compactWidth: CGFloat = 176
    static let touchWidth: CGFloat = 300

    private(set) var preference: TouchLayoutPreference
    private(set) var touchDetected = false

    /// Called whenever `isTouch` may have changed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastReported = false

    /// Command mode (full-screen control panel) always uses the large sizes.
    var commandModeActive = false {
        didSet { notifyIfChanged() }
    }

    var isTouch: Bool {
        if commandModeActive { return true }
        return switch preference {
        case .auto: touchDetected
        case .always: true
        case .never: false
        }
    }

    var panelWidth: CGFloat { isTouch ? Self.touchWidth : Self.compactWidth }

    private override init() {
        preference = Self.storedPreference()
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadPreference()
        }
    }

    /// Watch `view` (and its subviews) for touch vs pointer input.
    func attachSniffer(to view: NSView) {
        let sniffer = NSClickGestureRecognizer()
        sniffer.delegate = self
        sniffer.allowedTouchTypes = .direct
        // Never hold back or swallow the real events.
        sniffer.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(sniffer)
    }

    // A finger on the display. Returning false keeps the sniffer out of the stream.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        if touch.type == .direct { setTouchDetected(true) }
        return false
    }

    // Pointer input (mouse / trackpad). Direct touches never call this.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        if event.type == .leftMouseDown { setTouchDetected(false) }
        return false
    }

    private func setTouchDetected(_ touched: Bool) {
        guard touched != touchDetected else { return }
        touchDetected = touched
        notifyIfChanged()
    }

    private static func storedPreference() -> TouchLayoutPreference {
        UserDefaults.standard.string(forKey: TouchLayoutPreference.defaultsKey)
            .flatMap(TouchLayoutPreference.init(rawValue:)) ?? .auto
    }

    private func reloadPreference() {
        let stored = Self.storedPreference()
        guard stored != preference else { return }
        preference = stored
        notifyIfChanged()
    }

    private func notifyIfChanged() {
        guard isTouch != lastReported else { return }
        lastReported = isTouch
        onChange?()
    }

    /// Sync the baseline before the panel opens, without firing `onChange`.
    func syncBaseline() { lastReported = isTouch }
}
