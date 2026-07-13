import Foundation

public enum MediaKey {
    public static func make(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path
        }
        return url.absoluteString
    }
}

public struct PlaybackHistoryEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: String { mediaKey }
    public let mediaKey: String
    public var displayName: String
    public var bookmarkData: Data?
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var updatedAt: Date
    public var isCompleted: Bool

    public init(
        mediaKey: String,
        displayName: String,
        bookmarkData: Data? = nil,
        position: TimeInterval,
        duration: TimeInterval?,
        updatedAt: Date = Date(),
        isCompleted: Bool = false
    ) {
        self.mediaKey = mediaKey
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.position = max(0, position.isFinite ? position : 0)
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        } else {
            self.duration = nil
        }
        self.updatedAt = updatedAt
        self.isCompleted = isCompleted
    }

    public init(
        url: URL,
        bookmarkData: Data? = nil,
        position: TimeInterval,
        duration: TimeInterval?,
        updatedAt: Date = Date(),
        isCompleted: Bool = false
    ) {
        self.init(
            mediaKey: MediaKey.make(for: url),
            displayName: url.lastPathComponent,
            bookmarkData: bookmarkData,
            position: position,
            duration: duration,
            updatedAt: updatedAt,
            isCompleted: isCompleted
        )
    }
}

public struct ResumePolicy: Codable, Sendable, Equatable {
    public var minimumPosition: TimeInterval
    public var minimumRemainingTime: TimeInterval

    public init(minimumPosition: TimeInterval = 30, minimumRemainingTime: TimeInterval = 30) {
        self.minimumPosition = max(0, minimumPosition)
        self.minimumRemainingTime = max(0, minimumRemainingTime)
    }

    public func resumePosition(for entry: PlaybackHistoryEntry) -> TimeInterval? {
        guard !entry.isCompleted,
              entry.position > minimumPosition,
              let duration = entry.duration,
              duration - entry.position > minimumRemainingTime
        else {
            return nil
        }
        return min(entry.position, duration)
    }
}

public protocol PlaybackHistoryStoring: Sendable {
    func entry(for mediaKey: String) async throws -> PlaybackHistoryEntry?
    func allEntries() async throws -> [PlaybackHistoryEntry]
    func upsert(_ entry: PlaybackHistoryEntry) async throws
    func remove(mediaKey: String) async throws
    func removeAll() async throws
}

public enum PlaybackHistoryStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidData
    case unsupportedVersion(Int)
    case applicationSupportUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            "The playback history file is not valid."
        case let .unsupportedVersion(version):
            "Playback history version \(version) is newer than this app supports."
        case .applicationSupportUnavailable:
            "The Application Support directory is unavailable."
        }
    }
}

public actor JSONPlaybackHistoryStore: PlaybackHistoryStoring {
    public static let currentVersion = 1

    public nonisolated let fileURL: URL
    public nonisolated let maximumEntryCount: Int

    private struct Document: Codable {
        var version: Int
        var entries: [PlaybackHistoryEntry]
    }

    private var cachedEntries: [String: PlaybackHistoryEntry]?

    public init(fileURL: URL, maximumEntryCount: Int = 100) {
        self.fileURL = fileURL
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public init(applicationIdentifier: String, maximumEntryCount: Int = 100) throws {
        self.init(
            fileURL: try Self.defaultFileURL(applicationIdentifier: applicationIdentifier),
            maximumEntryCount: maximumEntryCount
        )
    }

    public nonisolated static func defaultFileURL(applicationIdentifier: String) throws -> URL {
        guard let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PlaybackHistoryStoreError.applicationSupportUnavailable
        }
        return baseURL
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("PlaybackHistory.json", isDirectory: false)
    }

    public func entry(for mediaKey: String) throws -> PlaybackHistoryEntry? {
        try loadIfNeeded()[mediaKey]
    }

    public func allEntries() throws -> [PlaybackHistoryEntry] {
        try loadIfNeeded().values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func upsert(_ entry: PlaybackHistoryEntry) throws {
        var entries = try loadIfNeeded()
        entries[entry.mediaKey] = entry
        entries = capped(entries)
        try persist(entries)
        cachedEntries = entries
    }

    public func remove(mediaKey: String) throws {
        var entries = try loadIfNeeded()
        entries.removeValue(forKey: mediaKey)
        try persist(entries)
        cachedEntries = entries
    }

    public func removeAll() throws {
        try persist([:])
        cachedEntries = [:]
    }

    private func loadIfNeeded() throws -> [String: PlaybackHistoryEntry] {
        if let cachedEntries {
            return cachedEntries
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty: [String: PlaybackHistoryEntry] = [:]
            cachedEntries = empty
            return empty
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decodedEntries: [PlaybackHistoryEntry]
        if let document = try? decoder.decode(Document.self, from: data) {
            guard document.version <= Self.currentVersion else {
                throw PlaybackHistoryStoreError.unsupportedVersion(document.version)
            }
            guard document.version >= 0 else {
                throw PlaybackHistoryStoreError.invalidData
            }
            decodedEntries = document.entries
        } else if let legacyEntries = try? decoder.decode([PlaybackHistoryEntry].self, from: data) {
            // Version 0 stored a bare entry array. It is rewritten as v1 on the next mutation.
            decodedEntries = legacyEntries
        } else {
            throw PlaybackHistoryStoreError.invalidData
        }

        let entries = capped(Dictionary(decodedEntries.map { ($0.mediaKey, $0) }, uniquingKeysWith: {
            $0.updatedAt >= $1.updatedAt ? $0 : $1
        }))
        cachedEntries = entries
        return entries
    }

    private func capped(
        _ entries: [String: PlaybackHistoryEntry]
    ) -> [String: PlaybackHistoryEntry] {
        guard entries.count > maximumEntryCount else {
            return entries
        }
        let newest = entries.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maximumEntryCount)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.mediaKey, $0) })
    }

    private func persist(_ entries: [String: PlaybackHistoryEntry]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let document = Document(
            version: Self.currentVersion,
            entries: entries.values.sorted { $0.updatedAt > $1.updatedAt }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }
}
