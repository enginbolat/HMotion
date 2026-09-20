import CoreMotion
import Foundation
import Observation
import UIKit

/// Feeds `CMHeadphoneMotionManager` samples through the shared `MotionAnalyzer` and
/// routes the resulting effects to whichever `AudioControlling` mode is selected.
///
/// The motion half is identical to the macOS build — same availability check, same
/// delegate, same analyzer. Only the effect-application half differs.
@MainActor
@Observable
final class HeadTrackingModel: NSObject, CMHeadphoneMotionManagerDelegate {

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

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    // MARK: - Observable state

    private(set) var availability: Availability = .ready
    private(set) var isRunning = false
    private(set) var isConnected = false
    private(set) var angleDegrees: Double?
    private(set) var phase: MotionAnalyzer.Phase = .calibrating
    private(set) var samples: [AngleSample] = []
    private(set) var log: [LogEntry] = []
    /// `true` once the app has been backgrounded during a session in a mode that
    /// can't survive it — used to explain a session that silently stopped working.
    private(set) var didLoseBackgroundTracking = false

    let builtInPlayer = BuiltInPlayerController()
    let appleMusic = AppleMusicController()

    var mode: AudioControlMode = .builtInPlayer {
        didSet {
            guard oldValue != mode else { return }
            // Never leave the previous mode ducked or paused by us.
            revertAudioSideEffects(on: controller(for: oldValue))
            append("Audio mode → \(mode.title)")
        }
    }

    var thresholdDegrees: Double = MotionAnalyzer.Configuration.defaultThresholdDegrees {
        didSet { analyzer.setThreshold(thresholdDegrees) }
    }

    var activeController: any AudioControlling { controller(for: mode) }

    // MARK: - Private state

    private let manager = CMHeadphoneMotionManager()
    private var analyzer = MotionAnalyzer()
    private var didPauseMedia = false
    private var didDuck = false

    override init() {
        super.init()
        manager.delegate = self
        analyzer.setThreshold(thresholdDegrees)
        availability = Self.currentAvailability(for: manager)
        observeAppLifecycle()
    }

    private func controller(for mode: AudioControlMode) -> any AudioControlling {
        switch mode {
        case .builtInPlayer: builtInPlayer
        case .appleMusic: appleMusic
        }
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
        didLoseBackgroundTracking = false
        isRunning = true

        if mode == .appleMusic { appleMusic.beginObserving() }
        append("Session started — hold still for calibration")

        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            // Delivered on `.main`, so main-actor state is safe to touch here.
            MainActor.assumeIsolated {
                self?.handle(motion: motion, error: error)
            }
        }
    }

    func stopSession() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        revertAudioSideEffects(on: activeController)
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
        revertAudioSideEffects(on: activeController)
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
            samples.append(AngleSample(timestamp: motion.timestamp, degrees: angle))
            trimSamples(upTo: motion.timestamp)
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
        let controller = activeController

        switch effect {
        case .calibrated:
            append("Baseline captured")

        case .duckVolume:
            guard mode.supportsDucking else { return }
            controller.duck(to: Self.duckFactor)
            didDuck = true
            append("Ducked volume")

        case .restoreVolume:
            guard didDuck else { return }
            controller.restoreVolume()
            didDuck = false
            append("Volume restored")

        case .pauseMedia:
            if controller.pause() {
                didPauseMedia = true
                append("Paused")
            } else {
                append("Threshold held, but nothing was playing")
            }

        case .resumeMedia:
            guard didPauseMedia else { return }
            controller.resume()
            didPauseMedia = false
            append("Resumed")
        }
    }

    /// Undoes anything we did to the user's audio, so switching modes or stopping
    /// never leaves playback stuck or the volume turned down.
    private func revertAudioSideEffects(on controller: any AudioControlling) {
        if didDuck {
            controller.restoreVolume()
            didDuck = false
        }
        if didPauseMedia {
            controller.resume()
            didPauseMedia = false
        }
    }

    // MARK: - Lifecycle

    /// In Apple Music mode iOS suspends us shortly after backgrounding and motion
    /// updates stop. Record that so the UI can explain a session that went quiet.
    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isRunning, !self.mode.supportsBackgroundTracking else { return }
                self.didLoseBackgroundTracking = true
                self.append("Backgrounded — tracking will stop in \(self.mode.title) mode")
            }
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
            revertAudioSideEffects(on: activeController)
        }
    }

    // MARK: - Logging

    private func append(_ message: String) {
        log.append(LogEntry(date: .now, message: message))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }
}

extension HeadTrackingModel.Availability: CustomStringConvertible {
    var description: String {
        switch self {
        case .ready:
            "Ready"
        case .deviceMotionUnavailable:
            "These headphones don't report head motion"
        case .notAuthorized(let status):
            switch status {
            case .denied: "Motion access denied in Settings › Privacy › Motion & Fitness"
            case .restricted: "Motion access restricted"
            default: "Motion access unavailable"
            }
        }
    }
}

extension HeadTrackingModel {
    var statusText: String {
        guard availability.isReady else { return availability.description }
        guard isRunning else { return "Idle" }
        switch phase {
        case .calibrating: return "Calibrating — hold still"
        case .monitoring: return "Monitoring"
        case .pendingPause: return "Above threshold — waiting to pause"
        case .paused: return "Paused"
        case .recovering: return "Back in place — waiting to resume"
        }
    }
}
