import CoreGraphics
import Foundation
@_implementationOnly import AetherEngine

/// A subtitle cue as the host overlays draw it: text, or a decoded bitmap (`bitmap`). Times are on the
/// engine's source axis, the same axis as `NuvioAetherPlayer.subtitleClockSeconds`.
public struct NuvioAetherSubtitleCue: Equatable {
    public let id: Int
    public let startSeconds: Double
    public let endSeconds: Double
    /// Plain text with styling flattened away; lines separated by "\n". Empty for a bitmap cue.
    public let text: String
    /// ASS numpad alignment the cue asked for (`\an`), nil for the host's default (bottom centre).
    public let alignment: Int?
    /// Raw ASS event lines (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`, one per
    /// line) when the track is styled ASS/SSA, for a libass renderer; `text` then holds the same lines
    /// flattened for the plain-text fallback. nil for every other track.
    public let assEvents: String?
    /// The decoded picture of a bitmap cue (PGS / DVB / DVD), nil for text.
    public let bitmap: NuvioAetherSubtitleBitmap?
}

/// A decoded bitmap subtitle (PGS / DVB / DVD).
public struct NuvioAetherSubtitleBitmap: Equatable {
    /// Fully rendered RGBA, premultiplied alpha.
    public let image: CGImage
    /// Where the image goes, normalized ([0, 1], y from the top) against `canvasSize`.
    public let position: CGRect
    /// Pixel size of the subtitle canvas (e.g. 1920x1080), `.zero` when unknown: `position` is then
    /// normalized against the video frame. Map the canvas onto the picture width-aligned and centred
    /// vertically: a cropped rip's canvas can be taller than its video.
    public let canvasSize: CGSize
    /// The disc authored this object as a forced caption.
    public let isForced: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image === rhs.image && lhs.position == rhs.position && lhs.canvasSize == rhs.canvasSize
            && lhs.isForced == rhs.isForced
    }
}

extension NuvioAetherSubtitleCue {
    static func make(from cue: SubtitleCue) -> NuvioAetherSubtitleCue? {
        if case .image(let image) = cue.body {
            return NuvioAetherSubtitleCue(
                id: cue.id,
                startSeconds: cue.startTime,
                endSeconds: cue.endTime,
                text: "",
                alignment: nil,
                assEvents: nil,
                bitmap: NuvioAetherSubtitleBitmap(
                    image: image.cgImage,
                    position: image.position,
                    canvasSize: image.canvasSize,
                    isForced: image.isForced
                )
            )
        }
        guard let text = cue.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let ass = ASSEventLines(trimmed) {
            return NuvioAetherSubtitleCue(
                id: cue.id,
                startSeconds: cue.startTime,
                endSeconds: cue.endTime,
                text: ass.plainText,
                alignment: ass.alignment,
                assEvents: trimmed,
                bitmap: nil
            )
        }
        return NuvioAetherSubtitleCue(
            id: cue.id,
            startSeconds: cue.startTime,
            endSeconds: cue.endTime,
            text: trimmed,
            alignment: cue.placement?.alignment,
            assEvents: nil,
            bitmap: nil
        )
    }
}

/// The raw event lines a cue carries under `LoadOptions.preserveASSMarkup` (ASS/SSA tracks only).
private struct ASSEventLines {
    /// Override tags and drawings removed, `\N` as a line break; may be empty (a drawing-only sign).
    let plainText: String
    let alignment: Int?

    private static let overrideBlock = try! NSRegularExpression(pattern: #"\{[^}]*\}"#)
    private static let drawingMode = try! NSRegularExpression(pattern: #"\\p[1-9]"#)
    private static let numpadAlignment = try! NSRegularExpression(pattern: #"\\an([1-9])"#)

    /// nil unless every line has the shape libavcodec gives ASS events (numeric ReadOrder, Layer and
    /// margins), so text that merely contains commas is never mistaken for one.
    init?(_ raw: String) {
        var texts: [String] = []
        var alignment: Int?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9,
                  [0, 1, 4, 5, 6].allSatisfy({ Int(fields[$0].trimmingCharacters(in: .whitespaces)) != nil })
            else { return nil }
            let body = String(fields[8])
            let range = NSRange(body.startIndex..., in: body)
            if alignment == nil,
               let match = Self.numpadAlignment.firstMatch(in: body, range: range),
               let digits = Range(match.range(at: 1), in: body) {
                alignment = Int(body[digits])
            }
            // A vector drawing (signs, karaoke effects) would print as coordinates.
            guard Self.drawingMode.firstMatch(in: body, range: range) == nil else { continue }
            let text = Self.overrideBlock
                .stringByReplacingMatches(in: body, range: range, withTemplate: "")
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }
        }
        plainText = texts.joined(separator: "\n")
        self.alignment = alignment
    }
}

/// The selected track when its cues arrive as raw ASS events: what a libass renderer needs to set
/// up a track. A new value (another track, or a new header) means start a fresh libass track.
public struct NuvioAetherASSSource: Equatable {
    /// `NuvioAetherTrack.id` of the selected track.
    public let trackId: Int
    /// `[Script Info]` and `[V4+ Styles]` (and usually the `[Events]` format line), NULs removed.
    public let header: String
}

/// A font file attached to the media (MKV attachments), for ASS styles that name it.
public struct NuvioAetherFontAttachment {
    public let name: String
    public let data: Data
}

/// A subtitle file outside the media (stream-provided or picked from an addon), loaded by the engine
/// and listed next to the embedded tracks.
public struct NuvioAetherExternalSubtitle: Equatable {
    public let url: URL
    public let name: String?
    public let language: String?
    /// nil sends the stream's own request headers.
    public let headers: [String: String]?

    public init(url: URL, name: String?, language: String?, headers: [String: String]?) {
        self.url = url
        self.name = name
        self.language = language
        self.headers = headers
    }

    var engineTrack: ExternalSubtitleTrack {
        ExternalSubtitleTrack(
            url: url,
            name: name?.isEmpty == false ? name : nil,
            language: language?.isEmpty == false ? language : nil,
            httpHeaders: headers?.isEmpty == false ? headers : nil
        )
    }
}
