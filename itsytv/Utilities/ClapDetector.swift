import AVFoundation
import SoundAnalysis
import os.log

private let log = Logger(subsystem: "com.itsytv.app", category: "Clap")

/// Listens on the microphone for a double clap.
///
/// Two checks have to agree, because the Mac sits in the same room as the TV it controls:
/// 1. **Onsets** – two sharp, loud transients (well above the room's level, dying away
///    quickly) between 0.15 s and 0.7 s apart. Found directly from the audio level, so
///    the timing is tight.
/// 2. **Classifier** – Apple's built-in sound classifier (SoundAnalysis) reports
///    "clapping" around the same moment. This rejects knocks, door slams and the like.
///
/// Audio is analysed in memory on this Mac; nothing is recorded or sent anywhere.
final class ClapDetector: NSObject, SNResultsObserving {
    /// Called on the main queue when a double clap is recognised.
    var onDoubleClap: (() -> Void)?

    // Tuning
    private let minLevel: Float = 0.05          // absolute RMS floor for a clap
    private let ambientMultiple: Float = 6      // …and this many times the room level
    private let maxThreshold: Float = 0.2       // …but never demand more than this, however loud the TV
    private let decayWithin: TimeInterval = 0.25 // a clap must die away this fast
    private let minGap: TimeInterval = 0.15
    private let maxGap: TimeInterval = 0.7
    private let classifierThreshold: Double = 0.12
    private let classifierWindow: TimeInterval = 1.2
    private let cooldown: TimeInterval = 1.5

    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let queue = DispatchQueue(label: "com.itsytv.clap")
    private var running = false
    /// Listening is wanted (between `start()` and `shutDown()`), even if the engine is momentarily down.
    private var wanted = false

    /// Stop for good (leaving command mode).
    func shutDown() {
        wanted = false
        stop()
    }

    // State below is only touched on `queue`.
    private var ambient: Float = 0.01
    private var wasLoud = false
    private var pendingOnset: (time: TimeInterval, level: Float)?
    private var lastSharpOnset: TimeInterval = -10
    private var candidateDeadline: TimeInterval?
    private var lastClassifierHit: TimeInterval = -10
    private var lastFire: TimeInterval = -10
    private var lastHealthLog: TimeInterval = 0
    private var configObserver: NSObjectProtocol?

    private static let clapLabels: Set<String> = ["clapping", "applause", "finger_snapping"]

    /// Ask for microphone access if needed, then start listening.
    func start() {
        wanted = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async { if granted { self?.startEngine() } }
            }
        default:
            log.error("microphone access denied – clap detection is off")
        }
    }

    /// Full restart: the audio engine stops itself when the input device or its format
    /// changes (AirPods connecting, another app taking the mic, …), and a failed
    /// classifier request never produces results again.
    private func restart(reason: String) {
        log.notice("restarting: \(reason, privacy: .public)")
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.wanted else { return }
            self.startEngine()
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { [weak self] in
            self?.analyzer?.removeAllRequests()
            self?.analyzer = nil
        }
    }

    private func startEngine() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("no usable microphone input")
            return
        }

        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // Shortest window the classifier allows (0.5 s) so two quick claps fill it.
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48_000)
            request.overlapFactor = 0.75
            try analyzer.add(request, withObserver: self)
        } catch {
            log.error("sound classifier unavailable: \(error.localizedDescription, privacy: .public)")
        }
        self.analyzer = analyzer

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let level = Self.rms(buffer)
            let duration = Double(buffer.frameLength) / format.sampleRate
            // The engine reuses tap buffers, so hand the queue its own copy.
            guard let copy = Self.copy(buffer) else { return }
            self.queue.async {
                self.analyzer?.analyze(copy, atAudioFramePosition: when.sampleTime)
                self.process(level: level, now: ProcessInfo.processInfo.systemUptime, bufferDuration: duration)
            }
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart(reason: "audio configuration changed")
        }

        do {
            try engine.start()
            running = true
            log.notice("clap detection listening")
        } catch {
            input.removeTap(onBus: 0)
            log.error("could not start microphone: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
        }
        return copy
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += data[i] * data[i] }
        return (sum / Float(n)).squareRoot()
    }

    // MARK: - Onset detection (on `queue`)

    private func process(level: Float, now: TimeInterval, bufferDuration: TimeInterval) {
        let threshold = min(maxThreshold, max(minLevel, ambient * ambientMultiple))
        let loud = level > threshold

        // A new loud burst starts a possible clap.
        if loud && !wasLoud && pendingOnset == nil {
            pendingOnset = (now, level)
        }
        wasLoud = loud

        // A clap dies away quickly; speech, music and rumble don't.
        if let onset = pendingOnset {
            if level < onset.level * 0.4 {
                pendingOnset = nil
                sharpOnset(at: onset.time, now: now)
            } else if now - onset.time > decayWithin {
                pendingOnset = nil
            }
        }

        // Track the room level only while it's quiet-ish, so claps don't raise the bar.
        if !loud { ambient = ambient * 0.97 + level * 0.03 }

        // Periodic health line, so a stall can be diagnosed from the log.
        if now - lastHealthLog > 15 {
            lastHealthLog = now
            log.notice("listening: ambient \(self.ambient, format: .fixed(precision: 4)) threshold \(threshold, format: .fixed(precision: 3)) last clap label \(now - self.lastClassifierHit, format: .fixed(precision: 1))s ago")
        }

        if let deadline = candidateDeadline, now > deadline {
            candidateDeadline = nil
            log.notice("double onset not confirmed as a clap")
        }
    }

    private func sharpOnset(at time: TimeInterval, now: TimeInterval) {
        let gap = time - lastSharpOnset
        lastSharpOnset = time
        log.notice("sharp sound, \(gap, format: .fixed(precision: 2))s after the previous one")
        guard gap >= minGap, gap <= maxGap, now - lastFire > cooldown else { return }
        // Two sharp sounds, clap-spaced. Fire if the classifier agrees (now or shortly).
        if now - lastClassifierHit < classifierWindow {
            fire(now: now)
        } else {
            candidateDeadline = now + classifierWindow
        }
    }

    private func fire(now: TimeInterval) {
        lastFire = now
        candidateDeadline = nil
        lastSharpOnset = -10
        log.notice("double clap")
        DispatchQueue.main.async { [weak self] in self?.onDoubleClap?() }
    }

    // MARK: - Classifier results

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classifications
            .filter { Self.clapLabels.contains($0.identifier) }
            .map(\.confidence).max() ?? 0
        guard confidence >= classifierThreshold else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastClassifierHit = now
            if self.candidateDeadline != nil, now - self.lastFire > self.cooldown {
                self.fire(now: now)
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        log.error("classifier failed: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.restart(reason: "classifier failed") }
    }

    func requestDidComplete(_ request: SNRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.restart(reason: "classifier stopped")
        }
    }
}
