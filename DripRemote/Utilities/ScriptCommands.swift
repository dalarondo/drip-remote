import AppKit
import os.log
import ItsytvCore

private let log = Logger(subsystem: "com.dripremote.app", category: "Script")

// Permissive on unknown state: only skip when we *know* the TV is already
// in the requested state. nowPlaying = nil (no MRP update yet on this
// session) means we forward the command — MRP .pause / .play is a safe
// no-op TV-side when nothing is loaded.

@objc(DRPPauseScriptCommand)
final class PauseScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let manager = AppDelegate.shared?.manager else {
                log.error("pause: AppDelegate.shared not available")
                return
            }
            if let np = manager.mrpManager.nowPlaying, !np.isPlaying { return }
            manager.mrpManager.sendCommand(.pause)
        }
        return nil
    }
}

@objc(DRPPlayScriptCommand)
final class PlayScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            guard let manager = AppDelegate.shared?.manager else {
                log.error("play: AppDelegate.shared not available")
                return
            }
            if let np = manager.mrpManager.nowPlaying, np.isPlaying { return }
            manager.mrpManager.sendCommand(.play)
        }
        return nil
    }
}
