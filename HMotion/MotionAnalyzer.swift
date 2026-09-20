import Foundation

/// A unit quaternion in the `(x, y, z, w)` component order used by `CMQuaternion`.
///
/// Declared independently of CoreMotion so the maths below can be exercised
/// without a real pair of headphones attached.
nonisolated struct Quaternion: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    var length: Double { (x * x + y * y + z * z + w * w).squareRoot() }

    /// The quaternion scaled to unit length, or `nil` if it is too close to zero to normalize.
    func normalized() -> Quaternion? {
        let length = self.length
        guard length > 1e-9 else { return nil }
        return Quaternion(x: x / length, y: y / length, z: z / length, w: w / length)
    }

    func dot(_ other: Quaternion) -> Double {
        x * other.x + y * other.y + z * other.z + w * other.w
    }

    var negated: Quaternion { Quaternion(x: -x, y: -y, z: -z, w: -w) }

    /// The smallest rotation angle, in degrees, between two orientations.
    ///
    /// Taking `abs` of the dot product folds `q` and `-q` together — they encode
    /// the same orientation — so the result always lands in `0...180`.
    static func angleDegrees(from lhs: Quaternion, to rhs: Quaternion) -> Double {
        let dot = min(max(abs(lhs.dot(rhs)), -1.0), 1.0)
        return 2 * acos(dot) * 180 / .pi
    }

    /// Component-wise mean of `samples`, renormalized to unit length.
    ///
    /// Each sample is sign-flipped to sit in the same hemisphere as the first one
    /// before summing; without that step `q` and `-q` would cancel each other out
    /// and produce a meaningless average.
    static func average(_ samples: [Quaternion]) -> Quaternion? {
        guard let reference = samples.first else { return nil }
        var sum = Quaternion(x: 0, y: 0, z: 0, w: 0)
        for sample in samples {
            let aligned = sample.dot(reference) < 0 ? sample.negated : sample
            sum.x += aligned.x
            sum.y += aligned.y
            sum.z += aligned.z
            sum.w += aligned.w
        }
        return sum.normalized()
    }
}

/// Turns a stream of head-orientation samples into "headphones came off / went back on"
/// decisions. Pure value type with no UI, CoreMotion, or timer dependencies: feed it
/// quaternions plus their timestamps and it hands back the angular deviation and any
/// side effects that should fire.
nonisolated struct MotionAnalyzer {

    struct Configuration: Equatable, Sendable {
        /// Deviation from baseline that counts as "the headphones moved off the head".
        ///
        /// This is the `THRESHOLD_DEGREES` knob. The value below is a placeholder —
        /// run a calibration session, watch the live readout while actually lifting the
        /// cups off your head, and set this comfortably below the peak you observe.
        static let defaultThresholdDegrees: Double = 35

        var thresholdDegrees: Double = defaultThresholdDegrees
        /// How long to collect samples before locking in the baseline orientation.
        var baselineDuration: TimeInterval = 1.0
        /// How long the deviation must stay above threshold before playback pauses.
        var pauseDelay: TimeInterval = 1.5
        /// How long the deviation must stay back below threshold before playback resumes.
        var resumeStableDuration: TimeInterval = 0.5
    }

    enum Phase: Equatable, Sendable {
        /// Collecting the first `baselineDuration` of samples.
        case calibrating
        /// Baseline known, deviation below threshold.
        case monitoring
        /// Above threshold, waiting out `pauseDelay` before committing to a pause.
        case pendingPause(since: TimeInterval)
        /// Pause committed.
        case paused
        /// Paused but back below threshold, waiting out `resumeStableDuration`.
        case recovering(since: TimeInterval)
    }

    enum Effect: Equatable, Sendable {
        case calibrated
        case duckVolume
        case restoreVolume
        case pauseMedia
        case resumeMedia
    }

    struct Update: Equatable, Sendable {
        /// `nil` while still calibrating — there is no baseline to compare against yet.
        var angleDegrees: Double?
        var effects: [Effect]
    }

    private(set) var configuration: Configuration
    private(set) var phase: Phase = .calibrating
    private(set) var baseline: Quaternion?

    private var calibrationStart: TimeInterval?
    private var calibrationSamples: [Quaternion] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Adjusts the threshold mid-session without discarding the baseline.
    mutating func setThreshold(_ degrees: Double) {
        configuration.thresholdDegrees = degrees
    }

    /// Drops the baseline and starts a fresh calibration window.
    mutating func reset() {
        phase = .calibrating
        baseline = nil
        calibrationStart = nil
        calibrationSamples.removeAll()
    }

    /// Feeds one orientation sample through the state machine.
    ///
    /// - Parameters:
    ///   - quaternion: The raw `attitude.quaternion` from the current device motion.
    ///   - timestamp: A monotonically increasing time in seconds (e.g. `CMDeviceMotion.timestamp`).
    mutating func ingest(_ quaternion: Quaternion, at timestamp: TimeInterval) -> Update {
        if case .calibrating = phase {
            return calibrate(with: quaternion, at: timestamp)
        }

        guard let baseline else { return Update(angleDegrees: nil, effects: []) }

        let angle = Quaternion.angleDegrees(from: baseline, to: quaternion)
        let isBeyondThreshold = angle > configuration.thresholdDegrees
        var effects: [Effect] = []

        switch phase {
        case .calibrating:
            break // Handled above.

        case .monitoring:
            if isBeyondThreshold {
                // Duck immediately so the moment of removal is quiet, then let the
                // debounce decide whether this was a real removal or just a head turn.
                phase = .pendingPause(since: timestamp)
                effects.append(.duckVolume)
            }

        case .pendingPause(let since):
            if !isBeyondThreshold {
                phase = .monitoring
                effects.append(.restoreVolume)
            } else if timestamp - since >= configuration.pauseDelay {
                phase = .paused
                effects.append(.pauseMedia)
            }

        case .paused:
            if !isBeyondThreshold {
                phase = .recovering(since: timestamp)
            }

        case .recovering(let since):
            if isBeyondThreshold {
                phase = .paused
            } else if timestamp - since >= configuration.resumeStableDuration {
                phase = .monitoring
                effects.append(.resumeMedia)
                effects.append(.restoreVolume)
            }
        }

        return Update(angleDegrees: angle, effects: effects)
    }

    private mutating func calibrate(with quaternion: Quaternion, at timestamp: TimeInterval) -> Update {
        let start = calibrationStart ?? timestamp
        calibrationStart = start
        calibrationSamples.append(quaternion)

        guard timestamp - start >= configuration.baselineDuration,
              let averaged = Quaternion.average(calibrationSamples) else {
            return Update(angleDegrees: nil, effects: [])
        }

        baseline = averaged
        calibrationSamples.removeAll()
        calibrationStart = nil
        phase = .monitoring
        return Update(angleDegrees: 0, effects: [.calibrated])
    }
}
