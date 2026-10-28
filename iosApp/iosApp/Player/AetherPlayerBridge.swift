import Foundation
import UIKit
import NuvioAetherKit
import ComposeApp

// MARK: - Player Bridge Implementation (Kotlin protocol conformance)

/// AetherEngine-backed implementation of the Kotlin player bridge.
///
/// Covers load, transport, position/duration, audio/subtitle track lists and selection,
/// playback state and errors. mpv-specific calls (video output tuning, subtitle styling,
/// raw property reads) and features not wired to AetherEngine yet (PiP, Now Playing,
/// subtitle rendering) are safe no-ops.
final class AetherPlayerBridgeImpl: NSObject, NuvioPlayerBridge {

    private var playerVC: AetherPlayerViewController?
    private var keyboardShortcutsEnabled = true
    private var keyboardShortcutHandler: ((String) -> Void)?
    private var preferredAudioLanguages: [String] = []

    /// Called once when the current load cannot play on AetherEngine (open failure, error before the
    /// first frame, or a source whose audio cannot be delivered). Used by the engine router to fall back.
    var onLoadFailed: ((String) -> Void)? {
        didSet { playerVC?.onLoadFailed = onLoadFailed }
    }

    /// AetherEngine has no way to play a separate audio URL alongside the video, so such streams are
    /// left to mpv.
    static func canAttempt(audioUrl: String?) -> Bool {
        audioUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    func createPlayerViewController() -> UIViewController {
        return ensurePlayerViewController()
    }

    // Engine choice is the router's job; this bridge is always AetherEngine.
    func setPreferredEngine(engine: String) {}

    private func ensurePlayerViewController() -> AetherPlayerViewController {
        if let playerVC { return playerVC }
        let vc = AetherPlayerViewController()
        vc.setKeyboardShortcutsEnabled(keyboardShortcutsEnabled)
        vc.setKeyboardShortcutHandler(keyboardShortcutHandler)
        vc.preferredAudioLanguages = preferredAudioLanguages
        vc.onLoadFailed = onLoadFailed
        self.playerVC = vc
        return vc
    }

    func loadFile(url: String) {
        loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil)
    }

    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        let vc = ensurePlayerViewController()
        guard Self.canAttempt(audioUrl: audioUrl) else {
            vc.failLoad("AetherEngine does not support a separate audio stream")
            return
        }
        // External subtitles are not rendered on the Aether path yet, so subtitlesJson is ignored.
        vc.load(AetherLoadRequest(url: videoUrl, headers: parseRequestHeaders(headersJson)))
    }

    func play() { playerVC?.playPlayback() }
    func pause() { playerVC?.pausePlayback() }
    func seekTo(positionMs: Int64) { playerVC?.seekToMs(positionMs) }
    func seekBy(offsetMs: Int64) { playerVC?.seekByMs(offsetMs) }
    // Remote commands / Now Playing are not wired to AetherEngine yet.
    func setSystemControlHandler(handler: PlayerSystemControlHandler?) {}
    func getKeepsPlaybackInBackground() -> Bool { false }
    func retry() { playerVC?.retryPlayback() }
    func isPictureInPictureSupported() -> Bool { false }
    func startPictureInPicture() {}
    func setVideoZoom(scale: Double) { playerVC?.setVideoZoom(scale) }
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {}
    func updateNowPlayingMetadata(title: String, subtitle: String?, artworkUrl: String?) {}
    func clearNowPlayingInfo() {}
    func setKeyboardShortcutsEnabled(enabled: Bool) {
        keyboardShortcutsEnabled = enabled
        playerVC?.setKeyboardShortcutsEnabled(enabled)
    }
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) {
        keyboardShortcutHandler = handler
        playerVC?.setKeyboardShortcutHandler(handler)
    }
    // mpv video/audio output options have no AetherEngine equivalent; the engine picks HDR/DV
    // presentation and the audio route itself.
    func configureVideoOutput(
        hardwareDecoder: String,
        targetColorspaceHint: Bool,
        toneMapping: String,
        hdrComputePeak: Bool,
        targetPrimaries: String,
        targetTransfer: String,
        extendedDynamicRange: Bool,
        deband: Bool,
        interpolation: Bool,
        brightness: Int32,
        contrast: Int32,
        saturation: Int32,
        gamma: Int32
    ) {}
    func configureAudioOutput(audioOutput: String) {}

    func applyAudioLanguagePreferences(languages: [String]) {
        preferredAudioLanguages = languages
        playerVC?.preferredAudioLanguages = languages
    }
    func setPlaybackSpeed(speed: Float) { playerVC?.setSpeed(speed) }
    func getVolume() -> Float { playerVC?.getVolume() ?? 1.0 }
    func setVolume(volume: Float) { playerVC?.setVolume(volume) }
    func setMuted(muted: Bool) { playerVC?.setMuted(muted) }
    func setEmbeddedPreviewMode(enabled: Bool) {}
    func setResizeMode(mode: Int32) { playerVC?.setResize(Int(mode)) }
    func syncVideoSurfaceLayout(width: Double, height: Double) {}

    // Audio tracks
    func getAudioTrackCount() -> Int32 { Int32(playerVC?.audioTracks.count ?? 0) }
    func getAudioTrackIndex(at: Int32) -> Int32 {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return 0 }
        return Int32(t[Int(at)].index)
    }
    func getAudioTrackId(at: Int32) -> String {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return "0" }
        return "\(t[Int(at)].id)"
    }
    func getAudioTrackLabel(at: Int32) -> String {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].title
    }
    func getAudioTrackLang(at: Int32) -> String {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].lang
    }
    func isAudioTrackSelected(at: Int32) -> Bool {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return false }
        return t[Int(at)].selected
    }

    // Subtitle tracks (listing only; cues are not rendered on the Aether path yet)
    func getSubtitleTrackCount() -> Int32 { Int32(playerVC?.subtitleTracks.count ?? 0) }
    func getSubtitleTrackIndex(at: Int32) -> Int32 {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return 0 }
        return Int32(t[Int(at)].index)
    }
    func getSubtitleTrackId(at: Int32) -> String {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return "0" }
        return "\(t[Int(at)].id)"
    }
    func getSubtitleTrackLabel(at: Int32) -> String {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].title
    }
    func getSubtitleTrackLang(at: Int32) -> String {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].lang
    }
    func isSubtitleTrackSelected(at: Int32) -> Bool {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return false }
        return t[Int(at)].selected
    }

    func selectAudioTrack(trackId: Int32) { playerVC?.selectAudio(Int(trackId)) }
    func selectSubtitleTrack(trackId: Int32) { playerVC?.selectSubtitle(Int(trackId)) }
    func setSubtitleUrl(url: String) {}
    func clearExternalSubtitle() {}
    func clearExternalSubtitleAndSelect(trackId: Int32) { playerVC?.selectSubtitle(Int(trackId)) }
    func setSubtitleDelayMs(delayMs: Int32) {}
    func setSubtitleFontPath(path: String) {}
    func applySubtitleStyle(
        textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        shadowOffset: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int32,
        stripSdh: Bool
    ) {}

    // State (polled from Kotlin every 250ms)
    func getIsLoading() -> Bool { playerVC?.isPlayerLoading ?? true }
    func getIsPlaying() -> Bool { playerVC?.isPlayerPlaying ?? false }
    func getIsEnded() -> Bool { playerVC?.isPlayerEnded ?? false }
    func getDurationMs() -> Int64 { playerVC?.durationMs ?? 0 }
    func getPositionMs() -> Int64 { playerVC?.positionMs ?? 0 }
    func getBufferedMs() -> Int64 { playerVC?.bufferedMs ?? 0 }
    func getPlaybackSpeed() -> Float { playerVC?.currentSpeed ?? 1.0 }
    func getVideoWidth() -> Int32 { Int32(playerVC?.currentVideoWidth ?? 0) }
    func getVideoHeight() -> Int32 { Int32(playerVC?.currentVideoHeight ?? 0) }
    func getErrorMessage() -> String { playerVC?.currentErrorMessage ?? "" }
    func getMediaInfoJson() -> String { playerVC?.getMediaInfoJson() ?? "{}" }
    // Raw mpv properties (chapters, mpv media info) do not exist on AetherEngine.
    func getProperty(name: String) -> String { "" }

    func destroy() {
        playerVC?.onLoadFailed = nil
        playerVC?.destroyPlayer()
        playerVC = nil
    }

    private func parseRequestHeaders(_ headersJson: String?) -> [String: String] {
        guard
            let headersJson,
            !headersJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = headersJson.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return raw.compactMapValues { $0 as? String }
    }
}

struct AetherLoadRequest {
    let url: String
    let headers: [String: String]
}

// MARK: - Aether Player View Controller

final class AetherPlayerViewController: UIViewController {

    private var player: NuvioAetherPlayer?
    private let audioSession = PlayerAudioSessionController()
    private var keyboardShortcutsEnabled = true
    private var keyboardShortcutHandler: ((String) -> Void)?
    private var initErrorMessage = ""

    var preferredAudioLanguages: [String] = [] {
        didSet { player?.preferredAudioLanguages = preferredAudioLanguages }
    }
    var onLoadFailed: ((String) -> Void)? {
        didSet { player?.onLoadFailed = onLoadFailed }
    }

    var audioTracks: [TrackInfo] { (player?.audioTracks ?? []).map { Self.trackInfo($0, type: "audio") } }
    var subtitleTracks: [TrackInfo] { (player?.subtitleTracks ?? []).map { Self.trackInfo($0, type: "sub") } }

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        _ = ensurePlayer()
    }

    // MARK: - Immersive system UI (mirrors the mpv view controller)

    override var canBecomeFirstResponder: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom, .left, .right] }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        publishImmersiveSystemUIVisibility(isVisible: true)
        refreshImmersiveSystemUI()
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        publishImmersiveSystemUIVisibility(isVisible: false)
        super.viewWillDisappear(animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            publishImmersiveSystemUIVisibility(isVisible: false)
        }
    }

    private func refreshImmersiveSystemUI() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()

        var currentParent = parent
        while let controller = currentParent {
            controller.setNeedsUpdateOfHomeIndicatorAutoHidden()
            controller.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            controller.setNeedsStatusBarAppearanceUpdate()
            if let rootController = controller as? RootComposeViewController {
                rootController.refreshImmersiveSystemUI()
            }
            currentParent = controller.parent
        }
    }

    private func publishImmersiveSystemUIVisibility(isVisible: Bool) {
        if isVisible {
            SystemUI.shared.playerDidBecomeVisible(self)
        } else {
            SystemUI.shared.playerDidBecomeHidden(self)
        }
        NotificationCenter.default.post(
            name: nuvioPlayerImmersiveSystemUIVisibilityDidChange,
            object: self,
            userInfo: [nuvioPlayerImmersiveSystemUIVisibleKey: isVisible]
        )
    }

    private func ensurePlayer() -> NuvioAetherPlayer? {
        if let player { return player }
        do {
            let player = try NuvioAetherPlayer()
            player.preferredAudioLanguages = preferredAudioLanguages
            player.onLoadFailed = onLoadFailed
            loadViewIfNeeded()
            player.view.frame = view.bounds
            player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(player.view)
            self.player = player
            return player
        } catch {
            initErrorMessage = "AetherEngine could not be initialised: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Loading

    func load(_ request: AetherLoadRequest) {
        guard let player = ensurePlayer() else {
            failLoad(initErrorMessage)
            return
        }
        guard let url = URL(string: request.url) else {
            player.failLoad("Invalid stream URL")
            return
        }
        audioSession.activate()
        player.load(url: url, headers: request.headers)
    }

    func failLoad(_ message: String) {
        if let player {
            player.failLoad(message)
        } else {
            initErrorMessage = message
            onLoadFailed?(message)
        }
    }

    func retryPlayback() { player?.retry() }

    func destroyPlayer() {
        player?.destroy()
        player?.view.removeFromSuperview()
        player = nil
        audioSession.deactivate()
    }

    // MARK: - Transport

    func playPlayback() { player?.play() }
    func pausePlayback() { player?.pause() }
    func seekToMs(_ ms: Int64) { player?.seek(toSeconds: Double(ms) / 1000.0) }
    func seekByMs(_ ms: Int64) { player?.seek(bySeconds: Double(ms) / 1000.0) }
    func setSpeed(_ speed: Float) { player?.setSpeed(speed) }
    func getVolume() -> Float { player?.volume ?? 1.0 }
    func setVolume(_ volume: Float) { player?.setVolume(volume) }
    func setMuted(_ muted: Bool) { player?.setMuted(muted) }
    func setResize(_ mode: Int) { player?.setResizeMode(mode) }

    func setVideoZoom(_ scale: Double) {
        let clamped = CGFloat(max(scale, 1.0))
        player?.view.transform = CGAffineTransform(scaleX: clamped, y: clamped)
    }

    // MARK: - Tracks

    func selectAudio(_ trackId: Int) { player?.selectAudioTrack(id: trackId) }
    func selectSubtitle(_ trackId: Int) { player?.selectSubtitleTrack(id: trackId) }

    private static func trackInfo(_ track: NuvioAetherTrack, type: String) -> TrackInfo {
        TrackInfo(index: track.index, id: track.id, type: type, title: track.title, lang: track.language, selected: track.selected)
    }

    // MARK: - State

    var isPlayerLoading: Bool {
        guard let player else { return initErrorMessage.isEmpty }
        return player.isLoading
    }
    var isPlayerPlaying: Bool { player?.isPlaying ?? false }
    var isPlayerEnded: Bool { player?.isEnded ?? false }
    var durationMs: Int64 { Self.milliseconds(player?.durationSeconds ?? 0) }
    var positionMs: Int64 { Self.milliseconds(player?.positionSeconds ?? 0) }
    var bufferedMs: Int64 { Self.milliseconds(player?.bufferedSeconds ?? 0) }
    var currentSpeed: Float { player?.speed ?? 1.0 }
    var currentVideoWidth: Int { player?.videoWidth ?? 0 }
    var currentVideoHeight: Int { player?.videoHeight ?? 0 }
    var currentErrorMessage: String { player?.errorMessage ?? initErrorMessage }

    private static func milliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 1000.0)
    }

    func getMediaInfoJson() -> String {
        guard let info = player?.mediaInfo(),
              let data = try? JSONSerialization.data(withJSONObject: info, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Hardware keyboard shortcuts

    // Mirrors the mpv view controller: report the shortcut to Kotlin, which runs the same action
    // a tap or gesture would.
    private enum KeyboardShortcut: String {
        case togglePlayback = "toggle_playback"
        case seekBackward = "seek_backward"
        case seekForward = "seek_forward"
        case exit

        init?(key: UIKey) {
            switch key.charactersIgnoringModifiers {
            case UIKeyCommand.inputEscape: self = .exit
            case UIKeyCommand.inputLeftArrow: self = .seekBackward
            case UIKeyCommand.inputRightArrow: self = .seekForward
            case " ": self = .togglePlayback
            default: return nil
            }
        }
    }

    func setKeyboardShortcutsEnabled(_ enabled: Bool) {
        keyboardShortcutsEnabled = enabled
    }

    func setKeyboardShortcutHandler(_ handler: ((String) -> Void)?) {
        keyboardShortcutHandler = handler
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard keyboardShortcutsEnabled, let handler = keyboardShortcutHandler else {
            super.pressesBegan(presses, with: event)
            return
        }

        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let shortcut = KeyboardShortcut(key: key) else {
                unhandled.insert(press)
                continue
            }
            handler(shortcut.rawValue)
        }

        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }
}
