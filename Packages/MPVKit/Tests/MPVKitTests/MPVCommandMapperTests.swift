import Foundation
import Testing
@testable import MPVKit

@Suite("MPV command mapping")
struct MPVCommandMapperTests {
    @Test("Local filenames remain one argument")
    func localFilePath() throws {
        let url = URL(fileURLWithPath: "/tmp/A film – final.mkv")
        #expect(
            try MPVCommandMapper.arguments(for: .loadFile(url, startPosition: nil))
                == ["loadfile", "/tmp/A film – final.mkv", "replace"]
        )
    }

    @Test("Start positions use locale-independent formatting")
    func startPosition() throws {
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        #expect(
            try MPVCommandMapper.arguments(for: .loadFile(url, startPosition: 65.25))
                == ["loadfile", "/tmp/movie.mkv", "replace", "-1", "start=65.25"]
        )
    }

    @Test("Normalized volume maps to mpv percent")
    func volume() throws {
        #expect(
            try MPVCommandMapper.arguments(for: .setVolume(0.425))
                == ["set", "volume", "42.5"]
        )
    }

    @Test("Track selection can disable a track")
    func trackSelection() throws {
        #expect(
            try MPVCommandMapper.arguments(for: .selectTrack(id: 7, type: .audio))
                == ["set", "aid", "7"]
        )
        #expect(
            try MPVCommandMapper.arguments(for: .selectTrack(id: nil, type: .subtitle))
                == ["set", "sid", "no"]
        )
    }

    @Test("Scaling commands preserve aspect ratio semantics")
    func scaling() throws {
        #expect(
            try MPVCommandMapper.arguments(for: .setVideoUnscaled(true))
                == ["set", "video-unscaled", "yes"]
        )
        #expect(
            try MPVCommandMapper.arguments(for: .setPanscan(1))
                == ["set", "panscan", "1"]
        )
    }

    @Test("Remote URLs are rejected for a local-only player")
    func remoteURL() {
        #expect(throws: MPVCommandMappingError.nonFileURL) {
            try MPVCommandMapper.arguments(
                for: .loadFile(URL(string: "https://example.com/movie.mkv")!, startPosition: nil)
            )
        }
    }

    @Test("Invalid ranges are rejected before reaching C")
    func invalidRanges() {
        #expect(throws: MPVCommandMappingError.volumeOutOfRange) {
            try MPVCommandMapper.arguments(for: .setVolume(1.1))
        }
        #expect(throws: MPVCommandMappingError.rateOutOfRange) {
            try MPVCommandMapper.arguments(for: .setRate(0))
        }
        #expect(throws: MPVCommandMappingError.negativePosition) {
            try MPVCommandMapper.arguments(for: .seekAbsolute(-1))
        }
    }
}
