import Foundation
import XCTest
@testable import PlayerCore

final class PlaybackHistoryTests: XCTestCase {
    func testRoundTripUpdateRemoveAndRemoveAll() async throws {
        let fixture = TemporaryHistoryFixture()
        defer { fixture.cleanUp() }
        let store = JSONPlaybackHistoryStore(fileURL: fixture.fileURL)
        let original = PlaybackHistoryEntry(
            url: URL(fileURLWithPath: "/tmp/movie.mkv"),
            bookmarkData: Data([1, 2, 3]),
            position: 90,
            duration: 400,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        try await store.upsert(original)
        let readOriginal = try await store.entry(for: original.mediaKey)
        XCTAssertEqual(readOriginal, original)

        var updated = original
        updated.position = 125
        try await store.upsert(updated)
        let updatedEntries = try await store.allEntries()
        XCTAssertEqual(updatedEntries, [updated])

        try await store.remove(mediaKey: original.mediaKey)
        let removedEntry = try await store.entry(for: original.mediaKey)
        XCTAssertNil(removedEntry)

        try await store.upsert(original)
        try await store.removeAll()
        let emptyEntries = try await store.allEntries()
        XCTAssertEqual(emptyEntries, [])
    }

    func testPersistsAcrossStoreInstancesAndCapsOldestEntries() async throws {
        let fixture = TemporaryHistoryFixture()
        defer { fixture.cleanUp() }
        let writer = JSONPlaybackHistoryStore(fileURL: fixture.fileURL, maximumEntryCount: 2)

        for index in 0..<3 {
            try await writer.upsert(
                PlaybackHistoryEntry(
                    url: URL(fileURLWithPath: "/tmp/movie-\(index).mkv"),
                    position: Double(index),
                    duration: 100,
                    updatedAt: Date(timeIntervalSince1970: Double(index + 1))
                )
            )
        }

        let reader = JSONPlaybackHistoryStore(fileURL: fixture.fileURL, maximumEntryCount: 2)
        let entries = try await reader.allEntries()
        XCTAssertEqual(entries.map(\.displayName), ["movie-2.mkv", "movie-1.mkv"])
        XCTAssertEqual(entries.count, 2)
    }

    func testReadsLegacyBareArrayAndMigratesOnMutation() async throws {
        let fixture = TemporaryHistoryFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyEntry = PlaybackHistoryEntry(
            url: URL(fileURLWithPath: "/tmp/legacy.mkv"),
            position: 75,
            duration: 200,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacyEntry]).write(to: fixture.fileURL)

        let store = JSONPlaybackHistoryStore(fileURL: fixture.fileURL)
        let decodedLegacyEntry = try await store.entry(for: legacyEntry.mediaKey)
        XCTAssertEqual(decodedLegacyEntry, legacyEntry)
        try await store.upsert(legacyEntry)

        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["version"] as? Int, JSONPlaybackHistoryStore.currentVersion)
    }

    func testRejectsFutureAndMalformedDocuments() async throws {
        let futureFixture = TemporaryHistoryFixture()
        defer { futureFixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: futureFixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"version\":99,\"entries\":[]}".utf8).write(to: futureFixture.fileURL)
        let futureStore = JSONPlaybackHistoryStore(fileURL: futureFixture.fileURL)

        do {
            _ = try await futureStore.allEntries()
            XCTFail("Expected unsupported version")
        } catch let error as PlaybackHistoryStoreError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }

        let malformedFixture = TemporaryHistoryFixture()
        defer { malformedFixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: malformedFixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: malformedFixture.fileURL)
        let malformedStore = JSONPlaybackHistoryStore(fileURL: malformedFixture.fileURL)

        do {
            _ = try await malformedStore.allEntries()
            XCTFail("Expected invalid data")
        } catch let error as PlaybackHistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testMediaKeyStandardizesFilePaths() {
        let first = URL(fileURLWithPath: "/tmp/folder/../movie.mkv")
        let second = URL(fileURLWithPath: "/tmp/movie.mkv")
        XCTAssertEqual(MediaKey.make(for: first), MediaKey.make(for: second))
    }
}

private struct TemporaryHistoryFixture: Sendable {
    let directoryURL: URL
    let fileURL: URL

    init() {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerCoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("history.json")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
