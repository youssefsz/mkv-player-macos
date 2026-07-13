import Foundation

/// The small, typed command surface used between `PlayerEngine` and libmpv.
///
/// Keeping command construction here makes escaping, numeric formatting, and
/// local-file validation independently testable without loading libmpv.
public enum MPVCommand: Equatable, Sendable {
    case loadFile(URL, startPosition: TimeInterval?)
    case setPaused(Bool)
    case seekAbsolute(TimeInterval)
    case seekRelative(TimeInterval)
    case setVolume(Double)
    case setMuted(Bool)
    case setRate(Double)
    case setVideoUnscaled(Bool)
    case setPanscan(Double)
    case selectTrack(id: Int64?, type: MPVTrackType)
    case selectChapter(Int)
    case addSubtitle(URL)
    case stop
}

public enum MPVTrackType: String, Equatable, Sendable {
    case video = "vid"
    case audio = "aid"
    case subtitle = "sid"
}

public enum MPVCommandMappingError: Error, Equatable, Sendable {
    case nonFileURL
    case invalidNumber
    case negativePosition
    case volumeOutOfRange
    case rateOutOfRange
    case negativeChapter
}

public enum MPVCommandMapper {
    /// Converts a typed command to the null-terminated argument vector expected
    /// by `mpv_command_async` (the null terminator is added by `MPVClient`).
    public static func arguments(for command: MPVCommand) throws -> [String] {
        switch command {
        case let .loadFile(url, startPosition):
            let path = try localPath(for: url)
            guard let startPosition else {
                return ["loadfile", path, "replace"]
            }
            guard startPosition.isFinite else {
                throw MPVCommandMappingError.invalidNumber
            }
            guard startPosition >= 0 else {
                throw MPVCommandMappingError.negativePosition
            }
            return [
                "loadfile",
                path,
                "replace",
                "-1",
                "start=\(format(startPosition))",
            ]

        case let .setPaused(paused):
            return ["set", "pause", yesNo(paused)]

        case let .seekAbsolute(seconds):
            guard seconds.isFinite else {
                throw MPVCommandMappingError.invalidNumber
            }
            guard seconds >= 0 else {
                throw MPVCommandMappingError.negativePosition
            }
            return ["seek", format(seconds), "absolute+exact"]

        case let .seekRelative(seconds):
            guard seconds.isFinite else {
                throw MPVCommandMappingError.invalidNumber
            }
            return ["seek", format(seconds), "relative+exact"]

        case let .setVolume(normalizedVolume):
            guard normalizedVolume.isFinite else {
                throw MPVCommandMappingError.invalidNumber
            }
            guard (0 ... 1).contains(normalizedVolume) else {
                throw MPVCommandMappingError.volumeOutOfRange
            }
            return ["set", "volume", format(normalizedVolume * 100)]

        case let .setMuted(muted):
            return ["set", "mute", yesNo(muted)]

        case let .setRate(rate):
            guard rate.isFinite else {
                throw MPVCommandMappingError.invalidNumber
            }
            guard (0.25 ... 4).contains(rate) else {
                throw MPVCommandMappingError.rateOutOfRange
            }
            return ["set", "speed", format(rate)]

        case let .setVideoUnscaled(unscaled):
            return ["set", "video-unscaled", yesNo(unscaled)]

        case let .setPanscan(amount):
            guard amount.isFinite else {
                throw MPVCommandMappingError.invalidNumber
            }
            guard (0 ... 1).contains(amount) else {
                throw MPVCommandMappingError.invalidNumber
            }
            return ["set", "panscan", format(amount)]

        case let .selectTrack(id, type):
            return ["set", type.rawValue, id.map(String.init) ?? "no"]

        case let .selectChapter(index):
            guard index >= 0 else {
                throw MPVCommandMappingError.negativeChapter
            }
            return ["set", "chapter", String(index)]

        case let .addSubtitle(url):
            return ["sub-add", try localPath(for: url), "select"]

        case .stop:
            return ["stop"]
        }
    }

    private static func localPath(for url: URL) throws -> String {
        guard url.isFileURL else {
            throw MPVCommandMappingError.nonFileURL
        }
        return url.standardizedFileURL.path
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    /// libmpv parses numbers with a period regardless of the user's locale.
    private static func format(_ number: Double) -> String {
        var result = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            number
        )

        while result.last == "0" {
            result.removeLast()
        }
        if result.last == "." {
            result.removeLast()
        }
        return result == "-0" ? "0" : result
    }
}
