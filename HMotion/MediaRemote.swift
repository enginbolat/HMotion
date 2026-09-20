import AppKit
import Foundation

/// Drives system-wide playback (whatever owns "Now Playing", not just one app).
///
/// There is no public API for this, so the private `MediaRemote` framework is loaded
/// at runtime with `dlopen` — its headers aren't shipped, and linking against it
/// directly would break the build on any machine where the framework moves.
/// That also makes this App Store-ineligible, which is fine for a personal tool.
///
/// Recent macOS releases have progressively locked `MRMediaRemoteSendCommand` down to
/// Apple-signed callers. When the symbol is missing or the command is refused, this
/// falls back to synthesizing the hardware play/pause key, which needs Accessibility
/// permission but no private API.
nonisolated enum MediaRemote {

    /// Values of the private `MRMediaRemoteCommand` enum.
    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
    }

    /// Which mechanism actually carried the command.
    enum Transport: Equatable {
        case mediaRemote
        case mediaKey
        case failed
    }

    private typealias SendCommandFunction = @convention(c) (Int32, CFDictionary?) -> DarwinBoolean

    private static let library: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY
    )

    private static let sendCommandFunction: SendCommandFunction? = {
        guard let library, let symbol = dlsym(library, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommandFunction.self)
    }()

    /// Whether the private framework loaded and exposed the command entry point.
    static var isPrivateFrameworkAvailable: Bool { sendCommandFunction != nil }

    @discardableResult
    static func send(_ command: Command) -> Transport {
        if let sendCommandFunction, sendCommandFunction(command.rawValue, nil).boolValue {
            return .mediaRemote
        }
        // The media key is a toggle, so it can only stand in for play/pause, and only
        // when the current playback state is the opposite of what we're asking for.
        return postPlayPauseKey() ? .mediaKey : .failed
    }

    /// `NX_KEYTYPE_PLAY` from `<IOKit/hidsystem/ev_keymap.h>`.
    private static let playPauseKeyCode: Int32 = 16

    private static func postPlayPauseKey() -> Bool {
        var posted = false
        for isKeyDown in [true, false] {
            // System-defined events pack the key code and up/down state into `data1`,
            // and mirror the state in the modifier flags.
            let state: Int32 = isKeyDown ? 0x0A : 0x0B
            let data1 = Int((playPauseKeyCode << 16) | (state << 8))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(state) << 8)

            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            ), let cgEvent = event.cgEvent else { continue }

            cgEvent.post(tap: .cghidEventTap)
            posted = true
        }
        return posted
    }
}
