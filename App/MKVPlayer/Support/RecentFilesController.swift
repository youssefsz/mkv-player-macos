import Foundation
import PlayerCore

@MainActor
final class RecentFilesController {
    nonisolated static let recentMediaKeysPreference = "recentMediaKeys"

    private let historyStore: (any PlaybackHistoryStoring)?
    private let bookmarkProvider: any BookmarkProviding
    private let defaults: UserDefaults
    private let preferenceKey: String

    init(
        historyStore: (any PlaybackHistoryStoring)?,
        bookmarkProvider: any BookmarkProviding = SecurityScopedBookmarkProvider(),
        defaults: UserDefaults = .standard,
        preferenceKey: String = RecentFilesController.recentMediaKeysPreference
    ) {
        self.historyStore = historyStore
        self.bookmarkProvider = bookmarkProvider
        self.defaults = defaults
        self.preferenceKey = preferenceKey
    }

    func loadRecentURLs() async -> [URL] {
        guard let historyStore,
              let entries = try? await historyStore.allEntries()
        else { return [] }

        let entriesByKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.mediaKey, $0) })
        let recentKeys = defaults.stringArray(forKey: preferenceKey) ?? []

        return recentKeys.compactMap { mediaKey in
            guard let entry = entriesByKey[mediaKey] else { return nil }
            if let bookmarkData = entry.bookmarkData,
               let resolved = try? bookmarkProvider.resolveBookmark(bookmarkData) {
                return resolved.url
            }
            guard entry.mediaKey.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: entry.mediaKey)
        }
    }

    func noteOpened(_ url: URL) {
        let mediaKey = MediaKey.make(for: url)
        var recentKeys = defaults.stringArray(forKey: preferenceKey) ?? []
        recentKeys.removeAll { $0 == mediaKey }
        recentKeys.insert(mediaKey, at: 0)
        defaults.set(Array(recentKeys.prefix(10)), forKey: preferenceKey)
    }

    func clear() {
        defaults.set([String](), forKey: preferenceKey)
    }
}
