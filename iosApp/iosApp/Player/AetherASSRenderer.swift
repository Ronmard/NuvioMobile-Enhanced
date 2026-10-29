import CoreGraphics
import Foundation
import Libass
import NuvioAetherKit

/// libass behind a serial queue for the AetherEngine path: one library and renderer per player, one
/// libass track per ASS source.
///
/// Calls the libass MPVKit already links (the copy mpv renders with) through instances of its own, so
/// nothing here touches mpv's state. Every libass call runs on `queue`.
final class AetherASSRenderer {

    enum Result {
        /// Same subtitles as the previous render at the same size.
        case unchanged
        /// `image` is nil when nothing is on screen; `rect` places it, in pixels of the rendered frame.
        case frame(image: CGImage?, rect: CGRect)
    }

    /// Bounds a frame (aspect-fill zoom can make the video rect much larger than the screen).
    private static let maxFrameDimension = 4096

    private let queue = DispatchQueue(label: "com.nuvio.aether.libass", qos: .userInitiated)
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private var track: UnsafeMutablePointer<ASS_Track>?
    /// `start|end|line` of every event fed to `track`; the engine re-emits cues after seeks.
    private var seenEvents = Set<String>()
    private var addedFonts = Set<String>()
    private var defaultFamily: String?
    private var frameSize = (width: 0, height: 0)
    private var storageSize = (width: 0, height: 0)
    private var hasRendered = false

    init?() {
        guard let library = ass_library_init() else { return nil }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        self.library = library
        self.renderer = renderer
        // Fonts embedded in a script's [Fonts] section, as mpv's sub-fonts default.
        ass_set_extract_fonts(library, 1)
        queue.async { self.configureFonts() }
    }

    deinit {
        // Every queued block retains self, so nothing is left running on `queue` by now.
        if let track { ass_free_track(track) }
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    /// The family unstyled or unresolvable text falls back to (mpv's `sub-font`).
    func setDefaultFamily(_ family: String?) {
        queue.async {
            guard family != self.defaultFamily else { return }
            self.defaultFamily = family
            self.configureFonts()
        }
    }

    /// Starts a fresh track for `source` (nil drops it). `fonts` are the media's attachments.
    func setSource(_ source: NuvioAetherASSSource?, fonts: [NuvioAetherFontAttachment]) {
        queue.async {
            if let track = self.track { ass_free_track(track) }
            self.track = nil
            self.seenEvents.removeAll()
            self.hasRendered = false
            guard let source else { return }
            self.addFonts(fonts)
            guard let track = ass_new_track(self.library) else { return }
            source.header.utf8CString.withUnsafeBufferPointer { buffer in
                // Header without an [Events] section: libass falls back to the standard event format.
                ass_process_codec_private(track, buffer.baseAddress, Int32(buffer.count - 1))
            }
            self.track = track
        }
    }

    /// Feeds the raw events of `cues` (cues without them are skipped); already-seen events are ignored.
    func addEvents(from cues: [NuvioAetherSubtitleCue]) {
        let events = cues.compactMap { cue in cue.assEvents.map { ($0, cue.startSeconds, cue.endSeconds) } }
        guard !events.isEmpty else { return }
        queue.async {
            guard let track = self.track else { return }
            for (raw, start, end) in events {
                for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                    let key = "\(start)|\(end)|\(line)"
                    guard !self.seenEvents.contains(key),
                          let dialogue = Self.dialogueLine(fromRawEvent: line, start: start, end: end)
                    else { continue }
                    self.seenEvents.insert(key)
                    ass_process_data(track, dialogue, Int32(dialogue.utf8.count))
                }
            }
        }
    }

    /// Drops every event but keeps the track (its styles), e.g. when the cue list is reset.
    func flushEvents() {
        queue.async {
            guard let track = self.track else { return }
            ass_flush_events(track)
            self.seenEvents.removeAll()
            self.hasRendered = false
        }
    }

    /// Renders the subtitles due at `timeMs` (source axis) into a `width` x `height` pixel frame laid
    /// over the video. `storage` is the video's coded size, which libass uses for the pixel aspect.
    func render(
        timeMs: Int64,
        width: Int,
        height: Int,
        storage: CGSize,
        completion: @escaping (Result) -> Void
    ) {
        queue.async {
            completion(self.renderOnQueue(timeMs: timeMs, width: width, height: height, storage: storage))
        }
    }

    // MARK: - Queue

    private func configureFonts() {
        // CoreText provider; attached and extracted fonts are matched first by family name.
        ass_set_fonts(renderer, nil, defaultFamily ?? "sans-serif", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
    }

    private func addFonts(_ fonts: [NuvioAetherFontAttachment]) {
        var added = false
        for font in fonts where !font.data.isEmpty && !addedFonts.contains(font.name) {
            addedFonts.insert(font.name)
            font.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ass_add_font(library, font.name, base, Int32(raw.count))
            }
            added = true
        }
        // Memory fonts are indexed when the font selector is built.
        if added { configureFonts() }
    }

    private func renderOnQueue(timeMs: Int64, width: Int, height: Int, storage: CGSize) -> Result {
        guard let track, width > 0, height > 0 else { return .frame(image: nil, rect: .zero) }
        let largest = max(width, height)
        let shrink = largest > Self.maxFrameDimension ? Double(Self.maxFrameDimension) / Double(largest) : 1
        let frameWidth = max(Int(Double(width) * shrink), 1)
        let frameHeight = max(Int(Double(height) * shrink), 1)

        var sizeChanged = false
        if frameSize != (frameWidth, frameHeight) {
            frameSize = (frameWidth, frameHeight)
            ass_set_frame_size(renderer, Int32(frameWidth), Int32(frameHeight))
            sizeChanged = true
        }
        let storageWidth = Int(storage.width.rounded())
        let storageHeight = Int(storage.height.rounded())
        if storageWidth > 0, storageHeight > 0, storageSize != (storageWidth, storageHeight) {
            storageSize = (storageWidth, storageHeight)
            ass_set_storage_size(renderer, Int32(storageWidth), Int32(storageHeight))
            sizeChanged = true
        }

        var change: Int32 = 0
        let images = ass_render_frame(renderer, track, timeMs, &change)
        if change == 0, !sizeChanged, hasRendered { return .unchanged }
        hasRendered = true
        guard let composite = Self.composite(images) else { return .frame(image: nil, rect: .zero) }
        let rect = CGRect(
            x: composite.rect.minX / shrink,
            y: composite.rect.minY / shrink,
            width: composite.rect.width / shrink,
            height: composite.rect.height / shrink
        )
        return .frame(image: composite.image, rect: rect)
    }

    /// libavcodec hands events as `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
    /// with the timing on the cue; libass parses `Dialogue:` lines in the track's event format.
    private static func dialogueLine(fromRawEvent line: Substring, start: Double, end: Double) -> String? {
        let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9, Int(fields[0]) != nil else { return nil }
        let tail = fields[2...].joined(separator: ",")
        return "Dialogue: \(fields[1]),\(timestamp(start)),\(timestamp(end)),\(tail)\n"
    }

    /// `H:MM:SS.cc`; libass reads timing at centisecond precision.
    private static func timestamp(_ seconds: Double) -> String {
        var centis = Int((max(seconds, 0) * 100).rounded())
        let hours = centis / 360_000
        centis %= 360_000
        let minutes = centis / 6_000
        centis %= 6_000
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, centis / 100, centis % 100)
    }

    /// Blends libass's alpha bitmaps (back to front) into one premultiplied RGBA image cropped to
    /// their bounds. nil when nothing is visible.
    private static func composite(_ head: UnsafeMutablePointer<ASS_Image>?) -> (image: CGImage, rect: CGRect)? {
        var bounds = CGRect.null
        var node = head
        while let image = node?.pointee {
            if image.w > 0, image.h > 0, (image.color & 0xFF) != 0xFF {
                bounds = bounds.union(CGRect(x: Int(image.dst_x), y: Int(image.dst_y), width: Int(image.w), height: Int(image.h)))
            }
            node = image.next
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }

        let originX = Int(bounds.minX)
        let originY = Int(bounds.minY)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let bytesPerRow = width * 4
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        // CGContext memory starts zeroed (transparent). Rows run top-down in memory, as libass's do.
        let contextBytesPerRow = context.bytesPerRow

        node = head
        while let image = node?.pointee {
            defer { node = image.next }
            let opacity = 255 - (image.color & 0xFF)
            guard image.w > 0, image.h > 0, opacity > 0, let bitmap = image.bitmap else { continue }
            let red = (image.color >> 24) & 0xFF
            let green = (image.color >> 16) & 0xFF
            let blue = (image.color >> 8) & 0xFF
            let stride = Int(image.stride)
            for row in 0..<Int(image.h) {
                let source = bitmap + row * stride
                var target = data + (Int(image.dst_y) - originY + row) * contextBytesPerRow + (Int(image.dst_x) - originX) * 4
                for column in 0..<Int(image.w) {
                    defer { target += 4 }
                    let coverage = UInt32(source[column])
                    guard coverage != 0 else { continue }
                    let alpha = (coverage * opacity + 127) / 255
                    let inverse = 255 - alpha
                    target[0] = UInt8((red * alpha + UInt32(target[0]) * inverse + 127) / 255)
                    target[1] = UInt8((green * alpha + UInt32(target[1]) * inverse + 127) / 255)
                    target[2] = UInt8((blue * alpha + UInt32(target[2]) * inverse + 127) / 255)
                    target[3] = UInt8(alpha + (UInt32(target[3]) * inverse + 127) / 255)
                }
            }
        }
        guard let cgImage = context.makeImage() else { return nil }
        return (cgImage, CGRect(x: originX, y: originY, width: width, height: height))
    }
}
