import Foundation

/// The playback backend boundary. Implementations own their threading model and must never
/// invoke blocking decoder APIs on the main actor.
public protocol PlayerEngine: Sendable {
    /// A single, long-lived stream of state changes. Events may arrive from any executor.
    /// Every media-scoped event must carry the originating request's `playbackID`.
    var events: AsyncStream<PlayerEvent> { get }

    func load(_ request: MediaLoadRequest) async throws
    func play() async throws
    func pause() async throws
    func seek(to seconds: TimeInterval) async throws
    func seek(by seconds: TimeInterval) async throws
    func setVolume(_ normalizedVolume: Double) async throws
    func setMuted(_ muted: Bool) async throws
    func setRate(_ rate: Double) async throws
    func setVideoScaling(_ mode: VideoScalingMode) async throws
    func selectTrack(id: Int64?, kind: TrackKind) async throws
    func selectChapter(index: Int) async throws
    func addExternalSubtitle(_ url: URL) async throws
    /// Completes only after the backend has confirmed that it no longer reads
    /// the current media resource.
    func stop() async throws
}
