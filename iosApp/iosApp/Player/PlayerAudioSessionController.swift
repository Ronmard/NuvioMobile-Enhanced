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
                      AVAudioSession.InterruptionType(rawValue: value) == .ended else { return }
                // Restore the session, but leave the player's play/pause decision unchanged.
                self.configure()
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

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard isActive else { return }
        // Include ringing, outgoing and held calls, and keep mixing until the last call ends.
        // Use the event for this call even if the observer's snapshot hasn't caught up yet.
        let hasCall = !call.hasEnded || callObserver.calls.contains {
            $0.uuid != call.uuid && !$0.hasEnded
        }
        configure(hasCall: hasCall)
    }

    private func configure(hasCall: Bool? = nil) {
        let session = AVAudioSession.sharedInstance()
        let mixing = hasCall ?? callObserver.calls.contains { !$0.hasEnded }
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
