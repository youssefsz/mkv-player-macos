import Foundation

public enum PlaybackPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed
}

public enum TrackKind: String, Codable, CaseIterable, Sendable {
    case video
    case audio
    case subtitle
}

public enum VideoScalingMode: String, Codable, CaseIterable, Sendable {
    /// Preserve the complete picture and allow letterboxing or pillarboxing.
    case fit
    /// Fill the available surface while preserving aspect ratio, cropping when necessary.
    case fill
    /// Display one video pixel per backing-store pixel when the renderer supports it.
    case actualSize
}

public struct VideoDimensions: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }
}

public struct TrackDescriptor: Codable, Identifiable, Sendable, Equatable {
    public let id: Int64
    public let kind: TrackKind
    public let title: String?
    public let languageCode: String?
    public let codec: String?
    public let isSelected: Bool
    public let isDefault: Bool
    public let isForced: Bool
    public let isExternal: Bool

    public init(
        id: Int64,
        kind: TrackKind,
        title: String? = nil,
        languageCode: String? = nil,
        codec: String? = nil,
        isSelected: Bool = false,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.languageCode = languageCode
        self.codec = codec
        self.isSelected = isSelected
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
    }

    public var displayName: String {
        if let title, !title.isEmpty {
            return title
        }
        if let languageCode, !languageCode.isEmpty {
            return Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
        }
        return switch kind {
        case .video: "Video \(id)"
        case .audio: "Audio \(id)"
        case .subtitle: "Subtitle \(id)"
        }
    }
}

public struct ChapterDescriptor: Codable, Identifiable, Sendable, Equatable {
    public var id: Int { index }
    public let index: Int
    public let title: String?
    public let startTime: TimeInterval

    public init(index: Int, title: String? = nil, startTime: TimeInterval) {
        self.index = index
        self.title = title
        self.startTime = max(0, startTime.isFinite ? startTime : 0)
    }

    public var displayName: String {
        guard let title, !title.isEmpty else {
            return "Chapter \(index + 1)"
        }
        return title
    }
}

public struct PlaybackError: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Code: String, Codable, CaseIterable, Sendable {
        case fileNotFound
        case accessDenied
        case unsupportedMedia
        case corruptMedia
        case engineUnavailable
        case renderingFailed
        case commandFailed
        case cancelled
        case unknown
    }

    public let code: Code
    public let message: String
    public let diagnostics: String?
    public let recoverySuggestion: String?

    public init(
        code: Code,
        message: String,
        diagnostics: String? = nil,
        recoverySuggestion: String? = nil
    ) {
        self.code = code
        self.message = message
        self.diagnostics = diagnostics
        self.recoverySuggestion = recoverySuggestion
    }

    public var errorDescription: String? { message }

    public static func wrapping(
        _ error: any Error,
        fallbackCode: Code = .unknown,
        recoverySuggestion: String? = nil
    ) -> PlaybackError {
        if let playbackError = error as? PlaybackError {
            return playbackError
        }

        let nsError = error as NSError
        return PlaybackError(
            code: fallbackCode,
            message: nsError.localizedDescription,
            diagnostics: "\(nsError.domain) (\(nsError.code))",
            recoverySuggestion: recoverySuggestion
        )
    }
}

public struct PlayerSnapshot: Codable, Sendable, Equatable {
    public var phase: PlaybackPhase
    public var mediaURL: URL?
    public var currentTime: TimeInterval
    public var duration: TimeInterval?
    public var isSeekable: Bool
    public var isBuffering: Bool
    public var videoScaling: VideoScalingMode
    public var naturalVideoSize: VideoDimensions?
    /// A normalized value in the closed range `0...1`.
    public var volume: Double
    public var isMuted: Bool
    public var rate: Double
    public var tracks: [TrackDescriptor]
    public var chapters: [ChapterDescriptor]

    public init(
        phase: PlaybackPhase = .idle,
        mediaURL: URL? = nil,
        currentTime: TimeInterval = 0,
        duration: TimeInterval? = nil,
        isSeekable: Bool = false,
        isBuffering: Bool = false,
        videoScaling: VideoScalingMode = .fit,
        naturalVideoSize: VideoDimensions? = nil,
        volume: Double = 1,
        isMuted: Bool = false,
        rate: Double = 1,
        tracks: [TrackDescriptor] = [],
        chapters: [ChapterDescriptor] = []
    ) {
        self.phase = phase
        self.mediaURL = mediaURL
        self.currentTime = Self.sanitizeTime(currentTime)
        self.duration = duration.map(Self.sanitizeTime)
        self.isSeekable = isSeekable
        self.isBuffering = isBuffering
        self.videoScaling = videoScaling
        self.naturalVideoSize = naturalVideoSize
        self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        self.isMuted = isMuted
        self.rate = rate.isFinite && rate > 0 ? rate : 1
        self.tracks = tracks
        self.chapters = chapters
    }

    public static let empty = PlayerSnapshot()

    public func selectedTrackID(for kind: TrackKind) -> Int64? {
        tracks.first(where: { $0.kind == kind && $0.isSelected })?.id
    }

    private static func sanitizeTime(_ value: TimeInterval) -> TimeInterval {
        max(0, value.isFinite ? value : 0)
    }
}

public struct MediaLoadRequest: Sendable, Equatable {
    /// Correlates every asynchronous engine event with the session that
    /// requested it. URLs alone are insufficient when the same file is
    /// reopened before the previous load has completely unloaded.
    public let playbackID: UUID
    public let url: URL
    public let startPosition: TimeInterval?
    public let autoplay: Bool

    public init(
        playbackID: UUID = UUID(),
        url: URL,
        startPosition: TimeInterval? = nil,
        autoplay: Bool = true
    ) {
        self.playbackID = playbackID
        self.url = url
        if let startPosition, startPosition.isFinite, startPosition > 0 {
            self.startPosition = startPosition
        } else {
            self.startPosition = nil
        }
        self.autoplay = autoplay
    }
}

public struct PlayerEvent: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case snapshot(PlayerSnapshot)
        case phaseChanged(PlaybackPhase)
        case positionChanged(currentTime: TimeInterval, duration: TimeInterval?)
        case bufferingChanged(Bool)
        case videoScalingChanged(VideoScalingMode)
        case videoSizeChanged(VideoDimensions?)
        case volumeChanged(volume: Double, isMuted: Bool)
        case rateChanged(Double)
        case tracksChanged([TrackDescriptor])
        case chaptersChanged([ChapterDescriptor])
        case mediaLoaded(URL)
        case ended
        case failed(PlaybackError)
    }

    /// `nil` is reserved for non-media/global events. Player engines must tag
    /// every event produced for a load request with that request's identifier.
    public let playbackID: UUID?
    public let payload: Payload

    public init(playbackID: UUID?, payload: Payload) {
        self.playbackID = playbackID
        self.payload = payload
    }

    public func withPlaybackID(_ playbackID: UUID) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: payload)
    }

    public static func snapshot(
        _ snapshot: PlayerSnapshot,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .snapshot(snapshot))
    }

    public static func phaseChanged(
        _ phase: PlaybackPhase,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .phaseChanged(phase))
    }

    public static func positionChanged(
        currentTime: TimeInterval,
        duration: TimeInterval?,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(
            playbackID: playbackID,
            payload: .positionChanged(currentTime: currentTime, duration: duration)
        )
    }

    public static func bufferingChanged(
        _ buffering: Bool,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .bufferingChanged(buffering))
    }

    public static func videoScalingChanged(
        _ mode: VideoScalingMode,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .videoScalingChanged(mode))
    }

    public static func videoSizeChanged(
        _ size: VideoDimensions?,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .videoSizeChanged(size))
    }

    public static func volumeChanged(
        volume: Double,
        isMuted: Bool,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(
            playbackID: playbackID,
            payload: .volumeChanged(volume: volume, isMuted: isMuted)
        )
    }

    public static func rateChanged(
        _ rate: Double,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .rateChanged(rate))
    }

    public static func tracksChanged(
        _ tracks: [TrackDescriptor],
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .tracksChanged(tracks))
    }

    public static func chaptersChanged(
        _ chapters: [ChapterDescriptor],
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .chaptersChanged(chapters))
    }

    public static func mediaLoaded(
        _ url: URL,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .mediaLoaded(url))
    }

    public static var ended: PlayerEvent {
        PlayerEvent(playbackID: nil, payload: .ended)
    }

    public static func ended(playbackID: UUID) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .ended)
    }

    public static func failed(
        _ error: PlaybackError,
        playbackID: UUID? = nil
    ) -> PlayerEvent {
        PlayerEvent(playbackID: playbackID, payload: .failed(error))
    }
}

public struct ResumeNotice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let position: TimeInterval

    public init(id: UUID = UUID(), position: TimeInterval) {
        self.id = id
        self.position = max(0, position.isFinite ? position : 0)
    }
}
