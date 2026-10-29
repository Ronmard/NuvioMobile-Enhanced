import Foundation
@_implementationOnly import AetherEngine

/// A text subtitle cue as the host overlay draws it. Times are on the engine's source axis, the same
/// axis as `NuvioAetherPlayer.subtitleClockSeconds`.
public struct NuvioAetherSubtitleCue: Equatable {
    public let id: Int
    public let startSeconds: Double
    public let endSeconds: Double
    /// Plain text with styling flattened away; lines separated by "\n".
    public let text: String
    /// ASS numpad alignment the cue asked for (`\an`), nil for the host's default (bottom centre).
    public let alignment: Int?
}

extension NuvioAetherSubtitleCue {
    /// Text cues only: bitmap cues (PGS / DVB / DVD) are not drawn by the host overlay yet.
    static func make(from cue: SubtitleCue) -> NuvioAetherSubtitleCue? {
        guard let text = cue.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NuvioAetherSubtitleCue(
            id: cue.id,
            startSeconds: cue.startTime,
            endSeconds: cue.endTime,
            text: trimmed,
            alignment: cue.placement?.alignment
        )
    }
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
