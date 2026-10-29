import AVFoundation
import UIKit
import NuvioAetherKit

/// Draws authored subtitles over the AetherEngine picture: styled ASS/SSA through libass and decoded
/// bitmap cues (PGS / DVB / DVD), laid out in the on-screen video rect and kept in step with playback.
///
/// Sits between the video surface and `AetherSubtitleOverlayView`; the overlay keeps drawing every
/// cue this view does not (`isRenderingASS` and `NuvioAetherSubtitleCue.bitmap` say which).
final class AetherStyledSubtitleView: UIView {

    struct VideoGeometry {
        /// Picture shape as presented (coded size under the pixel aspect).
        let displaySize: CGSize
        /// Coded size: the frame libass treats as the script's storage, and the pixel grid bitmap
        /// canvases are authored on.
        let codedSize: CGSize
    }

    var clock: (() -> AetherSubtitleOverlayView.Clock?)?
    var videoGeometry: (() -> VideoGeometry?)?

    /// 0 = Fit, 1 = Fill (stretch), 2 = Zoom (crop), as the bridge's resize modes.
    var resizeMode = 0 {
        didSet { if resizeMode != oldValue { refresh() } }
    }
    /// The zoom transform applied to the video surface.
    var videoZoom: CGFloat = 1 {
        didSet { if videoZoom != oldValue { refresh() } }
    }
    /// mpv `sub-delay`: positive shows subtitles later.
    var delaySeconds: Double = 0 {
        didSet { if delaySeconds != oldValue { refresh() } }
    }
    /// mpv `sub-font`: the family text falls back to when a style's font is missing.
    var defaultFontFamily: String? {
        didSet { if defaultFontFamily != oldValue { renderer?.setDefaultFamily(defaultFontFamily) } }
    }

    /// True while libass draws the selected track; its raw-event cues are then this view's.
    private(set) var isRenderingASS = false

    private let contentLayer = CALayer()
    /// Cues carrying a bitmap, in the engine's order (later ones layer over earlier ones).
    private var bitmapCues: [NuvioAetherSubtitleCue] = []
    private var bitmapLayers: [Int: CALayer] = [:]
    private var shownBitmapLayout: BitmapLayout?

    private struct BitmapLayout: Equatable {
        let cueIds: [Int]
        let videoRect: CGRect
    }
    private var renderer: AetherASSRenderer?
    private var didFailToCreateRenderer = false
    private var displayLink: CADisplayLink?
    private var clockInterpolator = AetherSubtitleClockInterpolator()
    /// Bumped whenever the track or its events change, so the next tick renders again even at the same
    /// time and size.
    private var contentGeneration = 0
    /// Bumped when the source changes: a render in flight for the previous track is dropped.
    private var sourceGeneration = 0
    private var isRenderInFlight = false
    private var lastRequest: RenderRequest?
    /// The image on screen, in pixels of the frame it was rendered for, and that frame's size.
    private var shownPixelRect: CGRect = .null
    private var shownPixelSize: CGSize = .zero

    private struct RenderRequest: Equatable {
        let timeMs: Int64
        let videoRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let generation: Int
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        contentLayer.contentsGravity = .resize
        layer.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    // MARK: - Content

    /// The selected track's ASS source; nil when the track is not styled ASS (or nothing is selected).
    /// `fonts` are the media's attached fonts, used only when a source is set.
    func setASSSource(_ source: NuvioAetherASSSource?, fonts: @autoclosure () -> [NuvioAetherFontAttachment]) {
        if source != nil, renderer == nil, !didFailToCreateRenderer {
            renderer = AetherASSRenderer()
            didFailToCreateRenderer = renderer == nil
            if didFailToCreateRenderer {
                print("[AetherSubtitles] libass could not be initialised; styled ASS falls back to plain text")
            }
            renderer?.setDefaultFamily(defaultFontFamily)
        }
        guard let renderer else {
            isRenderingASS = false
            return
        }
        renderer.setSource(source, fonts: source == nil ? [] : fonts())
        isRenderingASS = source != nil
        contentGeneration += 1
        sourceGeneration += 1
        if source == nil { clearContent() }
        renderer.addEvents(from: cues)
        updateDisplayLink()
        requestRender()
    }

    /// The selected track's cues; those carrying raw ASS events or a bitmap are drawn here.
    var cues: [NuvioAetherSubtitleCue] = [] {
        didSet {
            let bitmaps = cues.filter { $0.bitmap != nil }
            if bitmaps != bitmapCues {
                bitmapCues = bitmaps
                shownBitmapLayout = nil
                updateDisplayLink()
                updateBitmaps()
            }
            guard isRenderingASS, let renderer else { return }
            if cues.isEmpty {
                renderer.flushEvents()
            } else {
                renderer.addEvents(from: cues)
            }
            contentGeneration += 1
            requestRender()
        }
    }

    func reset() {
        cues = []
        clockInterpolator.reset()
        clearContent()
    }

    private func clearContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = nil
        bitmapLayers.values.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        bitmapLayers = [:]
        shownBitmapLayout = nil
        shownPixelRect = .null
        lastRequest = nil
    }

    // MARK: - Timing

    private func updateDisplayLink() {
        let wantsTicks = window != nil && (isRenderingASS || !bitmapCues.isEmpty)
        if wantsTicks, displayLink == nil {
            let link = CADisplayLink(target: StyledSubtitleDisplayLinkProxy(self), selector: #selector(StyledSubtitleDisplayLinkProxy.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wantsTicks, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
        // ASS moves, fades and karaoke sweeps animate per frame; bitmaps only switch on and off.
        displayLink?.preferredFrameRateRange = isRenderingASS
            ? CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
            : CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    }

    fileprivate func tick() {
        refresh()
    }

    private func refresh() {
        requestRender()
        updateBitmaps()
    }

    // MARK: - Bitmaps

    /// Shows the bitmap cues due now, one layer each, scaled onto the video rect by Core Animation.
    private func updateBitmaps() {
        guard !bitmapCues.isEmpty || !bitmapLayers.isEmpty else { return }
        guard let geometry = videoGeometry?(), let clock = clock?(), bounds.width > 0, bounds.height > 0 else {
            removeBitmapLayers(keeping: [])
            return
        }
        let rect = Self.videoRect(displaySize: geometry.displaySize, in: bounds, resizeMode: resizeMode, zoom: videoZoom)
        let time = clockInterpolator.time(for: clock) - delaySeconds
        let active = bitmapCues.filter { $0.startSeconds <= time && time < $0.endSeconds }
        let layout = BitmapLayout(cueIds: active.map(\.id), videoRect: rect)
        guard layout != shownBitmapLayout else { return }
        shownBitmapLayout = layout

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeBitmapLayers(keeping: Set(layout.cueIds))
        for cue in active {
            guard let bitmap = cue.bitmap else { continue }
            let bitmapLayer: CALayer
            if let existing = bitmapLayers[cue.id] {
                bitmapLayer = existing
            } else {
                bitmapLayer = CALayer()
                bitmapLayer.contentsGravity = .resize
                bitmapLayer.minificationFilter = .trilinear
                bitmapLayers[cue.id] = bitmapLayer
            }
            // Cue ids restart with each engine session, so never trust a reused layer's picture.
            bitmapLayer.contents = bitmap.image
            bitmapLayer.frame = Self.bitmapFrame(bitmap, codedSize: geometry.codedSize, in: rect)
            // Re-adding keeps the engine's order: a later cue draws over an earlier one.
            layer.addSublayer(bitmapLayer)
        }
        CATransaction.commit()
    }

    private func removeBitmapLayers(keeping ids: Set<Int>) {
        guard bitmapLayers.keys.contains(where: { !ids.contains($0) }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, bitmapLayer) in bitmapLayers where !ids.contains(id) {
            bitmapLayer.removeFromSuperlayer()
            bitmapLayers[id] = nil
        }
        CATransaction.commit()
        if ids.isEmpty { shownBitmapLayout = nil }
    }

    /// The `SubtitleImage` contract: `position` is normalized against the canvas; the canvas maps onto
    /// the coded picture width-aligned and centred vertically (a cropped rip's canvas is taller than its
    /// video), and the coded picture onto `videoRect`. A `.zero` canvas is the video frame itself.
    static func bitmapFrame(_ bitmap: NuvioAetherSubtitleBitmap, codedSize: CGSize, in videoRect: CGRect) -> CGRect {
        let position = bitmap.position
        let canvas = bitmap.canvasSize
        guard canvas.width > 0, canvas.height > 0, codedSize.width > 0, codedSize.height > 0 else {
            return CGRect(
                x: videoRect.minX + position.minX * videoRect.width,
                y: videoRect.minY + position.minY * videoRect.height,
                width: position.width * videoRect.width,
                height: position.height * videoRect.height
            )
        }
        // Canvas pixels to coded pixels, then coded pixels to points (per axis: Fill stretches and
        // anamorphic video presents wider than it is coded).
        let canvasToCoded = codedSize.width / canvas.width
        let scaleX = canvasToCoded * videoRect.width / codedSize.width
        let scaleY = canvasToCoded * videoRect.height / codedSize.height
        return CGRect(
            x: videoRect.minX + position.minX * canvas.width * scaleX,
            y: videoRect.midY + (position.minY - 0.5) * canvas.height * scaleY,
            width: position.width * canvas.width * scaleX,
            height: position.height * canvas.height * scaleY
        )
    }

    // MARK: - Rendering

    private func requestRender() {
        guard isRenderingASS, let renderer, !isRenderInFlight else { return }
        guard let geometry = videoGeometry?(), let clock = clock?(), bounds.width > 0, bounds.height > 0 else {
            clearContent()
            return
        }
        let rect = Self.videoRect(displaySize: geometry.displaySize, in: bounds, resizeMode: resizeMode, zoom: videoZoom)
        guard rect.width >= 1, rect.height >= 1 else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        let time = clockInterpolator.time(for: clock) - delaySeconds
        let timeMs = Int64((time * 1000).rounded())

        let request = RenderRequest(timeMs: timeMs, videoRect: rect, pixelWidth: width, pixelHeight: height, generation: contentGeneration)
        // Paused with nothing new: libass would answer "unchanged" anyway.
        guard request != lastRequest else { return }
        lastRequest = request
        isRenderInFlight = true
        let generation = sourceGeneration
        renderer.render(timeMs: timeMs, width: width, height: height, storage: geometry.codedSize) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRenderInFlight = false
                // A newer content generation is fine: the frame is still right for its time and the next
                // tick renders the new events. Only another track's frame must not be shown.
                guard generation == self.sourceGeneration, self.isRenderingASS else { return }
                self.apply(result, videoRect: rect, pixelSize: CGSize(width: width, height: height))
            }
        }
    }

    private func apply(_ result: AetherASSRenderer.Result, videoRect: CGRect, pixelSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch result {
        case .unchanged:
            // Same image; it still follows the video rect if only the layout moved.
            break
        case .frame(let image, let pixelRect):
            contentLayer.contents = image
            shownPixelRect = image == nil ? .null : pixelRect
            shownPixelSize = pixelSize
        }
        guard !shownPixelRect.isNull, shownPixelSize.width > 0, shownPixelSize.height > 0 else { return }
        let scaleX = videoRect.width / shownPixelSize.width
        let scaleY = videoRect.height / shownPixelSize.height
        contentLayer.frame = CGRect(
            x: videoRect.minX + shownPixelRect.minX * scaleX,
            y: videoRect.minY + shownPixelRect.minY * scaleY,
            width: shownPixelRect.width * scaleX,
            height: shownPixelRect.height * scaleY
        )
    }

    /// Where the video surface draws the picture: its gravity applied to `bounds`, then the zoom
    /// transform about the centre.
    static func videoRect(displaySize: CGSize, in bounds: CGRect, resizeMode: Int, zoom: CGFloat) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }
        var rect: CGRect
        switch resizeMode {
        case 1:
            rect = bounds
        case 2:
            let scale = max(bounds.width / displaySize.width, bounds.height / displaySize.height)
            let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        default:
            rect = AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
        }
        guard zoom != 1 else { return rect }
        let size = CGSize(width: rect.width * zoom, height: rect.height * zoom)
        let center = CGPoint(
            x: bounds.midX + (rect.midX - bounds.midX) * zoom,
            y: bounds.midY + (rect.midY - bounds.midY) * zoom
        )
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Keeps CADisplayLink from retaining the view.
private final class StyledSubtitleDisplayLinkProxy: NSObject {
    weak var target: AetherStyledSubtitleView?
    init(_ target: AetherStyledSubtitleView) { self.target = target }
    @objc func tick() { target?.tick() }
}
