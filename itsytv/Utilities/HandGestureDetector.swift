import AVFoundation
import Vision
import os.log
import CoreImage

private let log = Logger(subsystem: "com.itsytv.app", category: "Gesture")

/// Watches the camera for two held hand shapes: a raised open palm ("stop") and a
/// thumbs-up ("go"). Frames are analysed in memory on this Mac with Vision's hand-pose
/// detector; nothing is recorded or sent anywhere.
final class HandGestureDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Gesture: String {
        case palm, thumbsUp, waveLeft, waveRight

        /// Palm and a wave to the left mean stop; thumbs-up and a wave to the right mean go.
        var wantsPlaying: Bool { self == .thumbsUp || self == .waveRight }
    }

    /// Called on the main queue when a gesture has been held long enough.
    var onGesture: ((Gesture) -> Void)?

    // Tuning
    private let frameInterval: TimeInterval = 0.12   // analyse ~8 frames a second
    private let holdTime: TimeInterval = 0.8         // how long the shape must be held
    private let dropTolerance: TimeInterval = 0.4    // missed frames allowed during the hold
    private let cooldown: TimeInterval = 2.0
    private let minConfidence: Float = 0.2
    // Waves: the raised hand must travel this many shoulder-widths sideways, this fast.
    private let waveTravel: CGFloat = 0.6
    private let waveWindow: TimeInterval = 0.9

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.itsytv.gesture")
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    /// Finds the person at a distance, where a hand is too small for the hand detector alone.
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private var wristTracks: [String: [(t: TimeInterval, x: CGFloat, y: CGFloat)]] = [:]
    private var lastDiagnostic: TimeInterval = 0
    // Debugging aid: when `ITSYTV_GESTURE_DEBUG_DIR` (or the `gestureDebugSnapshotDir` default) is set, two frames are
    // saved there (about 6 s and 14 s after the camera starts) so the picture can be inspected.
    private var sessionStart: TimeInterval = 0
    private var snapshotsTaken = 0
    private var configured = false
    private var wanted = false
    private var askingForAccess = false

    // State below is only touched on `queue`.
    private var lastFrame: TimeInterval = 0
    private var current: Gesture?
    private var heldSince: TimeInterval = 0
    private var holdAnchor: CGPoint = .zero
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
            guard !askingForAccess else { return }      // ask once
            askingForAccess = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.askingForAccess = false
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
                // A hand across the room is only a few dozen pixels at VGA, so use the
                // highest of these the camera supports.
                for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .vga640x480]
                where self.session.canSetSessionPreset(preset) {
                    self.session.sessionPreset = preset
                    break
                }
                if self.session.canAddInput(input) { self.session.addInput(input) }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                // Biplanar YUV: plane 0 is brightness, which the diagnostics sample.
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(output) { self.session.addOutput(output) }
                self.session.commitConfiguration()
                self.configured = true
            }
            self.current = nil
            self.armed = true
            self.sessionStart = ProcessInfo.processInfo.systemUptime
            self.snapshotsTaken = 0
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
        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)

        if snapshotsTaken < 2, now - sessionStart > (snapshotsTaken == 0 ? 6 : 14),
           let dir = ProcessInfo.processInfo.environment["ITSYTV_GESTURE_DEBUG_DIR"]
               ?? UserDefaults.standard.string(forKey: "gestureDebugSnapshotDir") {
            snapshotsTaken += 1
            let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("gesture-frame-\(snapshotsTaken).jpg")
            if let data = CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB()) {
                try? data.write(to: url)
                log.notice("saved debug frame \(self.snapshotsTaken)")
            }
        }

        // 1. Whole frame – works when the hand is close to the camera.
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        var failure: String?
        do { try handler.perform([request]) } catch { failure = "hand: \(error.localizedDescription)" }
        var hands = request.results?.count ?? 0
        var seen = (request.results ?? []).compactMap { classify($0, scaleX: width, scaleY: height, origin: .zero) }.first

        // 2. At a distance: find the body, then look for a hand in a close crop around each wrist.
        do { try handler.perform([bodyRequest]) } catch { failure = "body: \(error.localizedDescription)" }
        // Everyone in frame counts – the person gesturing is not always the first one found.
        let bodies = bodyRequest.results ?? []
        let body = bodies.first
        var wave: Gesture?
        if bodies.isEmpty { wristTracks.removeAll() }
        for (index, person) in bodies.enumerated() {
            guard let joints = try? person.recognizedPoints(.all) else { continue }
            func j(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                guard let point = joints[name], point.confidence >= minConfidence else { return nil }
                return CGPoint(x: point.location.x * width, y: point.location.y * height)   // pixels
            }
            let shoulders: CGFloat? = {
                guard let l = j(.leftShoulder), let r = j(.rightShoulder) else { return nil }
                return hypot(l.x - r.x, l.y - r.y)
            }()

            for (hand, wristName, elbowName) in [("L", VNHumanBodyPoseObservation.JointName.leftWrist, VNHumanBodyPoseObservation.JointName.leftElbow),
                                                  ("R", .rightWrist, .rightElbow)] {
                let side = "\(index)\(hand)"
                guard let wrist = j(wristName), let elbow = j(elbowName) else {
                    wristTracks[side] = nil
                    continue
                }
                let forearm = hypot(wrist.x - elbow.x, wrist.y - elbow.y)

                // Wave: a raised hand (wrist above elbow) sweeping sideways.
                if wrist.y > elbow.y, let shoulders, shoulders > 1 {
                    if let w = trackWave(side: side, wrist: wrist, scale: shoulders, now: now) { wave = w }
                } else {
                    wristTracks[side] = nil
                }

                // Hand shape: crop a square around where the hand must be and run hand pose on it.
                guard seen == nil, forearm > 4 else { continue }
                let sidePx = max(forearm * 2.4, 96)
                let centre = CGPoint(x: wrist.x + (wrist.x - elbow.x) * 0.45, y: wrist.y + (wrist.y - elbow.y) * 0.45)
                let roiPx = CGRect(x: centre.x - sidePx / 2, y: centre.y - sidePx / 2, width: sidePx, height: sidePx)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                guard roiPx.width > 32, roiPx.height > 32 else { continue }
                request.regionOfInterest = CGRect(x: roiPx.minX / width, y: roiPx.minY / height,
                                                  width: roiPx.width / width, height: roiPx.height / height)
                try? handler.perform([request])
                hands += request.results?.count ?? 0
                seen = (request.results ?? []).compactMap { classify($0, scaleX: roiPx.width, scaleY: roiPx.height, origin: roiPx.origin) }.first
            }
        }

        if now - lastDiagnostic > 3 {
            lastDiagnostic = now
            let joints = (try? body?.recognizedPoints(.all))?.values.filter { $0.confidence >= self.minConfidence }.count ?? 0
            log.notice("seeing: \(Int(width))x\(Int(height)) brightness \(Self.brightness(pixels), format: .fixed(precision: 2)) people \(bodies.count) joints \(joints) hands \(hands) shape \(seen?.gesture.rawValue ?? "none", privacy: .public) error \(failure ?? "none", privacy: .public)")
        }

        if let wave, now - lastFire > cooldown {
            lastFire = now
            wristTracks.removeAll()
            log.notice("gesture: \(wave.rawValue, privacy: .public)")
            DispatchQueue.main.async { [weak self] in self?.onGesture?(wave) }
            return
        }
        update(seen: seen, now: now)
    }

    /// Average brightness of the frame, 0 (black) to 1 (white), from a sparse sample.
    private static func brightness(_ pixels: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return -1 }
        let w = CVPixelBufferGetWidthOfPlane(pixels, 0), h = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, count = 0
        for y in Swift.stride(from: 0, to: h, by: 16) {
            for x in Swift.stride(from: 0, to: w, by: 16) {
                sum += Int(bytes[y * stride + x])
                count += 1
            }
        }
        return count > 0 ? Double(sum) / Double(count) / 255 : -1
    }

    /// Sideways travel of a raised wrist within the wave window, in shoulder-widths.
    private func trackWave(side: String, wrist: CGPoint, scale: CGFloat, now: TimeInterval) -> Gesture? {
        var track = (wristTracks[side] ?? []).filter { now - $0.t <= waveWindow }
        track.append((now, wrist.x, wrist.y))
        wristTracks[side] = track
        guard let first = track.first, track.count >= 3 else { return nil }
        let dx = wrist.x - first.x
        let dy = wrist.y - first.y
        guard abs(dx) > scale * waveTravel, abs(dy) < abs(dx) * 0.5 else { return nil }
        // The camera image is not mirrored: your left is the image's right (x grows).
        return dx > 0 ? .waveLeft : .waveRight
    }

    private func update(seen: Shape?, now: TimeInterval) {
        if let seen {
            // A held shape must stay still. An open hand sweeping sideways is a wave,
            // not a palm – so if the hand drifts more than its own size, the hold restarts.
            let moved = hypot(seen.position.x - holdAnchor.x, seen.position.y - holdAnchor.y) > seen.size * 1.0
            if seen.gesture != current || moved {
                current = seen.gesture
                heldSince = now
                holdAnchor = seen.position
            }
            lastSeen = now
            if armed, now - heldSince >= holdTime, now - lastFire > cooldown {
                armed = false
                lastFire = now
                log.notice("gesture: \(seen.gesture.rawValue, privacy: .public)")
                let gesture = seen.gesture
                DispatchQueue.main.async { [weak self] in self?.onGesture?(gesture) }
            }
        } else if now - lastSeen > dropTolerance {
            // The hand went away (or changed to no recognised shape): reset and re-arm.
            current = nil
            armed = true
        }
    }

    // MARK: - Hand shape

    /// A recognised hand shape, with where the hand is (pixels) and how big, so a hold
    /// can require the hand to stay put.
    private struct Shape {
        let gesture: Gesture
        let position: CGPoint
        let size: CGFloat
    }

    /// `scaleX` / `scaleY` are the pixel size of the region the hand was detected in, so
    /// distances are measured in pixels (Vision's 0–1 coordinates stretch x and y differently).
    private func classify(_ hand: VNHumanHandPoseObservation, scaleX: CGFloat, scaleY: CGFloat, origin: CGPoint) -> Shape? {
        guard let points = try? hand.recognizedPoints(.all) else { return nil }
        func p(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let point = points[name], point.confidence >= minConfidence else { return nil }
            return CGPoint(x: point.location.x * scaleX, y: point.location.y * scaleY)
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
        guard size > 4 else { return nil }

        // A finger is extended when its tip is clearly further from the wrist than its
        // middle joint, and curled when the tip has come back inside it.
        func extended(_ tip: CGPoint, _ pip: CGPoint) -> Bool { dist(tip, wrist) > dist(pip, wrist) * 1.12 }
        func curled(_ tip: CGPoint, _ pip: CGPoint) -> Bool { dist(tip, wrist) < dist(pip, wrist) * 1.05 }

        let fingers = [(indexTip, indexPIP), (middleTip, middlePIP), (ringTip, ringPIP), (littleTip, littlePIP)]
        let thumbOut = dist(thumbTip, wrist) > dist(thumbIP, wrist) * 1.1

        // Vision's y axis points up.
        // Open palm, raised: every finger extended, fingertips well above the wrist.
        if fingers.allSatisfy({ extended($0.0, $0.1) }), thumbOut,
           middleTip.y - wrist.y > size * 1.0 {
            return Shape(gesture: .palm, position: CGPoint(x: origin.x + wrist.x, y: origin.y + wrist.y), size: size)
        }

        // Thumbs-up: four fingers curled, thumb extended and pointing up, above the knuckles.
        let thumbVector = CGPoint(x: thumbTip.x - thumbCMC.x, y: thumbTip.y - thumbCMC.y)
        if fingers.allSatisfy({ curled($0.0, $0.1) }), thumbOut,
           thumbVector.y > abs(thumbVector.x), thumbVector.y > size * 0.5,
           thumbTip.y > indexMCP.y, thumbTip.y > indexTip.y {
            return Shape(gesture: .thumbsUp, position: CGPoint(x: origin.x + wrist.x, y: origin.y + wrist.y), size: size)
        }
        return nil
    }
}
