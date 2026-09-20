import CoreMotion
import Foundation
import Observation

/// Bridges `CMHeadphoneMotionManager` to `MotionAnalyzer`, and turns the analyzer's
/// effects into real volume and playback changes.
@MainActor
@Observable
final class HeadTrackingController: NSObject, CMHeadphoneMotionManagerDelegate {

    /// Width of the live chart's rolling window, in seconds.
    static let chartWindow: TimeInterval = 10
    /// Fraction of the pre-removal volume to drop to while the debounce runs.
    static let duckFactor: Float = 0.2

    enum Availability: Equatable {
        case ready
        case deviceMotionUnavailable
        case notAuthorized(CMAuthorizationStatus)

        var isReady: Bool { self == .ready }
    }

    struct Sample: Identifiable, Equatable {
        let timestamp: TimeInterval
        let angleDegrees: Double
        var id: TimeInterval { timestamp }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    // MARK: - Observable state

    private(set) var availability: Availability = .ready
    private(set) var isRunning = false
    /// `true` once headphones that report motion have actually connected.
    private(set) var isConnected = false
    /// `nil` until the baseline has been captured.
    private(set) var angleDegrees: Double?
    private(set) var phase: MotionAnalyzer.Phase = .calibrating
    private(set) var samples: [Sample] = []
    private(set) var log: [LogEntry] = []

    /// Phase 2 behaviour. Off by default, so a fresh session is a pure calibration
    /// logger: deviation is measured and charted but nothing touches your audio.
    var isAutoPauseEnabled = false {
        didSet {
            guard oldValue != isAutoPauseEnabled else { return }
            if isAutoPauseEnabled {
                append("Auto-pause enabled")
            } else {
                revertAudioSideEffects()
                append("Auto-pause disabled")
            }
        }
    }

    var thresholdDegrees: Double = MotionAnalyzer.Configuration.defaultThresholdDegrees {
        didSet { analyzer.setThreshold(thresholdDegrees) }
    }

    // MARK: - Private state

    private let manager = CMHeadphoneMotionManager()
    private var analyzer = MotionAnalyzer()
    /// Volume to put back once the deviation settles, captured at the moment of ducking.
    private var volumeBeforeDucking: Float?
    /// Only resume playback if we were the ones who paused it.
    private var didPauseMedia = false

    override init() {
        super.init()
        manager.delegate = self
        analyzer.setThreshold(thresholdDegrees)
        availability = Self.currentAvailability(for: manager)
    }

    // MARK: - Session control

    func startSession() {
        guard !isRunning else { return }

        availability = Self.currentAvailability(for: manager)
        guard availability.isReady else {
            append("Cannot start: \(availability.description)")
            return
        }

        analyzer.reset()
        phase = .calibrating
        angleDegrees = nil
        samples.removeAll()
        isRunning = true
        append("Session started — hold still for calibration")

        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            // The handler is delivered on `.main`, so main-actor state is safe to touch.
            MainActor.assumeIsolated {
                self?.handle(motion: motion, error: error)
            }
        }
    }

    func stopSession() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        revertAudioSideEffects()
        isRunning = false
        angleDegrees = nil
        phase = .calibrating
        analyzer.reset()
        append("Session stopped")
    }

    /// Re-captures the baseline without interrupting the session — useful after
    /// re-seating the headphones.
    func recalibrate() {
        guard isRunning else { return }
        revertAudioSideEffects()
        analyzer.reset()
        phase = .calibrating
        angleDegrees = nil
        samples.removeAll()
        append("Recalibrating…")
    }

    // MARK: - Motion handling

    private func handle(motion: CMDeviceMotion?, error: (any Error)?) {
        if let error {
            append("Motion error: \(error.localizedDescription)")
            return
        }
        guard let motion else { return }

        let raw = motion.attitude.quaternion
        let quaternion = Quaternion(x: raw.x, y: raw.y, z: raw.z, w: raw.w)
        let update = analyzer.ingest(quaternion, at: motion.timestamp)

        phase = analyzer.phase
        angleDegrees = update.angleDegrees

        if let angle = update.angleDegrees {
            samples.append(Sample(timestamp: motion.timestamp, angleDegrees: angle))
            trimSamples(upTo: motion.timestamp)
            logToConsole(angle: angle, quaternion: quaternion)
        }

        for effect in update.effects {
            apply(effect)
        }
    }

    private func trimSamples(upTo now: TimeInterval) {
        let cutoff = now - Self.chartWindow
        guard let firstKept = samples.firstIndex(where: { $0.timestamp >= cutoff }), firstKept > 0 else { return }
        samples.removeFirst(firstKept)
    }

    private func apply(_ effect: MotionAnalyzer.Effect) {
        if case .calibrated = effect {
            append("Baseline captured") // Always reported, even in logger-only mode.
            return
        }
        // Phase 1 mode: measure and chart, but leave the audio alone.
        guard isAutoPauseEnabled else { return }

        switch effect {
        case .calibrated:
            break

        case .duckVolume:
            guard volumeBeforeDucking == nil, let current = SystemVolume.currentVolume() else { return }
            volumeBeforeDucking = current
            let ducked = current * Self.duckFactor
            if SystemVolume.setVolume(ducked) {
                append(String(format: "Ducked volume %.0f%% → %.0f%%", current * 100, ducked * 100))
            } else {
                volumeBeforeDucking = nil
                append("Could not change system volume")
            }

        case .restoreVolume:
            guard let previous = volumeBeforeDucking else { return }
            SystemVolume.setVolume(previous)
            volumeBeforeDucking = nil
            append(String(format: "Volume restored to %.0f%%", previous * 100))

        case .pauseMedia:
            didPauseMedia = true
            append("Paused" + Self.suffix(for: MediaRemote.send(.pause)))

        case .resumeMedia:
            guard didPauseMedia else { return }
            didPauseMedia = false
            append("Resumed" + Self.suffix(for: MediaRemote.send(.play)))
        }
    }

    /// Undoes anything we did to the user's audio, so toggling off or stopping never
    /// leaves the volume turned down or playback stuck.
    private func revertAudioSideEffects() {
        if let previous = volumeBeforeDucking {
            SystemVolume.setVolume(previous)
            volumeBeforeDucking = nil
        }
        if didPauseMedia {
            MediaRemote.send(.play)
            didPauseMedia = false
        }
    }

    private static func suffix(for transport: MediaRemote.Transport) -> String {
        switch transport {
        case .mediaRemote: ""
        case .mediaKey: " (via media key)"
        case .failed: " — command failed"
        }
    }

    // MARK: - Availability

    private static func currentAvailability(for manager: CMHeadphoneMotionManager) -> Availability {
        guard manager.isDeviceMotionAvailable else { return .deviceMotionUnavailable }
        let status = CMHeadphoneMotionManager.authorizationStatus()
        switch status {
        case .authorized, .notDetermined: return .ready
        default: return .notAuthorized(status)
        }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            isConnected = true
            append("Headphones connected")
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            isConnected = false
            append("Headphones disconnected")
            revertAudioSideEffects()
        }
    }

    // MARK: - Logging

    private func append(_ message: String) {
        log.append(LogEntry(date: .now, message: message))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    private func logToConsole(angle: Double, quaternion: Quaternion) {
        #if DEBUG
        let stamp = Self.consoleFormatter.string(from: .now)
        print(String(
            format: "[%@] Δ=%6.2f°  q=(%+.4f, %+.4f, %+.4f, %+.4f)",
            stamp, angle, quaternion.x, quaternion.y, quaternion.z, quaternion.w
        ))
        #endif
    }

    private static let consoleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

extension HeadTrackingController.Availability: CustomStringConvertible {
    var description: String {
        switch self {
        case .ready:
            "Ready"
        case .deviceMotionUnavailable:
            "This Mac or the connected headphones don't report head motion"
        case .notAuthorized(let status):
            switch status {
            case .denied: "Motion access denied in Privacy & Security"
            case .restricted: "Motion access restricted"
            default: "Motion access unavailable"
            }
        }
    }
}
