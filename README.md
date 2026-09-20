HMotion

Auto-pause your music when you take off your headphones — even if they don't have ear-detection hardware.

Beats Studio Pro (and similar over-ear headphones with spatial-audio head tracking but no proximity/ear-detection sensor) don't stop playback when you take them off, unlike AirPods. HMotion fixes that by using the headphones' built-in motion sensor instead of a dedicated ear-detection sensor.

How it works
You start a session while wearing your headphones.
HMotion reads live head-orientation data (CMDeviceMotion.attitude) via CMHeadphoneMotionManager and averages the first second of samples into a baseline orientation.
On every subsequent sample, it computes the angular deviation (in degrees) between the current orientation and the baseline, using the quaternion angular-distance formula:
   angle = 2 * acos(|dot(q_baseline, q_current)|)
If the deviation crosses a configurable threshold:
Audio volume is ducked instantly (so a headphone hitting a desk doesn't blast your ears).
A 1.5s debounce timer starts. If the deviation drops back below the threshold before the timer completes, the duck is reversed and nothing else happens — this filters out ordinary head movement (turning, nodding) from an actual removal.
If the timer completes, playback is paused.
When the orientation returns close to baseline and stays there briefly, playback resumes automatically and volume is restored.

No dedicated ear-detection hardware is required — only a headphone that streams motion data for spatial audio / dynamic head tracking.

Platforms
Platform	Status	Playback control
macOS (menu bar app)	✅ Working	System-wide play/pause via the private MediaRemote framework, works with any player (Spotify, Music, browser, etc.)
iOS	🚧 In progress	MPMusicPlayerController.systemMusicPlayer (Apple Music only) or a self-contained in-app player via AVAudioPlayer/AVPlayer + MPNowPlayingInfoCenter — iOS does not allow third-party apps to control arbitrary other apps' playback system-wide
Platform-specific notes
macOS: Runs as a menu bar (LSUIElement) app. Uses MediaRemote (private framework, loaded at runtime via dlopen) for system-wide pause/resume, and CoreAudio (kAudioHardwareServiceDeviceProperty_VirtualMainVolume) for volume ducking. Because it relies on a private framework, this app is not App Store distributable and is intended for personal/local use only.
iOS: CMHeadphoneMotionManager is available since iOS 14, but background motion updates are only reliable while the app itself holds an active audio session (UIBackgroundModes: audio). Requires NSMotionUsageDescription in Info.plist.
Why this exists

AirPods and a handful of Beats models (Beats Fit Pro, Powerbeats Fit, Powerbeats Pro 2) have dedicated ear-detection hardware. Beats Studio Pro does not — but it does support Personalized Spatial Audio with dynamic head tracking, which means it streams real-time orientation data over Bluetooth. HMotion repurposes that motion stream to approximate ear-detection behavior in software.

Project structure
HMotion/
├── MotionAnalyzer.swift   # Baseline capture, angular-distance math, debounce state machine (UI-independent, shared logic)
├── ...                    # Platform-specific UI and playback-control code (macOS menu bar / iOS app target)

MotionAnalyzer.swift is written to be platform-agnostic and is shared between the macOS and iOS targets.

Requirements
macOS 14+ (for CMHeadphoneMotionManager on macOS) / iOS 14+
A headphone model that supports spatial audio with dynamic head tracking (e.g. Beats Studio Pro, AirPods Pro/Max)
Xcode 15+
Calibration

The angular-deviation threshold isn't hardcoded to a "correct" value — it depends on your headphone model and how you typically remove it. Use the built-in live readout to watch the deviation while taking your headphones off a few times, then set the threshold slightly below the smallest value you observed during an actual removal.

Disclaimer

This is a personal utility project, not an Apple- or Beats-affiliated product. The macOS build uses an undocumented, private system framework (MediaRemote) and is provided as-is for personal use.

License

MIT (or your preferred license — update this section before publishing).
