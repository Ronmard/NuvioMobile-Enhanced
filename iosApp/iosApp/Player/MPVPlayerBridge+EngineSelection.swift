import Foundation
import ComposeApp

// Kept apart from MPVPlayerBridge.swift so the mpv bridge itself stays unchanged.
extension MPVPlayerBridgeImpl {
    // Engine choice is the router's job; this bridge is always mpv.
    func setPreferredEngine(engine: String) {}
}
