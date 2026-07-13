import Foundation
import PlayerCore

extension PlayerPresentationState {
    init(snapshot: PlayerSnapshot, displayedPosition: TimeInterval, error: PlaybackError?) {
        let phase: PlayerPresentationPhase = switch snapshot.phase {
        case .idle: .idle
        case .loading: .loading
        case .ready: .ready
        case .playing: .playing
        case .paused: .paused
        case .ended: .ended
        case .failed: .failed(error?.message ?? "The video could not be played.")
        }

        let currentChapterIndex = snapshot.chapters
            .filter { $0.startTime <= displayedPosition }
            .max(by: { $0.startTime < $1.startTime })?
            .index

        let videoScaling: VideoPresentationScaling = switch snapshot.videoScaling {
        case .fit: .fit
        case .fill: .fill
        case .actualSize: .actualSize
        }

        self.init(
            phase: phase,
            fileURL: snapshot.mediaURL,
            title: snapshot.mediaURL?.lastPathComponent ?? "MKV Player",
            position: displayedPosition,
            duration: snapshot.duration ?? 0,
            isSeekable: snapshot.isSeekable,
            volume: snapshot.volume * 100,
            isMuted: snapshot.isMuted,
            rate: snapshot.rate,
            isBuffering: snapshot.isBuffering,
            videoScaling: videoScaling,
            naturalVideoWidth: snapshot.naturalVideoSize?.width,
            naturalVideoHeight: snapshot.naturalVideoSize?.height,
            audioTracks: snapshot.tracks
                .filter { $0.kind == .audio }
                .map(Self.trackOption),
            subtitleTracks: snapshot.tracks
                .filter { $0.kind == .subtitle }
                .map(Self.trackOption),
            chapters: snapshot.chapters.map { chapter in
                PlayerChapterOption(
                    index: chapter.index,
                    title: chapter.displayName,
                    time: chapter.startTime,
                    isSelected: chapter.index == currentChapterIndex
                )
            },
            diagnostics: error.map { playbackError in
                [playbackError.message, playbackError.diagnostics]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
        )
    }

    private static func trackOption(_ track: TrackDescriptor) -> PlayerTrackOption {
        let details = [track.languageCode, track.codec]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
        return PlayerTrackOption(
            id: track.id,
            title: track.displayName,
            detail: details.isEmpty ? nil : details,
            isSelected: track.isSelected
        )
    }
}
