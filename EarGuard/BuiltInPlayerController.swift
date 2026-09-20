import AVFoundation
import Foundation
import MediaPlayer

/// Plays a user-supplied file or stream through `AVPlayer`.
///
/// This is the mode that actually survives backgrounding: because EarGuard owns an
/// active `.playback` audio session and the target declares the `audio` background
/// mode, the process keeps running with the screen locked — which in turn keeps
/// `CMHeadphoneMotionManager` delivering.
@MainActor
@Observable
final class BuiltInPlayerController: AudioControlling {

    let mode: AudioControlMode = .builtInPlayer

    private(set) var sourceURL: URL?
    private(set) var lastError: String?

    private let player = AVPlayer()
    /// Volume to return to after a duck. Non-nil only while ducked.
    private var volumeBeforeDucking: Float?
    private var didConfigureRemoteCommands = false

    var isPlaying: Bool { player.timeControlStatus == .playing }

    var statusDescription: String {
        if let lastError { return lastError }
        guard let sourceURL else { return "No audio loaded" }
        return sourceURL.isFileURL ? sourceURL.lastPathComponent : sourceURL.absoluteString
    }

    // MARK: - Loading

    func load(_ url: URL) {
        lastError = nil
        sourceURL = url
        // Security-scoped access is needed for files handed over by the document picker.
        let needsScope = url.isFileURL && url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.volume = 1
        volumeBeforeDucking = nil
        configureRemoteCommandsIfNeeded()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            activateSession()
            player.play()
        }
        updateNowPlayingInfo()
    }

    // MARK: - AudioControlling

    func duck(to fraction: Float) {
        guard volumeBeforeDucking == nil else { return }
        volumeBeforeDucking = player.volume
        player.volume = player.volume * fraction
    }

    func restoreVolume() {
        guard let previous = volumeBeforeDucking else { return }
        player.volume = previous
        volumeBeforeDucking = nil
    }

    func pause() -> Bool {
        guard isPlaying else { return false }
        player.pause()
        updateNowPlayingInfo()
        return true
    }

    func resume() {
        activateSession()
        player.play()
        updateNowPlayingInfo()
    }

    func deactivate() {
        restoreVolume()
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            lastError = "Audio session error: \(error.localizedDescription)"
        }
    }

    // MARK: - Now Playing / remote controls

    /// Keeps the lock screen and Control Center in sync, and makes the transport
    /// buttons there drive the same player EarGuard is pausing.
    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            _ = pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            togglePlayPause()
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: sourceURL?.lastPathComponent ?? "EarGuard",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let item = player.currentItem {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = item.currentTime().seconds
            let duration = item.duration.seconds
            if duration.isFinite { info[MPMediaItemPropertyPlaybackDuration] = duration }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
