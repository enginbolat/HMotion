import Foundation
import MediaPlayer

/// Drives the system Music app through `MPMusicPlayerController.systemMusicPlayer`.
///
/// Two limits are inherent to this mode, not implementation shortcuts:
///
/// 1. **No ducking.** There is no supported way to change Apple Music's or the system's
///    output volume from a third-party app. `MPMusicPlayerController.volume` was
///    deprecated in iOS 7 and `AVAudioSession.outputVolume` is read-only. So the
///    analyzer's duck step degrades to "do nothing and wait for the debounce".
/// 2. **Foreground only.** EarGuard holds no audio session here, so iOS suspends the
///    app shortly after it leaves the screen and motion updates stop with it.
@MainActor
@Observable
final class AppleMusicController: AudioControlling {

    let mode: AudioControlMode = .appleMusic

    private let player = MPMusicPlayerController.systemMusicPlayer

    var isPlaying: Bool { player.playbackState == .playing }

    var statusDescription: String {
        guard let item = player.nowPlayingItem else { return "Nothing playing in Music" }
        let title = item.title ?? "Unknown track"
        if let artist = item.artist { return "\(title) — \(artist)" }
        return title
    }

    func beginObserving() {
        player.beginGeneratingPlaybackNotifications()
    }

    // MARK: - AudioControlling

    /// Not supported in this mode — see the note on the type.
    func duck(to fraction: Float) {}

    func restoreVolume() {}

    func pause() -> Bool {
        guard isPlaying else { return false }
        player.pause()
        return true
    }

    func resume() {
        player.play()
    }

    func deactivate() {
        player.endGeneratingPlaybackNotifications()
    }
}
