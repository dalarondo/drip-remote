import AVFoundation
import Vision
import os.log

private let log = Logger(subsystem: "com.itsytv.app", category: "Gesture")

/// Watches the camera for two held hand shapes: a raised open palm ("stop") and a
/// thumbs-up ("go"). Frames are analysed in memory on this Mac with Vision's hand-pose
/// detector; nothing is recorded or sent anywhere.
final class HandGestureDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Gesture: String {
        case palm, thumbsUp
    }

    /// Called on the main queue when a gesture has been held long enough.
    var onGesture: ((Gesture) -> Void)?

    // Tuning
    private let frameInterval: TimeInterval = 0.12   // analyse ~8 frames a second
    private let holdTime: TimeInterval = 0.8         // how long the shape must be held
    private let dropTolerance: TimeInterval = 0.4    // missed frames allowed during the hold
    private let cooldown: TimeInterval = 2.0
    private let minConfidence: Float = 0.3

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.itsytv.gesture")
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var configured = false
    private var wanted = false

    // State below is only touched on `queue`.
    private var lastFrame: TimeInterval = 0
    private var current: Gesture?
    private var heldSince: TimeInterval = 0
    private var lastSeen: TimeInterval = 0
    private var lastFire: TimeInterval = -10
    /// After firing, the hand must go away before the same gesture can fire again.
    private var armed = true

    func start() {
        wanted = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.startSession() } else { log.error("camera access denied") }
            }
        default:
            log.error("camera access denied – hand gestures are off")
        }
    }

    func shutDown() {
        wanted = false
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            log.notice("camera stopped")
        }
    }

    private func startSession() {
        queue.async { [weak self] in
            guard let self, self.wanted else { return }
            if !self.configured {
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera) else {
                    log.error("no usable camera")
                    return
                }
                self.session.beginConfiguration()
                self.session.sessionPreset = .vga640x480   // plenty for hand pose, and light on power
                if self.session.canAddInput(input) { self.session.addInput(input) }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) { self.session.addOutput(output) }
                self.session.commitConfiguration()
                self.configured = true
            }
            self.current = nil
            self.armed = true
            if !self.session.isRunning {
                self.session.startRunning()
                log.notice("camera watching for hand gestures")
            }
        }
    }

    // MARK: - Frames (on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= frameInterval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        try? handler.perform([request])
        let seen = (request.results ?? []).compactMap(classify).first
        update(seen: seen, now: now)
    }

    private func update(seen: Gesture?, now: TimeInterval) {
        if let seen {
            if seen != current {
                current = seen
                heldSince = now
            }
            lastSeen = now
            if armed, now - heldSince >= holdTime, now - lastFire > cooldown {
                armed = false
                lastFire = now
                log.notice("gesture: \(seen.rawValue, privacy: .public)")
                DispatchQueue.main.async { [weak self] in self?.onGesture?(seen) }
            }
        } else if now - lastSeen > dropTolerance {
            // The hand went away (or changed to no recognised shape): reset and re-arm.
            current = nil
            armed = true
        }
    }

    // MARK: - Hand shape

    private func classify(_ hand: VNHumanHandPoseObservation) -> Gesture? {
        guard let points = try? hand.recognizedPoints(.all) else { return nil }
        func p(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let point = points[name], point.confidence >= minConfidence else { return nil }
            return point.location
        }
        guard let wrist = p(.wrist),
              let thumbTip = p(.thumbTip), let thumbIP = p(.thumbIP), let thumbCMC = p(.thumbCMC),
              let indexTip = p(.indexTip), let indexPIP = p(.indexPIP), let indexMCP = p(.indexMCP),
              let middleTip = p(.middleTip), let middlePIP = p(.middlePIP), let middleMCP = p(.middleMCP),
              let ringTip = p(.ringTip), let ringPIP = p(.ringPIP),
              let littleTip = p(.littleTip), let littlePIP = p(.littlePIP)
        else { return nil }

        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        // Hand size, to make every threshold independent of distance from the camera.
        let size = dist(wrist, middleMCP)
        guard size > 0.01 else { return nil }

        // A finger is extended when its tip is clearly further from the wrist than its
        // middle joint, and curled when the tip has come back inside it.
        func extended(_ tip: CGPoint, _ pip: CGPoint) -> Bool { dist(tip, wrist) > dist(pip, wrist) * 1.2 }
        func curled(_ tip: CGPoint, _ pip: CGPoint) -> Bool { dist(tip, wrist) < dist(pip, wrist) * 1.05 }

        let fingers = [(indexTip, indexPIP), (middleTip, middlePIP), (ringTip, ringPIP), (littleTip, littlePIP)]
        let thumbOut = dist(thumbTip, wrist) > dist(thumbIP, wrist) * 1.1

        // Vision's y axis points up.
        // Open palm, raised: every finger extended, fingertips well above the wrist.
        if fingers.allSatisfy({ extended($0.0, $0.1) }), thumbOut,
           middleTip.y - wrist.y > size * 1.2 {
            return .palm
        }

        // Thumbs-up: four fingers curled, thumb extended and pointing up, above the knuckles.
        let thumbVector = CGPoint(x: thumbTip.x - thumbCMC.x, y: thumbTip.y - thumbCMC.y)
        if fingers.allSatisfy({ curled($0.0, $0.1) }), thumbOut,
           thumbVector.y > abs(thumbVector.x), thumbVector.y > size * 0.5,
           thumbTip.y > indexMCP.y, thumbTip.y > indexTip.y {
            return .thumbsUp
        }
        return nil
    }
}
