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
    private let decayWithin: TimeInterval = 0.25 // a clap must die away this fast
    private let minGap: TimeInterval = 0.15
    private let maxGap: TimeInterval = 0.7
    private let classifierThreshold: Double = 0.2
    private let classifierWindow: TimeInterval = 1.2
    private let cooldown: TimeInterval = 1.5

    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private let queue = DispatchQueue(label: "com.itsytv.clap")
    private var running = false

    // State below is only touched on `queue`.
    private var ambient: Float = 0.01
    private var wasLoud = false
    private var pendingOnset: (time: TimeInterval, level: Float)?
    private var lastSharpOnset: TimeInterval = -10
    private var candidateDeadline: TimeInterval?
    private var lastClassifierHit: TimeInterval = -10
    private var lastFire: TimeInterval = -10

    private static let clapLabels: Set<String> = ["clapping", "applause", "finger_snapping"]

    /// Ask for microphone access if needed, then start listening.
    func start() {
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

    func stop() {
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
            self.queue.async {
                self.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
                self.process(level: level, now: ProcessInfo.processInfo.systemUptime, bufferDuration: duration)
            }
        }

        do {
            try engine.start()
            running = true
            log.info("clap detection listening")
        } catch {
            input.removeTap(onBus: 0)
            log.error("could not start microphone: \(error.localizedDescription, privacy: .public)")
        }
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
        let threshold = max(minLevel, ambient * ambientMultiple)
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

        if let deadline = candidateDeadline, now > deadline {
            candidateDeadline = nil
            log.debug("double onset not confirmed as a clap")
        }
    }

    private func sharpOnset(at time: TimeInterval, now: TimeInterval) {
        let gap = time - lastSharpOnset
        lastSharpOnset = time
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
        log.info("double clap")
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
    }
}
