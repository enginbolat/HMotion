import Foundation

/// What EarGuard is allowed to pause when the headphones come off.
///
/// iOS has no system-wide playback control for third-party apps, so unlike the macOS
/// build there is no single "pause everything" path. Each mode below is a different
/// trade-off between what it can control and whether it survives backgrounding.
enum AudioControlMode: String, CaseIterable, Identifiable, Sendable {
    /// Drive the built-in player. Full control including volume ducking, and the only
    /// mode that keeps working with the app backgrounded or the screen locked.
    case builtInPlayer
    /// Drive the system Music app via `MPMusicPlayerController.systemMusicPlayer`.
    /// Controls Apple Music only, cannot duck, and stops working once the app is
    /// backgrounded because EarGuard owns no audio session of its own.
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtInPlayer: "Built-in player"
        case .appleMusic: "Apple Music"
        }
    }

    var summary: String {
        switch self {
        case .builtInPlayer:
            "Plays your own file or stream. Works locked and backgrounded, and can duck the volume."
        case .appleMusic:
            "Controls the Music app. Foreground only, and cannot duck the volume."
        }
    }

    /// Whether the mode can lower the volume rather than only pause.
    var supportsDucking: Bool { self == .builtInPlayer }

    /// Whether motion tracking survives the app being backgrounded or the screen locking.
    var supportsBackgroundTracking: Bool { self == .builtInPlayer }
}

/// The operations `MotionAnalyzer.Effect` values get translated into.
///
/// Implementations must be idempotent and safe to call out of order — the analyzer
/// can emit `restoreVolume` without a preceding `duckVolume` if the mode changed
/// mid-session.
@MainActor
protocol AudioControlling: AnyObject {
    var mode: AudioControlMode { get }
    /// Whether something is currently playing that a pause would actually affect.
    var isPlaying: Bool { get }
    /// Human-readable description of what is loaded, for the UI.
    var statusDescription: String { get }

    /// Drop to a fraction of current volume, remembering the level to come back to.
    func duck(to fraction: Float)
    /// Undo a previous `duck(to:)`. No-op if not ducked.
    func restoreVolume()
    /// Pause playback. Returns `true` if something was actually playing and got paused.
    func pause() -> Bool
    /// Resume playback.
    func resume()
    /// Release any session or observers.
    func deactivate()
}
