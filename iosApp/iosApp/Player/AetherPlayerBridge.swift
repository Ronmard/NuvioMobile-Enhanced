import Foundation
import UIKit
import NuvioAetherKit
import ComposeApp

// MARK: - Player Bridge Implementation (Kotlin protocol conformance)

/// AetherEngine-backed implementation of the Kotlin player bridge.
///
/// Covers load, transport, position/duration, audio/subtitle track lists and selection,
/// text subtitles (drawn by `AetherSubtitleOverlayView`), styled ASS (libass) and bitmap subtitles (both
/// `AetherStyledSubtitleView`), playback state and errors, and remote commands / Now Playing
/// (`AetherNowPlayingController`). mpv-specific calls (video output tuning, raw property reads) and
/// features not wired to AetherEngine yet (PiP) are safe no-ops.
final class AetherPlayerBridgeImpl: NSObject, NuvioPlayerBridge {

    private var playerVC: AetherPlayerViewController?
    private var keyboardShortcutsEnabled = true
    private var keyboardShortcutHandler: ((String) -> Void)?
    private var preferredAudioLanguages: [String] = []
    private var systemControlHandler: PlayerSystemControlHandler?

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
        vc.systemControlHandler = systemControlHandler
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
        vc.load(AetherLoadRequest(
            url: videoUrl,
            headers: parseRequestHeaders(headersJson),
            subtitles: parseSubtitles(subtitlesJson)
        ))
    }

    /// Same JSON as the mpv bridge receives: [{url, language, name?, headers?}].
    private func parseSubtitles(_ json: String?) -> [NuvioAetherExternalSubtitle] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return raw.compactMap { dict in
            guard let urlString = dict["url"] as? String, let url = URL(string: urlString) else { return nil }
            let language = dict["language"] as? String
            return NuvioAetherExternalSubtitle(
                url: url,
                name: (dict["name"] as? String) ?? language,
                language: language,
                headers: dict["headers"] as? [String: String]
            )
        }
    }

    func play() { playerVC?.playPlayback() }
    func pause() { playerVC?.pausePlayback() }
    func seekTo(positionMs: Int64) { playerVC?.seekToMs(positionMs) }
    func seekBy(offsetMs: Int64) { playerVC?.seekByMs(offsetMs) }
    func setSystemControlHandler(handler: PlayerSystemControlHandler?) {
        systemControlHandler = handler
        playerVC?.systemControlHandler = handler
    }
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

    // Subtitle tracks (text cues are drawn by the overlay, styled ASS and bitmap cues by the styled layer)
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
    func setSubtitleUrl(url: String) { ensurePlayerViewController().addSubtitleUrl(url) }
    func clearExternalSubtitle() { playerVC?.removeExternalSubtitles(thenSelect: -1) }
    func clearExternalSubtitleAndSelect(trackId: Int32) { playerVC?.removeExternalSubtitles(thenSelect: Int(trackId)) }
    func setSubtitleDelayMs(delayMs: Int32) {
        ensurePlayerViewController().setSubtitleDelayMs(Int(delayMs))
    }
    func setSubtitleFontPath(path: String) {
        ensurePlayerViewController().setSubtitleFontPath(path)
    }
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
    ) {
        ensurePlayerViewController().applySubtitleStyle { fontFamily in
            var style = AetherSubtitleStyle(
                mpvTextColor: textColor,
                backgroundColor: backgroundColor,
                outlineColor: outlineColor,
                outlineSize: outlineSize,
                shadowOffset: shadowOffset,
                bold: bold,
                fontSize: fontSize,
                subPos: subPos,
                fontFamily: fontFamily
            )
            style.stripSdh = stripSdh
            return style
        }
    }

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
        // With a prepared next episode waiting, the session stays up for it (see PreparedAetherPlayer).
        destroy(keepAudioSession: PreparedAetherPlayer.shared.holdsAudioSessionForHandoff())
    }

    func destroy(keepAudioSession: Bool) {
        playerVC?.onLoadFailed = nil
        playerVC?.destroyPlayer(keepAudioSession: keepAudioSession)
        playerVC = nil
    }

    // MARK: - Next-episode prepare (driven by PreparedAetherPlayer)

    /// Loads the stream paused at [startPositionMs] so it buffers while another engine plays.
    func prepareFileWithAudio(videoUrl: String, headersJson: String?, subtitlesJson: String?, startPositionMs: Int64) {
        let vc = ensurePlayerViewController()
        vc.load(AetherLoadRequest(
            url: videoUrl,
            headers: parseRequestHeaders(headersJson),
            subtitles: parseSubtitles(subtitlesJson),
            startPositionSeconds: startPositionMs > 0 ? Double(startPositionMs) / 1000.0 : nil,
            autoplay: false
        ))
    }

    /// The prepared player is now the active engine.
    func didAdopt() {
        playerVC?.activateAudioSession()
        playerVC?.takeSystemControls()
    }

    var preparedBufferedSeconds: Double { playerVC?.bufferedSeconds ?? 0 }

    // The router owns next-episode preparation; a bare engine bridge never prepares.
    func prepareNextFile(
        videoUrl: String,
        audioUrl: String?,
        headersJson: String?,
        subtitlesJson: String?,
        startPositionMs: Int64,
        debugLogging: Bool
    ) -> Bool { false }
    func discardPreparedNextFile() {}

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
    let subtitles: [NuvioAetherExternalSubtitle]
    var startPositionSeconds: Double? = nil
    /// False for a next-episode prepare: loads paused and leaves the audio session to the engine
    /// that is playing.
    var autoplay = true
}

// MARK: - Aether Player View Controller

final class AetherPlayerViewController: UIViewController {

    private var player: NuvioAetherPlayer?
    private let audioSession: PlayerAudioSessionController = {
        // Movie playback mode (set by the controller) plus multichannel content: what lets AirPods
        // Spatial Audio / head tracking and multichannel routes engage for AetherEngine's output.
        let controller = PlayerAudioSessionController()
        controller.allowsMultichannelContent = true
        return controller
    }()
    private var keyboardShortcutsEnabled = true
    private var keyboardShortcutHandler: ((String) -> Void)?
    private lazy var nowPlaying = AetherNowPlayingController(owner: self)
    /// Set once this player is the one on screen (an autoplay load or an adopted next episode).
    private var ownsSystemControls = false
    var systemControlHandler: PlayerSystemControlHandler?
    private var initErrorMessage = ""
    private let subtitleOverlay = AetherSubtitleOverlayView()
    private let styledSubtitles = AetherStyledSubtitleView()
    /// Every cue of the selected track; the overlay gets those the styled layer does not draw.
    private var subtitleCues: [NuvioAetherSubtitleCue] = []
    private var requestHeaders: [String: String] = [:]
    /// Bumped by every load and external-subtitle change, so a slow addon download that finishes
    /// after the user moved on is dropped instead of selected.
    private var externalSubtitleGeneration = 0
    private var hasLoaded = false
    private lazy var subtitleFontFamily: String? = Self.defaultSubtitleFontFamily

    var preferredAudioLanguages: [String] = [] {
        didSet { player?.preferredAudioLanguages = preferredAudioLanguages }
    }
    var onLoadFailed: ((String) -> Void)?

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
        subtitleOverlay.style.fontFamily = subtitleFontFamily
        styledSubtitles.defaultFontFamily = subtitleFontFamily
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
            player.onLoadFailed = { [weak self] message in self?.handleLoadFailed(message) }
            loadViewIfNeeded()
            player.view.frame = view.bounds
            player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(player.view)
            attachSubtitleOverlay(to: player)
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
        if request.autoplay {
            audioSession.activate()
            takeSystemControls()
        }
        requestHeaders = request.headers
        // The engine router replays a remembered addon subtitle before the first load, so only a
        // later load (a different stream) invalidates downloads still in flight.
        if hasLoaded { externalSubtitleGeneration += 1 }
        hasLoaded = true
        subtitleOverlay.reset()
        styledSubtitles.reset()
        player.load(
            url: url,
            headers: request.headers,
            externalSubtitles: request.subtitles,
            startPositionSeconds: request.startPositionSeconds,
            autoplay: request.autoplay
        )
    }

    /// A prepared (paused, preloaded) player becomes the one on screen and takes over the audio session.
    func activateAudioSession() { audioSession.activate() }

    /// Remote commands and Now Playing follow the player on screen.
    func takeSystemControls() {
        ownsSystemControls = true
        nowPlaying.activate()
    }

    var bufferedSeconds: Double { player?.bufferedSeconds ?? 0 }

    func failLoad(_ message: String) {
        if let player {
            player.failLoad(message)
        } else {
            initErrorMessage = message
            handleLoadFailed(message)
        }
    }

    /// Gives up the system controls before the router can hand the load to mpv, whose own Now Playing
    /// controller then takes the shared centers.
    private func handleLoadFailed(_ message: String) {
        nowPlaying.resign(reason: "load failed")
        onLoadFailed?(message)
    }

    func retryPlayback() {
        if ownsSystemControls { nowPlaying.activate() }
        player?.retry()
    }

    /// [keepAudioSession] leaves the shared session active, for a teardown with another AetherEngine
    /// about to play (the prepared next episode), or for a prepared player that never owned it.
    func destroyPlayer(keepAudioSession: Bool = false) {
        subtitleOverlay.clock = nil
        subtitleOverlay.reset()
        styledSubtitles.clock = nil
        styledSubtitles.videoGeometry = nil
        styledSubtitles.setASSSource(nil, fonts: [])
        styledSubtitles.reset()
        player?.destroy()
        player?.view.removeFromSuperview()
        player = nil
        nowPlaying.resign(reason: "player destroyed")
        if keepAudioSession {
            audioSession.releaseWithoutDeactivating()
        } else {
            audioSession.deactivate()
        }
    }

    // MARK: - Transport

    // Requests from Now Playing go to the session controller when one handles them.
    func requestSystemPlaying(_ playing: Bool) {
        if systemControlHandler?.handleSetPlaying(playing: playing) == true { return }
        if playing { playPlayback() } else { pausePlayback() }
    }

    func requestSystemSeekTo(_ positionMs: Int64) {
        if systemControlHandler?.handleSeekTo(positionMs: positionMs) == true { return }
        seekToMs(positionMs)
    }

    func requestSystemSeekBy(_ offsetMs: Int64) {
        if systemControlHandler?.handleSeekBy(offsetMs: offsetMs) == true { return }
        seekByMs(offsetMs)
    }

    func playPlayback() { player?.play() }
    func pausePlayback() { player?.pause() }
    func seekToMs(_ ms: Int64) { player?.seek(toSeconds: Double(ms) / 1000.0) }
    func seekByMs(_ ms: Int64) { player?.seek(bySeconds: Double(ms) / 1000.0) }
    func setSpeed(_ speed: Float) { player?.setSpeed(speed) }
    func getVolume() -> Float { player?.volume ?? 1.0 }
    func setVolume(_ volume: Float) { player?.setVolume(volume) }
    func setMuted(_ muted: Bool) { player?.setMuted(muted) }
    func setResize(_ mode: Int) {
        player?.setResizeMode(mode)
        styledSubtitles.resizeMode = mode
    }

    func setVideoZoom(_ scale: Double) {
        let clamped = CGFloat(max(scale, 1.0))
        player?.view.transform = CGAffineTransform(scaleX: clamped, y: clamped)
        // Authored subtitles belong to the picture, so they zoom with it; the plain-text overlay does not.
        styledSubtitles.videoZoom = clamped
    }

    // MARK: - Subtitles

    /// The overlays sit above the video surface (and outside its zoom transform), below Compose's
    /// controls: styled ASS first, the plain-text overlay over it.
    private func attachSubtitleOverlay(to player: NuvioAetherPlayer) {
        let clock: () -> AetherSubtitleOverlayView.Clock? = { [weak player] in
            guard let player else { return nil }
            return AetherSubtitleOverlayView.Clock(
                seconds: player.subtitleClockSeconds,
                isRunning: player.isPlaying && !player.isLoading,
                rate: Double(player.speed)
            )
        }
        for overlay in [styledSubtitles, subtitleOverlay] as [UIView] {
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(overlay)
        }
        subtitleOverlay.clock = clock
        styledSubtitles.clock = clock
        styledSubtitles.videoGeometry = { [weak player] in
            guard let player, let displaySize = player.videoDisplaySize else { return nil }
            return AetherStyledSubtitleView.VideoGeometry(
                displaySize: displaySize,
                codedSize: CGSize(width: player.videoWidth, height: player.videoHeight)
            )
        }
        player.onSubtitleCuesChanged = { [weak self] cues in
            guard let self else { return }
            self.subtitleCues = cues
            self.styledSubtitles.cues = cues
            self.updateTextOverlayCues()
        }
        player.onSubtitleASSSourceChanged = { [weak self, weak player] source in
            guard let self, let player else { return }
            self.styledSubtitles.setASSSource(source, fonts: player.fontAttachments)
            self.updateTextOverlayCues()
        }
    }

    /// Bitmap cues are the styled layer's, and so are cues with raw ASS events while libass runs;
    /// otherwise the overlay draws their plain text.
    private func updateTextOverlayCues() {
        let drawsASS = styledSubtitles.isRenderingASS
        subtitleOverlay.cues = subtitleCues.filter { cue in
            cue.bitmap == nil && !(drawsASS && cue.assEvents != nil)
        }
    }

    // MARK: - Tracks

    func selectAudio(_ trackId: Int) { player?.selectAudioTrack(id: trackId) }
    func selectSubtitle(_ trackId: Int) { player?.selectSubtitleTrack(id: trackId) }

    /// An addon subtitle the user picked: loaded as an external track and selected, like mpv's
    /// `sub-add select`. Legacy-ordered Hebrew files get the same punctuation fix as on mpv, since
    /// UIKit lays Hebrew out right-to-left just like libass.
    func addSubtitleUrl(_ url: String) {
        externalSubtitleGeneration += 1
        let generation = externalSubtitleGeneration
        MPVSubtitleRtlFix.prepare(url: url, headers: requestHeaders) { [weak self] localPath, title in
            DispatchQueue.main.async {
                guard let self, self.externalSubtitleGeneration == generation else { return }
                let resolved = localPath.map { URL(fileURLWithPath: $0) } ?? URL(string: url)
                guard let resolved else { return }
                self.ensurePlayer()?.addExternalSubtitle(
                    NuvioAetherExternalSubtitle(url: resolved, name: title, language: nil, headers: nil),
                    select: true
                )
            }
        }
    }

    func setSubtitleDelayMs(_ delayMs: Int) {
        let delay = Double(max(-60_000, min(60_000, delayMs))) / 1000.0
        subtitleOverlay.delaySeconds = delay
        styledSubtitles.delaySeconds = delay
    }

    /// Empty path = the default face (the bundled Noto Sans mpv uses, else the system font).
    func setSubtitleFontPath(_ path: String) {
        let family = path.isEmpty ? nil : MPVSubtitleFontResolver.registerCustomFont(atPath: path)
        subtitleFontFamily = family ?? Self.defaultSubtitleFontFamily
        subtitleOverlay.style.fontFamily = subtitleFontFamily
        styledSubtitles.defaultFontFamily = subtitleFontFamily
    }

    /// Styles the plain-text overlay only: like mpv (`sub-ass-override=no`), styled ASS keeps its own.
    func applySubtitleStyle(_ makeStyle: (_ fontFamily: String?) -> AetherSubtitleStyle) {
        subtitleOverlay.style = makeStyle(subtitleFontFamily)
    }

    private static var defaultSubtitleFontFamily: String? {
        MPVSubtitleFontResolver.registerBundledFonts()
        let family = MPVSubtitleFontResolver.defaultFamily
        return family == "sans-serif" ? nil : family
    }

    func removeExternalSubtitles(thenSelect trackId: Int) {
        externalSubtitleGeneration += 1
        player?.removeExternalSubtitles(thenSelect: trackId)
    }

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
