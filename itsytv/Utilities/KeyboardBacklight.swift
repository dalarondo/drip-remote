import Foundation

/// Dims and restores the Mac's keyboard backlight.
///
/// macOS has no public API for this, so it uses the private `KeyboardBrightnessClient`
/// class in CoreBrightness, looked up at run time. If the class or its methods are
/// missing (a future macOS, or a sandbox that blocks it) every call quietly does nothing.
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    private typealias Getter = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Setter = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private let client: NSObject?
    private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    /// Brightness of each keyboard before we dimmed it; nil while not dimmed.
    private var saved: [UInt64: Float]?

    private init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        if let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let candidate = cls.init()
            let usable = candidate.responds(to: getSelector) && candidate.responds(to: setSelector)
                && candidate.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs"))
            client = usable ? candidate : nil
        } else {
            client = nil
        }
    }

    private var keyboardIDs: [UInt64] {
        guard let client,
              let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return ids.map(\.uint64Value)
    }

    var isDimmed: Bool { saved != nil }

    /// Turn the backlight off, remembering the current level.
    func dim() {
        guard let client, saved == nil else { return }
        let get = unsafeBitCast(client.method(for: getSelector), to: Getter.self)
        let set = unsafeBitCast(client.method(for: setSelector), to: Setter.self)
        var levels: [UInt64: Float] = [:]
        for id in keyboardIDs {
            levels[id] = get(client, getSelector, id)
            _ = set(client, setSelector, 0, id)
        }
        saved = levels
    }

    /// Put the backlight back to the level it had before `dim()`.
    func restore() {
        guard let client, let levels = saved else { return }
        saved = nil
        let set = unsafeBitCast(client.method(for: setSelector), to: Setter.self)
        for (id, level) in levels {
            _ = set(client, setSelector, level, id)
        }
    }
}
