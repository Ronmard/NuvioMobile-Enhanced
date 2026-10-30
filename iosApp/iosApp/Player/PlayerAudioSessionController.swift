import AVFoundation
import CallKit

/// Keeps normal playback eligible for Now Playing without taking audio away from calls.
final class PlayerAudioSessionController: NSObject, CXCallObserverDelegate {
    private let callObserver = CXCallObserver()
    private var isActive = false
    private var interruptionObserver: NSObjectProtocol?
    var onConfigurationChanged: (() -> Void)?
    /// Lets the route carry multichannel audio, which Spatial Audio / head tracking on AirPods and
    /// multichannel output need. Off by default so the mpv path's session is unchanged; the
    /// AetherEngine path turns it on.
    var allowsMultichannelContent = false
    /// Keeps playback going under a phone call by mixing with it, as the mpv path does. The AetherEngine
    /// path turns it off and pauses for the call instead (`onInterruption`).
    var mixesWithOthersDuringCalls = true

    enum Interruption {
        case began(wasSuspended: Bool)
        case ended(shouldResume: Bool)
    }
    /// Interruptions (calls, Siri, another app's audio); `.ended` arrives after the session is restored.
    var onInterruption: ((Interruption) -> Void)?

    func activate() {
        if !isActive {
            isActive = true
            callObserver.setDelegate(self, queue: .main)
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(), queue: .main
            ) { [weak self] notification in
                guard let self, self.isActive,
                      let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
                switch type {
                case .began:
                    let wasSuspended = notification.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false
                    self.onInterruption?(.began(wasSuspended: wasSuspended))
                case .ended:
                    // Restore the session; without an onInterruption handler the player's play/pause
                    // decision is left unchanged.
                    self.configure()
                    let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.onInterruption?(.ended(shouldResume: shouldResume))
                @unknown default:
                    break
                }
            }
        }
        configure()
    }

    func deactivate() {
        isActive = false
        callObserver.setDelegate(nil, queue: nil)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[NowPlaying] Failed to deactivate audio session: \(error)")
        }
        if allowsMultichannelContent {
            // The flag is session-wide and sticks; reset it so a later mpv session starts as before.
            try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(false)
        }
    }

    /// Stops observing without deactivating the shared session, for an engine handing playback to
    /// another one (which activates the session itself).
    func releaseWithoutDeactivating() {
        isActive = false
        callObserver.setDelegate(nil, queue: nil)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard isActive, mixesWithOthersDuringCalls else { return }
        // Include ringing, outgoing and held calls, and keep mixing until the last call ends.
        // Use the event for this call even if the observer's snapshot hasn't caught up yet.
        let hasCall = !call.hasEnded || callObserver.calls.contains {
            $0.uuid != call.uuid && !$0.hasEnded
        }
        configure(hasCall: hasCall)
    }

    private func configure(hasCall: Bool? = nil) {
        let session = AVAudioSession.sharedInstance()
        let mixing = mixesWithOthersDuringCalls && (hasCall ?? callObserver.calls.contains { !$0.hasEnded })
        let options: AVAudioSession.CategoryOptions = mixing ? [.mixWithOthers] : []
        do {
            if session.category != .playback || session.mode != .moviePlayback || session.categoryOptions != options {
                try session.setCategory(.playback, mode: .moviePlayback, options: options)
            }
            if allowsMultichannelContent && !session.supportsMultichannelContent {
                try session.setSupportsMultichannelContent(true)
            }
            try session.setActive(true)
            onConfigurationChanged?()
        } catch {
            print("[NowPlaying] Failed to activate audio session (call mixing: \(mixing)): \(error)")
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
}
